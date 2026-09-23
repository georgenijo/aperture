import CryptoKit
import Foundation

/// A tool-level failure with a stable machine-readable code and a message
/// that is safe to show in the browser.
struct LabError: Error, CustomStringConvertible {
  let code: String
  let message: String

  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }

  var description: String { "\(code): \(message)" }
}

/// One authoring value: sliders carry finite numbers, mode selectors carry
/// one of their declared option strings.
enum LabControlValue: Codable, Hashable, Sendable {
  case number(Double)
  case choice(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let text = try? container.decode(String.self) {
      self = .choice(text)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "A control value must be a number or a string.")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .number(let value): try container.encode(value)
    case .choice(let value): try container.encode(value)
    }
  }
}

struct ControlDefinition: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case number(min: Double, max: Double, neutral: Double)
    case choice(options: [String], neutral: String)
  }

  let id: String
  let group: String
  let kind: Kind

  var neutralValue: LabControlValue {
    switch kind {
    case .number(_, _, let neutral): .number(neutral)
    case .choice(_, let neutral): .choice(neutral)
    }
  }
}

/// `controls.json`, parsed once per process. It is the single authority for
/// which controls exist, their limits and neutral values; Python and the
/// browser read the same bytes, and the SHA-256 of those bytes is the
/// schema digest recorded in every candidate.
struct ControlSchema: Sendable {
  static let schemaName = "aperture.film-lab.controls"

  let version: Int
  let digest: String
  let baseRecipeID: String
  let baseRecipeVersion: Int
  let controls: [ControlDefinition]
  let defaultContext: LabContextInput
  let photoQualityOptions: [String]

  func definition(for id: String) -> ControlDefinition? {
    controls.first { $0.id == id }
  }

  static func load(from url: URL) throws -> ControlSchema {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw LabError("schema-unreadable", "Cannot read \(url.path).")
    }
    return try parse(data)
  }

  static func parse(_ data: Data) throws -> ControlSchema {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["schema"] as? String == schemaName,
      let version = root["version"] as? Int,
      let base = root["baseRecipe"] as? [String: Any],
      let baseID = base["id"] as? String,
      let baseVersion = base["version"] as? Int,
      let groups = root["groups"] as? [[String: Any]],
      let rawControls = root["controls"] as? [[String: Any]],
      let context = root["context"] as? [String: Any]
    else {
      throw LabError("schema-invalid", "controls.json does not have the expected shape.")
    }
    let groupIDs = Set(groups.compactMap { $0["id"] as? String })
    var controls: [ControlDefinition] = []
    for raw in rawControls {
      guard let id = raw["id"] as? String, let group = raw["group"] as? String,
        groupIDs.contains(group), let kind = raw["kind"] as? String
      else {
        throw LabError("schema-invalid", "A control is missing id, group or kind.")
      }
      guard !controls.contains(where: { $0.id == id }) else {
        throw LabError("schema-invalid", "Control \(id) is declared twice.")
      }
      switch kind {
      case "number":
        guard let min = (raw["min"] as? NSNumber)?.doubleValue,
          let max = (raw["max"] as? NSNumber)?.doubleValue,
          let neutral = (raw["neutral"] as? NSNumber)?.doubleValue,
          min.isFinite, max.isFinite, min < max, (min...max).contains(neutral)
        else {
          throw LabError("schema-invalid", "Control \(id) has invalid numeric limits.")
        }
        controls.append(
          ControlDefinition(id: id, group: group, kind: .number(min: min, max: max, neutral: neutral)))
      case "choice":
        guard let options = raw["options"] as? [String], !options.isEmpty,
          Set(options).count == options.count,
          let neutral = raw["neutral"] as? String, options.contains(neutral)
        else {
          throw LabError("schema-invalid", "Control \(id) has invalid options.")
        }
        controls.append(
          ControlDefinition(id: id, group: group, kind: .choice(options: options, neutral: neutral)))
      default:
        throw LabError("schema-invalid", "Control \(id) has unknown kind \(kind).")
      }
    }
    func contextDefault(_ key: String) -> String? {
      (context[key] as? [String: Any])?["default"] as? String
    }
    guard let seed = contextDefault("seed"), let capturedAt = contextDefault("capturedAt"),
      let timeZone = contextDefault("timeZone"), let quality = contextDefault("photoQuality"),
      let qualityOptions = (context["photoQuality"] as? [String: Any])?["options"] as? [String]
    else {
      throw LabError("schema-invalid", "controls.json context defaults are incomplete.")
    }
    return ControlSchema(
      version: version,
      digest: "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      baseRecipeID: baseID,
      baseRecipeVersion: baseVersion,
      controls: controls,
      defaultContext: LabContextInput(
        seed: seed, capturedAt: capturedAt, timeZone: timeZone, photoQuality: quality),
      photoQualityOptions: qualityOptions)
  }

  /// Validates every supplied value against its declaration and drops values
  /// equal to the neutral one, so "unset" and "set to neutral" are the same
  /// canonical (and exactly identity) settings.
  func validate(_ controls: [String: LabControlValue]) throws -> ValidatedControls {
    var canonical: [String: LabControlValue] = [:]
    for (id, value) in controls {
      guard let definition = definition(for: id) else {
        throw LabError("unknown-control", "Unknown control \"\(Self.printable(id))\".")
      }
      switch (definition.kind, value) {
      case (.number(let min, let max, let neutral), .number(let number)):
        guard number.isFinite, number >= min, number <= max else {
          throw LabError(
            "control-out-of-range", "\(id) must be a finite number from \(min) to \(max).")
        }
        if number != neutral { canonical[id] = .number(number) }
      case (.choice(let options, let neutral), .choice(let option)):
        guard options.contains(option) else {
          throw LabError(
            "control-out-of-range", "\(id) must be one of \(options.joined(separator: ", ")).")
        }
        if option != neutral { canonical[id] = .choice(option) }
      default:
        throw LabError("control-kind-mismatch", "\(id) has the wrong value type.")
      }
    }
    return ValidatedControls(values: canonical)
  }

  private static func printable(_ text: String) -> String {
    String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.prefix(40))
  }
}

