import Foundation

struct FilmRecipeIdentifier: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let nineteenNinetyEight = FilmRecipeIdentifier(rawValue: "aperture.1998")
  static let night = FilmRecipeIdentifier(rawValue: "aperture.night")
  static let cinema = FilmRecipeIdentifier(rawValue: "aperture.cinema")
  static let digicam = FilmRecipeIdentifier(rawValue: "aperture.digicam")
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
  static let current = 5
  static let supported = 1...5
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
        mode: .current, format: .huji, localeIdentifier: "en_US_POSIX")
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
            highlightTint: grade.highlightTint,
            blueGreenSuppression: grade.blueGreenSuppression,
            blueDarken: grade.blueDarken,
            redHueShift: grade.redHueShift
          ))
      case .grain(var grainStage):
        grainStage.amount = Self.clampUnit(grainStage.amount + grainShift)
        return .grain(grainStage)
      case .lightLeak(var leakStage):
        leakStage.probability = leakEnabled ? leakStage.probability : 0
        leakStage.strength =
          leakEnabled ? Self.clampUnit(leakStage.strength * (leakStrengthScale ?? 1)) : 0
        return .lightLeak(leakStage)
      // `.filmResponse` is deliberately left untouched: the fitted response
      // is the measured look, so 1998 no longer gets the per-shot
      // exposure/warmth jitter the parametric grade had. Grain and leak
      // variation still come from the seed. The jitter draws above are kept
      // so the RNG sequence, and therefore grain/leak decisions, is unchanged.
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
  /// Older item metadata omitted this field; those items decode with the
  /// Balanced quality that was current when they were written. This literal
  /// must never track `PhotoQualityPreference.balanced`, or raising the
  /// preference would silently re-encode historical items differently.
  static let legacyCompressionQuality = 0.88
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
        ?? FilmResolvedSettings.legacyCompressionQuality
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
  var filmResponse: FilmResponseStage? { stages.filmResponse }
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
  static let all: [FilmRecipe] = [nineteenNinetyEight, night, cinema, digicam]

  // Compact-digital look: neutral colour and a mild shared contrast curve
  // preserve the capture's white balance, blue hues and direct-flash lighting.
  // Sensor noise is retained; only a small amount of seeded grain is added.
  // No film bloom, blur, colour fringe or light-leak stage is injected.
  static let digicam = FilmRecipe(
    id: .digicam,
    version: FilmRecipeVersion.current,
    displayName: "Digicam",
    stages: [
      .filmResponse(
        FilmResponseStage(
          matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
          curves: Array(
            repeating: [0, 0.105, 0.230, 0.370, 0.515, 0.655, 0.785, 0.905, 1], count: 3),
          saturation: [1.00, 1.08, 1.02],
          hueChroma: Array(repeating: 0, count: 8),
          hueRotate: Array(repeating: 0, count: 8),
          hueLight: Array(repeating: 0, count: 8))),
      .grain(GrainStage(amount: 0.045, size: 1)),
      .vignette(VignetteStage(amount: 0.10)),
      .dateStamp(DateStampStage(style: .monospaced)),
    ]
  )

  // The 1998 look is a film response retargeted to measured Huji output
  // (recipe version 5). `tools/film-response-fit/` first fitted a crosstalk
  // matrix, per-channel tone curves, tone-dependent chroma, and per-hue-band
  // corrections to one aligned iPhone/Huji pair (v4); `measure.py` and
  // `retarget.py` then re-solved the tone curves, saturation, and blue-band
  // rotation against scene-averaged statistics of many Huji photos. The result:
  // olive shadows, lavender mids, cyan-mint highlights while clipped white
  // stays white, ~25% more saturation than the iPhone source (the v4 look
  // read as more saturated only because of its red-cast shadows), and blues
  // pushed toward violet. The optics stages
  // are sized to read at phone-screen size: a thresholded highlight glow so
  // lamps and flash hotspots bloom without hazing the shadows, a mild
  // isotropic blur, a deterministic chromatic-aberration fringe the
  // seven-segment stamp sits on top of, film grain, a big screen-blended
  // red/orange/pink leak from any edge on roughly one frame in three, and a
  // soft vignette.
  static let nineteenNinetyEight = FilmRecipe(
    id: .nineteenNinetyEight,
    version: FilmRecipeVersion.current,
    displayName: "1998",
    stages: [
      .filmResponse(
        FilmResponseStage(
          matrix: [0.998348, -0.008885, -0.148114,
            0.151087, 0.997864, -0.128046,
            -0.044489, -0.039532, 0.999481],
          curves: [
            [0.000000, 0.063311, 0.139185, 0.330192, 0.471497, 0.652940, 0.791238, 0.881440, 1.000000],
            [0.000000, 0.070095, 0.141415, 0.319199, 0.439739, 0.613283, 0.778255, 0.910293, 1.000000],
            [0.000000, 0.057964, 0.144936, 0.342940, 0.470812, 0.648847, 0.802260, 0.911952, 1.000000],
          ],
          saturation: [0.898702, 1.072762, 1.440906],
          hueChroma: [-0.008910, 0.246697, -0.133371, -0.010636, -0.002446, -0.004587, -0.164736, -0.002792],
          hueRotate: [-0.003869, -0.122947, -0.142692, -0.002308, 0.002107, 0.442644, 0.396280, -0.110779],
          hueLight: [-0.038137, 0.247080, -0.088487, -0.014831, -0.006916, -0.055911, -0.009129, -0.214261])),
      .halation(
        HalationStage(
          amount: 0.60, radiusScale: 0.018,
          tint: .fixed(red: 1.0, green: 0.84, blue: 0.80), radiusScalesWithAmount: false,
          highlightThreshold: 0.70)),
      .softness(SoftnessStage(amount: 0.72, kind: .gaussian)),
      // Runs before chromatic aberration deliberately, so the stamp picks up
      // the colour fringe like a real print would.
      .dateStamp(DateStampStage(style: .sevenSegment)),
      // Red inside, blue outside; roughly a 10px corner separation at 12 MP.
      .chromaticAberration(
        ChromaticAberrationStage(
          amount: 0.78, redGain: -0.0022, blueGain: 0.0032, lateralShiftScale: 0, seeded: false)),
      .grain(GrainStage(amount: 0.22, size: 1.0)),
      .lightLeak(
        LightLeakStage(
          probability: 0.30, strength: 0.95, minWidth: 0.25, maxWidth: 0.55,
          minIntensity: 0.72, maxIntensity: 1.0,
          palette: [
            LightLeakColor(red: 1.0, green: 0.22, blue: 0.08),
            LightLeakColor(red: 1.0, green: 0.45, blue: 0.10),
            LightLeakColor(red: 1.0, green: 0.30, blue: 0.45),
            LightLeakColor(red: 0.95, green: 0.12, blue: 0.20),
          ],
          alphaCap: 0.85,
          blend: .screen
        )),
      .vignette(VignetteStage(amount: 0.32)),
    ]
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
