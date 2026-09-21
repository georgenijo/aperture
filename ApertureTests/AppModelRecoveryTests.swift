import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Aperture

@MainActor
final class AppModelRecoveryTests: XCTestCase {
  func testLaunchRecoveryCarriesTheAttemptCountAcrossTheProcessingTransition() async throws {
    let (model, library, item) = try await makeModelWithUndevelopableItem(
      foundAt: .processing(attemptCount: 1))

    await model.recoverInterruptedItems([item])

    let recovered = try await currentItem(item.id, in: library)
    XCTAssertEqual(recovered.processing.phase, .failed)
    XCTAssertEqual(recovered.processing.attemptCount, 2)
    XCTAssertEqual(recovered.processing.failure?.attemptCount, 2)
    XCTAssertFalse(model.processingIDs.contains(item.id))
  }

  func testLaunchRecoveryStopsRetryingAnItemThatKeepsGettingInterrupted() async throws {
    let (model, library, item) = try await makeModelWithUndevelopableItem(
      foundAt: .processing(attemptCount: AppModel.maximumAutomaticRecoveryAttempts))

    await model.recoverInterruptedItems([item])

    let recovered = try await currentItem(item.id, in: library)
    XCTAssertEqual(recovered.processing.phase, .failed)
    XCTAssertEqual(recovered.processing.failure?.code, .interrupted)
    XCTAssertEqual(
      recovered.processing.attemptCount, AppModel.maximumAutomaticRecoveryAttempts)
    XCTAssertEqual(recovered.processing.failure?.isRecoverable, true)
    XCTAssertFalse(model.processingIDs.contains(item.id))
  }