/// Controls that passed `ControlSchema.validate`; neutral values are absent.
struct ValidatedControls: Hashable, Sendable {
  let values: [String: LabControlValue]

  static let empty = ValidatedControls(values: [:])

  func number(_ id: String) -> Double? {
    if case .number(let value)? = values[id] { return value }
    return nil
  }

  func choice(_ id: String) -> String? {
    if case .choice(let value)? = values[id] { return value }
    return nil
  }
}

/// The authoring context as text: the seed stays a decimal string end to end
/// so a browser never rounds a UInt64 above 2^53.
struct LabContextInput: Codable, Hashable, Sendable {
  let seed: String
  let capturedAt: String
  let timeZone: String
  let photoQuality: String
}

/// A validated, explicit render context. Nothing here is read from the clock,
/// locale or a random source, so the same context resolves identically.
struct LabContext: Hashable, Sendable {
  let seed: UInt64
  let capturedAt: Date
  let timeZone: TimeZone
  let photoQuality: PhotoQualityPreference

  var input: LabContextInput {
    LabContextInput(
      seed: String(seed),
      capturedAt: Self.canonicalInstant(capturedAt),
      timeZone: timeZone.identifier,
      photoQuality: photoQuality.rawValue)
  }

  static func validate(_ input: LabContextInput) throws -> LabContext {
    let seedText = input.seed
    guard !seedText.isEmpty, seedText.count <= 20,
      seedText.allSatisfy({ $0.isASCII && $0.isNumber }),
      seedText == "0" || !seedText.hasPrefix("0"),
      let seed = UInt64(seedText)
    else {
      throw LabError(
        "invalid-seed", "The seed must be a decimal integer from 0 to 18446744073709551615.")
    }
    guard input.capturedAt.count <= 40, let capturedAt = parseInstant(input.capturedAt) else {
      throw LabError(
        "invalid-captured-at",
        "The capture instant must be ISO 8601 with a zone, e.g. 2026-09-15T19:20:00Z.")
    }
    guard input.timeZone.count <= 64,
      input.timeZone == "UTC" || input.timeZone == "GMT"
        || TimeZone.knownTimeZoneIdentifiers.contains(input.timeZone),
      let timeZone = TimeZone(identifier: input.timeZone)
    else {
      throw LabError("invalid-time-zone", "Unknown time zone \"\(input.timeZone.prefix(64))\".")
    }
    guard let quality = PhotoQualityPreference(rawValue: input.photoQuality) else {
      throw LabError("invalid-photo-quality", "Unknown photo quality.")
    }
    return LabContext(seed: seed, capturedAt: capturedAt, timeZone: timeZone, photoQuality: quality)
  }

  /// Whole seconds between 1970 and 2100, with an explicit zone designator.
  static func parseInstant(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: text),
      date.timeIntervalSince1970 >= 0, date.timeIntervalSince1970 < 4_102_444_800,
      date.timeIntervalSince1970.rounded() == date.timeIntervalSince1970
    else { return nil }
    return date
  }

  static func canonicalInstant(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
  }
}
