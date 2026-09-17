import Foundation

/// One step of a film recipe's processing pipeline, as data rather than a
/// hard-coded call order. `FilmRecipe.stages` is an ordered array of these;
/// `FilmProcessor`/`VideoProcessor` dispatch on whichever cases are present
/// instead of assuming every recipe touches every effect. Issue #17 turns the
/// old flat `FilmParameters` knobs into this list without changing any look:
/// `FilmStage.legacyPipeline` reproduces the exact v1 order and arithmetic.
enum FilmStage: Hashable, Sendable {
  case colorGrade(FilmColorGrade)
  case halation(HalationStage)
  case softness(SoftnessStage)
  case chromaticAberration(ChromaticAberrationStage)
  case grain(GrainStage)
  case lightLeak(LightLeakStage)
  case vignette(VignetteStage)
  case dateStamp(DateStampStage)
}

extension FilmStage: Codable {
  private enum Kind: String, Codable {
    case colorGrade, halation, softness, chromaticAberration, grain, lightLeak, vignette
    case dateStamp
  }

  private enum CodingKeys: String, CodingKey {
    case kind, configuration
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .colorGrade:
      self = .colorGrade(try container.decode(FilmColorGrade.self, forKey: .configuration))
    case .halation:
      self = .halation(try container.decode(HalationStage.self, forKey: .configuration))
    case .softness:
      self = .softness(try container.decode(SoftnessStage.self, forKey: .configuration))
    case .chromaticAberration:
      self = .chromaticAberration(
        try container.decode(ChromaticAberrationStage.self, forKey: .configuration))
    case .grain:
      self = .grain(try container.decode(GrainStage.self, forKey: .configuration))
    case .lightLeak:
      self = .lightLeak(try container.decode(LightLeakStage.self, forKey: .configuration))
    case .vignette:
      self = .vignette(try container.decode(VignetteStage.self, forKey: .configuration))
    case .dateStamp:
      self = .dateStamp(try container.decode(DateStampStage.self, forKey: .configuration))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .colorGrade(let configuration):
      try container.encode(Kind.colorGrade, forKey: .kind)
      try container.encode(configuration, forKey: .configuration)
    case .halation(let configuration):
      try container.encode(Kind.halation, forKey: .kind)
      try container.encode(configuration, forKey: .configuration)
    case .softness(let configuration):
      try container.encode(Kind.softness, forKey: .kind)
      try container.encode(configuration, forKey: .configuration)
    case .chromaticAberration(let configuration):
      try container.encode(Kind.chromaticAberration, forKey: .kind)
      try container.encode(configuration, forKey: .configuration)
    case .grain(let configuration):
      try container.encode(Kind.grain, forKey: .kind)
      try container.encode(configuration, forKey: .configuration)
    case .lightLeak(let configuration):
      try container.encode(Kind.lightLeak, forKey: .kind)
      try container.encode(configuration, forKey: .configuration)
    case .vignette(let configuration):
      try container.encode(Kind.vignette, forKey: .kind)
      try container.encode(configuration, forKey: .configuration)
    case .dateStamp(let configuration):
      try container.encode(Kind.dateStamp, forKey: .kind)
      try container.encode(configuration, forKey: .configuration)
    }
  }
}

/// Bloom/halation around bright areas, tinted and blended back in.
struct HalationStage: Codable, Hashable, Sendable {
  /// How the bloom highlight is tinted before it's blended back in.
  enum Tint: Codable, Hashable, Sendable {
    /// Reproduces the original warm-halation matrix
    /// `(1 + red·amount, 1 + green·amount, 1 − blue·amount)`.
    case warmByAmount(red: Double, green: Double, blue: Double)
    /// Sets the bloom's colour-matrix diagonal directly, independent of amount.
    case fixed(red: Double, green: Double, blue: Double)
  }

