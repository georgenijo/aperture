import Foundation
import XCTest

@testable import Aperture

final class FilmResponseModelTests: XCTestCase {
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
