import Foundation
import XCTest

@testable import Aperture

final class FilmResponseModelTests: XCTestCase {
  func testDigicamKeepsGreysNeutralWithStrongerFlashContrast() throws {
    let response = try XCTUnwrap(FilmRecipeCatalog.digicam.stages.filmResponse)
    for step in 0...64 {
      let value = Double(step) / 64
      let input = FilmRGB(red: value, green: value, blue: value)
      let mapped = FilmResponseModel.map(input, response: response)
      XCTAssertEqual(mapped.red, mapped.green, accuracy: 0.0001)
      XCTAssertEqual(mapped.blue, mapped.green, accuracy: 0.0001)
      if value > 0 && value <= 0.25 {
        XCTAssertGreaterThan(mapped.luminance, 0)
        XCTAssertLessThan(mapped.luminance, value)
      }
    }
  }

  func testDigicamRestrainsBrightWarmChromaWithoutLiftingTheBackground() throws {
    let response = try XCTUnwrap(FilmRecipeCatalog.digicam.stages.filmResponse)
    let previous = FilmResponseStage(
      matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
      curves: Array(repeating: [0, 0.065, 0.165, 0.325, 0.535, 0.755, 0.910, 0.980, 1], count: 3),
      saturation: [1.04, 1.16, 1.04],
      hueChroma: Array(repeating: 0, count: 8),
      hueRotate: Array(repeating: 0, count: 8),
      hueLight: Array(repeating: 0, count: 8))
    // Warm flash-lit probes should retain colour but avoid the previous
    // boost that pushed red toward clipping and obscured skin texture.
    for (red, green, blue) in [(0.95, 0.70, 0.48), (0.90, 0.62, 0.42), (0.85, 0.55, 0.32)] {
      let input = FilmRGB(red: red, green: green, blue: blue)
      let before = FilmResponseModel.map(input, response: previous)
      let after = FilmResponseModel.map(input, response: response)
      XCTAssertLessThan(after.red, before.red)
      XCTAssertLessThan(oklabHueAndChroma(after).chroma, oklabHueAndChroma(before).chroma)
      XCTAssertGreaterThan(after.red, after.green)
      XCTAssertGreaterThan(after.green, after.blue)
    }
    for value in [0.125, 0.25, 0.375] {
      let input = FilmRGB(red: value, green: value, blue: value)
      XCTAssertEqual(
        FilmResponseModel.map(input, response: response).luminance,
        FilmResponseModel.map(input, response: previous).luminance, accuracy: 0.000001)
    }
    let white = FilmResponseModel.map(FilmRGB(red: 1, green: 1, blue: 1), response: response)
    XCTAssertEqual(white.red, 1, accuracy: 0.0001)
    XCTAssertEqual(white.green, 1, accuracy: 0.0001)
    XCTAssertEqual(white.blue, 1, accuracy: 0.0001)
  }

  func testDigicamPreservesBlueHueInsteadOfRotatingItViolet() throws {
    let response = try XCTUnwrap(FilmRecipeCatalog.digicam.stages.filmResponse)
    for (red, green, blue) in [(90.0, 140.0, 210.0), (150, 170, 220), (117, 133, 175), (45, 75, 160)] {
      let input = FilmRGB(red: red / 255, green: green / 255, blue: blue / 255)
      let before = oklabHueAndChroma(input)
      let after = oklabHueAndChroma(FilmResponseModel.map(input, response: response))
      let shift = (after.hue - before.hue + 540).truncatingRemainder(dividingBy: 360) - 180
      // A steep shared RGB curve can move blue toward cyan, but must not
      // introduce the violet rotation of the film recipe.
      XCTAssertGreaterThan(shift, -13)
      XCTAssertLessThan(shift, 5)
      let mapped = FilmResponseModel.map(input, response: response)
      XCTAssertGreaterThan(mapped.blue, mapped.green)
      XCTAssertGreaterThan(mapped.green, mapped.red)
    }
  }

  private let huji = FilmRecipeCatalog.nineteenNinetyEight.stages.filmResponse

  func testIdentityResponseIsIdentity() {
    let identity = FilmResponseStage.identity
    for value in stride(from: 0.0, through: 1.0, by: 0.125) {
      let input = FilmRGB(red: value, green: value * 0.5, blue: 1 - value)
      let mapped = FilmResponseModel.map(input, response: identity)
      XCTAssertEqual(mapped.red, input.red, accuracy: 0.002)
      XCTAssertEqual(mapped.green, input.green, accuracy: 0.002)
      XCTAssertEqual(mapped.blue, input.blue, accuracy: 0.002)
    }
  }

