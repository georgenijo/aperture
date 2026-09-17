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
      // A legacy manifest is upgraded in memory to the stage schema so its
      // re-encoded form is never a version-1 document carrying `stages`.
      XCTAssertEqual(decoded.version, FilmRecipeVersion.stageSchema)
      let reencoded = try JSONSerialization.jsonObject(with: encoder.encode(decoded))
        as? [String: Any]
      XCTAssertNotNil(reencoded?["stages"])
      XCTAssertNil(reencoded?["parameters"])
      XCTAssertEqual(reencoded?["version"] as? Int, FilmRecipeVersion.stageSchema)

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

  // MARK: 2b. Stage-schema-2 wire format keeps its rendering semantics

  func testSchemaTwoChromaticAberrationAndHalationDecodeWithTheirOriginalSemantics() throws {
    let decoder = ApertureJSON.makeDecoder()
    let encoder = ApertureJSON.makeEncoder()

    // Schema 2 persisted an unsigned `blueGain` that the renderer subtracted
    // (`blueScale = 1 - 0.0042·a·s`). Schema 3 adds the gain, so the legacy
    // key must decode negated, and a decode → encode → decode round trip must
    // not flip it again.
    let legacyCA = Data(
      #"{"kind":"chromaticAberration","configuration":{"amount":0.5,"blueGain":0.0042,"redGain":0.0048}}"#
        .utf8)
    guard case .chromaticAberration(let ca) = try decoder.decode(FilmStage.self, from: legacyCA)
    else { return XCTFail("Expected a chromatic aberration stage") }
    XCTAssertEqual(ca.blueGain, -0.0042, accuracy: 1e-12)
    XCTAssertEqual(ca.redGain, 0.0048, accuracy: 1e-12)
    XCTAssertTrue(ca.seeded)

    let reencoded = try encoder.encode(FilmStage.chromaticAberration(ca))
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
    let configuration = try XCTUnwrap(json["configuration"] as? [String: Any])
    XCTAssertNil(configuration["blueGain"], "the unsigned legacy key must never be written again")
    XCTAssertEqual(configuration["signedBlueGain"] as? Double ?? .nan, -0.0042, accuracy: 1e-12)
    guard case .chromaticAberration(let roundTripped) = try decoder.decode(
      FilmStage.self, from: reencoded)
    else { return XCTFail("Expected a chromatic aberration stage") }
    XCTAssertEqual(roundTripped, ca)

    // A schema-3 payload carrying both keys prefers the signed one.
    let mixed = Data(
      #"{"kind":"chromaticAberration","configuration":{"amount":0.5,"blueGain":0.0042,"signedBlueGain":0.0032}}"#
        .utf8)
    guard case .chromaticAberration(let preferred) = try decoder.decode(FilmStage.self, from: mixed)
    else { return XCTFail("Expected a chromatic aberration stage") }
    XCTAssertEqual(preferred.blueGain, 0.0032, accuracy: 1e-12)

    // Schema 2 persisted the halation tint as three loose warm gains; a
    // non-default value must survive as `.warmByAmount`, not be replaced by
    // the catalog default.
    let legacyHalation = Data(
      #"{"kind":"halation","configuration":{"amount":0.3,"warmRedGain":0.4,"warmBlueGain":0.05}}"#
        .utf8)
    guard case .halation(let halation) = try decoder.decode(FilmStage.self, from: legacyHalation)
    else { return XCTFail("Expected a halation stage") }
    XCTAssertEqual(halation.tint, .warmByAmount(red: 0.4, green: 0.04, blue: 0.05))
    XCTAssertTrue(halation.radiusScalesWithAmount)

    let explicitTint = Data(
      #"{"kind":"halation","configuration":{"amount":0.3,"warmRedGain":0.4,"tint":{"fixed":{"red":1,"green":0.78,"blue":0.92}}}}"#
        .utf8)
    guard case .halation(let fixed) = try decoder.decode(FilmStage.self, from: explicitTint)
    else { return XCTFail("Expected a halation stage") }
    XCTAssertEqual(fixed.tint, .fixed(red: 1, green: 0.78, blue: 0.92))
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

  func testMalformedLightLeakConfigurationsAreNormalisedInsteadOfTrapping() throws {
    let json = """
      {"kind":"lightLeak","configuration":{"probability":1,"strength":1,
       "minWidth":0.42,"maxWidth":0.16,"minPosition":0.9,"maxPosition":0.1,
       "palette":[]}}
      """
    let stage = try ApertureJSON.makeDecoder().decode(FilmStage.self, from: Data(json.utf8))
    let leak = try XCTUnwrap([stage].lightLeak)
    XCTAssertEqual(leak.minWidth, 0.16)
    XCTAssertEqual(leak.maxWidth, 0.42)
    XCTAssertEqual(leak.minPosition, 0.1)
    XCTAssertEqual(leak.maxPosition, 0.9)
    XCTAssertEqual(leak.palette, LightLeakStage.defaultPalette)

    let applied = AppliedFilmRecipe(
      identifier: .night, version: FilmRecipeVersion.current, seed: 7, stages: [stage],
      resolvedSettings: FilmResolvedSettings(
        lightLeakApplied: true, dateStampConfiguration: .off, dateStampText: nil,
        timeZoneIdentifier: "GMT"))
    let decision = FilmProcessingDecision.make(for: applied)
    XCTAssertNotNil(decision.leak)
  }

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
    /// Mean per-pixel HSV saturation.
    let saturation: Double
    /// Fraction of pixels whose brightest channel is at or below 5/255.
    let blackClip: Double
  }

  private struct ReferenceKey: Hashable {
    let recipe: FilmRecipeIdentifier
    let fixture: String
  }

  /// Coarse, renderer-tolerant characterization of every catalog recipe
  /// against each fixture at a fixed seed. `GoldenRenderTests` is the exact
  /// pixel-identity contract; this is a looser, independent guard so an
  /// unrelated future change to a stage's numbers is caught even where a
  /// byte-exact golden isn't in play. Regenerate the table by running with
  /// `APERTURE_DUMP_REFERENCE_STATS=1` and pasting the printed rows.
  private let referenceStatistics: [ReferenceKey: ReferenceStatistics] = [
    ReferenceKey(recipe: .nineteenNinetyEight, fixture: "day-portrait"): ReferenceStatistics(
      mean: 0.4595, standardDeviation: 0.3267, redMean: 0.5188, saturation: 0.4979,
      blackClip: 0.0153),
    ReferenceKey(recipe: .night, fixture: "day-portrait"): ReferenceStatistics(
      mean: 0.4637, standardDeviation: 0.3341, redMean: 0.4914, saturation: 0.4300,
      blackClip: 0.0712),
    ReferenceKey(recipe: .cinema, fixture: "day-portrait"): ReferenceStatistics(
      mean: 0.5476, standardDeviation: 0.2856, redMean: 0.5642, saturation: 0.2634,
      blackClip: 0.0017),
    ReferenceKey(recipe: .legacyOriginal, fixture: "day-portrait"): ReferenceStatistics(
      mean: 0.4247, standardDeviation: 0.2533, redMean: 0.4417, saturation: 0.3146,
      blackClip: 0.0015),
    ReferenceKey(recipe: .nineteenNinetyEight, fixture: "night-flash"): ReferenceStatistics(
      mean: 0.1992, standardDeviation: 0.2677, redMean: 0.2896, saturation: 0.5871,
      blackClip: 0.1934),
    ReferenceKey(recipe: .night, fixture: "night-flash"): ReferenceStatistics(
      mean: 0.1720, standardDeviation: 0.2669, redMean: 0.2297, saturation: 0.2908,
      blackClip: 0.4850),
    ReferenceKey(recipe: .cinema, fixture: "night-flash"): ReferenceStatistics(
      mean: 0.2566, standardDeviation: 0.2565, redMean: 0.3000, saturation: 0.3139,
      blackClip: 0.0872),
    ReferenceKey(recipe: .legacyOriginal, fixture: "night-flash"): ReferenceStatistics(
      mean: 0.1932, standardDeviation: 0.1953, redMean: 0.2339, saturation: 0.3267,
      blackClip: 0.0777),
    ReferenceKey(recipe: .nineteenNinetyEight, fixture: "hdr-still-life"): ReferenceStatistics(
      mean: 0.3756, standardDeviation: 0.3266, redMean: 0.4727, saturation: 0.6410,
      blackClip: 0.0650),
    ReferenceKey(recipe: .night, fixture: "hdr-still-life"): ReferenceStatistics(
      mean: 0.3716, standardDeviation: 0.3454, redMean: 0.4399, saturation: 0.5149,
      blackClip: 0.1624),
    ReferenceKey(recipe: .cinema, fixture: "hdr-still-life"): ReferenceStatistics(
      mean: 0.4414, standardDeviation: 0.3237, redMean: 0.5023, saturation: 0.4806,
      blackClip: 0.0294),
    ReferenceKey(recipe: .legacyOriginal, fixture: "hdr-still-life"): ReferenceStatistics(
      mean: 0.3388, standardDeviation: 0.2689, redMean: 0.3903, saturation: 0.5576,
      blackClip: 0.0233),
  ]

  func testPerRecipeReferenceStatisticsStayWithinTolerance() async throws {
    let tolerance = 0.015
    let dump = ProcessInfo.processInfo.environment["APERTURE_DUMP_REFERENCE_STATS"] != nil
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let date = Date(timeIntervalSince1970: 893_980_800)
    let options = FilmProcessingOptions(
      lightLeaksEnabled: false, dateStamp: .off)

    for fixture in ["day-portrait", "night-flash", "hdr-still-life"] {
      let source = try fixtureCGImage(named: fixture)
      for recipe in FilmRecipeCatalog.all + [FilmRecipeCatalog.legacyOriginal] {
        let applied = recipe.resolve(
          seed: 4_242, capturedAt: date, options: options, timeZone: .gmt)
        let rendered = try await processor.renderedCGImage(
          CIImage(cgImage: source), recipe: applied, renderSize: .preview(maxPixelDimension: 128))
        let stats = try pixelStatistics(rendered)
        if dump {
          print(
            String(
              format: "    ReferenceKey(recipe: .%@, fixture: \"%@\"): ReferenceStatistics(\n"
                + "      mean: %.4f, standardDeviation: %.4f, redMean: %.4f, saturation: %.4f,\n"
                + "      blackClip: %.4f),",
              [
                FilmRecipeIdentifier.nineteenNinetyEight: "nineteenNinetyEight",
                .night: "night", .cinema: "cinema", .legacyOriginal: "legacyOriginal",
              ][recipe.id] ?? recipe.id.rawValue, fixture,
              stats.mean, stats.standardDeviation, stats.redMean, stats.saturation,
              stats.blackClip))
          continue
        }
        let label = "\(recipe.displayName)/\(fixture)"
        let reference = try XCTUnwrap(
          referenceStatistics[ReferenceKey(recipe: recipe.id, fixture: fixture)],
          "missing reference for \(label)")

        XCTAssertEqual(stats.mean, reference.mean, accuracy: tolerance, "\(label) mean")
        XCTAssertEqual(
          stats.standardDeviation, reference.standardDeviation, accuracy: tolerance,
          "\(label) standardDeviation")
        XCTAssertEqual(stats.redMean, reference.redMean, accuracy: tolerance, "\(label) redMean")
        XCTAssertEqual(
          stats.saturation, reference.saturation, accuracy: tolerance, "\(label) saturation")
        XCTAssertEqual(
          stats.blackClip, reference.blackClip, accuracy: tolerance, "\(label) blackClip")
      }
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
    let saturation: Double
    let blackClip: Double
  }

  private func pixelStatistics(_ image: CGImage) throws -> PixelStatistics {
    guard let providerData = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(providerData)
    else {
      throw FilmProcessorError.renderFailed
    }
    let count = image.width * image.height
    let bytesPerRow = image.bytesPerRow
    var luminances = [Double]()
    luminances.reserveCapacity(count)
    var redSum = 0.0
    var saturationSum = 0.0
    var clipped = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let offset = y * bytesPerRow + x * 4
        let red = Double(pointer[offset]) / 255
        let green = Double(pointer[offset + 1]) / 255
        let blue = Double(pointer[offset + 2]) / 255
        luminances.append((red + green + blue) / 3)
        redSum += red
        let brightest = max(red, green, blue)
        let darkest = min(red, green, blue)
        saturationSum += brightest > 0 ? (brightest - darkest) / brightest : 0
        if brightest <= 5.0 / 255 { clipped += 1 }
      }
    }
    let mean = luminances.reduce(0, +) / Double(count)
    let variance =
      luminances.reduce(0) { partial, value in partial + (value - mean) * (value - mean) }
      / Double(count)
    return PixelStatistics(
      mean: mean, standardDeviation: variance.squareRoot(), redMean: redSum / Double(count),
      saturation: saturationSum / Double(count), blackClip: Double(clipped) / Double(count))
  }
}
