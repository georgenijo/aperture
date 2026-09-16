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

struct FilmRecipe: Codable, Hashable, Identifiable, Sendable {
  let id: FilmRecipeIdentifier
  let version: Int
  let displayName: String
  let baseParameters: FilmParameters

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
      && random.chance(baseParameters.lightLeakProbability)

    let resolved = FilmParameters(
      exposure: baseParameters.exposure + exposureShift,
      contrast: baseParameters.contrast,
      saturation: baseParameters.saturation,
      warmth: baseParameters.warmth + warmthShift,
      highlightRolloff: baseParameters.highlightRolloff,
      shadowCoolness: baseParameters.shadowCoolness,
      grainAmount: baseParameters.grainAmount + grainShift,
      grainSize: baseParameters.grainSize,
      halation: baseParameters.halation,
      vignette: baseParameters.vignette,
      softness: baseParameters.softness,
      chromaticAberration: baseParameters.chromaticAberration,
      lightLeakProbability: leakEnabled ? baseParameters.lightLeakProbability : 0,
      lightLeakStrength: leakEnabled
        ? baseParameters.lightLeakStrength * random.value(in: 0.72...1.0)
        : 0,
      channelSplit: baseParameters.channelSplit,
      blackCrush: baseParameters.blackCrush,
      shadowTint: baseParameters.shadowTint,
      highlightTint: baseParameters.highlightTint
    )

    return AppliedFilmRecipe(
      identifier: id,
      version: version,
      seed: seed,
      parameters: resolved,
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

struct AppliedFilmRecipe: Codable, Hashable, Sendable {
  let identifier: FilmRecipeIdentifier
  let version: Int
  let seed: UInt64
  let parameters: FilmParameters
  let resolvedSettings: FilmResolvedSettings

  /// Convenience access to the persisted still-encoding quality.
  var compressionQuality: Double { resolvedSettings.compressionQuality }
}

enum FilmRecipeCatalog {
  static let all: [FilmRecipe] = [nineteenNinetyEight, night, cinema]

  static let nineteenNinetyEight = FilmRecipe(
    id: .nineteenNinetyEight,
    version: 1,
    displayName: "1998",
    // Huji's signature is a dense disposable-camera curve with vivid source
    // colours, cool shade, warm skin/wood, and imperfect optics. Avoid broad
    // split tints here: they turn neutral walls and white highlights pink.
    baseParameters: FilmParameters(
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
    version: 1,
    displayName: "Night",
    baseParameters: FilmParameters(
      exposure: -0.08, contrast: 1.24, saturation: 1.06, warmth: 0.08,
      highlightRolloff: 0.66, shadowCoolness: 0.34,
      grainAmount: 0.42, grainSize: 1.1, halation: 0.48,
      vignette: 0.27, softness: 0.11, chromaticAberration: 0.025,
      lightLeakProbability: 0.08, lightLeakStrength: 0.2
    )
  )

  static let cinema = FilmRecipe(
    id: .cinema,
    version: 1,
    displayName: "Cinema",
    baseParameters: FilmParameters(
      exposure: 0, contrast: 0.94, saturation: 0.88, warmth: 0.06,
      highlightRolloff: 0.74, shadowCoolness: 0.18,
      grainAmount: 0.17, grainSize: 0.72, halation: 0.18,
      vignette: 0.12, softness: 0.1, chromaticAberration: 0.012,
      lightLeakProbability: 0.05, lightLeakStrength: 0.14
    )
  )

  static let legacyOriginal = FilmRecipe(
    id: .legacyOriginal,
    version: 1,
    displayName: "Original Capture",
    baseParameters: FilmParameters(
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
