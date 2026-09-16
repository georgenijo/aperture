import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest

@testable import Aperture

/// Captures the exact pixel output of the pre-refactor (v1, flat-parameter)
/// film pipeline. Issue #17 turns each recipe's flat knobs into an ordered
/// stage list; this fixture set is the pixel-identity contract that refactor
/// must satisfy. Regenerate these PNGs only when a look is intentionally
/// changed, never as a side effect of a structural refactor.
final class GoldenRenderTests: XCTestCase {
  private let fixtureNames = ["day-portrait", "night-flash", "hdr-still-life"]
  private let captureDate = Date(timeIntervalSince1970: 893_980_800)
  private let renderDimension = 256

  private var options: FilmProcessingOptions {
    FilmProcessingOptions(
      lightLeaksEnabled: true,
      dateStamp: DateStampConfiguration(
        mode: .nostalgic1998, format: .yearMonthDay, localeIdentifier: "en_US_POSIX")
    )
  }

  private struct GoldenCase {
    let fixtureName: String
    let recipe: FilmRecipe
    let seed: UInt64
  }

  func testGoldenRendersMatchCapturedPipelineOutput() async throws {
    let writeDirectory = ProcessInfo.processInfo.environment["APERTURE_WRITE_GOLDENS"]
    if writeDirectory == nil {
      #if !targetEnvironment(simulator)
        throw XCTSkip(
          "On-device CPU rendering may differ from the golden references by up to one LSB.")
      #endif
    }

    var cases: [GoldenCase] = []
    for (filmIndex, film) in FilmRecipeCatalog.all.enumerated() {
      for (fixtureIndex, fixtureName) in fixtureNames.enumerated() {
        let base = UInt64(1_000 + filmIndex * 100 + fixtureIndex * 10)
        let seed = findLightLeakSeed(for: film, base: base)
        let applied = film.resolve(
          seed: seed, capturedAt: captureDate, options: options, timeZone: .gmt)
        XCTAssertTrue(
          applied.resolvedSettings.lightLeakApplied,
          "\(film.displayName)/\(fixtureName) must cover a light-leak render")
        cases.append(GoldenCase(fixtureName: fixtureName, recipe: film, seed: seed))
      }
    }
    // Every stage runs on this pipeline (colour grade, halation/bloom,
    // softness, chromatic aberration, grain, vignette, date stamp); the
    // catalog films above additionally cover the light-leak stage. Original
    // Capture covers the all-zero, dateless baseline on top of that.
    cases.append(
      GoldenCase(fixtureName: "day-portrait", recipe: FilmRecipeCatalog.legacyOriginal, seed: 42))

    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))

    for testCase in cases {
      let applied = testCase.recipe.resolve(
        seed: testCase.seed, capturedAt: captureDate, options: options, timeZone: .gmt)
      let source = try fixtureCGImage(named: testCase.fixtureName)
      let rendered = try await processor.renderedCGImage(
        CIImage(cgImage: source),
        recipe: applied,
        orientation: .up,
        renderSize: .preview(maxPixelDimension: renderDimension)
      )
      let sanitizedIdentifier = testCase.recipe.id.rawValue.replacingOccurrences(
        of: ".", with: "-")
      let fileName = "golden-\(testCase.fixtureName)-\(sanitizedIdentifier).png"

      if let writeDirectory {
        let directoryURL = URL(fileURLWithPath: writeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
          at: directoryURL, withIntermediateDirectories: true)
        try writePNG(rendered, to: directoryURL.appendingPathComponent(fileName))
      } else {
        #if targetEnvironment(simulator)
          assertMatchesGolden(rendered, fileName: fileName)
        #endif
      }
    }
  }

  /// Searches seeds upward from `base` until the resolved recipe reports a
  /// light-leak render, so the golden set provably exercises that stage.
  private func findLightLeakSeed(for film: FilmRecipe, base: UInt64) -> UInt64 {
    var seed = base
    for _ in 0..<5_000 {
      let applied = film.resolve(
        seed: seed, capturedAt: captureDate, options: options, timeZone: .gmt)
      if applied.resolvedSettings.lightLeakApplied {
        return seed
      }
      seed += 1
    }
    XCTFail("Could not find a light-leak seed for \(film.displayName) within budget")
    return base
  }

  private func fixtureCGImage(named name: String) throws -> CGImage {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "png"))
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw FilmProcessorError.decodeFailed
    }
    return cgImage
  }

  private func writePNG(_ image: CGImage, to url: URL) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)
    else {
      throw FilmProcessorError.cannotCreateDestination
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw FilmProcessorError.cannotFinalizeDestination
    }
  }

  private func assertMatchesGolden(
    _ rendered: CGImage, fileName: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let bundle = Bundle(for: Self.self)
    let baseName = (fileName as NSString).deletingPathExtension
    guard let referenceURL = bundle.url(forResource: baseName, withExtension: "png") else {
      XCTFail("Missing golden fixture \(fileName)", file: file, line: line)
      return
    }
    guard let referenceSource = CGImageSourceCreateWithURL(referenceURL as CFURL, nil),
      let referenceImage = CGImageSourceCreateImageAtIndex(referenceSource, 0, nil)
    else {
      XCTFail("Could not decode golden fixture \(fileName)", file: file, line: line)
      return
    }
    XCTAssertEqual(
      referenceImage.width, rendered.width, "\(fileName) width mismatch", file: file, line: line)
    XCTAssertEqual(
      referenceImage.height, rendered.height, "\(fileName) height mismatch", file: file, line: line
    )
    guard referenceImage.width == rendered.width, referenceImage.height == rendered.height else {
      return
    }
    guard let referenceBytes = rgba8Bytes(referenceImage), let renderedBytes = rgba8Bytes(rendered)
    else {
      XCTFail("Could not rasterize \(fileName) for comparison", file: file, line: line)
      return
    }
    var maxDelta = 0
    for index in 0..<min(referenceBytes.count, renderedBytes.count) {
      let delta = abs(Int(referenceBytes[index]) - Int(renderedBytes[index]))
      if delta > maxDelta { maxDelta = delta }
    }
    XCTAssertLessThanOrEqual(
      maxDelta, 1,
      "\(fileName) exceeded the 1/255 tolerance with a max per-channel delta of \(maxDelta)/255",
      file: file, line: line)
  }

  /// Draws through a canonical sRGB RGBA8 context so a freshly rendered
  /// `CGImage` and a PNG round-tripped through `ImageIO` compare byte-for-byte.
  private func rgba8Bytes(_ image: CGImage) -> [UInt8]? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let baseAddress = buffer.baseAddress,
        let context = CGContext(
          data: baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return success ? bytes : nil
  }
}
