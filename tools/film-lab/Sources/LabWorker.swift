import Foundation

/// A minimal JSON value for protocol responses.
enum LabJSON: Encodable {
  case string(String)
  case number(Double)
  case int(Int)
  case bool(Bool)
  case null
  case array([LabJSON])
  case object([String: LabJSON])

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  static func optional(_ value: String?) -> LabJSON { value.map(LabJSON.string) ?? .null }
}

/// One NDJSON request from `server.py`. Paths are server-owned files inside
/// the session directory; image bytes never travel over the protocol.
struct LabRequest: Decodable {
  struct Size: Decodable {
    let kind: String
    let maxDimension: Int?
  }

  let id: Int
  let op: String
  let source: String?
  let output: String?
  let controls: [String: LabControlValue]?
  let context: LabContextInput?
  let size: Size?
  let quality: Double?
  let name: String?
  let text: String?
  let provenance: LabCandidate.Provenance?
  let milliseconds: Int?
}

struct LabWorker {
  static let protocolVersion = 1
  static let maximumLineBytes = 1 << 20

  let schema: ControlSchema
  let root: URL
  let testHooks: Bool
  let maximumPixels: Int

  func run() {
    while let line = readLine(strippingNewline: true) {
      if line.isEmpty { continue }
      let response = autoreleasepool { handle(line: line) }
      FileHandle.standardOutput.write(response)
    }
  }

  func handle(line: String) -> Data {
    var requestID = -1
    let result: Result<LabJSON, Error>
    if line.utf8.count > Self.maximumLineBytes {
      result = .failure(LabError("request-too-large", "The request line is too large."))
    } else {
      do {
        let request = try JSONDecoder().decode(LabRequest.self, from: Data(line.utf8))
        requestID = request.id
        result = .success(try perform(request))
      } catch {
        result = .failure(error)
      }
    }
    return Self.encodeResponse(id: requestID, result: result)
  }

