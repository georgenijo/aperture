import Foundation

/// A data-driven film response, fitted offline from aligned reference pairs
/// (`tools/film-response-fit/`) rather than hand-tuned knobs. It is the colour
/// stage of recipes that need real tonal shape: a crosstalk matrix in linear
/// light, one monotone tone curve per channel on the encoded domain, a
/// tone-dependent chroma gain, and per-hue-band chroma/rotation/lightness
/// corrections in OKLab. Every term is a smooth function of its input so the
/// stage bakes cleanly into `FilmColorCube`'s 32³ table.
///
/// `FilmResponseModel.map` must stay numerically identical to
/// `tools/film-response-fit/model.py`; `FilmResponseModelTests` pins that
/// parity against Python-generated probes.
struct FilmResponseStage: Codable, Hashable, Sendable {
  static let knotCount = 9
  static let bandCount = 8

  /// Row-major 3×3 crosstalk applied to linear-light RGB. Rows are
  /// renormalised to sum to 1 at render time so white stays white.
  var matrix: [Double]
  /// `knotCount` output values per channel (red, green, blue) at uniformly
  /// spaced encoded-domain inputs 0…1; enforced monotone at render time.
  var curves: [[Double]]
  /// OKLab chroma gain at L = 0, 0.5, 1 (quadratic through the three).
  var saturation: [Double]
  /// Additive chroma gain per hue band (periodic, piecewise linear).
  var hueChroma: [Double]
  /// Hue rotation in radians per hue band.
  var hueRotate: [Double]
  /// Fractional OKLab lightness change per hue band, weighted by chroma so
  /// neutrals are untouched.
  var hueLight: [Double]

  private static let identityMatrix: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
  private static let identityCurve: [Double] = (0..<knotCount).map {
    Double($0) / Double(knotCount - 1)
  }
  private static let unitSaturation: [Double] = [1, 1, 1]
  private static let zeroBands: [Double] = Array(repeating: 0, count: bandCount)

  static let identity = FilmResponseStage(
    matrix: identityMatrix,
    curves: Array(repeating: identityCurve, count: 3),
    saturation: unitSaturation,
    hueChroma: zeroBands,
    hueRotate: zeroBands,
    hueLight: zeroBands)

  init(
    matrix: [Double], curves: [[Double]], saturation: [Double],
    hueChroma: [Double], hueRotate: [Double], hueLight: [Double]
  ) {
    // Fallbacks read the plain constants, never `identity`, so building
    // `identity` itself cannot recurse into its own one-time initialiser.
    self.matrix = Self.normalised(matrix, count: 9, fallback: Self.identityMatrix)
    var normalisedCurves = [[Double]]()
    for channel in 0..<3 {
      let curve = channel < curves.count ? curves[channel] : Self.identityCurve
      normalisedCurves.append(
        Self.normalised(curve, count: Self.knotCount, fallback: Self.identityCurve))
    }
    self.curves = normalisedCurves
    self.saturation = Self.normalised(saturation, count: 3, fallback: Self.unitSaturation)
    self.hueChroma = Self.normalised(hueChroma, count: Self.bandCount, fallback: Self.zeroBands)
    self.hueRotate = Self.normalised(hueRotate, count: Self.bandCount, fallback: Self.zeroBands)
    self.hueLight = Self.normalised(hueLight, count: Self.bandCount, fallback: Self.zeroBands)
  }

