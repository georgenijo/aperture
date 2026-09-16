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
      XCTAssertTrue(catalogRecipe.stages.isWithinSupportedBounds)
      let applied = catalogRecipe.resolve(
        seed: 99,
        capturedAt: date,
        options: options,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
      XCTAssertTrue(applied.stages.isWithinSupportedBounds)
      XCTAssertEqual(applied.version, catalogRecipe.version)
      XCTAssertEqual(applied.seed, 99)
    }
  }

  func testResolvedCompressionQualityIsDeterministicAndBounded() {
    let expected: [(PhotoQualityPreference, Double)] = [
      (.spaceSaving, 0.72),
      (.balanced, 0.92),
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

  func testLegacyResolvedSettingsDecodeToTheFrozenHistoricalBalancedQuality() throws {
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
    // Frozen at the Balanced value that was current when such manifests were
    // written; raising the preference (0.88 → 0.92) must not re-encode them.
    XCTAssertEqual(decoded.compressionQuality, 0.88)
    XCTAssertEqual(FilmResolvedSettings.legacyCompressionQuality, 0.88)
    XCTAssertNotEqual(decoded.compressionQuality, PhotoQualityPreference.balanced.compressionQuality)
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
    // 1998's forced stamp format is `.huji` ("M d ''yy"); this capture date
    // is 1999-01-01 00:00 UTC, so the rendered text is "1 1 '99".
    XCTAssertEqual(recipe.resolvedSettings.dateStampText, "1 1 '99")

    let small = try XCTUnwrap(
      FilmDateStampLayout.make(
        text: "1 1 '99", canvasSize: CGSize(width: 1000, height: 800)))
    let large = try XCTUnwrap(
      FilmDateStampLayout.make(
        text: "1 1 '99", canvasSize: CGSize(width: 2000, height: 1600)))
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
    let recipe = makeGradeOnlyRecipe(
      FilmRecipeCatalog.nineteenNinetyEight.stages.colorGrade ?? .neutral)
    let output = try await processor.renderedCGImage(
      CIImage(cgImage: source), recipe: recipe, renderSize: .preview(maxPixelDimension: 64))

    let expected = FilmColorModel.map(wall, grade: recipe.colorGrade)
    let centre = try centrePixel(output)
    XCTAssertEqual(centre.red, expected.red, accuracy: 3 / 255, "red")
    XCTAssertEqual(centre.green, expected.green, accuracy: 3 / 255, "green")
    XCTAssertEqual(centre.blue, expected.blue, accuracy: 3 / 255, "blue")
    // Sanity: the Huji grade should not paint a neutral wall lavender.
    XCTAssertLessThan(abs(centre.blue - centre.red), 0.08)
  }

  func testChromaticAberrationBlueSeparatesFartherThanRedAndIsDeterministicAcrossSeeds()
    async throws
  {
    // A mid-grey field with a bright square off-centre: the 1998 stage
    // scales the red/blue records around the optical centre by different
    // amounts, so a feature away from centre should land at a different
    // distance per channel. `seeded: false` also means two different
    // render seeds must produce byte-identical output.
    let source = try XCTUnwrap(
      makeGreySquareImage(
        width: 512, height: 384, squareRect: CGRect(x: 360, y: 40, width: 80, height: 80)))
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let stages: [FilmStage] = [
      .colorGrade(.neutral),
      .halation(HalationStage(amount: 0)),
      .softness(SoftnessStage(amount: 0)),
      .chromaticAberration(
        ChromaticAberrationStage(
          amount: 0.78, redGain: -0.0022, blueGain: 0.0032, lateralShiftScale: 0, seeded: false)),
      .grain(GrainStage(amount: 0, size: 1)),
      .lightLeak(LightLeakStage(probability: 0, strength: 0, minWidth: 0.16, maxWidth: 0.42)),
      .vignette(VignetteStage(amount: 0)),
      .dateStamp(DateStampStage()),
    ]
    func recipe(seed: UInt64) -> AppliedFilmRecipe {
      AppliedFilmRecipe(
        identifier: .legacyOriginal, version: FilmRecipeVersion.current, seed: seed,
        stages: stages,
        resolvedSettings: FilmResolvedSettings(
          lightLeakApplied: false, dateStampConfiguration: .off, dateStampText: nil,
          timeZoneIdentifier: "GMT"))
    }

    let first = try await processor.renderedCGImage(
      CIImage(cgImage: source), recipe: recipe(seed: 1))
    let second = try await processor.renderedCGImage(
      CIImage(cgImage: source), recipe: recipe(seed: 2))
    XCTAssertEqual(try pixelBytes(first), try pixelBytes(second))

    let redCentroid = try brightChannelCentroid(first, channelOffset: 0, threshold: 0.75)
    let blueCentroid = try brightChannelCentroid(first, channelOffset: 2, threshold: 0.75)
    let centre = CGPoint(x: Double(first.width) / 2, y: Double(first.height) / 2)
    let redDistance = hypot(redCentroid.x - centre.x, redCentroid.y - centre.y)
    let blueDistance = hypot(blueCentroid.x - centre.x, blueCentroid.y - centre.y)
    XCTAssertGreaterThan(blueDistance, redDistance)
  }

  func testGaussianSoftnessBlursIsotropicallyAndChangesOutput() async throws {
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let verticalSource = try XCTUnwrap(makeEdgeImage(width: 400, height: 400, verticalEdge: true))
    let horizontalSource = try XCTUnwrap(
      makeEdgeImage(width: 400, height: 400, verticalEdge: false))

    func stages(amount: Double) -> [FilmStage] {
      [
        .colorGrade(.neutral),
        .halation(HalationStage(amount: 0)),
        .softness(SoftnessStage(amount: amount, kind: .gaussian, gaussianRadiusScale: 0.01)),
        .chromaticAberration(ChromaticAberrationStage(amount: 0)),
        .grain(GrainStage(amount: 0, size: 1)),
        .lightLeak(LightLeakStage(probability: 0, strength: 0, minWidth: 0.16, maxWidth: 0.42)),
        .vignette(VignetteStage(amount: 0)),
        .dateStamp(DateStampStage()),
      ]
    }
    func recipe(amount: Double) -> AppliedFilmRecipe {
      AppliedFilmRecipe(
        identifier: .nineteenNinetyEight, version: FilmRecipeVersion.current, seed: 5,
        stages: stages(amount: amount),
        resolvedSettings: FilmResolvedSettings(
          lightLeakApplied: false, dateStampConfiguration: .off, dateStampText: nil,
          timeZoneIdentifier: "GMT"))
    }

    let verticalSharp = try await processor.renderedCGImage(
      CIImage(cgImage: verticalSource), recipe: recipe(amount: 0))
    let verticalBlurred = try await processor.renderedCGImage(
      CIImage(cgImage: verticalSource), recipe: recipe(amount: 1))
    let horizontalBlurred = try await processor.renderedCGImage(
      CIImage(cgImage: horizontalSource), recipe: recipe(amount: 1))

    let sharpWidth = try transitionWidth(verticalSharp, verticalEdge: true)
    let verticalWidth = try transitionWidth(verticalBlurred, verticalEdge: true)
    let horizontalWidth = try transitionWidth(horizontalBlurred, verticalEdge: false)

    // Gaussian softness visibly widens a hard edge...
    XCTAssertGreaterThan(verticalWidth, sharpWidth + 3)
    // ...and does so isotropically: horizontal- and vertical-edge blur widths agree.
    XCTAssertEqual(
      Double(verticalWidth), Double(horizontalWidth),
      accuracy: Double(verticalWidth) * 0.25 + 2)
  }

  func testNineteenNinetyEightLightLeakOnlyPicksConfiguredEdgesAcross200Seeds() throws {
    let leakStage = try XCTUnwrap(FilmRecipeCatalog.nineteenNinetyEight.stages.lightLeak)
    XCTAssertEqual(leakStage.edges, [.top, .right])

    var sawALeak = false
    for seed in UInt64(0)..<200 {
      let recipe = FilmRecipeCatalog.nineteenNinetyEight.resolve(
        seed: seed,
        capturedAt: Date(timeIntervalSince1970: 0),
        options: FilmProcessingOptions(lightLeaksEnabled: true, dateStamp: .off),
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
      if let leak = FilmProcessingDecision.make(for: recipe).leak {
        sawALeak = true
        XCTAssertTrue(leak.edge == .top || leak.edge == .right, "seed \(seed) picked \(leak.edge)")
      }
    }
    XCTAssertTrue(sawALeak, "expected at least one of 200 seeds to trigger a 1998 light leak")
  }

  func testLightLeakRenderedAlphaNeverExceedsAlphaCap() throws {
    let leakStage = try XCTUnwrap(FilmRecipeCatalog.nineteenNinetyEight.stages.lightLeak)
    XCTAssertEqual(leakStage.alphaCap, 0.16, accuracy: 0.0001)

    let decision = LightLeakDecision(
      edge: .top, position: 0.5, width: leakStage.maxWidth, angle: 0,
      color: LightLeakColor(red: 1, green: 1, blue: 1), intensity: leakStage.maxIntensity)
    let extent = CGRect(x: 0, y: 0, width: 256, height: 192)
    // Strength far above 1 pushes the raw formula well past the cap, so the
    // clamp is what's actually being exercised here.
    let overlay = try XCTUnwrap(
      FilmProcessor.makeLightLeakImage(
        extent: extent, decision: decision, strength: 10, alphaCap: leakStage.alphaCap))
    let context = CIContext(options: [.useSoftwareRenderer: true])
    let rendered = try XCTUnwrap(context.createCGImage(overlay, from: extent))
    guard let data = rendered.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
      return XCTFail("no pixel data")
    }
    let bytesPerRow = rendered.bytesPerRow
    var maxAlpha: UInt8 = 0
    for y in 0..<rendered.height {
      for x in 0..<rendered.width {
        let offset = y * bytesPerRow + x * 4
        maxAlpha = max(maxAlpha, pointer[offset + 3])
      }
    }
    XCTAssertLessThanOrEqual(Double(maxAlpha) / 255.0, leakStage.alphaCap + 1.0 / 255.0)
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
    let unsupportedVersion = FilmRecipeVersion.current + 1
    let unsupported = AppliedFilmRecipe(
      identifier: valid.identifier,
      version: unsupportedVersion,
      seed: valid.seed,
      stages: valid.stages,
      resolvedSettings: valid.resolvedSettings
    )
    XCTAssertThrowsError(try FilmProcessor.shared.process(source, recipe: unsupported)) { error in
      XCTAssertEqual(error as? FilmProcessorError, .unsupportedRecipeVersion(unsupportedVersion))
    }

    let missingStamp = AppliedFilmRecipe(
      identifier: valid.identifier,
      version: valid.version,
      seed: valid.seed,
      stages: valid.stages,
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
  private func makeGradeOnlyRecipe(_ grade: FilmColorGrade) -> AppliedFilmRecipe {
    let stages: [FilmStage] = [
      .colorGrade(grade),
      .halation(HalationStage(amount: 0)),
      .softness(SoftnessStage(amount: 0)),
      .chromaticAberration(ChromaticAberrationStage(amount: 0)),
      .grain(GrainStage(amount: 0, size: 1)),
      .lightLeak(LightLeakStage(probability: 0, strength: 0, minWidth: 0.16, maxWidth: 0.42)),
      .vignette(VignetteStage(amount: 0)),
      .dateStamp(DateStampStage()),
    ]
    return AppliedFilmRecipe(
      identifier: .nineteenNinetyEight, version: FilmRecipeVersion.current, seed: 1,
      stages: stages,
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

  /// A mid-grey field with a solid white square, used to probe chromatic
  /// aberration's per-channel radial scaling.
  private func makeGreySquareImage(width: Int, height: Int, squareRect: CGRect) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(squareRect)
    return context.makeImage()
  }

  /// The intensity-weighted centroid of pixels above `threshold` in one
  /// channel, isolating a bright feature from a uniform background.
  private func brightChannelCentroid(_ image: CGImage, channelOffset: Int, threshold: Double)
    throws -> CGPoint
  {
    guard let providerData = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(providerData)
    else {
      throw FilmProcessorError.renderFailed
    }
    let bytesPerRow = image.bytesPerRow
    var sumWeight = 0.0
    var sumX = 0.0
    var sumY = 0.0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let offset = y * bytesPerRow + x * 4
        let value = Double(pointer[offset + channelOffset]) / 255.0
        guard value > threshold else { continue }
        sumWeight += value
        sumX += value * Double(x)
        sumY += value * Double(y)
      }
    }
    guard sumWeight > 0 else { throw FilmProcessorError.renderFailed }
    return CGPoint(x: sumX / sumWeight, y: sumY / sumWeight)
  }

  /// A hard black/white step edge, used to measure blur width and isotropy.
  private func makeEdgeImage(width: Int, height: Int, verticalEdge: Bool) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    if verticalEdge {
      context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    } else {
      context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    }
    return context.makeImage()
  }

  /// The pixel span, along the axis perpendicular to the edge, over which
  /// the red channel climbs from 5% to 95% through the image's centre line.
  private func transitionWidth(_ image: CGImage, verticalEdge: Bool) throws -> Int {
    guard let providerData = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(providerData)
    else {
      throw FilmProcessorError.renderFailed
    }
    let bytesPerRow = image.bytesPerRow
    var values = [Double]()
    if verticalEdge {
      let y = image.height / 2
      for x in 0..<image.width {
        values.append(Double(pointer[y * bytesPerRow + x * 4]) / 255.0)
      }
    } else {
      let x = image.width / 2
      for y in 0..<image.height {
        values.append(Double(pointer[y * bytesPerRow + x * 4]) / 255.0)
      }
    }
    // Count samples strictly inside the transition band rather than locating
    // ordered start/end indices: depending on edge orientation, the bitmap's
    // row order can make the ramp run high-to-low instead of low-to-high
    // (CGContext fills use a bottom-left origin while the resulting CGImage
    // buffer is top-row-first), and an ordered-index search silently returns
    // 0 for a decreasing ramp. Counting the band membership is direction-
    // agnostic and still measures the same physical transition width.
    return values.filter { $0 > 0.05 && $0 < 0.95 }.count
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
