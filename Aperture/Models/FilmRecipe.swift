import Foundation

struct FilmRecipeIdentifier: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let nineteenNinetyEight = FilmRecipeIdentifier(rawValue: "aperture.1998")
  static let night = FilmRecipeIdentifier(rawValue: "aperture.night")
  static let cinema = FilmRecipeIdentifier(rawValue: "aperture.cinema")
  static let legacyOriginal = FilmRecipeIdentifier(rawValue: "aperture.legacy-original")
}

struct FilmParameters: Codable, Hashable, Sendable {
  let exposure: Double
  let contrast: Double
  let saturation: Double
  let warmth: Double
  let highlightRolloff: Double
  let shadowCoolness: Double
  let grainAmount: Double
  let grainSize: Double
  let halation: Double
  let vignette: Double
  let softness: Double
  let chromaticAberration: Double
  let lightLeakProbability: Double
  let lightLeakStrength: Double
  /// Cross-process channel split (0...1); omitted from manifests written before v1.1.
  let channelSplit: Double
  /// How hard the toe is pulled to black (0...1); omitted from older manifests.
  let blackCrush: Double
  /// Split-tone offsets for the shadow and highlight bands; neutral in older manifests.
  let shadowTint: FilmColorTint
  let highlightTint: FilmColorTint

  init(
    exposure: Double,
    contrast: Double,
    saturation: Double,
    warmth: Double,
    highlightRolloff: Double,
    shadowCoolness: Double,
    grainAmount: Double,
    grainSize: Double,
    halation: Double,
    vignette: Double,
    softness: Double,
    chromaticAberration: Double,
    lightLeakProbability: Double,
    lightLeakStrength: Double,
    channelSplit: Double = 0,
    blackCrush: Double = 0,
    shadowTint: FilmColorTint = .neutral,
    highlightTint: FilmColorTint = .neutral
  ) {
    self.exposure = Self.clamp(exposure, to: -1...1, fallback: 0)
    self.contrast = Self.clamp(contrast, to: 0.75...1.5, fallback: 1)
    self.saturation = Self.clamp(saturation, to: 0.5...1.6, fallback: 1)
    self.warmth = Self.clamp(warmth, to: -1...1, fallback: 0)
    self.highlightRolloff = Self.clampUnit(highlightRolloff)
    self.shadowCoolness = Self.clampUnit(shadowCoolness)
    self.grainAmount = Self.clampUnit(grainAmount)
    self.grainSize = Self.clamp(grainSize, to: 0.25...3, fallback: 1)
    self.halation = Self.clampUnit(halation)
    self.vignette = Self.clampUnit(vignette)
    self.softness = Self.clampUnit(softness)
    self.chromaticAberration = Self.clampUnit(chromaticAberration)
    self.lightLeakProbability = Self.clampUnit(lightLeakProbability)
    self.lightLeakStrength = Self.clampUnit(lightLeakStrength)
    self.channelSplit = Self.clampUnit(channelSplit)
    self.blackCrush = Self.clampUnit(blackCrush)
    self.shadowTint = shadowTint
    self.highlightTint = highlightTint
  }

  /// The colour and tone subset, ready to bake into a `CIColorCube`.
  var colorGrade: FilmColorGrade {
    FilmColorGrade(
      exposure: exposure, contrast: contrast, saturation: saturation, warmth: warmth,
      highlightRolloff: highlightRolloff, shadowCoolness: shadowCoolness,
      channelSplit: channelSplit, blackCrush: blackCrush,
      shadowTint: shadowTint, highlightTint: highlightTint)
  }

  var isWithinSupportedBounds: Bool {
    (-1...1).contains(exposure)
      && (0.75...1.5).contains(contrast)
      && (0.5...1.6).contains(saturation)
      && (-1...1).contains(warmth)
      && Self.unitValues(self).allSatisfy { (0...1).contains($0) }
      && (0.25...3).contains(grainSize)
  }

