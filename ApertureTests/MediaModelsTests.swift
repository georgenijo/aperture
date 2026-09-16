import XCTest

@testable import Aperture

final class MediaModelsTests: XCTestCase {
  func testMetadataRoundTripPreservesReproducibleCaptureState() throws {
    let capturedAt = Date(timeIntervalSince1970: 1_789_492_500)
    let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let options = FilmProcessingOptions(
      lightLeaksEnabled: true,
      dateStamp: DateStampConfiguration(
        mode: .nostalgic1998,
        format: .monthDayYear,
        localeIdentifier: "en_US_POSIX"
      )
    )
    let recipe = FilmRecipeCatalog.nineteenNinetyEight.resolve(
      seed: 0xCAFE_BABE,
      capturedAt: capturedAt,
      options: options,
      timeZone: timeZone
    )
    let item = MediaItem(
      id: UUID(uuidString: "F158443A-88BB-4F16-B31E-01BFCE7143E8")!,
      mediaType: .video,
      files: MediaFileSet(
        processed: "media/f158443a-88bb-4f16-b31e-01bfce7143e8/processed.mov",
        original: "media/f158443a-88bb-4f16-b31e-01bfce7143e8/original.mov",
        thumbnail: "media/f158443a-88bb-4f16-b31e-01bfce7143e8/thumbnail.jpg"
      ),
      dimensions: PixelDimensions(width: 3_840, height: 2_160),
      durationSeconds: 8.25,
      capturedAt: capturedAt,
      recipe: recipe,
      camera: CameraCaptureMetadata(
        position: .back,
        deviceType: "virtual-triple-camera",
        deviceUniqueID: "test-camera",
        lensDisplayName: "2×",
        zoomFactor: 2,
        nominalFocalLengthIn35mm: 48,
        virtualDeviceSwitchOverZoomFactors: [0.5, 1, 2, 5],
        flashMode: .auto,
        isMacroEnabled: false
      ),
      isFavorite: true,
      processing: .failed(
        MediaProcessingFailure(
          code: .interrupted,
          message: "Retry after interruption",
          isRecoverable: true,
          attemptCount: 1
        )
      )
    )

    let data = try ApertureJSON.makeEncoder().encode(item)
    let decoded = try ApertureJSON.makeDecoder().decode(MediaItem.self, from: data)

    XCTAssertEqual(decoded, item)
    XCTAssertEqual(decoded.recipe.resolvedSettings.dateStampText, "2026/09/15  13:15")
    XCTAssertEqual(decoded.recipe.resolvedSettings.timeZoneIdentifier, "America/New_York")
  }

  func testSeededRandomSequenceAndResolvedRecipeAreDeterministic() {
    var first = SeededRandomNumberGenerator(seed: 42)
    var second = SeededRandomNumberGenerator(seed: 42)
    var different = SeededRandomNumberGenerator(seed: 43)

    let firstSequence = (0..<16).map { _ in first.next() }
    XCTAssertEqual(firstSequence, (0..<16).map { _ in second.next() })
    XCTAssertNotEqual(firstSequence, (0..<16).map { _ in different.next() })

    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let options = FilmProcessingOptions(lightLeaksEnabled: true, dateStamp: .off)
    let lhs = FilmRecipeCatalog.night.resolve(
      seed: 123_456,
      capturedAt: date,
      options: options,
      timeZone: .gmt
    )
    let rhs = FilmRecipeCatalog.night.resolve(
      seed: 123_456,
      capturedAt: date,
      options: options,
      timeZone: .gmt
    )
    XCTAssertEqual(lhs, rhs)
  }

