import CryptoKit
import Foundation

enum LabFingerprint {
  static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func of<T: Encodable>(_ value: T) throws -> String {
    "sha256:" + SHA256.hash(data: try canonicalJSON(value)).map { String(format: "%02x", $0) }
      .joined()
  }

  /// The unresolved shipping recipe; a change here means a candidate was
  /// authored against a different baseline.
  static func baseRecipe() throws -> String { try of(LabRecipeBuilder.baseRecipe) }
}

/// A Film Lab recipe candidate. It is authoring data for a later, deliberately
/// versioned app recipe: not an app-library manifest and not a settings file.
struct LabCandidate: Codable, Sendable {
  static let schemaName = "aperture.film-lab.candidate"
  static let schemaVersion = 1
  static let maximumNameLength = 80

  struct Base: Codable, Sendable {
    let recipeId: String
    let recipeVersion: Int
    let fingerprint: String
  }

  struct ControlSchemaReference: Codable, Sendable {
    let version: Int
    let digest: String
  }

  struct Provenance: Codable, Sendable {
    let tool: String
    let toolVersion: String
    let createdAt: String
    let gitCommit: String?
    let renderer: String
  }

  let schema: String
  let schemaVersion: Int
  let name: String
  let controls: [String: LabControlValue]
  let context: LabContextInput
  let base: Base
  let controlSchema: ControlSchemaReference
  let provenance: Provenance?
  /// The exact applied recipe the controls produced for `context`. The app
  /// decodes this shape directly, so its UInt64 seed stays a JSON integer;
  /// the browser only ever handles this document as opaque text.
  let appliedRecipe: AppliedFilmRecipe?
  let appliedRecipeFingerprint: String?

  static let allowedKeys: Set<String> = [
    "schema", "schemaVersion", "name", "controls", "context", "base", "controlSchema",
    "provenance", "appliedRecipe", "appliedRecipeFingerprint",
  ]

  static func validateName(_ raw: String) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= maximumNameLength,
      name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw LabError(
        "invalid-name", "A look name must be 1–\(maximumNameLength) printable characters.")
    }
    return name
  }

  static func make(
    name: String, controls: ValidatedControls, context: LabContext, schema: ControlSchema,
    provenance: Provenance
  ) throws -> (candidate: LabCandidate, text: String) {
    let applied = LabRecipeBuilder.build(controls: controls, context: context)
    let candidate = LabCandidate(
      schema: schemaName,
      schemaVersion: schemaVersion,
      name: try validateName(name),
      controls: controls.values,
      context: context.input,
      base: Base(
        recipeId: LabRecipeBuilder.baseRecipe.id.rawValue,
        recipeVersion: LabRecipeBuilder.baseRecipe.version,
        fingerprint: try LabFingerprint.baseRecipe()),
      controlSchema: ControlSchemaReference(version: schema.version, digest: schema.digest),
      provenance: provenance,
      appliedRecipe: applied,
      appliedRecipeFingerprint: try LabFingerprint.of(applied))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let text = String(decoding: try encoder.encode(candidate), as: UTF8.self) + "\n"
    return (candidate, text)
  }

  struct Imported: Sendable {
    let name: String
    let controls: ValidatedControls
    let context: LabContext
    let applied: AppliedFilmRecipe
    let verifiedSnapshot: Bool
  }

  /// Rebuilds a candidate from its validated controls and context only.
  /// An included applied snapshot is decoded for comparison and never
  /// rendered: several stage initialisers accept unvalidated fields.
  static func importText(_ text: String, schema: ControlSchema) throws -> Imported {
    let data = Data(text.utf8)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LabError("invalid-json", "The file is not a JSON object.")
    }
    let unknown = Set(object.keys).subtracting(allowedKeys)
    guard unknown.isEmpty else {
      throw LabError(
        "unknown-field", "Unsupported field \(unknown.sorted().first.map { "\"\($0.prefix(40))\"" } ?? "").")
    }
    let candidate: LabCandidate
    do {
      candidate = try JSONDecoder().decode(LabCandidate.self, from: data)
    } catch {
      throw LabError("invalid-candidate", "The file is not a Film Lab candidate.")
    }
    guard candidate.schema == schemaName, candidate.schemaVersion == schemaVersion else {
      throw LabError("unsupported-schema", "Unsupported candidate schema or version.")
    }
    guard candidate.base.recipeId == LabRecipeBuilder.baseRecipe.id.rawValue,
      candidate.base.recipeVersion == LabRecipeBuilder.baseRecipe.version,
      candidate.base.fingerprint == (try LabFingerprint.baseRecipe())
    else {
      throw LabError(
        "unsupported-baseline",
        "The candidate was authored against a different base recipe than this build ships.")
    }
    guard candidate.controlSchema.version == schema.version else {
      throw LabError("unsupported-control-schema", "Unsupported control-schema version.")
    }
    let name = try validateName(candidate.name)
    let controls = try schema.validate(candidate.controls)
    let context = try LabContext.validate(candidate.context)
    let rebuilt = LabRecipeBuilder.build(controls: controls, context: context)
    let rebuiltFingerprint = try LabFingerprint.of(rebuilt)

    if candidate.appliedRecipeFingerprint != nil, candidate.appliedRecipe == nil {
      throw LabError("snapshot-incomplete", "A fingerprint was supplied without its applied recipe.")
    }
    if let snapshot = candidate.appliedRecipe {
      // The decoded comparison keeps integers such as the UInt64 seed exact;
      // the raw comparison catches malformed fields that the app's lenient
      // decoders would normalise away (e.g. a short crosstalk matrix).
      let rawSnapshot = try? JSONDecoder().decode([String: LabJSONShape].self, from: data)["appliedRecipe"]
      let rebuiltShape = try JSONDecoder().decode(LabJSONShape.self, from: try JSONEncoder().encode(rebuilt))
      guard rawSnapshot == rebuiltShape,
        snapshot == rebuilt,
        (try LabFingerprint.of(snapshot)) == rebuiltFingerprint,
        candidate.appliedRecipeFingerprint == nil
          || candidate.appliedRecipeFingerprint == rebuiltFingerprint
      else {
        throw LabError(
          "snapshot-mismatch",
          "The included applied recipe does not match what these controls produce; refusing to change the look silently.")
      }
    } else if candidate.controlSchema.digest != schema.digest {
      // Without a snapshot there is no proof the control meanings still match.
      throw LabError(
        "control-schema-changed",
        "controls.json changed since this candidate was written and it carries no applied snapshot to verify against.")
    }
    return Imported(
      name: name, controls: controls, context: context, applied: rebuilt,
      verifiedSnapshot: candidate.appliedRecipe != nil)
  }
}

/// A JSON value decoded exactly as written, for structural comparison: the
/// same keys, array lengths and value kinds (a boolean never equals a number).
/// Numbers are compared as correctly rounded doubles; integer exactness, such
/// as the UInt64 seed, is enforced by the typed comparison alongside it.
indirect enum LabJSONShape: Decodable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([LabJSONShape])
  case object([String: LabJSONShape])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([LabJSONShape].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: LabJSONShape].self))
    }
  }
}