  var amount: Double
  var minimumAmount: Double = 0.001
  var intensityScale: Double = 0.75
  var intensityCap: Double = 1
  var radiusScale: Double = 0.012
  var minimumRadius: Double = 1
  var tint: Tint = .warmByAmount(red: 0.20, green: 0.04, blue: 0.10)
  /// When true (the default), the bloom radius also scales with `amount`,
  /// matching the original `extent.width * radiusScale * amount` formula.
  /// When false, the radius is `max(minimumRadius, extent.width * radiusScale)`.
  var radiusScalesWithAmount: Bool = true
  var blendOpacityScale: Double = 0.82
  var blendOpacityCap: Double = 0.68

  init(
    amount: Double,
    minimumAmount: Double = 0.001,
    intensityScale: Double = 0.75,
    intensityCap: Double = 1,
    radiusScale: Double = 0.012,
    minimumRadius: Double = 1,
    tint: Tint = .warmByAmount(red: 0.20, green: 0.04, blue: 0.10),
    radiusScalesWithAmount: Bool = true,
    blendOpacityScale: Double = 0.82,
    blendOpacityCap: Double = 0.68
  ) {
    self.amount = amount
    self.minimumAmount = minimumAmount
    self.intensityScale = intensityScale
    self.intensityCap = intensityCap
    self.radiusScale = radiusScale
    self.minimumRadius = minimumRadius
    self.tint = tint
    self.radiusScalesWithAmount = radiusScalesWithAmount
    self.blendOpacityScale = blendOpacityScale
    self.blendOpacityCap = blendOpacityCap
  }

  private enum CodingKeys: String, CodingKey {
    case amount, minimumAmount, intensityScale, intensityCap, radiusScale, minimumRadius
    case tint, radiusScalesWithAmount, blendOpacityScale, blendOpacityCap
  }

  /// Stage-schema-2 manifests persisted the warm tint as three loose gains.
  private enum LegacyCodingKeys: String, CodingKey {
    case warmRedGain, warmGreenGain, warmBlueGain
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let tint: Tint
    if let persisted = try values.decodeIfPresent(Tint.self, forKey: .tint) {
      tint = persisted
    } else {
      let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
      tint = .warmByAmount(
        red: try legacyValues.decodeIfPresent(Double.self, forKey: .warmRedGain) ?? 0.20,
        green: try legacyValues.decodeIfPresent(Double.self, forKey: .warmGreenGain) ?? 0.04,
        blue: try legacyValues.decodeIfPresent(Double.self, forKey: .warmBlueGain) ?? 0.10)
    }
    self.init(
      amount: try values.decode(Double.self, forKey: .amount),
      minimumAmount: try values.decodeIfPresent(Double.self, forKey: .minimumAmount) ?? 0.001,
      intensityScale: try values.decodeIfPresent(Double.self, forKey: .intensityScale) ?? 0.75,
      intensityCap: try values.decodeIfPresent(Double.self, forKey: .intensityCap) ?? 1,
      radiusScale: try values.decodeIfPresent(Double.self, forKey: .radiusScale) ?? 0.012,
      minimumRadius: try values.decodeIfPresent(Double.self, forKey: .minimumRadius) ?? 1,
      tint: tint,
      radiusScalesWithAmount: try values.decodeIfPresent(
        Bool.self, forKey: .radiusScalesWithAmount) ?? true,
      blendOpacityScale: try values.decodeIfPresent(Double.self, forKey: .blendOpacityScale) ?? 0.82,
      blendOpacityCap: try values.decodeIfPresent(Double.self, forKey: .blendOpacityCap) ?? 0.68
    )
  }
}