  func testEveryPresetAndVariationStaysWithinParameterBounds() {
    for recipe in FilmRecipeCatalog.all {
      XCTAssertTrue(recipe.baseParameters.isWithinSupportedBounds, recipe.displayName)
      for seed in UInt64(0)..<500 {
        let resolved = recipe.resolve(
          seed: seed,
          capturedAt: Date(timeIntervalSince1970: 0),
          options: FilmProcessingOptions(lightLeaksEnabled: true, dateStamp: .off),
          timeZone: .gmt
        )
        XCTAssertTrue(
          resolved.parameters.isWithinSupportedBounds, "\(recipe.displayName), seed \(seed)")
      }
    }

    let clamped = FilmParameters(
      exposure: 100, contrast: -100, saturation: 100, warmth: -.infinity,
      highlightRolloff: 4, shadowCoolness: -1,
      grainAmount: 5, grainSize: 100, halation: -.infinity,
      vignette: 10, softness: -3, chromaticAberration: 8,
      lightLeakProbability: 3, lightLeakStrength: -2
    )
    XCTAssertTrue(clamped.isWithinSupportedBounds)
  }

  func testDateStampModesAndFormats() throws {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = .gmt
    components.year = 2026
    components.month = 9
    components.day = 15
    components.hour = 12
    let date = try XCTUnwrap(components.date)

    XCTAssertEqual(
      ApertureDateStampFormatter.string(
        for: date,
        configuration: DateStampConfiguration(
          mode: .current,
          format: .yearMonthDay,
          localeIdentifier: "en_US_POSIX"
        ),
        timeZone: .gmt
      ),
      "2026 09 15"
    )
    XCTAssertEqual(
      ApertureDateStampFormatter.string(
        for: date,
        configuration: DateStampConfiguration(
          mode: .current,
          format: .digitalDateTime,
          localeIdentifier: "en_US_POSIX"
        ),
        timeZone: .gmt
      ),
      "2026/09/15  12:00"
    )
    XCTAssertEqual(
      ApertureDateStampFormatter.string(
        for: date,
        configuration: DateStampConfiguration(
          mode: .nostalgic1998,
          format: .dayMonthYear,
          localeIdentifier: "en_US_POSIX"
        ),
        timeZone: .gmt
      ),
      "15 09 98"
    )
    XCTAssertNil(
      ApertureDateStampFormatter.string(for: date, configuration: .off, timeZone: .gmt)
    )

    components.year = 2024
    components.month = 2
    components.day = 29
    let leapDay = try XCTUnwrap(components.date)
    XCTAssertEqual(
      ApertureDateStampFormatter.string(
        for: leapDay,
        configuration: DateStampConfiguration(
          mode: .nostalgic1998,
          format: .yearMonthDay,
          localeIdentifier: "en_US_POSIX"
        ),
        timeZone: .gmt
      ),
      "1998 02 28"
    )
  }

  func testProcessingAttemptCountSurvivesEveryPhaseAndLegacyManifests() throws {
    let encoder = ApertureJSON.makeEncoder()
    let decoder = ApertureJSON.makeDecoder()

    let processing = MediaProcessingState.processing(attemptCount: 2)
    XCTAssertEqual(processing.attemptCount, 2)
    XCTAssertEqual(
      try decoder.decode(MediaProcessingState.self, from: try encoder.encode(processing)),
      processing)
    XCTAssertEqual(processing.nextAttempt, .processing(attemptCount: 3))
    XCTAssertEqual(MediaProcessingState.pending.nextAttempt, .processing(attemptCount: 1))

    let failure = MediaProcessingFailure(
      code: .renderFailed, message: "boom", isRecoverable: true, attemptCount: 3)
    XCTAssertEqual(MediaProcessingState.failed(failure).attemptCount, 3)

    let legacyProcessing = Data(#"{"phase":"processing"}"#.utf8)
    XCTAssertEqual(
      try decoder.decode(MediaProcessingState.self, from: legacyProcessing),
      .processing(attemptCount: 0))
    let legacyFailedJSON = Data(
      #"{"phase":"failed","failure":{"code":"interrupted","message":"m","isRecoverable":true,"attemptCount":3}}"#
        .utf8)
    XCTAssertEqual(
      try decoder.decode(MediaProcessingState.self, from: legacyFailedJSON).attemptCount, 3)
  }
}
