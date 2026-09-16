import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Aperture

/// Geometry, colour, and rendering coverage for the `.sevenSegment` LED
/// date-stamp style. The `.monospaced` style's pixels are already covered
/// (unchanged) by `GoldenRenderTests`.
final class DateStampOverlayTests: XCTestCase {
  private let sampleText = "9 15 '26"

  // MARK: - Layout geometry

  func testSevenSegmentLayoutPortraitHugsLeftEdgeReadingBottomToTop() throws {
    let canvasSize = CGSize(width: 3024, height: 4032)
    let stage = DateStampStage(style: .sevenSegment)
    let layout = try XCTUnwrap(
      FilmDateStampLayout.make(text: sampleText, canvasSize: canvasSize, style: stage))

    XCTAssertEqual(layout.rotation, .pi / 2, accuracy: 0.0001)
    XCTAssertEqual(layout.fontPointSize, 84.672, accuracy: 0.1)

    // Rotating the (unrotated) frame by +90° about its own origin
    // (frame.minX, frame.minY) sweeps the advance direction (frame.width)
    // from +x to +y and the glyph-cell height (frame.height ==
    // fontPointSize) from +y to -x, so the visual bounding box spans
    // x: [frame.minX - fontPointSize, frame.minX], y: [frame.minY, frame.minY + frame.width].
    let visualMinX = layout.frame.minX - layout.fontPointSize
    let visualMaxX = layout.frame.minX
    let shortestSide = min(canvasSize.width, canvasSize.height)
    XCTAssertEqual(
      visualMinX / shortestSide, 0.035, accuracy: 0.001,
      "the gap between the left edge and the nearest glyph edge is the 3.5% margin")
    XCTAssertLessThan(
      visualMaxX, canvasSize.width * 0.10, "the stamp should hug the left 10% of the width")

    XCTAssertEqual(layout.frame.minY / shortestSide, 0.11, accuracy: 0.001)
  }

  func testSevenSegmentLayoutLandscapeIsBottomRightWithoutRotation() throws {
    let canvasSize = CGSize(width: 4032, height: 3024)
    let stage = DateStampStage(style: .sevenSegment)
    let layout = try XCTUnwrap(
      FilmDateStampLayout.make(text: sampleText, canvasSize: canvasSize, style: stage))

    XCTAssertEqual(layout.rotation, 0)
    XCTAssertGreaterThan(layout.frame.minX, canvasSize.width * 0.5)
    XCTAssertLessThanOrEqual(layout.frame.maxX, canvasSize.width)
    XCTAssertLessThan(layout.frame.minY, canvasSize.height * 0.5)
  }

  func testMonospacedTwoArgumentOverloadStillCompilesAndMatchesDefaultStyle() throws {
    let canvasSize = CGSize(width: 1000, height: 800)
    let legacy = try XCTUnwrap(FilmDateStampLayout.make(text: sampleText, canvasSize: canvasSize))
    let explicit = try XCTUnwrap(
      FilmDateStampLayout.make(text: sampleText, canvasSize: canvasSize, style: DateStampStage()))
    XCTAssertEqual(legacy, explicit)
    XCTAssertEqual(legacy.rotation, 0)
  }

  // MARK: - Rendered pixels