/// A soft-focus feel: either a mild zoom blur strongest away from frame
/// centre (`.radialZoom`, the original look), or an isotropic Gaussian blur
/// scaled by the shortest side (`.gaussian`).
struct SoftnessStage: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case radialZoom
    case gaussian
  }

  var amount: Double
  var minimumAmount: Double = 0.001
  var zoomBlurScale: Double = 0.0026
  var innerRadiusScale: Double = 0.38
  var outerRadiusScale: Double = 0.78
  var fallbackBlendOpacityScale: Double = 0.55
  var fallbackBlendOpacityCap: Double = 0.42
  var kind: Kind = .radialZoom
  var gaussianRadiusScale: Double = 0.0004

  init(
    amount: Double,
    minimumAmount: Double = 0.001,
    zoomBlurScale: Double = 0.0026,
    innerRadiusScale: Double = 0.38,
    outerRadiusScale: Double = 0.78,
    fallbackBlendOpacityScale: Double = 0.55,
    fallbackBlendOpacityCap: Double = 0.42,
    kind: Kind = .radialZoom,
    gaussianRadiusScale: Double = 0.0004
  ) {
    self.amount = amount
    self.minimumAmount = minimumAmount
    self.zoomBlurScale = zoomBlurScale
    self.innerRadiusScale = innerRadiusScale
    self.outerRadiusScale = outerRadiusScale
    self.fallbackBlendOpacityScale = fallbackBlendOpacityScale
    self.fallbackBlendOpacityCap = fallbackBlendOpacityCap
    self.kind = kind
    self.gaussianRadiusScale = gaussianRadiusScale
  }

  private enum CodingKeys: String, CodingKey {
    case amount, minimumAmount, zoomBlurScale, innerRadiusScale, outerRadiusScale
    case fallbackBlendOpacityScale, fallbackBlendOpacityCap, kind, gaussianRadiusScale
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      amount: try values.decode(Double.self, forKey: .amount),
      minimumAmount: try values.decodeIfPresent(Double.self, forKey: .minimumAmount) ?? 0.001,
      zoomBlurScale: try values.decodeIfPresent(Double.self, forKey: .zoomBlurScale) ?? 0.0026,
      innerRadiusScale: try values.decodeIfPresent(Double.self, forKey: .innerRadiusScale) ?? 0.38,
      outerRadiusScale: try values.decodeIfPresent(Double.self, forKey: .outerRadiusScale) ?? 0.78,
      fallbackBlendOpacityScale: try values.decodeIfPresent(
        Double.self, forKey: .fallbackBlendOpacityScale) ?? 0.55,
      fallbackBlendOpacityCap: try values.decodeIfPresent(
        Double.self, forKey: .fallbackBlendOpacityCap) ?? 0.42,
      kind: try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .radialZoom,
      gaussianRadiusScale: try values.decodeIfPresent(
        Double.self, forKey: .gaussianRadiusScale) ?? 0.0004
    )
  }
}

/// Cheap-lens colour fringing: red/blue channels scaled and shifted apart.
struct ChromaticAberrationStage: Codable, Hashable, Sendable {
  var amount: Double
  var minimumAmount: Double = 0.0005
  var redGain: Double = 0.0048
  /// Signed gain applied as `blueScale = 1 + blueGain * amount * shift`. The
  /// default is negative so the v1 look (blue shrinking, i.e. `1 - 0.0042 *
  /// amount * shift`) is unchanged.
  var blueGain: Double = -0.0042
  var lateralShiftScale: Double = 0.00045
  /// When true (the default), the per-render seed drives the red/blue channel
  /// shift amounts and shift direction. When false, both channel shifts are
  /// fixed at 1 and the direction is always positive, so the render is fully
  /// deterministic across seeds.
  var seeded: Bool = true

  init(
    amount: Double,
    minimumAmount: Double = 0.0005,
    redGain: Double = 0.0048,
    blueGain: Double = -0.0042,
    lateralShiftScale: Double = 0.00045,
    seeded: Bool = true
  ) {
    self.amount = amount
    self.minimumAmount = minimumAmount
    self.redGain = redGain
    self.blueGain = blueGain
    self.lateralShiftScale = lateralShiftScale
    self.seeded = seeded
  }

  /// `blueGain` is persisted under `signedBlueGain`. Stage-schema-2
  /// manifests wrote an unsigned `blueGain` that the renderer *subtracted*
  /// (`1 - blueGain * amount * shift`); decoding negates that legacy key so
  /// the persisted look is unchanged, and re-encoding only ever writes the
  /// signed key, so a decode/encode round trip cannot flip the sign twice.
  private enum CodingKeys: String, CodingKey {
    case amount, minimumAmount, redGain, lateralShiftScale, seeded
    case blueGain = "signedBlueGain"
  }