  func testGreysStayMonotonicAndBoundedUnderTheFittedResponse() throws {
    let response = try XCTUnwrap(huji, "1998 must carry a film response stage")
    var previous = -1.0
    for step in 0...64 {
      let value = Double(step) / 64
      let mapped = FilmResponseModel.map(
        FilmRGB(red: value, green: value, blue: value), response: response)
      XCTAssertGreaterThanOrEqual(mapped.luminance, previous - 0.0005, "grey \(value) inverted")
      for channel in [mapped.red, mapped.green, mapped.blue] {
        XCTAssertGreaterThanOrEqual(channel, 0)
        XCTAssertLessThanOrEqual(channel, 1)
      }
      previous = mapped.luminance
    }
    let black = FilmResponseModel.map(FilmRGB(red: 0, green: 0, blue: 0), response: response)
    XCTAssertLessThan(black.luminance, 0.01, "black must stay black")
    let white = FilmResponseModel.map(FilmRGB(red: 1, green: 1, blue: 1), response: response)
    XCTAssertGreaterThan(white.luminance, 0.9, "white must stay near white")
  }

  private func grey(_ value: Double, _ response: FilmResponseStage) -> FilmRGB {
    FilmResponseModel.map(FilmRGB(red: value, green: value, blue: value), response: response)
  }

  private func oklabHueAndChroma(_ colour: FilmRGB) -> (hue: Double, chroma: Double) {
    let lab = FilmResponseModel.oklab(
      fromLinear: (
        FilmResponseModel.srgbToLinear(colour.red),
        FilmResponseModel.srgbToLinear(colour.green),
        FilmResponseModel.srgbToLinear(colour.blue)
      ))
    let hue = atan2(lab.2, lab.1) * 180 / .pi
    return (hue < 0 ? hue + 360 : hue, (lab.1 * lab.1 + lab.2 * lab.2).squareRoot())
  }

  func testGreyRampDevelopsTheHujiToneTint() throws {
    // Recipe v5 retargets 1998 to measured Huji output (tools/film-response-fit
    // measure.py → retarget.py): a grey wall develops olive shadows, lavender
    // mids (red and blue over green), and cyan-mint highlights (green and
    // blue over red), while black stays black and clipped white stays white:
    // the cyan belongs to the highlights, not to blown skies and flash spots.
    let response = try XCTUnwrap(huji)

    let shadow = grey(0.08, response)
    XCTAssertGreaterThan(shadow.green, shadow.blue + 0.004, "shadows lean olive, not blue")
    XCTAssertGreaterThan(shadow.green, shadow.red, "shadows lean olive, not red")

    for value in [0.47, 0.71] {
      let mid = grey(value, response)
      XCTAssertGreaterThan(mid.red, mid.green + 0.015, "grey \(value) should read lavender")
      XCTAssertGreaterThan(mid.blue, mid.green + 0.015, "grey \(value) should read lavender")
    }

    let highlight = grey(0.91, response)
    XCTAssertGreaterThan(highlight.green, highlight.red + 0.025, "highlights lean cyan")
    XCTAssertGreaterThan(highlight.blue, highlight.red + 0.025, "highlights lean cyan")

    let white = grey(1, response)
    for channel in [white.red, white.green, white.blue] {
      XCTAssertGreaterThan(channel, 0.98, "clipped white stays white, not cyan")
    }
    XCTAssertLessThan(grey(0, response).luminance, 0.01, "black stays black")
  }

  func testBluesRotateTowardVioletAndGainChroma() throws {
    // Huji pushes skies, denim, and blue walls toward violet: each iPhone
    // blue rotates about +15..+30 degrees in OKLab and never loses chroma.
    let response = try XCTUnwrap(huji)
    let blues = [(90.0, 140.0, 210.0), (150, 170, 220), (117, 133, 175), (45, 75, 160)]
    for (red, green, blue) in blues {
      let input = FilmRGB(red: red / 255, green: green / 255, blue: blue / 255)
      let before = oklabHueAndChroma(input)
      let after = oklabHueAndChroma(FilmResponseModel.map(input, response: response))
      let shift = after.hue - before.hue
      XCTAssertGreaterThan(shift, 15, "blue \(red),\(green),\(blue) rotated only \(shift)°")
      XCTAssertLessThan(shift, 30, "blue \(red),\(green),\(blue) rotated \(shift)°")
      XCTAssertGreaterThanOrEqual(after.chroma, before.chroma * 0.95)
    }
  }