  private enum CodingKeys: String, CodingKey {
    case exposure, contrast, saturation, warmth, highlightRolloff, shadowCoolness
    case grainAmount, grainSize, halation, vignette, softness, chromaticAberration
    case lightLeakProbability, lightLeakStrength
    case channelSplit, blackCrush, shadowTint, highlightTint
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      exposure: try values.decode(Double.self, forKey: .exposure),
      contrast: try values.decode(Double.self, forKey: .contrast),
      saturation: try values.decode(Double.self, forKey: .saturation),
      warmth: try values.decode(Double.self, forKey: .warmth),
      highlightRolloff: try values.decode(Double.self, forKey: .highlightRolloff),
      shadowCoolness: try values.decode(Double.self, forKey: .shadowCoolness),
      grainAmount: try values.decode(Double.self, forKey: .grainAmount),
      grainSize: try values.decode(Double.self, forKey: .grainSize),
      halation: try values.decode(Double.self, forKey: .halation),
      vignette: try values.decode(Double.self, forKey: .vignette),
      softness: try values.decode(Double.self, forKey: .softness),
      chromaticAberration: try values.decode(Double.self, forKey: .chromaticAberration),
      lightLeakProbability: try values.decode(Double.self, forKey: .lightLeakProbability),
      lightLeakStrength: try values.decode(Double.self, forKey: .lightLeakStrength),
      channelSplit: try values.decodeIfPresent(Double.self, forKey: .channelSplit) ?? 0,
      blackCrush: try values.decodeIfPresent(Double.self, forKey: .blackCrush) ?? 0,
      shadowTint: try values.decodeIfPresent(FilmColorTint.self, forKey: .shadowTint) ?? .neutral,
      highlightTint: try values.decodeIfPresent(FilmColorTint.self, forKey: .highlightTint)
        ?? .neutral
    )
  }

  private static func clampUnit(_ value: Double) -> Double {
    clamp(value, to: 0...1, fallback: 0)
  }

  private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double)
    -> Double
  {
    guard value.isFinite else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
  }

  private static func unitValues(_ value: FilmParameters) -> [Double] {
    [
      value.highlightRolloff, value.shadowCoolness, value.grainAmount,
      value.halation, value.vignette, value.softness,
      value.chromaticAberration, value.lightLeakProbability, value.lightLeakStrength,
      value.channelSplit, value.blackCrush,
    ]
  }
}

/// The persisted manifest schema. v1 recipes were a flat `FilmParameters`
/// knob set applied in a hard-coded order; v2 recipes carry that same order
/// (and, for future recipes, other orders) explicitly as `stages`.
enum FilmRecipeVersion {
  static let current = 2
  static let supported = 1...2
  /// The first version whose manifests persist `stages` instead of the flat
  /// v1 `parameters`.
  static let stageSchema = 2
}

struct FilmRecipe: Codable, Hashable, Identifiable, Sendable {
  let id: FilmRecipeIdentifier
  let version: Int
  let displayName: String
  let stages: [FilmStage]

  init(id: FilmRecipeIdentifier, version: Int, displayName: String, stages: [FilmStage]) {
    self.id = id
    self.version = version
    self.displayName = displayName
    self.stages = stages
  }

  /// Authoring convenience for the flat v1 knob set: expands to the fixed
  /// legacy stage order under the hood so every existing recipe definition
  /// keeps reading the same numbers it always has.
  init(id: FilmRecipeIdentifier, version: Int, displayName: String, parameters: FilmParameters) {
    self.init(
      id: id, version: version, displayName: displayName,
      stages: FilmStage.legacyPipeline(parameters: parameters, identifier: id))
  }