  private enum LegacyCodingKeys: String, CodingKey {
    case unsignedBlueGain = "blueGain"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
    let blueGain: Double
    if let signed = try values.decodeIfPresent(Double.self, forKey: .blueGain) {
      blueGain = signed
    } else if let unsigned = try legacyValues.decodeIfPresent(
      Double.self, forKey: .unsignedBlueGain)
    {
      blueGain = -unsigned
    } else {
      blueGain = -0.0042
    }
    self.init(
      amount: try values.decode(Double.self, forKey: .amount),
      minimumAmount: try values.decodeIfPresent(Double.self, forKey: .minimumAmount) ?? 0.0005,
      redGain: try values.decodeIfPresent(Double.self, forKey: .redGain) ?? 0.0048,
      blueGain: blueGain,
      lateralShiftScale: try values.decodeIfPresent(Double.self, forKey: .lateralShiftScale)
        ?? 0.00045,
      seeded: try values.decodeIfPresent(Bool.self, forKey: .seeded) ?? true
    )
  }
}

/// Luminance-weighted monochrome noise.
struct GrainStage: Codable, Hashable, Sendable {
  var amount: Double
  var size: Double
  var minimumAmount: Double = 0.001
  var gainCap: Double = 1
  var gainScale: Double = 0.23
  var biasScale: Double = 0.5
  var curveConstant: Double = 0.25
  var curveLinear: Double = 3
  var curveQuadratic: Double = -3

  init(
    amount: Double,
    size: Double,
    minimumAmount: Double = 0.001,
    gainCap: Double = 1,
    gainScale: Double = 0.23,
    biasScale: Double = 0.5,
    curveConstant: Double = 0.25,
    curveLinear: Double = 3,
    curveQuadratic: Double = -3
  ) {
    self.amount = amount
    self.size = size
    self.minimumAmount = minimumAmount
    self.gainCap = gainCap
    self.gainScale = gainScale
    self.biasScale = biasScale
    self.curveConstant = curveConstant
    self.curveLinear = curveLinear
    self.curveQuadratic = curveQuadratic
  }

  private enum CodingKeys: String, CodingKey {
    case amount, size, minimumAmount, gainCap, gainScale, biasScale
    case curveConstant, curveLinear, curveQuadratic
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      amount: try values.decode(Double.self, forKey: .amount),
      size: try values.decode(Double.self, forKey: .size),
      minimumAmount: try values.decodeIfPresent(Double.self, forKey: .minimumAmount) ?? 0.001,
      gainCap: try values.decodeIfPresent(Double.self, forKey: .gainCap) ?? 1,
      gainScale: try values.decodeIfPresent(Double.self, forKey: .gainScale) ?? 0.23,
      biasScale: try values.decodeIfPresent(Double.self, forKey: .biasScale) ?? 0.5,
      curveConstant: try values.decodeIfPresent(Double.self, forKey: .curveConstant) ?? 0.25,
      curveLinear: try values.decodeIfPresent(Double.self, forKey: .curveLinear) ?? 3,
      curveQuadratic: try values.decodeIfPresent(Double.self, forKey: .curveQuadratic) ?? -3
    )
  }
}

/// A procedural light leak: whether/how strongly one appears is a per-render
/// random draw (`FilmProcessingDecision`); this stage carries the probability,
/// strength, and the geometric ranges that draw samples from.
struct LightLeakStage: Codable, Hashable, Sendable {
  var probability: Double
  var strength: Double
  var minWidth: Double
  var maxWidth: Double
  var minPosition: Double = 0.16
  var maxPosition: Double = 0.84
  var minAngle: Double = -0.42
  var maxAngle: Double = 0.42
  var minIntensity: Double = 0.68
  var maxIntensity: Double = 1.0
  var palette: [LightLeakColor] = LightLeakStage.defaultPalette
  /// Which edges a leak may be drawn from. An empty array means all four
  /// (left, right, top, bottom, in that order), the same set and order
  /// `FilmProcessingDecision.make` always drew from before this field existed
  /// -- so the default reproduces identical draws for identical seeds.
  var edges: [LightLeakDecision.Edge] = LightLeakDecision.Edge.allCases
  /// Hard ceiling on the rendered leak's per-pixel alpha.
  var alphaCap: Double = 0.68

