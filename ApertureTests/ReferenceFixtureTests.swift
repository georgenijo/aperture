import CoreImage
import XCTest

@testable import Aperture

final class ReferenceFixtureTests: XCTestCase {
  private let fixtureNames = ["day-portrait", "night-flash", "hdr-still-life"]
  private let captureDate = Date(timeIntervalSince1970: 893_980_800)

  func testRepresentativeFixturesRemainVisibleAcrossEveryFilm() throws {
    let context = CIContext(options: [.useSoftwareRenderer: true])

    for fixtureName in fixtureNames {
      let source = try fixtureData(named: fixtureName)
      for (index, film) in FilmRecipeCatalog.all.enumerated() {
        let applied = film.resolve(
          seed: UInt64(4_200 + index),
          capturedAt: captureDate,
          options: FilmProcessingOptions(
            lightLeaksEnabled: true,
            dateStamp: .off
          ),
          timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt
        )
        let rendered = try FilmProcessor.shared.process(
          source,
          recipe: applied,
          renderSize: .preview(maxPixelDimension: 256)
        )
        let statistics = try luminanceStatistics(for: rendered, context: context)

        XCTAssertTrue(rendered.extent.width.isFinite)
        XCTAssertTrue(rendered.extent.height.isFinite)
        XCTAssertGreaterThan(rendered.extent.width, 0)
        XCTAssertGreaterThan(rendered.extent.height, 0)
        XCTAssertGreaterThan(
          statistics.mean, 0.04, "\(fixtureName) / \(film.displayName) became too dark")
        XCTAssertLessThan(
          statistics.mean, 0.96, "\(fixtureName) / \(film.displayName) became too bright")
        XCTAssertGreaterThan(
          statistics.standardDeviation, 0.035,
          "\(fixtureName) / \(film.displayName) lost useful contrast")
        XCTAssertLessThan(
          statistics.clippedBlackFraction, 0.72,
          "\(fixtureName) / \(film.displayName) crushed most shadows")
        XCTAssertLessThan(
          statistics.clippedWhiteFraction, 0.72,
          "\(fixtureName) / \(film.displayName) clipped most highlights")
        for channelMean in [statistics.redMean, statistics.greenMean, statistics.blueMean] {
          XCTAssertTrue(channelMean.isFinite)
          XCTAssertTrue((0...1).contains(channelMean))
        }
      }
    }
  }

  private func fixtureData(named name: String) throws -> Data {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "png"))
    return try Data(contentsOf: url)
  }

  private func luminanceStatistics(
    for image: CIImage,
    context: CIContext
  ) throws -> (
    mean: Double,
    standardDeviation: Double,
    clippedBlackFraction: Double,
    clippedWhiteFraction: Double,
    redMean: Double,
    greenMean: Double,
    blueMean: Double
  ) {
    let extent = image.extent
    let scale = min(1, 64 / max(extent.width, extent.height))
    let width = max(1, Int((extent.width * scale).rounded(.down)))
    let height = max(1, Int((extent.height * scale).rounded(.down)))
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let sample =
      image
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .cropped(to: bounds)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    context.render(
      sample,
      toBitmap: &pixels,
      rowBytes: width * 4,
      bounds: bounds,
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )

    var luminances = [Double]()
    var redValues = [Double]()
    var greenValues = [Double]()
    var blueValues = [Double]()
    luminances.reserveCapacity(width * height)
    redValues.reserveCapacity(width * height)
    greenValues.reserveCapacity(width * height)
    blueValues.reserveCapacity(width * height)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let red = Double(pixels[offset]) / 255
      let green = Double(pixels[offset + 1]) / 255
      let blue = Double(pixels[offset + 2]) / 255
      luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
      redValues.append(red)
      greenValues.append(green)
      blueValues.append(blue)
    }
    let mean = luminances.reduce(0, +) / Double(luminances.count)
    let variance = luminances.reduce(0) { $0 + pow($1 - mean, 2) } / Double(luminances.count)
    let clippedBlack = Double(luminances.filter { $0 < 0.012 }.count) / Double(luminances.count)
    let clippedWhite = Double(luminances.filter { $0 > 0.988 }.count) / Double(luminances.count)
    return (
      mean,
      sqrt(variance),
      clippedBlack,
      clippedWhite,
      redValues.reduce(0, +) / Double(redValues.count),
      greenValues.reduce(0, +) / Double(greenValues.count),
      blueValues.reduce(0, +) / Double(blueValues.count)
    )
  }
}