  func resolve(
    seed: UInt64,
    capturedAt: Date,
    options: FilmProcessingOptions,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> AppliedFilmRecipe {
    let stampConfiguration =
      id == .nineteenNinetyEight
      ? DateStampConfiguration(
        mode: .current, format: .digitalDateTime, localeIdentifier: "en_US_POSIX")
      : options.dateStamp
    var random = SeededRandomNumberGenerator(seed: seed)
    let exposureShift = random.value(in: -0.045...0.045)
    let warmthShift = random.value(in: -0.025...0.025)
    let grainShift = random.value(in: -0.035...0.035)
    let leakEnabled =
      options.lightLeaksEnabled
      && random.chance(stages.lightLeak?.probability ?? 0)
    let leakStrengthScale = leakEnabled ? random.value(in: 0.72...1.0) : nil

    let resolvedStages: [FilmStage] = stages.map { stage in
      switch stage {
      case .colorGrade(let grade):
        return .colorGrade(
          FilmColorGrade(
            exposure: grade.exposure + exposureShift,
            contrast: grade.contrast,
            saturation: grade.saturation,
            warmth: grade.warmth + warmthShift,
            highlightRolloff: grade.highlightRolloff,
            shadowCoolness: grade.shadowCoolness,
            channelSplit: grade.channelSplit,
            blackCrush: grade.blackCrush,
            shadowTint: grade.shadowTint,
            highlightTint: grade.highlightTint
          ))
      case .grain(var grainStage):
        grainStage.amount = Self.clampUnit(grainStage.amount + grainShift)
        return .grain(grainStage)
      case .lightLeak(var leakStage):
        leakStage.probability = leakEnabled ? leakStage.probability : 0
        leakStage.strength =
          leakEnabled ? Self.clampUnit(leakStage.strength * (leakStrengthScale ?? 1)) : 0
        return .lightLeak(leakStage)
      default:
        return stage
      }
    }

    return AppliedFilmRecipe(
      identifier: id,
      version: version,
      seed: seed,
      stages: resolvedStages,
      resolvedSettings: FilmResolvedSettings(
        lightLeakApplied: leakEnabled,
        dateStampConfiguration: stampConfiguration,
        dateStampText: ApertureDateStampFormatter.string(
          for: capturedAt,
          configuration: stampConfiguration,
          timeZone: timeZone
        ),
        timeZoneIdentifier: timeZone.identifier,
        compressionQuality: options.photoQuality.compressionQuality
      )
    )
  }

  private static func clampUnit(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}

struct FilmProcessingOptions: Codable, Hashable, Sendable {
  let lightLeaksEnabled: Bool
  let dateStamp: DateStampConfiguration
  let photoQuality: PhotoQualityPreference

  init(
    lightLeaksEnabled: Bool,
    dateStamp: DateStampConfiguration,
    photoQuality: PhotoQualityPreference = .balanced
  ) {
    self.lightLeaksEnabled = lightLeaksEnabled
    self.dateStamp = dateStamp
    self.photoQuality = photoQuality
  }
}

struct FilmResolvedSettings: Codable, Hashable, Sendable {
  let lightLeakApplied: Bool
  let dateStampConfiguration: DateStampConfiguration
  /// Rendering consumes this persisted text, never the current locale or time zone.
  let dateStampText: String?
  let timeZoneIdentifier: String
  /// Older item metadata omitted this field; those items decode as balanced.
  let compressionQuality: Double

  init(
    lightLeakApplied: Bool,
    dateStampConfiguration: DateStampConfiguration,
    dateStampText: String?,
    timeZoneIdentifier: String,
    compressionQuality: Double = PhotoQualityPreference.balanced.compressionQuality
  ) {
    self.lightLeakApplied = lightLeakApplied
    self.dateStampConfiguration = dateStampConfiguration
    self.dateStampText = dateStampText
    self.timeZoneIdentifier = timeZoneIdentifier
    guard compressionQuality.isFinite else {
      self.compressionQuality = PhotoQualityPreference.balanced.compressionQuality
      return
    }
    self.compressionQuality = min(max(compressionQuality, 0), 1)
  }

  private enum CodingKeys: String, CodingKey {
    case lightLeakApplied, dateStampConfiguration, dateStampText
    case timeZoneIdentifier, compressionQuality
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      lightLeakApplied: try values.decode(Bool.self, forKey: .lightLeakApplied),
      dateStampConfiguration: try values.decode(
        DateStampConfiguration.self, forKey: .dateStampConfiguration),
      dateStampText: try values.decodeIfPresent(String.self, forKey: .dateStampText),
      timeZoneIdentifier: try values.decode(String.self, forKey: .timeZoneIdentifier),
      compressionQuality: try values.decodeIfPresent(Double.self, forKey: .compressionQuality)
        ?? PhotoQualityPreference.balanced.compressionQuality
    )
  }
}

struct AppliedFilmRecipe: Hashable, Sendable {
  let identifier: FilmRecipeIdentifier
  let version: Int
  let seed: UInt64
  let stages: [FilmStage]
  let resolvedSettings: FilmResolvedSettings

  init(
    identifier: FilmRecipeIdentifier,
    version: Int,
    seed: UInt64,
    stages: [FilmStage],
    resolvedSettings: FilmResolvedSettings
  ) {
    self.identifier = identifier
    self.version = version
    self.seed = seed
    self.stages = stages
    self.resolvedSettings = resolvedSettings
  }