  static let defaultPalette: [LightLeakColor] = [
    LightLeakColor(red: 1.0, green: 0.20, blue: 0.06),
    LightLeakColor(red: 1.0, green: 0.38, blue: 0.07),
    LightLeakColor(red: 0.96, green: 0.08, blue: 0.16),
    LightLeakColor(red: 1.0, green: 0.55, blue: 0.12),
  ]

  init(
    probability: Double,
    strength: Double,
    minWidth: Double,
    maxWidth: Double,
    minPosition: Double = 0.16,
    maxPosition: Double = 0.84,
    minAngle: Double = -0.42,
    maxAngle: Double = 0.42,
    minIntensity: Double = 0.68,
    maxIntensity: Double = 1.0,
    palette: [LightLeakColor] = LightLeakStage.defaultPalette,
    edges: [LightLeakDecision.Edge] = LightLeakDecision.Edge.allCases,
    alphaCap: Double = 0.68
  ) {
    // Normalise so a hand-edited or corrupt manifest can never trap the
    // renderer: reversed ranges are swapped, non-finite bounds fall back to
    // the v1 constants, and an empty palette uses the default one.
    self.probability = Self.unit(probability)
    self.strength = Self.unit(strength)
    (self.minWidth, self.maxWidth) = Self.ordered(minWidth, maxWidth, fallback: (0.16, 0.42))
    (self.minPosition, self.maxPosition) = Self.ordered(
      minPosition, maxPosition, fallback: (0.16, 0.84))
    (self.minAngle, self.maxAngle) = Self.ordered(minAngle, maxAngle, fallback: (-0.42, 0.42))
    (self.minIntensity, self.maxIntensity) = Self.ordered(
      minIntensity, maxIntensity, fallback: (0.68, 1.0))
    self.palette = palette.isEmpty ? LightLeakStage.defaultPalette : palette
    // `edges` restricts which of the four sides a leak may be drawn from
    // (issue #18's 1998 retune); an empty array falls back to all four so a
    // corrupt or hand-edited manifest can't suppress every leak.
    self.edges = edges.isEmpty ? LightLeakDecision.Edge.allCases : edges
    self.alphaCap = Self.unit(alphaCap)
  }

  private static func unit(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }

  private static func ordered(_ lower: Double, _ upper: Double, fallback: (Double, Double))
    -> (Double, Double)
  {
    guard lower.isFinite, upper.isFinite else { return fallback }
    return lower <= upper ? (lower, upper) : (upper, lower)
  }

  private enum CodingKeys: String, CodingKey {
    case probability, strength, minWidth, maxWidth, minPosition, maxPosition
    case minAngle, maxAngle, minIntensity, maxIntensity, palette, edges, alphaCap
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      probability: try values.decode(Double.self, forKey: .probability),
      strength: try values.decode(Double.self, forKey: .strength),
      minWidth: try values.decode(Double.self, forKey: .minWidth),
      maxWidth: try values.decode(Double.self, forKey: .maxWidth),
      minPosition: try values.decodeIfPresent(Double.self, forKey: .minPosition) ?? 0.16,
      maxPosition: try values.decodeIfPresent(Double.self, forKey: .maxPosition) ?? 0.84,
      minAngle: try values.decodeIfPresent(Double.self, forKey: .minAngle) ?? -0.42,
      maxAngle: try values.decodeIfPresent(Double.self, forKey: .maxAngle) ?? 0.42,
      minIntensity: try values.decodeIfPresent(Double.self, forKey: .minIntensity) ?? 0.68,
      maxIntensity: try values.decodeIfPresent(Double.self, forKey: .maxIntensity) ?? 1.0,
      palette: try values.decodeIfPresent([LightLeakColor].self, forKey: .palette)
        ?? LightLeakStage.defaultPalette,
      edges: try values.decodeIfPresent([LightLeakDecision.Edge].self, forKey: .edges)
        ?? LightLeakDecision.Edge.allCases,
      alphaCap: try values.decodeIfPresent(Double.self, forKey: .alphaCap) ?? 0.68
    )
  }
}