  /// `AppModel.setFavorite`/`delete` publish their result through the new
  /// lightweight `syncAfterMutation()` path: they must reflect their own
  /// mutation immediately, without incidentally recovering an unrelated
  /// staged transaction the way the full, disk-reconciling `refresh()`
  /// (still used at startup, on error, and by the Lab's `.task`) would.
  func testFavoriteAndDeleteSyncWithoutRecoveringAnUnrelatedStagedItem() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApertureTests-mutation-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let library = MediaLibrary(rootURL: root)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )

    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: "ApertureTests-mutation-sync-\(item.id)"))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: "ApertureTests-mutation-sync-\(item.id)")
    }
    let model = AppModel(mediaLibrary: library, settingsStore: SettingsStore(defaults: defaults))
    await model.prepare()
    XCTAssertEqual(model.items.map(\.id), [item.id])

    // A completed-but-uncommitted transaction sitting on disk, exactly like
    // the setup MediaLibraryTests uses to exercise refreshSnapshot()'s
    // recovery. Nothing has told the actor's in-memory index about it yet.
    let staged = try await library.stage(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("other-photo".utf8), fileExtension: "jpg")
    )

    await model.setFavorite(model.items[0], isFavorite: true)
    XCTAssertEqual(model.items.map(\.id), [item.id])
    XCTAssertEqual(model.items.first?.isFavorite, true)

    let deleted = await model.delete(model.items[0])
    XCTAssertTrue(deleted)
    XCTAssertTrue(
      model.items.isEmpty,
      "delete() must not incidentally recover the unrelated staged item via disk reconciliation")

    // The explicit, disk-reconciling refresh() is the one that recovers it.
    await model.refresh()
    XCTAssertEqual(model.items.map(\.id), [staged.item.id])
  }

  func testPendingRecordingGatesRepeatedStartAndModeChangeUntilFailureCallback() async throws {
    let (model, _, item) = try await makeModelWithUndevelopableItem(foundAt: .ready)
    let context = RecordingContext(
      recipe: item.recipe, preserveOriginal: true, autoSaveToPhotos: false)
    model.recordingContext = context
    XCTAssertFalse(model.isRecording)
    XCTAssertTrue(model.isRecordingOrStarting)

    model.startRecording()
    XCTAssertEqual(model.recordingContext?.recipe, context.recipe)
    XCTAssertNil(model.notice, "A duplicate request must be refused before permission or queue work")
    model.setCaptureMode(.video)
    XCTAssertEqual(model.captureMode, .photo)
    XCTAssertEqual(model.notice, "Stop the recording before changing modes.")

    model.handleVideoCapture(.failure(CameraIssue(
      kind: .recording, title: "Camera not ready", message: "Test rejection",
      recoverySuggestion: "Try again")))
    XCTAssertNil(model.recordingContext)
    XCTAssertFalse(model.isRecordingOrStarting)
    XCTAssertEqual(model.cameraIssue?.message, "Test rejection")
  }

  // MARK: - Astra P1: reconciled ready replacements must not become retryable

  /// A `replaceProcessedAsset` that commits its new `.ready` metadata and
  /// asset durably, but then fails writing the manifest *and* fails the
  /// metadata-rollback attempt that follows, must not surface to
  /// `developExisting` as a development failure. The on-disk item is
  /// already the newly developed rendition; only `refresh()`'s disk
  /// reconciliation can discover that (the actor's in-memory manifest is
  /// left stale by the failed commit), and `AppModel` must keep the item
  /// `.ready` instead of calling `markProcessingFailed` and offering a "Try
  /// Again" that would apply the film recipe a second time to bytes that
  /// already contain it. Preserve Original is off (no `original:` payload),
  /// matching the finding's emphasis: re-development reads the already
  /// filtered processed asset as its source.
  func testDevelopExistingRecoversManifestAndRollbackFailureAsReadyWithoutRerendering() async throws {
    let root = try makeTempDirectory(named: "app-model-manifest-rollback")
    let failures = AppModelReplacementFailurePlan()
    let library = MediaLibrary(
      rootURL: root,
      fileSystem: MediaLibraryFileSystem(FileManager.default) { data, url, options in
        try failures.write(data, to: url, options: options)
      }
    )

    let oldImageData = try makeSolidJPEGData(pixelSize: 12, red: 90, green: 140, blue: 200)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: oldImageData, fileExtension: "jpg")
    )
    let expectedEncoded = try independentlyDeveloped(oldImageData, recipe: item.recipe)

    // Arm on the write that actually commits the replacement (see
    // `AppModelReplacementFailurePlan`'s doc comment), then fail the
    // manifest commit and the metadata rollback write that follows it — the
    // same fault
    // `MediaLibraryTests.testReplacementRollbackFailureRetainsBothPayloadsForRecovery`
    // exercises at the `MediaLibrary` layer, driven here through `AppModel`
    // so the state-corruption Astra flagged is actually covered.
    failures.originalProcessedPath = item.files.processed
    failures.failNextManifestWrite = true
    failures.failRollbackWrite = true

    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: "app-model-manifest-rollback-\(item.id)"))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: "app-model-manifest-rollback-\(item.id)")
    }
    let model = AppModel(mediaLibrary: library, settingsStore: SettingsStore(defaults: defaults))
    model.processingIDs.insert(item.id)

    await model.developExisting(item)

    XCTAssertFalse(model.processingIDs.contains(item.id))
    XCTAssertNil(model.errorMessage)
    XCTAssertTrue(
      model.notice?.contains("Storage cleanup needs attention") == true,
      "a recovered replacement stays ready but must still disclose the storage problem")
    let recoveredModelItem = try XCTUnwrap(model.items.first(where: { $0.id == item.id }))
    XCTAssertEqual(
      recoveredModelItem.processing.phase, .ready,
      "a committed replacement must stay ready, never failed, so 'Try Again' is never offered")

    let recoveredLibraryItem = try await currentItem(item.id, in: library)
    XCTAssertEqual(recoveredLibraryItem.processing.phase, .ready)
    let recoveredAssetURL = try await library.assetURL(
      for: recoveredLibraryItem, kind: .processed)
    let recoveredURL = try XCTUnwrap(recoveredAssetURL)
    XCTAssertEqual(
      try Data(contentsOf: recoveredURL), expectedEncoded,
      "the developed bytes must match a single application of the recipe, not a second render")
  }

  /// The second scenario Astra called out: the replacement's new `.ready`
  /// metadata and manifest commit both succeed durably — the media library
  /// actor's own in-memory index already reflects it — but the post-commit
  /// removal of the *superseded* old asset then fails. That failure must
  /// resolve without ever calling the disk-reconciling `refresh()`, which
  /// would hit the very same persistent removal fault while cleaning up the
  /// orphan during `reconcileCommittedItems()` and could otherwise hide an
  /// already-durable ready replacement.
  func testDevelopExistingRecoversSupersededAssetCleanupFailureAsReadyWithoutRerendering()
    async throws
  {
    let root = try makeTempDirectory(named: "app-model-cleanup-failure")
    let fileManager = SelectiveRemovalFailingFileManager()
    let library = MediaLibrary(rootURL: root, fileSystem: MediaLibraryFileSystem(fileManager))

    let oldImageData = try makeSolidJPEGData(pixelSize: 12, red: 30, green: 200, blue: 60)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: oldImageData, fileExtension: "jpg")
    )
    let oldAssetURL = try await library.assetURL(for: item, kind: .processed)
    let oldURL = try XCTUnwrap(oldAssetURL)
    // The fault is persistent (never clears), so a fallback `refresh()`
    // would fail on the exact same orphan cleanup step if the fix ever
    // needed to reach it — it must not, for this scenario.
    fileManager.pathsToFail.insert(oldURL.path)
    let expectedEncoded = try independentlyDeveloped(oldImageData, recipe: item.recipe)

    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: "app-model-cleanup-failure-\(item.id)"))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: "app-model-cleanup-failure-\(item.id)")
    }
    let model = AppModel(mediaLibrary: library, settingsStore: SettingsStore(defaults: defaults))
    model.processingIDs.insert(item.id)

    await model.developExisting(item)

    XCTAssertFalse(model.processingIDs.contains(item.id))
    XCTAssertNil(model.errorMessage)
    XCTAssertTrue(
      model.notice?.contains("Storage cleanup needs attention") == true,
      "a recovered replacement stays ready but must still disclose the storage problem")
    let recoveredModelItem = try XCTUnwrap(model.items.first(where: { $0.id == item.id }))
    XCTAssertEqual(recoveredModelItem.processing.phase, .ready)

    let recoveredAssetURL = try await library.assetURL(
      for: recoveredModelItem, kind: .processed)
    let recoveredURL = try XCTUnwrap(recoveredAssetURL)
    XCTAssertEqual(try Data(contentsOf: recoveredURL), expectedEncoded)
    // The superseded old file is still on disk: cleanup genuinely failed and
    // was never retried, but that is a diagnostics-only leftover, not data
    // loss or a corrupted item.
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
  }

  /// The video completion path Astra explicitly asked to be covered: the
  /// same manifest-write-plus-failed-rollback fault as the photo scenario,
  /// but exercised through `developExisting`'s video branch and
  /// `developVideo`'s own `replaceProcessedAsset` call. A strong,
  /// non-idempotent exposure grade makes a second application of the
  /// recipe land far outside a single-pass tolerance, so recovering to
  /// `.ready` with the single-pass frame proves no second render occurred.
  func testDevelopVideoRecoversManifestAndRollbackFailureAsReadyWithoutRerendering() async throws {
    let root = try makeTempDirectory(named: "app-model-video-manifest-rollback")
    let sourceMovieURL = try makeTinyMovie(
      solid: FilmRGB(red: 128 / 255, green: 128 / 255, blue: 128 / 255))
    addTeardownBlock { try? FileManager.default.removeItem(at: sourceMovieURL) }

    let failures = AppModelReplacementFailurePlan()
    let library = MediaLibrary(
      rootURL: root,
      fileSystem: MediaLibraryFileSystem(FileManager.default) { data, url, options in
        try failures.write(data, to: url, options: options)
      }
    )

    // Exposure-only grade on a flat grey source isolates a pure per-channel
    // gain: single vs. double application diverge by tens of levels, far
    // past codec noise, with no cross-channel interaction to account for.
    let grade = FilmColorGrade(
      exposure: 1.0, contrast: 1, saturation: 1, warmth: 0,
      highlightRolloff: 0, shadowCoolness: 0, channelSplit: 0, blackCrush: 0,
      shadowTint: .neutral, highlightTint: .neutral)
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
    let recipe = AppliedFilmRecipe(
      identifier: .nineteenNinetyEight, version: FilmRecipeVersion.current, seed: 1,
      stages: stages,
      resolvedSettings: FilmResolvedSettings(
        lightLeakApplied: false, dateStampConfiguration: .off, dateStampText: nil,
        timeZoneIdentifier: "GMT"))

    let request = MediaWriteRequest(
      id: UUID(),
      mediaType: .video,
      dimensions: PixelDimensions(width: 64, height: 48),
      durationSeconds: 0.3,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      recipe: recipe,
      processing: .ready
    )
    let item = try await library.createAndCommit(
      request,
      processed: MediaAssetPayload(fileURL: sourceMovieURL)
    )

    let sourceCentre = try await centrePixel(ofVideoAt: sourceMovieURL)
    let expectedCentre = FilmColorModel.map(sourceCentre, grade: recipe.colorGrade)

    // Arm on the write that actually commits the replacement (see
    // `AppModelReplacementFailurePlan`'s doc comment) so the fault lands in
    // `developVideo`'s `replaceProcessedAsset` call, not the preceding
    // `updateProcessing(nextAttempt)` write.
    failures.originalProcessedPath = item.files.processed
    failures.failNextManifestWrite = true
    failures.failRollbackWrite = true

    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: "app-model-video-manifest-rollback-\(item.id)"))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: "app-model-video-manifest-rollback-\(item.id)")
    }
    let model = AppModel(mediaLibrary: library, settingsStore: SettingsStore(defaults: defaults))
    model.processingIDs.insert(item.id)

    await model.developExisting(item)

    XCTAssertFalse(model.processingIDs.contains(item.id))
    XCTAssertNil(model.errorMessage)
    XCTAssertTrue(
      model.notice?.contains("Storage cleanup needs attention") == true,
      "a recovered replacement stays ready but must still disclose the storage problem")
    let recoveredModelItem = try XCTUnwrap(model.items.first(where: { $0.id == item.id }))
    XCTAssertEqual(recoveredModelItem.processing.phase, .ready)

    let recoveredLibraryItem = try await currentItem(item.id, in: library)
    XCTAssertEqual(recoveredLibraryItem.processing.phase, .ready)
    let recoveredAssetURL = try await library.assetURL(
      for: recoveredLibraryItem, kind: .processed)
    let recoveredURL = try XCTUnwrap(recoveredAssetURL)
    let recoveredCentre = try await centrePixel(ofVideoAt: recoveredURL)

    XCTAssertEqual(recoveredCentre.red, expectedCentre.red, accuracy: 8 / 255, "red")
    XCTAssertEqual(recoveredCentre.green, expectedCentre.green, accuracy: 8 / 255, "green")
    XCTAssertEqual(recoveredCentre.blue, expectedCentre.blue, accuracy: 8 / 255, "blue")
    // A double render would apply the exposure gain twice, landing far
    // outside single-pass tolerance — confirms the two are distinguishable.
    let doublyGraded = FilmColorModel.map(expectedCentre, grade: recipe.colorGrade)
    XCTAssertGreaterThan(
      abs(doublyGraded.red - expectedCentre.red), 30 / 255,
      "the single- and double-graded expectations must be clearly distinguishable")
  }

  /// A distinct instance of the same bug shape, not a fault-injection replay:
  /// an item that is already `.ready` from a *prior* successful development,
  /// whose source then goes missing before a new `developExisting` call. That
  /// call throws immediately — `existingOriginalOrProcessedURL` finds nothing
  /// to read — before ever reaching `replaceProcessedAsset`, so no new
  /// replacement is attempted or committed. A post-hoc "is the item ready?"
  /// check cannot distinguish this from a real committed replacement, since
  /// the item was ready before the call and remains exactly as ready
  /// afterward; only checking that a *new* replacement actually happened
  /// avoids reporting this real failure as a success. Preserve Original is
  /// off, so there is no fallback original to read either.
  func testDevelopExistingWithMissingSourceIsNotReportedAsSuccessfulDevelopment() async throws {
    let root = try makeTempDirectory(named: "app-model-missing-source")
    let library = MediaLibrary(rootURL: root)

    let oldImageData = try makeSolidJPEGData(pixelSize: 12, red: 10, green: 50, blue: 220)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: oldImageData, fileExtension: "jpg")
    )
    let processedAssetURL = try await library.assetURL(for: item, kind: .processed)
    let processedURL = try XCTUnwrap(processedAssetURL)
    try FileManager.default.removeItem(at: processedURL)

    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: "app-model-missing-source-\(item.id)"))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: "app-model-missing-source-\(item.id)")
    }
    let model = AppModel(mediaLibrary: library, settingsStore: SettingsStore(defaults: defaults))
    model.processingIDs.insert(item.id)

    await model.developExisting(item)

    XCTAssertFalse(model.processingIDs.contains(item.id))
    XCTAssertNotNil(
      model.errorMessage,
      "a missing source is a real failure and must be reported, not silently treated as success")
    XCTAssertNil(
      model.notice,
      "no replacement was ever attempted, so there is nothing to report as 'Developed.'")
  }

  private func makeModelWithUndevelopableItem(
    foundAt state: MediaProcessingState
  ) async throws -> (AppModel, MediaLibrary, MediaItem) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApertureTests-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let library = MediaLibrary(rootURL: root)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("not-an-image".utf8), fileExtension: "jpg")
    )
    try await library.updateProcessing(state, for: item.id)
    let found = try await currentItem(item.id, in: library)

    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ApertureTests-recovery-\(item.id)"))
    addTeardownBlock { defaults.removePersistentDomain(forName: "ApertureTests-recovery-\(item.id)") }
    let model = AppModel(
      mediaLibrary: library, settingsStore: SettingsStore(defaults: defaults))
    return (model, library, found)
  }

  private func currentItem(_ id: UUID, in library: MediaLibrary) async throws -> MediaItem {
    let items = try await library.items()
    return try XCTUnwrap(items.first(where: { $0.id == id }))
  }

  private func makeTempDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApertureTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// Replicates `AppModel.develop(item:sourceData:)`'s exact two-step
  /// render so a test can independently recompute the single-pass expected
  /// bytes and assert the recovered item's actual bytes match it exactly —
  /// proof that exactly one render occurred, relying on the deterministic,
  /// no-random/date/settings-state rendering invariant.
  private func independentlyDeveloped(_ sourceData: Data, recipe: AppliedFilmRecipe) throws -> Data
  {
    let image = try FilmProcessor.shared.process(sourceData, recipe: recipe)
    return try FilmProcessor.shared.encodedData(
      image,
      format: .jpeg,
      quality: CGFloat(recipe.resolvedSettings.compressionQuality),
      metadataSource: sourceData
    )
  }

  private enum TestImageError: Error { case cannotCreateContext, cannotCreateDestination }

  /// A minimal, real JPEG so `FilmProcessor` (which decodes real image
  /// bytes) has something genuine to develop, mirroring the "Preserve
  /// Original off" scenario where re-development reads the already
  /// filtered processed asset rather than a preserved camera original.
  private func makeSolidJPEGData(pixelSize: Int, red: UInt8, green: UInt8, blue: UInt8) throws
    -> Data
  {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw TestImageError.cannotCreateContext }
    context.setFillColor(
      red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    guard let cgImage = context.makeImage() else { throw TestImageError.cannotCreateContext }

    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw TestImageError.cannotCreateDestination }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw TestImageError.cannotCreateDestination
    }
    return data as Data
  }

  /// A tiny, real `.mov` so `VideoProcessor` (which opens a genuine
  /// `AVAsset`) has something to develop, mirroring `VideoProcessorTests`'
  /// own `makeTinyVideo` helper (duplicated locally since that one is
  /// private to its file).
  private func makeTinyMovie(solid: FilmRGB) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("aperture-apptest-video-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let width = 64
    let height = 48
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 250_000,
          AVVideoExpectedSourceFrameRateKey: 10,
        ],
      ])
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw NSError(
        domain: "ApertureTests", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "The test video writer could not add its video input."
        ])
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.startWriting() else { throw writer.error ?? testVideoWriterError() }
    writer.startSession(atSourceTime: .zero)
    for frameIndex in 0..<3 {
      while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.001)
      }
      guard
        let pixelBuffer = makeSolidPixelBuffer(width: width, height: height, solid: solid),
        adaptor.append(
          pixelBuffer, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 10))
      else {
        input.markAsFinished()
        throw writer.error ?? testVideoWriterError()
      }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 30) == .success else {
      throw testVideoWriterError()
    }
    guard writer.status == .completed else { throw writer.error ?? testVideoWriterError() }
    return url
  }

  private func makeSolidPixelBuffer(width: Int, height: Int, solid: FilmRGB) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes =
      [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      ] as CFDictionary
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
      ) == kCVReturnSuccess,
      let pixelBuffer
    else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
    let red = UInt8((solid.red * 255).rounded())
    let green = UInt8((solid.green * 255).rounded())
    let blue = UInt8((solid.blue * 255).rounded())
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = blue
        pixels[offset + 1] = green
        pixels[offset + 2] = red
        pixels[offset + 3] = 255
      }
    }
    return pixelBuffer
  }

  private func testVideoWriterError() -> NSError {
    NSError(
      domain: "ApertureTests", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "The test video writer did not finish."])
  }

  private func centrePixel(ofVideoAt url: URL) async throws -> FilmRGB {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let (frame, _) = try await generator.image(at: CMTime(value: 1, timescale: 10))
    return try centrePixel(frame)
  }

  private func centrePixel(_ image: CGImage) throws -> FilmRGB {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    var bytes = [UInt8](repeating: 0, count: 4)
    guard
      let context = CGContext(
        data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw TestImageError.cannotCreateContext }
    context.draw(
      image,
      in: CGRect(
        x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
        width: CGFloat(image.width), height: CGFloat(image.height)))
    return FilmRGB(
      red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
  }
}