  func testMidtoneSaturationRises() throws {
    // Huji photos measure ~25% more saturated than their iPhone sources.
    let response = try XCTUnwrap(huji)
    func hsvSaturation(_ colour: FilmRGB) -> Double {
      let high = max(colour.red, colour.green, colour.blue)
      let low = min(colour.red, colour.green, colour.blue)
      return high > 0 ? (high - low) / high : 0
    }
    let samples = [
      FilmRGB(red: 0.62, green: 0.45, blue: 0.36),  // skin
      FilmRGB(red: 0.35, green: 0.50, blue: 0.28),  // foliage
      FilmRGB(red: 0.70, green: 0.40, blue: 0.20),  // orange knit
      FilmRGB(red: 0.40, green: 0.48, blue: 0.62),  // denim
    ]
    let before = samples.map(hsvSaturation).reduce(0, +)
    let after = samples.map { hsvSaturation(FilmResponseModel.map($0, response: response)) }
      .reduce(0, +)
    XCTAssertGreaterThan(after, before * 1.1, "midtone saturation \(before) → \(after)")
  }

  func testCurvesBlockMustBeExactlyThreeChannelsOrFallsBackWholesale() {
    let identityCurve = FilmResponseStage.identity.curves[0]
    let black = Array(repeating: 0.0, count: FilmResponseStage.knotCount)
    // One valid-length row: fall back to three identity curves rather than
    // blacking out the red channel and filling the rest.
    let oneRow = FilmResponseStage(
      matrix: FilmResponseStage.identity.matrix, curves: [black], saturation: [1, 1, 1],
      hueChroma: [], hueRotate: [], hueLight: [])
    XCTAssertEqual(oneRow.curves, FilmResponseStage.identity.curves)
    // Four rows: also wholesale fallback, not "keep the first three".
    let fourRows = FilmResponseStage(
      matrix: FilmResponseStage.identity.matrix,
      curves: [black, identityCurve, identityCurve, identityCurve], saturation: [1, 1, 1],
      hueChroma: [], hueRotate: [], hueLight: [])
    XCTAssertEqual(fourRows.curves, FilmResponseStage.identity.curves)
    // Three rows with one bad inner length: only that row falls back.
    let mixed = FilmResponseStage(
      matrix: FilmResponseStage.identity.matrix,
      curves: [black, [0, 1], identityCurve], saturation: [1, 1, 1],
      hueChroma: [], hueRotate: [], hueLight: [])
    XCTAssertEqual(mixed.curves, [black, identityCurve, identityCurve])
  }

  func testColourCubesFollowStageOrderForStillsAndVideo() throws {
    // A manifest with both colour stages composes them in array order in
    // both media paths: the video cube list mirrors the still executor.
    let response = try XCTUnwrap(huji)
    let grade = FilmColorModelTests.legacyHujiGrade
    func recipe(_ stages: [FilmStage]) -> AppliedFilmRecipe {
      AppliedFilmRecipe(
        identifier: .nineteenNinetyEight, version: FilmRecipeVersion.current, seed: 1,
        stages: stages,
        resolvedSettings: FilmResolvedSettings(
          lightLeakApplied: false, dateStampConfiguration: .off, dateStampText: nil,
          timeZoneIdentifier: "GMT"))
    }
    let gradeThenResponse = FilmColorCube.data(
      for: recipe([.colorGrade(grade), .filmResponse(response)]))
    XCTAssertEqual(gradeThenResponse.count, 2)
    XCTAssertEqual(gradeThenResponse[0], FilmColorCube.data(grade: grade))
    XCTAssertEqual(gradeThenResponse[1], FilmColorCube.data(response: response))
    let responseThenGrade = FilmColorCube.data(
      for: recipe([.filmResponse(response), .vignette(VignetteStage(amount: 0)), .colorGrade(grade)]))
    XCTAssertEqual(responseThenGrade[0], FilmColorCube.data(response: response))
    XCTAssertEqual(responseThenGrade[1], FilmColorCube.data(grade: grade))
    XCTAssertTrue(FilmColorCube.data(for: recipe([.vignette(VignetteStage(amount: 0))])).isEmpty)
  }