/// Edge darkening.
struct VignetteStage: Codable, Hashable, Sendable {
  var amount: Double
  var minimumAmount: Double = 0.001
  var intensityScale: Double = 0.74
  var intensityCap: Double = 1
  var radiusScale: Double = 0.68
  var minimumRadius: Double = 0.1

  init(
    amount: Double,
    minimumAmount: Double = 0.001,
    intensityScale: Double = 0.74,
    intensityCap: Double = 1,
    radiusScale: Double = 0.68,
    minimumRadius: Double = 0.1
  ) {
    self.amount = amount
    self.minimumAmount = minimumAmount
    self.intensityScale = intensityScale
    self.intensityCap = intensityCap
    self.radiusScale = radiusScale
    self.minimumRadius = minimumRadius
  }

  private enum CodingKeys: String, CodingKey {
    case amount, minimumAmount, intensityScale, intensityCap, radiusScale, minimumRadius
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      amount: try values.decode(Double.self, forKey: .amount),
      minimumAmount: try values.decodeIfPresent(Double.self, forKey: .minimumAmount) ?? 0.001,
      intensityScale: try values.decodeIfPresent(Double.self, forKey: .intensityScale) ?? 0.74,
      intensityCap: try values.decodeIfPresent(Double.self, forKey: .intensityCap) ?? 1,
      radiusScale: try values.decodeIfPresent(Double.self, forKey: .radiusScale) ?? 0.68,
      minimumRadius: try values.decodeIfPresent(Double.self, forKey: .minimumRadius) ?? 0.1
    )
  }
}

/// The persisted date-stamp overlay. `style` selects a rendering treatment;
/// the geometry/colour fields below are only consumed by `.sevenSegment` —
/// `.monospaced` ignores them and keeps its own hard-coded look so existing
/// renders stay byte-identical.
struct DateStampStage: Codable, Hashable, Sendable {
  enum Style: String, Codable, Hashable, Sendable {
    case monospaced
    case sevenSegment
  }

  var style: Style = .monospaced
  var red: Double = 193.0 / 255
  var green: Double = 81.0 / 255
  var blue: Double = 17.0 / 255
  var alpha: Double = 0.95
  /// × font size.
  var glowRadiusScale: Double = 0.25
  var glowAlpha: Double = 0.5
  /// × shortest canvas side.
  var fontSizeScale: Double = 0.028
  /// × shortest canvas side; distance from the left edge in portrait / the
  /// right edge in landscape.
  var edgeMarginScale: Double = 0.035
  /// × shortest canvas side; distance from the bottom edge.
  var endMarginScale: Double = 0.11

  init(
    style: Style = .monospaced,
    red: Double = 193.0 / 255,
    green: Double = 81.0 / 255,
    blue: Double = 17.0 / 255,
    alpha: Double = 0.95,
    glowRadiusScale: Double = 0.25,
    glowAlpha: Double = 0.5,
    fontSizeScale: Double = 0.028,
    edgeMarginScale: Double = 0.035,
    endMarginScale: Double = 0.11
  ) {
    self.style = style
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
    self.glowRadiusScale = glowRadiusScale
    self.glowAlpha = glowAlpha
    self.fontSizeScale = fontSizeScale
    self.edgeMarginScale = edgeMarginScale
    self.endMarginScale = endMarginScale
  }

  private enum CodingKeys: String, CodingKey {
    case style, red, green, blue, alpha, glowRadiusScale, glowAlpha, fontSizeScale,
      edgeMarginScale, endMarginScale
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      style: try values.decodeIfPresent(Style.self, forKey: .style) ?? .monospaced,
      red: try values.decodeIfPresent(Double.self, forKey: .red) ?? 193.0 / 255,
      green: try values.decodeIfPresent(Double.self, forKey: .green) ?? 81.0 / 255,
      blue: try values.decodeIfPresent(Double.self, forKey: .blue) ?? 17.0 / 255,
      alpha: try values.decodeIfPresent(Double.self, forKey: .alpha) ?? 0.95,
      glowRadiusScale: try values.decodeIfPresent(Double.self, forKey: .glowRadiusScale) ?? 0.25,
      glowAlpha: try values.decodeIfPresent(Double.self, forKey: .glowAlpha) ?? 0.5,
      fontSizeScale: try values.decodeIfPresent(Double.self, forKey: .fontSizeScale) ?? 0.028,
      edgeMarginScale: try values.decodeIfPresent(Double.self, forKey: .edgeMarginScale) ?? 0.035,
      endMarginScale: try values.decodeIfPresent(Double.self, forKey: .endMarginScale) ?? 0.11
    )
  }
}

