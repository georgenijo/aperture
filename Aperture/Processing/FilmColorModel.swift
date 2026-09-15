import Foundation

/// An sRGB-encoded colour with components in 0...1.
struct FilmRGB: Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double

  var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

/// A signed per-channel offset applied to one tonal band of the image.
struct FilmColorTint: Codable, Hashable, Sendable {
  let red: Double
  let green: Double
  let blue: Double

  static let neutral = FilmColorTint(red: 0, green: 0, blue: 0)

  init(red: Double, green: Double, blue: Double) {
    self.red = Self.clamp(red)
    self.green = Self.clamp(green)
    self.blue = Self.clamp(blue)
  }

  private static func clamp(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, -1), 1)
  }
}

/// The subset of `FilmParameters` that decides colour and tone. It is kept
/// free of Core Image so the mapping can be unit-tested numerically and baked
/// into a `CIColorCube` for stills and video alike.
struct FilmColorGrade: Hashable, Sendable {
  let exposure: Double
  let contrast: Double
  let saturation: Double
  let warmth: Double
  let highlightRolloff: Double
  let shadowCoolness: Double
  let channelSplit: Double
  let blackCrush: Double
  let shadowTint: FilmColorTint
  let highlightTint: FilmColorTint
}

enum FilmColorModel {
  /// Maps one sRGB colour through the grade. Every stage is a smooth,
  /// monotonic function of the input so a coarse cube interpolates cleanly.
  static func map(_ input: FilmRGB, grade: FilmColorGrade) -> FilmRGB {
    var red = clampUnit(input.red)
    var green = clampUnit(input.green)
    var blue = clampUnit(input.blue)

    // Exposure as gain, so blacks stay black.
    let gain = pow(2, grade.exposure * 0.6)
    red = clampUnit(red * gain)
    green = clampUnit(green * gain)
    blue = clampUnit(blue * gain)

    // Cross-process style channel split: red climbs out of the midtones,
    // blue lifts only in the highlights, green barely moves.
    if grade.channelSplit > 0 {
      let split = grade.channelSplit
      red = clampUnit(red + split * 1.0 * red * (1 - red))
      green = clampUnit(green + split * 0.25 * green * (1 - green))
      blue = clampUnit(blue + split * 0.55 * blue * blue * (1 - blue))
    }

    // Contrast around middle grey, then the film highlight rolloff.
    red = contrastCurve(red, grade: grade)
    green = contrastCurve(green, grade: grade)
    blue = contrastCurve(blue, grade: grade)

    // Saturation as a mix against luminance.
    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    red = clampUnit(luminance + (red - luminance) * grade.saturation)
    green = clampUnit(luminance + (green - luminance) * grade.saturation)
    blue = clampUnit(luminance + (blue - luminance) * grade.saturation)

    // Legacy global warmth and cool shadows, matching the matrix the
    // Night and Cinema recipes were tuned against.
    red = clampUnit(red * (1 + grade.warmth * 0.08))
    blue = clampUnit(blue * (1 - grade.warmth * 0.07 + grade.shadowCoolness * 0.04))

    // Split toning by tonal band. Deep blacks are excluded from the shadow
    // band so a crushed bottle stays black instead of turning orange.
    let tone = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    let highlightWeight = smoothstep(0.42, 0.88, tone)
    let shadowWeight = smoothstep(0.05, 0.30, tone) * (1 - highlightWeight)
    red += grade.shadowTint.red * shadowWeight + grade.highlightTint.red * highlightWeight
    green += grade.shadowTint.green * shadowWeight + grade.highlightTint.green * highlightWeight
    blue += grade.shadowTint.blue * shadowWeight + grade.highlightTint.blue * highlightWeight

    // Black crush: pull the toe down and restretch so white stays white.
    if grade.blackCrush > 0 {
      let floor = grade.blackCrush * 0.08
      red = (red - floor) / (1 - floor)
      green = (green - floor) / (1 - floor)
      blue = (blue - floor) / (1 - floor)
    }

    return FilmRGB(red: clampUnit(red), green: clampUnit(green), blue: clampUnit(blue))
  }

  /// A `CIColorCube` table: `dimension³` RGBA float entries, blue-major.
  static func cubeData(dimension: Int, grade: FilmColorGrade) -> Data {
    let dimension = max(2, min(64, dimension))
    var floats = [Float]()
    floats.reserveCapacity(dimension * dimension * dimension * 4)
    let step = 1 / Double(dimension - 1)
    for blue in 0..<dimension {
      for green in 0..<dimension {
        for red in 0..<dimension {
          let mapped = map(
            FilmRGB(
              red: Double(red) * step, green: Double(green) * step, blue: Double(blue) * step),
            grade: grade)
          floats.append(Float(mapped.red))
          floats.append(Float(mapped.green))
          floats.append(Float(mapped.blue))
          floats.append(1)
        }
      }
    }
    return floats.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private static func contrastCurve(_ value: Double, grade: FilmColorGrade) -> Double {
    var output = 0.5 + (value - 0.5) * grade.contrast
    output = clampUnit(output)
    // Matches the legacy tone-curve points: 1 → 1 - 0.16r, 0.75 → 0.76 - 0.10r.
    let rolloff = grade.highlightRolloff
    output -= rolloff * 0.16 * output * output * output
    return clampUnit(output)
  }

  private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    let t = clampUnit((value - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
  }

  private static func clampUnit(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}