  func testCubeDataMatchesPointwiseMapping() throws {
    let response = try XCTUnwrap(huji)
    let dimension = 8
    let data = FilmResponseModel.cubeData(dimension: dimension, response: response)
    XCTAssertEqual(data.count, dimension * dimension * dimension * 4 * MemoryLayout<Float>.size)
    let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let (r, g, b) = (5, 2, 7)
    let index = ((b * dimension + g) * dimension + r) * 4
    let expected = FilmResponseModel.map(
      FilmRGB(
        red: Double(r) / Double(dimension - 1),
        green: Double(g) / Double(dimension - 1),
        blue: Double(b) / Double(dimension - 1)),
      response: response)
    XCTAssertEqual(Double(floats[index]), expected.red, accuracy: 0.0001)
    XCTAssertEqual(Double(floats[index + 1]), expected.green, accuracy: 0.0001)
    XCTAssertEqual(Double(floats[index + 2]), expected.blue, accuracy: 0.0001)
    XCTAssertEqual(floats[index + 3], 1)
  }

  /// The Swift port must agree with the Python fitter that produced the
  /// recipe (`tools/film-response-fit/model.py`). The fixture holds the
  /// response parameters and probe colours mapped by Python.
  func testSwiftPortMatchesPythonReferenceProbes() throws {
    struct Fixture: Decodable {
      struct Probe: Decodable {
        let input: [Double]
        let output: [Double]
      }
      let response: FilmResponseStage
      let probes: [Probe]
    }
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "film-response-probes", withExtension: "json"))
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    XCTAssertGreaterThan(fixture.probes.count, 100)
    for probe in fixture.probes {
      let mapped = FilmResponseModel.map(
        FilmRGB(red: probe.input[0], green: probe.input[1], blue: probe.input[2]),
        response: fixture.response)
      let label = "probe \(probe.input)"
      XCTAssertEqual(mapped.red, probe.output[0], accuracy: 0.5 / 255, label)
      XCTAssertEqual(mapped.green, probe.output[1], accuracy: 0.5 / 255, label)
      XCTAssertEqual(mapped.blue, probe.output[2], accuracy: 0.5 / 255, label)
    }
    // And the shipped 1998 response is the fitted one, not a stale copy.
    XCTAssertEqual(fixture.response, try XCTUnwrap(huji))
  }

  func testMalformedResponseFallsBackToIdentityInsteadOfTrapping() throws {
    let decoder = ApertureJSON.makeDecoder()
    let json = Data(
      (#"{"kind":"filmResponse","configuration":{"matrix":[1,2],"curves":[[0,1]],"saturation":[1],"#
        + #""hueChroma":[0.1,0.2],"hueRotate":[],"hueLight":[]}}"#).utf8)
    // Wrong element counts fall back wholesale; a partially specified
    // configuration decodes with identity defaults.
    guard case .filmResponse(let stage) = try decoder.decode(FilmStage.self, from: json) else {
      return XCTFail("expected a filmResponse stage")
    }
    XCTAssertEqual(stage.matrix, FilmResponseStage.identity.matrix)
    XCTAssertEqual(stage.curves, FilmResponseStage.identity.curves)
    XCTAssertEqual(stage.hueChroma, FilmResponseStage.identity.hueChroma)
    let empty = Data(#"{"kind":"filmResponse","configuration":{}}"#.utf8)
    guard case .filmResponse(let defaulted) = try decoder.decode(FilmStage.self, from: empty)
    else { return XCTFail("expected a filmResponse stage") }
    XCTAssertEqual(defaulted, .identity)
    let mapped = FilmResponseModel.map(FilmRGB(red: 0.3, green: 0.6, blue: 0.9), response: defaulted)
    XCTAssertEqual(mapped.red, 0.3, accuracy: 0.002)
    let nonFinite = FilmResponseStage(
      matrix: [1, 0, 0, 0, .nan, 0, 0, 0, .infinity], curves: FilmResponseStage.identity.curves,
      saturation: [1, 1, 1], hueChroma: [], hueRotate: [], hueLight: [])
    XCTAssertEqual(nonFinite.matrix, FilmResponseStage.identity.matrix)
  }

  func testResponseStageRoundTripsThroughTheStageCodec() throws {
    let response = try XCTUnwrap(huji)
    let encoder = ApertureJSON.makeEncoder()
    let decoder = ApertureJSON.makeDecoder()
    let data = try encoder.encode(FilmStage.filmResponse(response))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["kind"] as? String, "filmResponse")
    XCTAssertEqual(try decoder.decode(FilmStage.self, from: data), .filmResponse(response))
  }
}