  /// Convenience access to the persisted still-encoding quality.
  var compressionQuality: Double { resolvedSettings.compressionQuality }
  var colorGrade: FilmColorGrade { stages.colorGrade ?? .neutral }
  var halation: HalationStage? { stages.halation }
  var softness: SoftnessStage? { stages.softness }
  var chromaticAberration: ChromaticAberrationStage? { stages.chromaticAberration }
  var grain: GrainStage? { stages.grain }
  var lightLeak: LightLeakStage? { stages.lightLeak }
  var vignette: VignetteStage? { stages.vignette }
  var dateStamp: DateStampStage? { stages.dateStamp }
}

extension AppliedFilmRecipe: Codable {
  private enum CodingKeys: String, CodingKey {
    case identifier, version, seed, stages, parameters, resolvedSettings
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let identifier = try values.decode(FilmRecipeIdentifier.self, forKey: .identifier)
    var version = try values.decode(Int.self, forKey: .version)
    let stages: [FilmStage]
    if let decodedStages = try values.decodeIfPresent([FilmStage].self, forKey: .stages) {
      stages = decodedStages
    } else {
      // Pre-#17 manifests persisted a flat `FilmParameters` knob set; expand
      // it into the equivalent fixed-order stage list on read. The values
      // are the v1 pipeline's, so output is unchanged, but the in-memory
      // recipe is now stage-shaped and re-encodes as the stage schema, so it
      // reports the stage schema version rather than a hybrid.
      let legacyParameters = try values.decode(FilmParameters.self, forKey: .parameters)
      stages = FilmStage.legacyPipeline(parameters: legacyParameters, identifier: identifier)
      version = max(version, FilmRecipeVersion.stageSchema)
    }
    self.init(
      identifier: identifier,
      version: version,
      seed: try values.decode(UInt64.self, forKey: .seed),
      stages: stages,
      resolvedSettings: try values.decode(FilmResolvedSettings.self, forKey: .resolvedSettings)
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(identifier, forKey: .identifier)
    try container.encode(version, forKey: .version)
    try container.encode(seed, forKey: .seed)
    try container.encode(stages, forKey: .stages)
    try container.encode(resolvedSettings, forKey: .resolvedSettings)
  }
}

enum FilmRecipeCatalog {
  static let all: [FilmRecipe] = [nineteenNinetyEight, night, cinema]

  static let nineteenNinetyEight = FilmRecipe(
    id: .nineteenNinetyEight,
    version: FilmRecipeVersion.current,
    displayName: "1998",
    // Huji's signature is a dense disposable-camera curve with vivid source
    // colours, cool shade, warm skin/wood, and imperfect optics. Avoid broad
    // split tints here: they turn neutral walls and white highlights pink.
    parameters: FilmParameters(
      exposure: 0.015, contrast: 1.22, saturation: 1.42, warmth: 0.10,
      highlightRolloff: 0.16, shadowCoolness: 0.42,
      grainAmount: 0.24, grainSize: 0.56, halation: 0.16,
      vignette: 0.075, softness: 0.72, chromaticAberration: 0.78,
      lightLeakProbability: 0.46, lightLeakStrength: 0.48,
      channelSplit: 0.07, blackCrush: 0.43,
      shadowTint: FilmColorTint(red: -0.018, green: 0.012, blue: 0.045),
      highlightTint: FilmColorTint(red: 0.014, green: 0.006, blue: -0.012)
    )
  )

  static let night = FilmRecipe(
    id: .night,
    version: FilmRecipeVersion.current,
    displayName: "Night",
    parameters: FilmParameters(
      exposure: -0.08, contrast: 1.24, saturation: 1.06, warmth: 0.08,
      highlightRolloff: 0.66, shadowCoolness: 0.34,
      grainAmount: 0.42, grainSize: 1.1, halation: 0.48,
      vignette: 0.27, softness: 0.11, chromaticAberration: 0.025,
      lightLeakProbability: 0.08, lightLeakStrength: 0.2
    )
  )

  static let cinema = FilmRecipe(
    id: .cinema,
    version: FilmRecipeVersion.current,
    displayName: "Cinema",
    parameters: FilmParameters(
      exposure: 0, contrast: 0.94, saturation: 0.88, warmth: 0.06,
      highlightRolloff: 0.74, shadowCoolness: 0.18,
      grainAmount: 0.17, grainSize: 0.72, halation: 0.18,
      vignette: 0.12, softness: 0.1, chromaticAberration: 0.012,
      lightLeakProbability: 0.05, lightLeakStrength: 0.14
    )
  )

  static let legacyOriginal = FilmRecipe(
    id: .legacyOriginal,
    version: FilmRecipeVersion.current,
    displayName: "Original Capture",
    parameters: FilmParameters(
      exposure: 0, contrast: 1, saturation: 1, warmth: 0,
      highlightRolloff: 0, shadowCoolness: 0,
      grainAmount: 0, grainSize: 1, halation: 0,
      vignette: 0, softness: 0, chromaticAberration: 0,
      lightLeakProbability: 0, lightLeakStrength: 0
    )
  )

  static func recipe(for identifier: FilmRecipeIdentifier) -> FilmRecipe? {
    (all + [legacyOriginal]).first { $0.id == identifier }
  }
}