  func testSevenSegmentRenderIsOrangeAlongLeftEdgeWithGlow() throws {
    let width = 756
    let height = 1008
    let extent = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    let stage = DateStampStage(style: .sevenSegment)
    let image = try XCTUnwrap(
      FilmOverlayFactory.dateStampImage(text: sampleText, extent: extent, stage: stage))

    let context = CIContext(options: [.useSoftwareRenderer: true])
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    context.render(
      image,
      toBitmap: &pixels,
      rowBytes: width * 4,
      bounds: extent,
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )

    var opaqueCount = 0
    var opaqueSumR = 0.0
    var opaqueSumG = 0.0
    var opaqueSumB = 0.0
    var glowCount = 0
    var outsideLeftBandOpaque = 0
    let leftBand = CGFloat(width) * 0.12

    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let alpha = Double(pixels[offset + 3]) / 255.0
        if alpha > 0.5, CGFloat(x) >= leftBand {
          outsideLeftBandOpaque += 1
        }
        if alpha > 0.9 {
          // Bitmap channels may be premultiplied; unpremultiply by the
          // pixel's own alpha to recover the fill colour.
          opaqueCount += 1
          opaqueSumR += Double(pixels[offset]) / alpha
          opaqueSumG += Double(pixels[offset + 1]) / alpha
          opaqueSumB += Double(pixels[offset + 2]) / alpha
        }
        if alpha > 0.05, alpha < 0.5 {
          glowCount += 1
        }
      }
    }

    XCTAssertEqual(
      outsideLeftBandOpaque, 0, "opaque-ish pixels must stay within the left 12% of the width")
    XCTAssertGreaterThan(opaqueCount, 0, "expected crisp digit pixels")
    XCTAssertEqual(opaqueSumR / Double(opaqueCount), 193, accuracy: 12)
    XCTAssertEqual(opaqueSumG / Double(opaqueCount), 81, accuracy: 12)
    XCTAssertEqual(opaqueSumB / Double(opaqueCount), 17, accuracy: 12)
    XCTAssertGreaterThan(glowCount, 0, "expected a soft glow halo beyond the crisp digit alpha")
  }

  // MARK: - Digit segment table

  func testEachDigitRendersItsStandardSegmentPattern() {
    let expected: [Int: Set<Character>] = [
      0: ["a", "b", "c", "d", "e", "f"],
      1: ["b", "c"],
      2: ["a", "b", "d", "e", "g"],
      3: ["a", "b", "c", "d", "g"],
      4: ["b", "c", "f", "g"],
      5: ["a", "c", "d", "f", "g"],
      6: ["a", "c", "d", "e", "f", "g"],
      7: ["a", "b", "c"],
      8: ["a", "b", "c", "d", "e", "f", "g"],
      9: ["a", "b", "c", "d", "f", "g"],
    ]
    for digit in 0...9 {
      XCTAssertEqual(
        FilmOverlayFactory.sevenSegmentLitSegments(for: digit), expected[digit],
        "digit \(digit) should light the standard LED segment set")
    }
    XCTAssertEqual(
      Set(expected.values).count, 10, "every digit 0-9 should have a distinct lit-segment set")
  }

  // MARK: - Visual preview (skipped unless APERTURE_STAMP_PREVIEW is set)

  func testSevenSegmentPreviewRender() throws {
    guard let path = ProcessInfo.processInfo.environment["APERTURE_STAMP_PREVIEW"],
      !path.isEmpty
    else {
      throw XCTSkip("Set APERTURE_STAMP_PREVIEW to a file path to write a preview PNG.")
    }

    let width = 756
    let height = 1008
    let extent = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    let stage = DateStampStage(style: .sevenSegment)
    let background = CIImage(color: CIColor(red: 0.35, green: 0.35, blue: 0.35)).cropped(
      to: extent)
    let stamp = try XCTUnwrap(
      FilmOverlayFactory.dateStampImage(text: sampleText, extent: extent, stage: stage))
    let composite = try XCTUnwrap(CIFilter(name: "CISourceOverCompositing"))
    composite.setValue(stamp, forKey: kCIInputImageKey)
    composite.setValue(background, forKey: kCIInputBackgroundImageKey)
    let result = try XCTUnwrap(composite.outputImage?.cropped(to: extent))

    let context = CIContext(options: [.useSoftwareRenderer: true])
    let cgImage = try XCTUnwrap(context.createCGImage(result, from: extent))

    let destinationURL = URL(fileURLWithPath: path)
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, cgImage, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination), "failed to write preview PNG to \(path)")
  }
}

