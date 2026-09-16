import CoreGraphics
import CoreImage
import Foundation
import XCTest

@testable import Aperture

final class FilmProcessorTests: XCTestCase {
  func testProcessingDecisionIsDeterministicForSeed() throws {
    let recipe = makeRecipe(seed: 0x1234_5678_9ABC_DEF0)
    let first = FilmProcessingDecision.make(for: recipe)
    let second = FilmProcessingDecision.make(for: recipe)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.seed, recipe.seed)

    let different = FilmProcessingDecision.make(for: makeRecipe(seed: recipe.seed &+ 1))
    XCTAssertNotEqual(first, different)
    if let leak = first.leak {
      XCTAssertTrue((0.16...0.84).contains(leak.position))
      XCTAssertTrue((0.16...0.42).contains(leak.width))
      XCTAssertTrue((0...1).contains(leak.intensity))
    }
  }

  func testCatalogAndResolvedParametersRemainBounded() {
    let date = Date(timeIntervalSince1970: 915_148_800)
    let options = FilmProcessingOptions(
      lightLeaksEnabled: true,
      dateStamp: DateStampConfiguration(mode: .off)
    )
    for catalogRecipe in FilmRecipeCatalog.all {
      XCTAssertTrue(catalogRecipe.baseParameters.isWithinSupportedBounds)
      let applied = catalogRecipe.resolve(
        seed: 99,
        capturedAt: date,
        options: options,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
      XCTAssertTrue(applied.parameters.isWithinSupportedBounds)
      XCTAssertEqual(applied.version, catalogRecipe.version)
      XCTAssertEqual(applied.seed, 99)
    }
  }

  func testResolvedCompressionQualityIsDeterministicAndBounded() {
    let expected: [(PhotoQualityPreference, Double)] = [
      (.spaceSaving, 0.72),
      (.balanced, 0.88),
      (.maximum, 0.97),
    ]
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    for (preference, expectedQuality) in expected {
      let options = FilmProcessingOptions(
        lightLeaksEnabled: true,
        dateStamp: .off,
        photoQuality: preference
      )
      let first = FilmRecipeCatalog.night.resolve(
        seed: 44,
        capturedAt: date,
        options: options,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
      let second = FilmRecipeCatalog.night.resolve(
        seed: 44,
        capturedAt: date,
        options: options,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )

      XCTAssertEqual(first.compressionQuality, expectedQuality, accuracy: 0.000_001)
      XCTAssertEqual(first.compressionQuality, second.compressionQuality, accuracy: 0.000_001)
      XCTAssertTrue(first.compressionQuality.isFinite)
      XCTAssertTrue((0.0...1.0).contains(first.compressionQuality))
    }

    let settingsAtZero = FilmResolvedSettings(
      lightLeakApplied: false,
      dateStampConfiguration: .off,
      dateStampText: nil,
      timeZoneIdentifier: TimeZone(secondsFromGMT: 0)!.identifier,
      compressionQuality: -1
    )
    let settingsAtOne = FilmResolvedSettings(
      lightLeakApplied: false,
      dateStampConfiguration: .off,
      dateStampText: nil,
      timeZoneIdentifier: TimeZone(secondsFromGMT: 0)!.identifier,
      compressionQuality: 2
    )
    let settingsAtNaN = FilmResolvedSettings(
      lightLeakApplied: false,
      dateStampConfiguration: .off,
      dateStampText: nil,
      timeZoneIdentifier: TimeZone(secondsFromGMT: 0)!.identifier,
      compressionQuality: .nan
    )
    XCTAssertEqual(settingsAtZero.compressionQuality, 0)
    XCTAssertEqual(settingsAtOne.compressionQuality, 1)
    XCTAssertEqual(
      settingsAtNaN.compressionQuality, PhotoQualityPreference.balanced.compressionQuality)
  }

  func testLegacyResolvedSettingsDecodeDefaultsToBalancedQuality() throws {
    let legacyPayload = Data(
      """
      {
        "lightLeakApplied": false,
        "dateStampConfiguration": {
          "mode": "off",
          "format": "yearMonthDay",
          "localeIdentifier": "en_US_POSIX"
        },
        "dateStampText": null,
        "timeZoneIdentifier": "GMT"
      }
      """.utf8
    )

    let decoded = try JSONDecoder().decode(FilmResolvedSettings.self, from: legacyPayload)
    XCTAssertEqual(decoded.compressionQuality, PhotoQualityPreference.balanced.compressionQuality)
  }

  func testPersistedDateStampTextAndLayoutScaleTogether() throws {
    let date = Date(timeIntervalSince1970: 915_148_800)
    let options = FilmProcessingOptions(
      lightLeaksEnabled: false,
      dateStamp: DateStampConfiguration(
        mode: .nostalgic1998,
        format: .yearMonthDay,
        localeIdentifier: "en_US_POSIX"
      )
    )
    let recipe = FilmRecipeCatalog.nineteenNinetyEight.resolve(
      seed: 7,
      capturedAt: date,
      options: options,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    XCTAssertEqual(recipe.resolvedSettings.dateStampText, "1999/01/01  00:00")

    let small = try XCTUnwrap(
      FilmDateStampLayout.make(
        text: "1999/01/01  00:00", canvasSize: CGSize(width: 1000, height: 800)))
    let large = try XCTUnwrap(
      FilmDateStampLayout.make(
        text: "1999/01/01  00:00", canvasSize: CGSize(width: 2000, height: 1600)))
    XCTAssertEqual(large.frame.minX, small.frame.minX * 2, accuracy: 0.01)
    XCTAssertEqual(large.frame.minY, small.frame.minY * 2, accuracy: 0.01)
    XCTAssertEqual(large.frame.width, small.frame.width * 2, accuracy: 0.01)
    XCTAssertEqual(large.fontPointSize, small.fontPointSize * 2, accuracy: 0.01)
  }

  func testSyntheticRenderChangesStatisticsWithoutClippingToBlack() async throws {
    let source = try XCTUnwrap(makeSyntheticImage(width: 256, height: 192))
    let sourceImage = CIImage(cgImage: source)
    let recipe = makeRecipe(seed: 0xBADC_0FFE)
    let output = try await FilmProcessor.shared.renderedCGImage(
      sourceImage,
      recipe: recipe,
      orientation: .up,
      renderSize: .preview(maxPixelDimension: 256)
    )
    XCTAssertEqual(output.width, 256)
    XCTAssertEqual(output.height, 192)

    let sourceStats = try pixelStatistics(source)
    let outputStats = try pixelStatistics(output)
    XCTAssertGreaterThan(outputStats.mean, 0.03)
    XCTAssertLessThan(outputStats.mean, 0.98)
    XCTAssertGreaterThan(outputStats.standardDeviation, 0.005)
    XCTAssertGreaterThan(outputStats.meanAbsoluteDifference(from: sourceStats), 0.001)
    XCTAssertTrue(outputStats.allFinite)
  }

  func testColorStageRendersTheFilmColorModel() async throws {
    // A flat wall-coloured frame with every spatial effect at zero must come
    // out as the colour model's mapping: stills and video share that cube.
    let wall = FilmRGB(red: 171 / 255, green: 173 / 255, blue: 163 / 255)
    let source = try XCTUnwrap(makeSolidImage(wall, width: 64, height: 48))
    XCTAssertEqual(try centrePixel(source).blue, wall.blue, accuracy: 1 / 255, "source")
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let recipe = makeGradeOnlyRecipe(FilmRecipeCatalog.nineteenNinetyEight.baseParameters)
    let output = try await processor.renderedCGImage(
      CIImage(cgImage: source), recipe: recipe, renderSize: .preview(maxPixelDimension: 64))

    let expected = FilmColorModel.map(wall, grade: recipe.parameters.colorGrade)
    let centre = try centrePixel(output)
    XCTAssertEqual(centre.red, expected.red, accuracy: 3 / 255, "red")
    XCTAssertEqual(centre.green, expected.green, accuracy: 3 / 255, "green")
    XCTAssertEqual(centre.blue, expected.blue, accuracy: 3 / 255, "blue")
    // Sanity: the Huji grade should not paint a neutral wall lavender.
    XCTAssertLessThan(abs(centre.blue - centre.red), 0.08)
  }

  func testRenderedOutputIsExactlyRepeatableForSameSeed() async throws {
    let source = try XCTUnwrap(makeSyntheticImage(width: 96, height: 72))
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let recipe = makeRecipe(seed: 0x0123_4567_89AB_CDEF)

    let first = try await processor.renderedCGImage(
      CIImage(cgImage: source),
      recipe: recipe,
      renderSize: .preview(maxPixelDimension: 96)
    )
    let second = try await processor.renderedCGImage(
      CIImage(cgImage: source),
      recipe: recipe,
      renderSize: .preview(maxPixelDimension: 96)
    )

    XCTAssertEqual(first.width, second.width)
    XCTAssertEqual(first.height, second.height)
    XCTAssertEqual(try pixelBytes(first), try pixelBytes(second))
  }

  func testRenderedOutputVariesForDifferentSeeds() async throws {
    let source = try XCTUnwrap(makeSyntheticImage(width: 96, height: 72))
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let first = try await processor.renderedCGImage(
      CIImage(cgImage: source),
      recipe: makeRecipe(seed: 11),
      renderSize: .preview(maxPixelDimension: 96)
    )
    let second = try await processor.renderedCGImage(
      CIImage(cgImage: source),
      recipe: makeRecipe(seed: 12),
      renderSize: .preview(maxPixelDimension: 96)
    )

    XCTAssertNotEqual(try pixelBytes(first), try pixelBytes(second))
  }

  func testProcessorRejectsMalformedDataInvalidRenderSizeAndUnsupportedRecipe() async throws {
    XCTAssertThrowsError(
      try FilmProcessor.shared.process(
        Data("not-an-image".utf8),
        recipe: makeRecipe(seed: 1)
      )
    ) { error in
      XCTAssertEqual(error as? FilmProcessorError, .decodeFailed)
    }

    let source = try XCTUnwrap(makeSyntheticImage(width: 32, height: 24))
    XCTAssertThrowsError(
      try FilmProcessor.shared.process(
        source,
        recipe: makeRecipe(seed: 1),
        renderSize: .preview(maxPixelDimension: 0)
      )
    ) { error in
      XCTAssertEqual(error as? FilmProcessorError, .invalidRenderSize)
    }

    let valid = makeRecipe(seed: 1)
    let unsupported = AppliedFilmRecipe(
      identifier: valid.identifier,
      version: 2,
      seed: valid.seed,
      parameters: valid.parameters,
      resolvedSettings: valid.resolvedSettings
    )
    XCTAssertThrowsError(try FilmProcessor.shared.process(source, recipe: unsupported)) { error in
      XCTAssertEqual(error as? FilmProcessorError, .unsupportedRecipeVersion(2))
    }

    let missingStamp = AppliedFilmRecipe(
      identifier: valid.identifier,
      version: valid.version,
      seed: valid.seed,
      parameters: valid.parameters,
      resolvedSettings: FilmResolvedSettings(
        lightLeakApplied: false,
        dateStampConfiguration: DateStampConfiguration(
          mode: .current,
          format: .yearMonthDay,
          localeIdentifier: "en_US_POSIX"
        ),
        dateStampText: nil,
        timeZoneIdentifier: TimeZone.gmt.identifier
      )
    )
    XCTAssertThrowsError(try FilmProcessor.shared.process(source, recipe: missingStamp)) { error in
      XCTAssertEqual(error as? FilmProcessorError, .missingDateStampText)
    }
  }

  func testDateStampedRenderUsesPersistedTextAndRemainsStable() async throws {
    let source = try XCTUnwrap(makeSyntheticImage(width: 160, height: 120))
    let options = FilmProcessingOptions(
      lightLeaksEnabled: false,
      dateStamp: DateStampConfiguration(
        mode: .nostalgic1998,
        format: .yearMonthDay,
        localeIdentifier: "en_US_POSIX"
      )
    )
    let stamped = FilmRecipeCatalog.legacyOriginal.resolve(
      seed: 73,
      capturedAt: Date(timeIntervalSince1970: 915_148_800),
      options: options,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    XCTAssertEqual(stamped.resolvedSettings.dateStampText, "1998 01 01")

    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let first = try await processor.renderedCGImage(CIImage(cgImage: source), recipe: stamped)
    let second = try await processor.renderedCGImage(CIImage(cgImage: source), recipe: stamped)
    XCTAssertEqual(try pixelBytes(first), try pixelBytes(second))

    let unstamped = FilmRecipeCatalog.legacyOriginal.resolve(
      seed: stamped.seed,
      capturedAt: Date(timeIntervalSince1970: 915_148_800),
      options: .init(lightLeaksEnabled: false, dateStamp: .off),
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let withoutStamp = try await processor.renderedCGImage(
      CIImage(cgImage: source), recipe: unstamped)
    XCTAssertNotEqual(try pixelBytes(first), try pixelBytes(withoutStamp))
  }

  private func makeRecipe(seed: UInt64) -> AppliedFilmRecipe {
    FilmRecipeCatalog.night.resolve(
      seed: seed,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      options: FilmProcessingOptions(
        lightLeaksEnabled: true,
        dateStamp: DateStampConfiguration(mode: .off)
      ),
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
  }

  /// The catalog grade with grain, halation, softness, aberration, vignette
  /// and leaks removed, so only the colour stage touches the pixels.
  private func makeGradeOnlyRecipe(_ base: FilmParameters) -> AppliedFilmRecipe {
    let parameters = FilmParameters(
      exposure: base.exposure, contrast: base.contrast, saturation: base.saturation,
      warmth: base.warmth, highlightRolloff: base.highlightRolloff,
      shadowCoolness: base.shadowCoolness,
      grainAmount: 0, grainSize: 1, halation: 0, vignette: 0, softness: 0,
      chromaticAberration: 0, lightLeakProbability: 0, lightLeakStrength: 0,
      channelSplit: base.channelSplit, blackCrush: base.blackCrush,
      shadowTint: base.shadowTint, highlightTint: base.highlightTint)
    return AppliedFilmRecipe(
      identifier: .nineteenNinetyEight, version: 1, seed: 1, parameters: parameters,
      resolvedSettings: FilmResolvedSettings(
        lightLeakApplied: false, dateStampConfiguration: .off, dateStampText: nil,
        timeZoneIdentifier: "GMT"))
  }

  private func makeSolidImage(_ color: FilmRGB, width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return nil }
    // `CGColor(red:green:blue:alpha:)` is generic RGB; build the fill in sRGB.
    guard
      let fill = CGColor(
        colorSpace: colorSpace, components: [color.red, color.green, color.blue, 1])
    else { return nil }
    context.setFillColor(fill)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  private func centrePixel(_ image: CGImage) throws -> FilmRGB {
    guard let providerData = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(providerData)
    else {
      throw FilmProcessorError.renderFailed
    }
    let offset = ((image.height / 2) * image.bytesPerRow) + (image.width / 2) * 4
    return FilmRGB(
      red: Double(pointer[offset]) / 255,
      green: Double(pointer[offset + 1]) / 255,
      blue: Double(pointer[offset + 2]) / 255)
  }

  private func makeSyntheticImage(width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else { return nil }
    let colors =
      [
        CGColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1),
        CGColor(red: 0.84, green: 0.42, blue: 0.21, alpha: 1),
      ] as CFArray
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])
    else { return nil }
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: 0, y: 0),
      end: CGPoint(x: width, y: height),
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.setFillColor(CGColor(red: 0.92, green: 0.8, blue: 0.58, alpha: 1))
    let ellipseRect = CGRect(
      x: CGFloat(width) * 0.40,
      y: CGFloat(height) * 0.32,
      width: CGFloat(width) * 0.2,
      height: CGFloat(height) * 0.28
    )
    context.fillEllipse(in: ellipseRect)
    return context.makeImage()
  }

  private struct PixelStatistics {
    let mean: Double
    let standardDeviation: Double
    let redMean: Double
    let allFinite: Bool

    func meanAbsoluteDifference(from other: PixelStatistics) -> Double {
      abs(mean - other.mean) + abs(redMean - other.redMean)
    }
  }

  private func pixelStatistics(_ image: CGImage) throws -> PixelStatistics {
    guard let providerData = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(providerData)
    else {
      throw FilmProcessorError.renderFailed
    }
    let count = image.width * image.height
    var values = [Double]()
    values.reserveCapacity(count)
    var reds = [Double]()
    reds.reserveCapacity(count)
    for index in 0..<count {
      let offset = index * 4
      let red = Double(pointer[offset]) / 255
      let green = Double(pointer[offset + 1]) / 255
      let blue = Double(pointer[offset + 2]) / 255
      values.append((red + green + blue) / 3)
      reds.append(red)
    }
    let mean = values.reduce(0, +) / Double(count)
    let redMean = reds.reduce(0, +) / Double(count)
    let variance =
      values.reduce(0) { partial, value in
        partial + (value - mean) * (value - mean)
      } / Double(count)
    return PixelStatistics(
      mean: mean,
      standardDeviation: variance.squareRoot(),
      redMean: redMean,
      allFinite: values.allSatisfy(\.isFinite)
    )
  }

  private func pixelBytes(_ image: CGImage) throws -> Data {
    guard let providerData = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(providerData)
    else {
      throw FilmProcessorError.renderFailed
    }
    return Data(bytes: pointer, count: CFDataGetLength(providerData))
  }
}
