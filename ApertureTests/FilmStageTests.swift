import CoreGraphics
import CoreImage
import Foundation
import XCTest

@testable import Aperture

/// Issue #17 turns each recipe's flat `FilmParameters` knobs into an ordered
/// `[FilmStage]` list that `FilmProcessor`/`VideoProcessor` dispatch on,
/// instead of a hard-coded call sequence. `GoldenRenderTests` is the
/// pixel-identity contract for that refactor; this file covers the stage
/// model's own data-as-pipeline behaviour: legacy manifest equivalence,
/// round-tripping without the old flat schema, per-stage default-filling,
/// that the executor really is driven by the array (not a fixed order), and
/// a coarse statistical characterization of every catalog recipe.
final class FilmStageTests: XCTestCase {

  // MARK: 1. v1 manifest decode equivalence + leak width by identifier

  func testLegacyV1ManifestDecodesToEquivalentStagesAndWidthVariesByIdentifier() throws {
    let encoder = ApertureJSON.makeEncoder()
    let decoder = ApertureJSON.makeDecoder()

    let parameters = FilmParameters(
      exposure: 0.04, contrast: 1.12, saturation: 1.18, warmth: 0.22,
      highlightRolloff: 0.52, shadowCoolness: 0.08, grainAmount: 0.26, grainSize: 0.85,
      halation: 0.22, vignette: 0.18, softness: 0.09, chromaticAberration: 0.035,
      lightLeakProbability: 0.18, lightLeakStrength: 0.28)

    for identifier in [
      FilmRecipeIdentifier.nineteenNinetyEight, .night, .cinema, .legacyOriginal,
    ] {
      // Shape a v2 (stages-based) manifest with the app's own encoder just to
      // get a well-formed envelope (identifier/version/seed/resolvedSettings)
      // without hard-coding how `FilmRecipeIdentifier` serializes, then swap
      // `stages` for the pre-#17 flat `parameters` payload it would have
      // decoded from.
      let shaped = AppliedFilmRecipe(
        identifier: identifier, version: 1, seed: 55,
        stages: FilmStage.legacyPipeline(parameters: parameters, identifier: identifier),
        resolvedSettings: FilmResolvedSettings(
          lightLeakApplied: false, dateStampConfiguration: .off, dateStampText: nil,
          timeZoneIdentifier: "GMT"))
      var jsonObject = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: encoder.encode(shaped)) as? [String: Any])
      jsonObject.removeValue(forKey: "stages")
      jsonObject["parameters"] = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: encoder.encode(parameters)) as? [String: Any])
      let legacyPayload = try JSONSerialization.data(withJSONObject: jsonObject)

      let decoded = try decoder.decode(AppliedFilmRecipe.self, from: legacyPayload)
      let expectedStages = FilmStage.legacyPipeline(parameters: parameters, identifier: identifier)
      XCTAssertEqual(decoded.stages, expectedStages, identifier.rawValue)
      XCTAssertEqual(decoded.identifier, identifier)
      XCTAssertEqual(decoded.version, 1)

      let leak = try XCTUnwrap(decoded.stages.lightLeak, identifier.rawValue)
      if identifier == .nineteenNinetyEight {
        XCTAssertEqual(leak.minWidth, 0.10, identifier.rawValue)
        XCTAssertEqual(leak.maxWidth, 0.27, identifier.rawValue)
      } else {
        XCTAssertEqual(leak.minWidth, 0.16, identifier.rawValue)
        XCTAssertEqual(leak.maxWidth, 0.42, identifier.rawValue)
      }
    }
  }

  // MARK: 2. Round-trip without the legacy flat schema

  func testCatalogRecipesRoundTripAsStagesWithoutLegacyParametersKey() throws {
    let encoder = ApertureJSON.makeEncoder()
    let decoder = ApertureJSON.makeDecoder()
    let date = Date(timeIntervalSince1970: 915_148_800)
    let options = FilmProcessingOptions(lightLeaksEnabled: true, dateStamp: .off)

    for recipe in FilmRecipeCatalog.all + [FilmRecipeCatalog.legacyOriginal] {
      let applied = recipe.resolve(seed: 777, capturedAt: date, options: options, timeZone: .gmt)
      let data = try encoder.encode(applied)
      let jsonObject = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertNotNil(jsonObject["stages"], "\(recipe.displayName) must persist stages")
      XCTAssertNil(jsonObject["parameters"], "\(recipe.displayName) must not persist \"parameters\"")

      let decoded = try decoder.decode(AppliedFilmRecipe.self, from: data)
      XCTAssertEqual(decoded, applied, recipe.displayName)
    }
  }

  // MARK: 3. Partial-stage decode fills defaults; unknown kind throws

  func testStageDecodeFillsDefaultsForPartialConfigurationAndRejectsUnknownKind() throws {
    let decoder = ApertureJSON.makeDecoder()

    let partialHalation = Data(#"{"kind":"halation","configuration":{"amount":0.3}}"#.utf8)
    guard case .halation(let halationStage) = try decoder.decode(
      FilmStage.self, from: partialHalation)
    else {
      return XCTFail("Expected a decoded halation stage")
    }
    XCTAssertEqual(halationStage.amount, 0.3)
    XCTAssertEqual(halationStage.minimumAmount, 0.001)
    XCTAssertEqual(halationStage.intensityScale, 0.75)
    XCTAssertEqual(halationStage.intensityCap, 1)
    XCTAssertEqual(halationStage.radiusScale, 0.012)
    XCTAssertEqual(halationStage.minimumRadius, 1)
    XCTAssertEqual(
      halationStage.tint, .warmByAmount(red: 0.20, green: 0.04, blue: 0.10))
    XCTAssertEqual(halationStage.radiusScalesWithAmount, true)
    XCTAssertEqual(halationStage.blendOpacityScale, 0.82)
    XCTAssertEqual(halationStage.blendOpacityCap, 0.68)

    let partialLightLeak = Data(
      #"{"kind":"lightLeak","configuration":{"probability":0.4,"strength":0.5,"minWidth":0.16,"maxWidth":0.42}}"#
        .utf8)
    guard case .lightLeak(let leakStage) = try decoder.decode(
      FilmStage.self, from: partialLightLeak)
    else {
      return XCTFail("Expected a decoded lightLeak stage")
    }
    XCTAssertEqual(leakStage.minPosition, 0.16)
    XCTAssertEqual(leakStage.maxPosition, 0.84)
    XCTAssertEqual(leakStage.minAngle, -0.42)
    XCTAssertEqual(leakStage.maxAngle, 0.42)
    XCTAssertEqual(leakStage.minIntensity, 0.68)
    XCTAssertEqual(leakStage.maxIntensity, 1.0)
    XCTAssertEqual(leakStage.palette, LightLeakStage.defaultPalette)
    XCTAssertEqual(leakStage.edges, LightLeakDecision.Edge.allCases)
    XCTAssertEqual(leakStage.alphaCap, 0.68)

    let partialDateStamp = Data(#"{"kind":"dateStamp","configuration":{}}"#.utf8)
    guard case .dateStamp(let dateStampStage) = try decoder.decode(
      FilmStage.self, from: partialDateStamp)
    else {
      return XCTFail("Expected a decoded dateStamp stage")
    }
    XCTAssertEqual(dateStampStage.style, .monospaced)

    let unknownKind = Data(#"{"kind":"bogus","configuration":{}}"#.utf8)
    XCTAssertThrowsError(try decoder.decode(FilmStage.self, from: unknownKind)) { error in
      guard case DecodingError.dataCorrupted = error else {
        return XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
      }
    }
  }

  // MARK: 4. The executor is driven by the stage array, not a fixed order

  func testExecutorAppliesOnlyPresentStagesInArrayOrder() async throws {
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let context = CIContext(options: [.useSoftwareRenderer: true])
    let source = try XCTUnwrap(makeSyntheticImage(width: 96, height: 72))
    let resolvedSettings = FilmResolvedSettings(
      lightLeakApplied: false, dateStampConfiguration: .off, dateStampText: nil,
      timeZoneIdentifier: "GMT")

    // A vignette-only stage list (no colour grade, softness, grain, date
    // stamp, ...) must render, and must match calling `applyVignette`
    // directly against the identically normalized/scaled/cropped image
    // outside the executor loop -- proof the loop dispatches on whichever
    // stages are present rather than a hard-coded call sequence.
    let vignetteOnly = AppliedFilmRecipe(
      identifier: .legacyOriginal, version: FilmRecipeVersion.current, seed: 5,
      stages: [.vignette(VignetteStage(amount: 0.6))],
      resolvedSettings: resolvedSettings)
    let rendered = try await processor.renderedCGImage(
      CIImage(cgImage: source), recipe: vignetteOnly, renderSize: .preview(maxPixelDimension: 96))

    let normalized = try FilmProcessor.normalized(CIImage(cgImage: source), orientation: .up)
    let sized = try FilmProcessor.scaled(normalized, to: .preview(maxPixelDimension: 96))
    let bounds = try FilmProcessor.finiteExtent(sized.extent)
    let bare = sized.cropped(to: bounds)
    let expectedImage = processor.applyVignette(
      bare, stage: VignetteStage(amount: 0.6), extent: bounds
    ).cropped(to: bounds)
    let expected = try XCTUnwrap(context.createCGImage(expectedImage, from: bounds))

    XCTAssertEqual(try pixelBytes(rendered), try pixelBytes(expected))

    // Order matters: swapping grain/vignette order in the array must change
    // the rendered bytes, proving the loop runs stages in array order
    // instead of always grain-then-vignette (or vice versa).
    let forward = AppliedFilmRecipe(
      identifier: .legacyOriginal, version: FilmRecipeVersion.current, seed: 9,
      stages: [
        .grain(GrainStage(amount: 0.9, size: 1)), .vignette(VignetteStage(amount: 0.6)),
      ],
      resolvedSettings: resolvedSettings)
    let reversed = AppliedFilmRecipe(
      identifier: .legacyOriginal, version: FilmRecipeVersion.current, seed: 9,
      stages: [
        .vignette(VignetteStage(amount: 0.6)), .grain(GrainStage(amount: 0.9, size: 1)),
      ],
      resolvedSettings: resolvedSettings)
    let forwardRendered = try await processor.renderedCGImage(
      CIImage(cgImage: source), recipe: forward, renderSize: .preview(maxPixelDimension: 96))
    let reversedRendered = try await processor.renderedCGImage(
      CIImage(cgImage: source), recipe: reversed, renderSize: .preview(maxPixelDimension: 96))
    XCTAssertNotEqual(try pixelBytes(forwardRendered), try pixelBytes(reversedRendered))
  }

  // MARK: 5. Per-recipe reference statistics

  private struct ReferenceStatistics {
    let mean: Double
    let standardDeviation: Double
    let redMean: Double
  }

  /// Coarse, renderer-tolerant characterization of every catalog recipe
  /// against a fixed fixture/seed. `GoldenRenderTests` is the exact
  /// pixel-identity contract for the #17 refactor; this is a looser,
  /// independent guard so an unrelated future change to a stage's numbers
  /// is caught even where a byte-exact golden isn't in play.
  private let referenceStatistics: [FilmRecipeIdentifier: ReferenceStatistics] = [
    // Re-measured for the 1998-Huji-parity retune (issue #18): the new grade's
    // blue-suppression/red-hue-shift terms and retuned chromatic
    // aberration/softness/light-leak stages shift this fixture's statistics
    // from the pre-retune baseline (mean 0.5075, std 0.3309, redMean 0.5467).
    .nineteenNinetyEight: ReferenceStatistics(
      mean: 0.4665, standardDeviation: 0.3088, redMean: 0.5057),
    .night: ReferenceStatistics(mean: 0.4637, standardDeviation: 0.3341, redMean: 0.4914),
    .cinema: ReferenceStatistics(mean: 0.5476, standardDeviation: 0.2856, redMean: 0.5642),
    .legacyOriginal: ReferenceStatistics(mean: 0.4247, standardDeviation: 0.2533, redMean: 0.4417),
  ]

  func testPerRecipeReferenceStatisticsStayWithinTolerance() async throws {
    let tolerance = 0.015
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let date = Date(timeIntervalSince1970: 893_980_800)
    let options = FilmProcessingOptions(
      lightLeaksEnabled: false, dateStamp: .off)
    let source = try fixtureCGImage(named: "day-portrait")

    for recipe in FilmRecipeCatalog.all + [FilmRecipeCatalog.legacyOriginal] {
      let applied = recipe.resolve(seed: 4_242, capturedAt: date, options: options, timeZone: .gmt)
      let rendered = try await processor.renderedCGImage(
        CIImage(cgImage: source), recipe: applied, renderSize: .preview(maxPixelDimension: 128))
      let stats = try pixelStatistics(rendered)
      let reference = try XCTUnwrap(
        referenceStatistics[recipe.id], "missing reference for \(recipe.displayName)")

      XCTAssertEqual(
        stats.mean, reference.mean, accuracy: tolerance, "\(recipe.displayName) mean")
      XCTAssertEqual(
        stats.standardDeviation, reference.standardDeviation, accuracy: tolerance,
        "\(recipe.displayName) standardDeviation")
      XCTAssertEqual(
        stats.redMean, reference.redMean, accuracy: tolerance, "\(recipe.displayName) redMean")
    }
  }

  // MARK: Helpers

  private func makeSyntheticImage(width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
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
    return context.makeImage()
  }

  private func fixtureCGImage(named name: String) throws -> CGImage {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "png"))
    let data = try Data(contentsOf: url)
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
      throw FilmProcessorError.decodeFailed
    }
    return cgImage
  }

  private func pixelBytes(_ image: CGImage) throws -> Data {
    guard let providerData = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(providerData)
    else {
      throw FilmProcessorError.renderFailed
    }
    return Data(bytes: pointer, count: CFDataGetLength(providerData))
  }

  private struct PixelStatistics {
    let mean: Double
    let standardDeviation: Double
    let redMean: Double
  }

  private func pixelStatistics(_ image: CGImage) throws -> PixelStatistics {
    guard let providerData = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(providerData)
    else {
      throw FilmProcessorError.renderFailed
    }
    let count = image.width * image.height
    var luminances = [Double]()
    var reds = [Double]()
    luminances.reserveCapacity(count)
    reds.reserveCapacity(count)
    for index in 0..<count {
      let offset = index * 4
      let red = Double(pointer[offset]) / 255
      let green = Double(pointer[offset + 1]) / 255
      let blue = Double(pointer[offset + 2]) / 255
      luminances.append((red + green + blue) / 3)
      reds.append(red)
    }
    let mean = luminances.reduce(0, +) / Double(count)
    let redMean = reds.reduce(0, +) / Double(count)
    let variance =
      luminances.reduce(0) { partial, value in partial + (value - mean) * (value - mean) }
      / Double(count)
    return PixelStatistics(mean: mean, standardDeviation: variance.squareRoot(), redMean: redMean)
  }
}