  private enum CodingKeys: String, CodingKey {
    case matrix, curves, saturation, hueChroma, hueRotate, hueLight
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      matrix: try values.decodeIfPresent([Double].self, forKey: .matrix) ?? Self.identityMatrix,
      curves: try values.decodeIfPresent([[Double]].self, forKey: .curves)
        ?? Array(repeating: Self.identityCurve, count: 3),
      saturation: try values.decodeIfPresent([Double].self, forKey: .saturation)
        ?? Self.unitSaturation,
      hueChroma: try values.decodeIfPresent([Double].self, forKey: .hueChroma) ?? Self.zeroBands,
      hueRotate: try values.decodeIfPresent([Double].self, forKey: .hueRotate) ?? Self.zeroBands,
      hueLight: try values.decodeIfPresent([Double].self, forKey: .hueLight) ?? Self.zeroBands)
  }

  /// A hand-edited or corrupt manifest can never trap the renderer: wrong
  /// element counts fall back wholesale, non-finite entries fall back
  /// element-wise.
  private static func normalised(_ values: [Double], count: Int, fallback: [Double]) -> [Double] {
    guard values.count == count else { return fallback }
    return zip(values, fallback).map { $0.isFinite ? $0 : $1 }
  }
}

enum FilmResponseModel {
  /// Maps one sRGB-encoded colour through the response. Mirrors
  /// `tools/film-response-fit/model.py::apply` exactly.
  static func map(_ input: FilmRGB, response: FilmResponseStage) -> FilmRGB {
    var rgb = (
      srgbToLinear(clampUnit(input.red)),
      srgbToLinear(clampUnit(input.green)),
      srgbToLinear(clampUnit(input.blue))
    )

    // Crosstalk matrix in linear light, rows renormalised to sum 1.
    let m = response.matrix
    func row(_ index: Int) -> (Double, Double, Double) {
      let a = m[index * 3], b = m[index * 3 + 1], c = m[index * 3 + 2]
      let sum = a + b + c
      guard abs(sum) > 1e-9 else { return (index == 0 ? 1 : 0, index == 1 ? 1 : 0, index == 2 ? 1 : 0) }
      return (a / sum, b / sum, c / sum)
    }
    let (r0, r1, r2) = (row(0), row(1), row(2))
    let mixed = (
      max(0, r0.0 * rgb.0 + r0.1 * rgb.1 + r0.2 * rgb.2),
      max(0, r1.0 * rgb.0 + r1.1 * rgb.1 + r1.2 * rgb.2),
      max(0, r2.0 * rgb.0 + r2.1 * rgb.1 + r2.2 * rgb.2)
    )
    rgb = mixed

    // Per-channel monotone tone curves on the encoded domain.
    let encoded = [linearToSrgb(rgb.0), linearToSrgb(rgb.1), linearToSrgb(rgb.2)]
    var toned = [0.0, 0.0, 0.0]
    for channel in 0..<3 {
      toned[channel] = clampUnit(
        Self.monotoneCubic(response.curves[channel], at: clampUnit(encoded[channel])))
    }

    // Chroma and hue corrections in OKLab.
    let lab = oklab(fromLinear: (srgbToLinear(toned[0]), srgbToLinear(toned[1]), srgbToLinear(toned[2])))
    let lightness = lab.0
    let chroma = (lab.1 * lab.1 + lab.2 * lab.2).squareRoot()
    let hue = atan2(lab.2, lab.1)
    let s = response.saturation
    let toneGain =
      s[0] * (1 - lightness) * (1 - 2 * lightness) + s[1] * 4 * lightness * (1 - lightness)
      + s[2] * lightness * (2 * lightness - 1)
    let gain = max(0, toneGain + band(response.hueChroma, hue: hue))
    let rotatedHue = hue + band(response.hueRotate, hue: hue)
    let scaledChroma = chroma * gain
    let chromaWeight = min(max(chroma / 0.12, 0), 1)
    let adjustedLightness = clampUnit(lightness * (1 + band(response.hueLight, hue: hue) * chromaWeight))
    let output = linear(
      fromOklab: (
        adjustedLightness, scaledChroma * cos(rotatedHue), scaledChroma * sin(rotatedHue)
      ))
    return FilmRGB(
      red: clampUnit(linearToSrgb(output.0)),
      green: clampUnit(linearToSrgb(output.1)),
      blue: clampUnit(linearToSrgb(output.2)))
  }