extension FilmStage {
  /// Expands the flat v1 `FilmParameters` knob set into the fixed 8-stage
  /// order the original hard-coded pipeline always ran in. `identifier`
  /// decides the light-leak width range: 1998 used a narrower band than
  /// every other recipe.
  static func legacyPipeline(parameters: FilmParameters, identifier: FilmRecipeIdentifier)
    -> [FilmStage]
  {
    let isHujiStyle = identifier == .nineteenNinetyEight
    return [
      .colorGrade(parameters.colorGrade),
      .halation(HalationStage(amount: parameters.halation)),
      .softness(SoftnessStage(amount: parameters.softness)),
      .chromaticAberration(ChromaticAberrationStage(amount: parameters.chromaticAberration)),
      .grain(GrainStage(amount: parameters.grainAmount, size: parameters.grainSize)),
      .lightLeak(
        LightLeakStage(
          probability: parameters.lightLeakProbability,
          strength: parameters.lightLeakStrength,
          minWidth: isHujiStyle ? 0.10 : 0.16,
          maxWidth: isHujiStyle ? 0.27 : 0.42
        )),
      .vignette(VignetteStage(amount: parameters.vignette)),
      .dateStamp(DateStampStage()),
    ]
  }
}

extension Array where Element == FilmStage {
  var colorGrade: FilmColorGrade? {
    for case .colorGrade(let value) in self { return value }
    return nil
  }

  var halation: HalationStage? {
    for case .halation(let value) in self { return value }
    return nil
  }

  var softness: SoftnessStage? {
    for case .softness(let value) in self { return value }
    return nil
  }

  var chromaticAberration: ChromaticAberrationStage? {
    for case .chromaticAberration(let value) in self { return value }
    return nil
  }

  var grain: GrainStage? {
    for case .grain(let value) in self { return value }
    return nil
  }

  var lightLeak: LightLeakStage? {
    for case .lightLeak(let value) in self { return value }
    return nil
  }

  var vignette: VignetteStage? {
    for case .vignette(let value) in self { return value }
    return nil
  }

  var dateStamp: DateStampStage? {
    for case .dateStamp(let value) in self { return value }
    return nil
  }

  /// Mirrors `FilmParameters.isWithinSupportedBounds`: every present stage's
  /// user-facing knob stays inside the range the effect was authored for.
  var isWithinSupportedBounds: Bool {
    if let grade = colorGrade {
      guard (-1...1).contains(grade.exposure),
        (0.75...1.5).contains(grade.contrast),
        (0.5...1.6).contains(grade.saturation),
        (-1...1).contains(grade.warmth),
        (0...1).contains(grade.highlightRolloff),
        (0...1).contains(grade.shadowCoolness),
        (0...1).contains(grade.channelSplit),
        (0...1).contains(grade.blackCrush),
        (0...1).contains(grade.blueGreenSuppression),
        (0...1).contains(grade.blueDarken),
        (0...1).contains(grade.redHueShift)
      else { return false }
    }
    if let halation, !(0...1).contains(halation.amount) { return false }
    if let softness, !(0...1).contains(softness.amount) { return false }
    if let chromaticAberration, !(0...1).contains(chromaticAberration.amount) { return false }
    if let grain {
      guard (0...1).contains(grain.amount), (0.25...3).contains(grain.size) else { return false }
    }
    if let lightLeak {
      guard (0...1).contains(lightLeak.probability), (0...1).contains(lightLeak.strength) else {
        return false
      }
    }
    if let vignette, !(0...1).contains(vignette.amount) { return false }
    return true
  }
}