/// Mirrors `MediaLibraryTests`' private `DataWriteFailurePlan`, but arms only
/// once it observes the write that actually *commits a replacement*: an
/// item.json payload transitioning to `.ready` with a processed path
/// different from `originalProcessedPath`. `developExisting`'s own
/// preceding `updateProcessing(nextAttempt)` call writes item.json first —
/// same processed path, `.processing` phase, not `.ready` — so it never
/// arms this plan; only `replaceProcessedAsset`'s own `update(item:at:)`
/// call (new path, `.ready`) does. Set `originalProcessedPath` after
/// creating the item (its value isn't known until then) and before
/// triggering development. Duplicated locally because the original
/// `DataWriteFailurePlan` is private to its file.
private final class AppModelReplacementFailurePlan: @unchecked Sendable {
  var originalProcessedPath: String?
  var failNextManifestWrite = false
  var failRollbackWrite = false
  private var armed = false
  private var manifestFailed = false

  func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
    if url.lastPathComponent == MediaLibraryPaths.itemMetadata, !armed,
      let originalProcessedPath,
      let item = try? ApertureJSON.makeDecoder().decode(MediaItem.self, from: data),
      item.processing.phase == .ready,
      item.files.processed != originalProcessedPath
    {
      armed = true
    }
    if url.lastPathComponent == MediaLibraryPaths.manifest, armed, failNextManifestWrite {
      failNextManifestWrite = false
      manifestFailed = true
      throw NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSLocalizedDescriptionKey: "Injected manifest write failure."]
      )
    }
    if url.lastPathComponent == MediaLibraryPaths.itemMetadata, armed, manifestFailed,
      failRollbackWrite
    {
      throw NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSLocalizedDescriptionKey: "Injected metadata rollback failure."]
      )
    }
    try data.write(to: url, options: options)
  }
}

/// A `FileManager` that fails `removeItem` only for paths explicitly
/// registered as failing, so a post-commit superseded-asset cleanup can be
/// made to fail without disturbing any other file operation `MediaLibrary`
/// performs (including a later, unrelated cleanup elsewhere).
private final class SelectiveRemovalFailingFileManager: FileManager {
  var pathsToFail: Set<String> = []

  override func removeItem(at url: URL) throws {
    if pathsToFail.contains(url.path) {
      throw NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSLocalizedDescriptionKey: "Injected superseded-asset removal failure."]
      )
    }
    try super.removeItem(at: url)
  }
}
