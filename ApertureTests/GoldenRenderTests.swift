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
    var fileSuffix = ""
  }

  /// 1998 as shipped in recipe v4, frozen here because the catalog now builds
  /// v5. Items developed under v4 persist these stages and must keep
  /// rendering exactly as they did; its goldens are the v4 1998 renders.
  private static let nineteenNinetyEightV4 = FilmRecipe(
    id: .nineteenNinetyEight,
    version: 4,
    displayName: "1998",
    stages: [
      .filmResponse(
        FilmResponseStage(
          matrix: [0.998348, -0.008885, -0.148114,
            0.151087, 0.997864, -0.128046,
            -0.044489, -0.039532, 0.999481],
          curves: [
            [0.000000, 0.090402, 0.152593, 0.319448, 0.439925, 0.613285, 0.779785, 0.917039, 0.994538],
            [0.000000, 0.070095, 0.141415, 0.319199, 0.439739, 0.613283, 0.778255, 0.910293, 0.981941],
            [0.000000, 0.047451, 0.130237, 0.318950, 0.439552, 0.613282, 0.775150, 0.903420, 0.968171],
          ],
          saturation: [0.758925, 1.199240, 0.579074],
          hueChroma: [-0.008910, 0.246697, -0.133371, -0.010636, -0.002446, -0.004587, -0.164736, -0.002792],
          hueRotate: [-0.003869, -0.122947, -0.142692, -0.002308, 0.002107, 0.150000, -0.001415, -0.110779],
          hueLight: [-0.038137, 0.247080, -0.088487, -0.014831, -0.006916, -0.055911, -0.009129, -0.214261])),
      .halation(
        HalationStage(
          amount: 0.30, radiusScale: 0.02,
          tint: .fixed(red: 1.0, green: 0.80, blue: 0.90), radiusScalesWithAmount: false)),
      .softness(SoftnessStage(amount: 0.72, kind: .gaussian)),
      .dateStamp(DateStampStage(style: .sevenSegment)),
      .chromaticAberration(
        ChromaticAberrationStage(
          amount: 0.78, redGain: -0.0022, blueGain: 0.0032, lateralShiftScale: 0, seeded: false)),
      .grain(GrainStage(amount: 0.22, size: 1.0)),
      .lightLeak(
        LightLeakStage(
          probability: 0.46, strength: 0.30, minWidth: 0.10, maxWidth: 0.27,
          palette: [
            LightLeakColor(red: 1.0, green: 0.47, blue: 0.16),
            LightLeakColor(red: 1.0, green: 0.42, blue: 0.12),
            LightLeakColor(red: 1.0, green: 0.52, blue: 0.20),
          ],
          edges: [.top, .right],
          alphaCap: 0.16
        )),
      .vignette(VignetteStage(amount: 0.32)),
    ]
  )

  func testGoldenRendersMatchCapturedPipelineOutput() async throws {
    let writeDirectory = ProcessInfo.processInfo.environment["APERTURE_WRITE_GOLDENS"]
    if writeDirectory == nil {
      #if !targetEnvironment(simulator)
        throw XCTSkip(
          "On-device CPU rendering may differ from the golden references by up to one LSB.")
      #endif
    }

    var cases: [GoldenCase] = []
    let films = FilmRecipeCatalog.all.enumerated().map { ($0.offset, $0.element, "") }
      + [(0, Self.nineteenNinetyEightV4, "-v4")]
    for (filmIndex, film, fileSuffix) in films {
      for (fixtureIndex, fixtureName) in fixtureNames.enumerated() {
        let base = UInt64(1_000 + filmIndex * 100 + fixtureIndex * 10)
        let seed = findLightLeakSeed(for: film, base: base)
        let applied = film.resolve(
          seed: seed, capturedAt: captureDate, options: options, timeZone: .gmt)
        XCTAssertEqual(
          applied.resolvedSettings.lightLeakApplied, (film.stages.lightLeak?.probability ?? 0) > 0,
          "\(film.displayName)/\(fixtureName) must cover its configured leak behaviour")
        cases.append(
          GoldenCase(fixtureName: fixtureName, recipe: film, seed: seed, fileSuffix: fileSuffix))
      }
    }
    // Every stage runs on this pipeline (colour grade, halation/bloom,
    // softness, chromatic aberration, grain, vignette, date stamp); the
    // catalog films above additionally cover the light-leak stage. Original
    // Capture covers the all-zero grade (stamp still on) on top of that.
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
      let fileName =
        "golden-\(testCase.fixtureName)-\(sanitizedIdentifier)\(testCase.fileSuffix).png"

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
    guard (film.stages.lightLeak?.probability ?? 0) > 0 else { return base }
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
