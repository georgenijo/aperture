import XCTest

@testable import Aperture

final class FilmColorModelTests: XCTestCase {
  private let huji = FilmRecipeCatalog.nineteenNinetyEight.stages.colorGrade ?? .neutral

  func testHujiGradePreservesSceneHuesWhileSeparatingWarmAndCoolColors() {
    let wall = FilmColorModel.map(rgb(171, 173, 163), grade: huji)
    let wood = FilmColorModel.map(rgb(113, 74, 41), grade: huji)
    let bottle = FilmColorModel.map(rgb(17, 14, 8), grade: huji)

    // Near-neutral highlights stay near-neutral instead of being painted
    // lavender, warm browns gain separation, and blacks retain a hard toe.
    XCTAssertLessThan(abs(wall.blue - wall.red), 0.08)
    XCTAssertGreaterThan(wood.red - wood.blue, 0.24)
    XCTAssertLessThan(bottle.luminance, 0.025)
    XCTAssertGreaterThan(wall.luminance, bottle.luminance + 0.45)
  }

  func testHujiGradePullsBlueSkiesAndWarmsSkinTowardReferenceHues() {
    // Reference outputs measured from a Huji-shot sky and a Huji-shot skin
    // tone; probes the blueGreenSuppression/blueDarken/redHueShift terms
    // introduced for the 1998 recipe. Tolerance matches the spec (12/255).
    let sky = FilmColorModel.map(rgb(5, 90, 205), grade: huji)
    assertClose(sky, rgb(4, 38, 152), tolerance: 12.0 / 255.0, "sky")

    let skin = FilmColorModel.map(rgb(132, 39, 13), grade: huji)
    assertClose(skin, rgb(147, 55, 17), tolerance: 12.0 / 255.0, "skin")
  }

  func testNeutralGradeIsIdentity() {
    let neutral = FilmRecipeCatalog.legacyOriginal.stages.colorGrade ?? .neutral
    for value in stride(from: 0.0, through: 1.0, by: 0.125) {
      let mapped = FilmColorModel.map(FilmRGB(red: value, green: value * 0.5, blue: 1 - value),
        grade: neutral)
      XCTAssertEqual(mapped.red, value, accuracy: 0.002)
      XCTAssertEqual(mapped.green, value * 0.5, accuracy: 0.002)
      XCTAssertEqual(mapped.blue, 1 - value, accuracy: 0.002)
    }
  }

  func testGreysStayMonotonicAndBoundedUnderHujiGrade() {
    var previous = -1.0
    for step in 0...64 {
      let value = Double(step) / 64
      let mapped = FilmColorModel.map(FilmRGB(red: value, green: value, blue: value), grade: huji)
      let luminance = 0.2126 * mapped.red + 0.7152 * mapped.green + 0.0722 * mapped.blue
      XCTAssertGreaterThanOrEqual(luminance, previous - 0.0005, "grey \(value) inverted")
      for channel in [mapped.red, mapped.green, mapped.blue] {
        XCTAssertGreaterThanOrEqual(channel, 0)
        XCTAssertLessThanOrEqual(channel, 1)
      }
      previous = luminance
    }
  }

  func testCubeDataMatchesPointwiseMapping() throws {
    let dimension = 8
    let data = FilmColorModel.cubeData(dimension: dimension, grade: huji)
    XCTAssertEqual(data.count, dimension * dimension * dimension * 4 * MemoryLayout<Float>.size)
    let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    // Core Image orders the cube blue-major, then green, then red.
    let (r, g, b) = (5, 2, 7)
    let index = ((b * dimension + g) * dimension + r) * 4
    let expected = FilmColorModel.map(
      FilmRGB(
        red: Double(r) / Double(dimension - 1),
        green: Double(g) / Double(dimension - 1),
        blue: Double(b) / Double(dimension - 1)),
      grade: huji)
    XCTAssertEqual(Double(floats[index]), expected.red, accuracy: 0.0001)
    XCTAssertEqual(Double(floats[index + 1]), expected.green, accuracy: 0.0001)
    XCTAssertEqual(Double(floats[index + 2]), expected.blue, accuracy: 0.0001)
    XCTAssertEqual(floats[index + 3], 1)
  }

  func testGradeSurvivesLegacyParameterManifests() throws {
    // Manifests written before the split-tone fields existed decode as neutral tints.
    let json = """
      {"exposure":0.04,"contrast":1.12,"saturation":1.18,"warmth":0.22,
       "highlightRolloff":0.52,"shadowCoolness":0.08,"grainAmount":0.26,"grainSize":0.85,
       "halation":0.22,"vignette":0.18,"softness":0.09,"chromaticAberration":0.035,
       "lightLeakProbability":0.18,"lightLeakStrength":0.28}
      """
    let parameters = try ApertureJSON.makeDecoder().decode(
      FilmParameters.self, from: Data(json.utf8))
    XCTAssertEqual(parameters.shadowTint, .neutral)
    XCTAssertEqual(parameters.highlightTint, .neutral)
    XCTAssertEqual(parameters.channelSplit, 0)
    XCTAssertEqual(parameters.blackCrush, 0)
    // FilmRecipe no longer exposes `baseParameters` (recipes are stage lists),
    // so this mirrors the 1998 catalog entry's literal values directly to
    // keep testing `FilmParameters`, the v1 wire format, round-tripping.
    let hujiParameters = FilmParameters(
      exposure: 0.015, contrast: 1.22, saturation: 1.42, warmth: 0.10,
      highlightRolloff: 0.16, shadowCoolness: 0.42,
      grainAmount: 0.24, grainSize: 0.56, halation: 0.16,
      vignette: 0.075, softness: 0.72, chromaticAberration: 0.78,
      lightLeakProbability: 0.46, lightLeakStrength: 0.48,
      channelSplit: 0.07, blackCrush: 0.43,
      shadowTint: FilmColorTint(red: -0.018, green: 0.012, blue: 0.045),
      highlightTint: FilmColorTint(red: 0.014, green: 0.006, blue: -0.012)
    )
    let roundTrip = try ApertureJSON.makeDecoder().decode(
      FilmParameters.self, from: ApertureJSON.makeEncoder().encode(hujiParameters))
    XCTAssertEqual(roundTrip, hujiParameters)
  }

  private func rgb(_ red: Int, _ green: Int, _ blue: Int) -> FilmRGB {
    FilmRGB(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
  }

  private func assertClose(
    _ actual: FilmRGB, _ expected: FilmRGB, tolerance: Double, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let detail =
      "\(label): got (\(Int(actual.red * 255)), \(Int(actual.green * 255)), "
      + "\(Int(actual.blue * 255))) expected (\(Int(expected.red * 255)), "
      + "\(Int(expected.green * 255)), \(Int(expected.blue * 255)))"
    XCTAssertEqual(actual.red, expected.red, accuracy: tolerance, detail, file: file, line: line)
    XCTAssertEqual(
      actual.green, expected.green, accuracy: tolerance, detail, file: file, line: line)
    XCTAssertEqual(actual.blue, expected.blue, accuracy: tolerance, detail, file: file, line: line)
  }
}