  static func encodeResponse(id: Int, result: Result<LabJSON, Error>) -> Data {
    var envelope: [String: LabJSON] = ["id": .int(id)]
    switch result {
    case .success(let value):
      envelope["ok"] = .bool(true)
      envelope["result"] = value
    case .failure(let error):
      envelope["ok"] = .bool(false)
      let (code, message) = describe(error)
      envelope["error"] = .object(["code": .string(code), "message": .string(message)])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = (try? encoder.encode(LabJSON.object(envelope))) ?? Data("{\"id\":-1,\"ok\":false}".utf8)
    data.append(0x0A)
    return data
  }

  static func describe(_ error: Error) -> (String, String) {
    switch error {
    case let error as LabError:
      return (error.code, error.message)
    case let error as FilmProcessorError:
      return ("render-failed", error.errorDescription ?? "Rendering failed.")
    case is DecodingError:
      return ("bad-request", "The request did not match the renderer protocol.")
    default:
      return ("internal", "The renderer failed unexpectedly.")
    }
  }

  func perform(_ request: LabRequest) throws -> LabJSON {
    switch request.op {
    case "hello":
      return .object([
        "protocol": .int(Self.protocolVersion),
        "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
        "controlSchemaVersion": .int(schema.version),
        "controlSchemaDigest": .string(schema.digest),
        "baseRecipeId": .string(LabRecipeBuilder.baseRecipe.id.rawValue),
        "baseRecipeVersion": .int(LabRecipeBuilder.baseRecipe.version),
        "baseRecipeFingerprint": .string(try LabFingerprint.baseRecipe()),
        "handlers": .array(LabRecipeBuilder.handlers.map { .string($0.id) }),
      ])

    case "inspect":
      let info = try LabImaging.inspect(try sourceURL(request), maximumPixels: maximumPixels)
      return .object([
        "type": .string(info.typeIdentifier),
        "width": .int(info.width),
        "height": .int(info.height),
        "orientation": .int(Int(info.orientation)),
        "colorModel": .optional(info.colorModel),
        "profileName": .optional(info.profileName),
      ])

    case "original":
      let size = try renderSize(request.size, allowFull: false)
      let started = Date()
      let rendered = try LabImaging.renderJPEG(
        source: try sourceURL(request), recipe: LabImaging.originalRecipe, renderSize: size,
        quality: 0.9, maximumPixels: maximumPixels)
      try LabImaging.writeAtomically(rendered.data, to: try outputURL(request))
      return .object([
        "width": .int(rendered.width), "height": .int(rendered.height),
        "bytes": .int(rendered.data.count), "renderMs": .int(Self.milliseconds(since: started)),
      ])

    case "resolve":
      let (controls, context) = try validatedInputs(request)
      let applied = LabRecipeBuilder.build(controls: controls, context: context)
      return try describe(applied, controls: controls, context: context)

    case "render":
      let (controls, context) = try validatedInputs(request)
      let size = try renderSize(request.size, allowFull: true)
      let applied = LabRecipeBuilder.build(controls: controls, context: context)
      // Full-resolution output uses the recipe's persisted Photo Quality,
      // like a capture; previews use a lighter fixed quality.
      let quality: Double
      if case .full = size.kind {
        quality = applied.compressionQuality
      } else {
        quality = min(max(request.quality ?? 0.85, 0.5), 1)
      }
      let started = Date()
      let rendered = try LabImaging.renderJPEG(
        source: try sourceURL(request), recipe: applied, renderSize: size, quality: quality,
        maximumPixels: maximumPixels)
      try LabImaging.writeAtomically(rendered.data, to: try outputURL(request))
      var summary = try describe(applied, controls: controls, context: context, includeText: false)
      if case .object(var fields) = summary {
        fields["width"] = .int(rendered.width)
        fields["height"] = .int(rendered.height)
        fields["bytes"] = .int(rendered.data.count)
        fields["quality"] = .number(quality)
        fields["renderMs"] = .int(Self.milliseconds(since: started))
        summary = .object(fields)
      }
      return summary

    case "candidate":
      let (controls, context) = try validatedInputs(request)
      guard let provenance = request.provenance else {
        throw LabError("bad-request", "Candidate provenance is required.")
      }
      let made = try LabCandidate.make(
        name: request.name ?? "", controls: controls, context: context, schema: schema,
        provenance: provenance)
      return .object([
        "name": .string(made.candidate.name),
        "text": .string(made.text),
        "appliedFingerprint": .optional(made.candidate.appliedRecipeFingerprint),
      ])

    case "import":
      guard let text = request.text else { throw LabError("bad-request", "Missing text.") }
      let imported = try LabCandidate.importText(text, schema: schema)
      var summary = try describe(
        imported.applied, controls: imported.controls, context: imported.context)
      if case .object(var fields) = summary {
        fields["name"] = .string(imported.name)
        fields["verifiedSnapshot"] = .bool(imported.verifiedSnapshot)
        summary = .object(fields)
      }
      return summary

    case "crash" where testHooks:
      exit(3)

    case "sleep" where testHooks:
      Thread.sleep(forTimeInterval: Double(min(max(request.milliseconds ?? 0, 0), 60_000)) / 1000)
      return .object([:])

    default:
      throw LabError("unknown-op", "Unknown renderer operation.")
    }
  }

  private func describe(
    _ applied: AppliedFilmRecipe, controls: ValidatedControls, context: LabContext,
    includeText: Bool = true
  ) throws -> LabJSON {
    var fields: [String: LabJSON] = [
      "controls": .object(
        controls.values.mapValues {
          switch $0 {
          case .number(let value): .number(value)
          case .choice(let value): .string(value)
          }
        }),
      "context": .object([
        "seed": .string(context.input.seed),
        "capturedAt": .string(context.input.capturedAt),
        "timeZone": .string(context.input.timeZone),
        "photoQuality": .string(context.input.photoQuality),
      ]),
      "appliedFingerprint": .string(try LabFingerprint.of(applied)),
      "isBaseline": .bool(controls.values.isEmpty),
      "lightLeakApplied": .bool(applied.resolvedSettings.lightLeakApplied),
      "dateStampText": .optional(applied.resolvedSettings.dateStampText),
      "compressionQuality": .number(applied.compressionQuality),
    ]
    if includeText {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      fields["appliedText"] = .string(String(decoding: try encoder.encode(applied), as: UTF8.self))
    }
    return .object(fields)
  }

  private func validatedInputs(_ request: LabRequest) throws -> (ValidatedControls, LabContext) {
    guard let context = request.context else {
      throw LabError("bad-request", "Missing render context.")
    }
    return (try schema.validate(request.controls ?? [:]), try LabContext.validate(context))
  }

  private func renderSize(_ size: LabRequest.Size?, allowFull: Bool) throws -> FilmRenderSize {
    switch size?.kind {
    case "full" where allowFull:
      return .full
    case "preview":
      guard let dimension = size?.maxDimension, (64...4096).contains(dimension) else {
        throw LabError("bad-request", "Preview size must be 64–4096 pixels.")
      }
      return .preview(maxPixelDimension: dimension)
    default:
      throw LabError("bad-request", "Unsupported render size.")
    }
  }

  // MARK: - Paths

  private func sourceURL(_ request: LabRequest) throws -> URL {
    guard let path = request.source else { throw LabError("bad-request", "Missing source.") }
    let url = try contained(path, missingCode: "missing-source")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { throw LabError("missing-source", "The source photo no longer exists.") }
    return url
  }

  private func outputURL(_ request: LabRequest) throws -> URL {
    guard let path = request.output else { throw LabError("bad-request", "Missing output.") }
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$", options: .regularExpression) != nil
    else { throw LabError("bad-path", "Invalid output name.") }
    let parent = try contained(url.deletingLastPathComponent().path)
    let output = parent.appendingPathComponent(name)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    {
      throw LabError("bad-path", "Refusing to write through a symbolic link.")
    }
    return output
  }

  /// Absolute, `..`-free, and inside the session root once every symbolic
  /// link is resolved with `realpath(3)` (which, unlike Foundation's
  /// resolver, never rewrites `/private/var` to `/var`).
  private func contained(_ path: String, missingCode: String = "bad-path") throws -> URL {
    guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), path.count < 1024
    else { throw LabError("bad-path", "Paths must be absolute session paths.") }
    guard let resolved = Self.realPath(path) else {
      throw LabError(missingCode, missingCode == "bad-path" ? "Path does not exist." : "The source photo no longer exists.")
    }
    guard let rootPath = Self.realPath(root.path),
      resolved == rootPath || resolved.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    else {
      throw LabError("bad-path", "Path is outside the session directory.")
    }
    return URL(fileURLWithPath: resolved)
  }

  static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  static func milliseconds(since start: Date) -> Int {
    Int((Date().timeIntervalSince(start) * 1000).rounded())
  }
}