  /// A `CIColorCube` table for the response: `dimension³` RGBA floats, blue-major.
  static func cubeData(dimension: Int, response: FilmResponseStage) -> Data {
    let dimension = max(2, min(64, dimension))
    var floats = [Float]()
    floats.reserveCapacity(dimension * dimension * dimension * 4)
    let step = 1 / Double(dimension - 1)
    for blue in 0..<dimension {
      for green in 0..<dimension {
        for red in 0..<dimension {
          let mapped = map(
            FilmRGB(red: Double(red) * step, green: Double(green) * step, blue: Double(blue) * step),
            response: response)
          floats.append(Float(mapped.red))
          floats.append(Float(mapped.green))
          floats.append(Float(mapped.blue))
          floats.append(1)
        }
      }
    }
    return floats.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  // MARK: - Pieces

  /// Fritsch–Carlson monotone piecewise-cubic interpolation over uniformly
  /// spaced knots; the knot values are made monotone first.
  static func monotoneCubic(_ knots: [Double], at x: Double) -> Double {
    let n = knots.count
    guard n >= 2 else { return x }
    var y = [Double](repeating: 0, count: n)
    var running = -Double.infinity
    for i in 0..<n {
      running = max(running, min(max(knots[i], 0), 1))
      y[i] = running
    }
    let h = 1 / Double(n - 1)
    var delta = [Double](repeating: 0, count: n - 1)
    for i in 0..<(n - 1) { delta[i] = (y[i + 1] - y[i]) / h }
    var m = [Double](repeating: 0, count: n)
    m[0] = delta[0]
    m[n - 1] = delta[n - 2]
    if n > 2 {
      for i in 1..<(n - 1) {
        if delta[i - 1] * delta[i] <= 0 {
          m[i] = 0
        } else {
          let w1 = 2 * h + h
          let w2 = h + 2 * h
          m[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
        }
      }
    }
    let position = x / h
    let i = min(max(Int(position.rounded(.down)), 0), n - 2)
    let t = min(max((x - Double(i) * h) / h, 0), 1)
    let t2 = t * t, t3 = t2 * t
    let h00 = 2 * t3 - 3 * t2 + 1
    let h10 = t3 - 2 * t2 + t
    let h01 = -2 * t3 + 3 * t2
    let h11 = t3 - t2
    return h00 * y[i] + h10 * h * m[i] + h01 * y[i + 1] + h11 * h * m[i + 1]
  }

  /// Periodic piecewise-linear lookup over `bandCount` hue bands.
  static func band(_ values: [Double], hue: Double) -> Double {
    let count = values.count
    guard count > 0 else { return 0 }
    var turns = hue / (2 * Double.pi)
    turns -= turns.rounded(.down)
    let position = turns * Double(count)
    let index = Int(position.rounded(.down)) % count
    let fraction = position - position.rounded(.down)
    return values[index] * (1 - fraction) + values[(index + 1) % count] * fraction
  }

  static func srgbToLinear(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }

  static func linearToSrgb(_ value: Double) -> Double {
    let clamped = max(0, value)
    return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
  }

  static func oklab(fromLinear rgb: (Double, Double, Double)) -> (Double, Double, Double) {
    let l = cbrt(max(0, 0.4122214708 * rgb.0 + 0.5363325363 * rgb.1 + 0.0514459929 * rgb.2))
    let m = cbrt(max(0, 0.2119034982 * rgb.0 + 0.6806995451 * rgb.1 + 0.1073969566 * rgb.2))
    let s = cbrt(max(0, 0.0883024619 * rgb.0 + 0.2817188376 * rgb.1 + 0.6299787005 * rgb.2))
    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    )
  }

  static func linear(fromOklab lab: (Double, Double, Double)) -> (Double, Double, Double) {
    let l = pow(lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2, 3)
    let m = pow(lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2, 3)
    let s = pow(lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2, 3)
    return (
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    )
  }

  private static func clampUnit(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}
