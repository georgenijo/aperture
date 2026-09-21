import XCTest

@testable import Aperture

final class MediaLibraryTests: XCTestCase {
  func testUpdatingRecipePersistsWithoutChangingAssets() async throws {
    let root = try temporaryDirectory(named: "recipe-update")
    let library = MediaLibrary(rootURL: root)
    let payload = Data("camera-capture".utf8)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: payload, fileExtension: "jpg"),
      original: MediaAssetPayload(data: payload, fileExtension: "jpg")
    )
    let newRecipe = FilmRecipeCatalog.nineteenNinetyEight.resolve(
      seed: item.recipe.seed,
      capturedAt: item.capturedAt,
      options: FilmProcessingOptions(
        lightLeaksEnabled: false,
        dateStamp: .off
      ),
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    let updated = try await library.updateRecipe(newRecipe, for: item.id)
    XCTAssertEqual(updated.recipe, newRecipe)
    XCTAssertEqual(updated.files, item.files)

    let relaunched = MediaLibrary(rootURL: root)
    let relaunchedItems = try await relaunched.items()
    let persisted = try XCTUnwrap(relaunchedItems.first)
    XCTAssertEqual(persisted.recipe, newRecipe)
    XCTAssertEqual(persisted.files, item.files)
  }

  func testCreationCommitAndDeletionRemoveAuthoritativeAssets() async throws {
    let root = try temporaryDirectory(named: "library")
    let library = MediaLibrary(rootURL: root)
    let request = TestMediaFactory.makeWriteRequest()
    let processedData = Data("processed-photo".utf8)
    let originalData = Data("original-photo".utf8)
    let thumbnailData = Data("thumbnail-photo".utf8)

    let item = try await library.createAndCommit(
      request,
      processed: MediaAssetPayload(data: processedData, fileExtension: "JPG"),
      original: MediaAssetPayload(data: originalData, fileExtension: "heic"),
      thumbnail: MediaAssetPayload(data: thumbnailData, fileExtension: "jpg")
    )
    let processedURLValue = try await library.assetURL(for: item, kind: .processed)
    let originalURLValue = try await library.assetURL(for: item, kind: .original)
    let thumbnailURLValue = try await library.assetURL(for: item, kind: .thumbnail)
    let processedURL = try XCTUnwrap(processedURLValue)
    let originalURL = try XCTUnwrap(originalURLValue)
    let thumbnailURL = try XCTUnwrap(thumbnailURLValue)
    XCTAssertEqual(try Data(contentsOf: processedURL), processedData)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalData)
    XCTAssertEqual(try Data(contentsOf: thumbnailURL), thumbnailData)

    let deleted = try await library.delete(id: item.id)
    XCTAssertEqual(deleted.id, item.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: processedURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
    let stagingURL = root.appendingPathComponent(MediaLibraryPaths.staging)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil)
        .isEmpty)
    let remainingItems = try await library.items()
    XCTAssertTrue(remainingItems.isEmpty)

    do {
      _ = try await library.delete(id: item.id)
      XCTFail("Expected a missing-item error")
    } catch let error as MediaLibraryError {
      XCTAssertEqual(error, .itemNotFound(item.id))
    }
  }

  func testFileBackedVideoStagesWithoutLoadingMovieIntoData() async throws {
    let parent = try temporaryDirectory(named: "video")
    let root = parent.appendingPathComponent("library")
    let movieURL = parent.appendingPathComponent("capture.mov")
    let movieData = Data(repeating: 0xA5, count: 128 * 1_024)
    try movieData.write(to: movieURL)

    let photoRequest = TestMediaFactory.makeWriteRequest()
    let request = MediaWriteRequest(
      id: photoRequest.id,
      mediaType: .video,
      dimensions: PixelDimensions(width: 1_920, height: 1_080),
      durationSeconds: 4.5,
      capturedAt: photoRequest.capturedAt,
      recipe: photoRequest.recipe,
      processing: .pending
    )
    let library = MediaLibrary(rootURL: root)
    let item = try await library.createAndCommit(
      request,
      processed: MediaAssetPayload(fileURL: movieURL)
    )

    XCTAssertTrue(MediaAssetPayload(fileURL: movieURL).isFileBacked)
    let storedURLValue = try await library.assetURL(for: item, kind: .processed)
    let storedURL = try XCTUnwrap(storedURLValue)
    XCTAssertNotEqual(storedURL, movieURL)
    XCTAssertEqual(try Data(contentsOf: storedURL), movieData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: movieURL.path))
  }

  func testReplacingProcessedAssetCommitsMetadataBeforeRemovingSource() async throws {
    let root = try temporaryDirectory(named: "library")
    let library = MediaLibrary(rootURL: root)
    let originalCapture = Data("camera-capture".utf8)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: originalCapture, fileExtension: "heic"),
      original: MediaAssetPayload(data: originalCapture, fileExtension: "heic")
    )
    let oldProcessedURLValue = try await library.assetURL(for: item, kind: .processed)
    let originalURLValue = try await library.assetURL(for: item, kind: .original)
    let oldProcessedURL = try XCTUnwrap(oldProcessedURLValue)
    let originalURL = try XCTUnwrap(originalURLValue)

    let rendered = Data("developed-photo".utf8)
    let replacement = try await library.replaceProcessedAsset(
      for: item.id,
      with: MediaAssetPayload(data: rendered, fileExtension: "jpg"),
      dimensions: PixelDimensions(width: 24, height: 16)
    )
    let replacementURLValue = try await library.assetURL(for: replacement, kind: .processed)
    let replacementURL = try XCTUnwrap(replacementURLValue)

    XCTAssertEqual(try Data(contentsOf: replacementURL), rendered)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldProcessedURL.path))
    XCTAssertEqual(try Data(contentsOf: originalURL), originalCapture)
    XCTAssertEqual(replacement.dimensions, PixelDimensions(width: 24, height: 16))
    XCTAssertEqual(replacement.processing, .ready)

    let relaunched = MediaLibrary(rootURL: root)
    let relaunchedItems = try await relaunched.items()
    XCTAssertEqual(relaunchedItems.first, replacement)
  }

  func testFailedReplacementKeepsPreviouslyCommittedAsset() async throws {
    let root = try temporaryDirectory(named: "library")
    let library = MediaLibrary(rootURL: root)
    let originalCapture = Data("camera-capture".utf8)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: originalCapture, fileExtension: "heic")
    )
    let originalURLValue = try await library.assetURL(for: item, kind: .processed)
    let originalURL = try XCTUnwrap(originalURLValue)

    do {
      _ = try await library.replaceProcessedAsset(
        for: item.id,
        with: MediaAssetPayload(data: Data(), fileExtension: "jpg"),
        dimensions: PixelDimensions(width: 24, height: 16)
      )
      XCTFail("Expected empty replacement to fail")
    } catch let error as MediaLibraryError {
      guard case .invalidMedia = error else {
        return XCTFail("Expected invalidMedia, got \(error)")
      }
    }

    XCTAssertEqual(try Data(contentsOf: originalURL), originalCapture)
    let itemsAfterFailure = try await library.items()
    XCTAssertEqual(itemsAfterFailure.first, item)
  }

  func testDeletionSurfacesMissingDirectoryAndKeepsManifestEntry() async throws {
    let root = try temporaryDirectory(named: "library")
    let library = MediaLibrary(rootURL: root)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )
    let assetURLValue = try await library.assetURL(for: item, kind: .processed)
    let assetURL = try XCTUnwrap(assetURLValue)
    try FileManager.default.removeItem(at: assetURL.deletingLastPathComponent())

    do {
      _ = try await library.delete(id: item.id)
      XCTFail("Expected a real file-operation error")
    } catch let error as MediaLibraryError {
      guard case .fileOperation = error else {
        return XCTFail("Expected fileOperation, got \(error)")
      }
    }
    let itemsAfterFailure = try await library.items()
    XCTAssertEqual(itemsAfterFailure.map(\.id), [item.id])
  }

  func testCompleteStagingIsRecoveredAfterRelaunch() async throws {
    let root = try temporaryDirectory(named: "library")
    let firstLibrary = MediaLibrary(rootURL: root)
    let request = TestMediaFactory.makeWriteRequest()
    let staged = try await firstLibrary.stage(
      request,
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )

    let relaunchedLibrary = MediaLibrary(rootURL: root)
    let snapshot = try await relaunchedLibrary.prepare()
    XCTAssertEqual(snapshot.items.map(\.id), [staged.item.id])
    XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .recoveredStagedItem })
    let urlValue = try await relaunchedLibrary.assetURL(for: staged.item, kind: .processed)
    let url = try XCTUnwrap(urlValue)
    XCTAssertEqual(try Data(contentsOf: url), Data("photo".utf8))
  }

  func testCompleteStagingIsRecoveredDuringLiveRefresh() async throws {
    let root = try temporaryDirectory(named: "library")
    let library = MediaLibrary(rootURL: root)
    _ = try await library.prepare()
    let staged = try await library.stage(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )

    let snapshot = try await library.refreshSnapshot()

    XCTAssertEqual(snapshot.items.map(\.id), [staged.item.id])
    XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .recoveredStagedItem })
    let recoveredURL = try await library.assetURL(for: staged.item, kind: .processed)
    let url = try XCTUnwrap(recoveredURL)
    XCTAssertEqual(try Data(contentsOf: url), Data("photo".utf8))
  }

  func testCurrentSnapshotMirrorsMutationsWithoutRunningDiskReconciliation() async throws {
    let root = try temporaryDirectory(named: "current-snapshot-mutations")
    let library = MediaLibrary(rootURL: root)
    _ = try await library.prepare()

    // Create: currentSnapshot() sees a just-committed item immediately.
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )
    var snapshot = await library.currentSnapshot()
    XCTAssertEqual(snapshot.items.map(\.id), [item.id])
    XCTAssertEqual(snapshot.items.first?.processing.phase, .ready)

    // Processing transition (the "every capture processing state" case).
    try await library.updateProcessing(.pending, for: item.id)
    snapshot = await library.currentSnapshot()
    XCTAssertEqual(snapshot.items.first?.processing.phase, .pending)

    try await library.updateProcessing(.ready, for: item.id)
    snapshot = await library.currentSnapshot()
    XCTAssertEqual(snapshot.items.first?.processing.phase, .ready)

    // Favorite.
    try await library.setFavorite(true, for: item.id)
    snapshot = await library.currentSnapshot()
    XCTAssertEqual(snapshot.items.first?.isFavorite, true)

    // Replace (the develop()/developVideo() completion path).
    let replaced = try await library.replaceProcessedAsset(
      for: item.id,
      with: MediaAssetPayload(data: Data("developed".utf8), fileExtension: "jpg"),
      dimensions: item.dimensions,
      durationSeconds: item.durationSeconds,
      processing: .ready
    )
    snapshot = await library.currentSnapshot()
    XCTAssertEqual(snapshot.items.first?.files, replaced.files)
    let replacementAssetURL = try await library.assetURL(for: replaced, kind: .processed)
    let replacedURL = try XCTUnwrap(replacementAssetURL)
    XCTAssertEqual(try Data(contentsOf: replacedURL), Data("developed".utf8))

    // Delete.
    _ = try await library.delete(id: item.id)
    snapshot = await library.currentSnapshot()
    XCTAssertTrue(snapshot.items.isEmpty)
  }

  func testCurrentSnapshotSkipsReconciliationThatRefreshSnapshotPerforms() async throws {
    let root = try temporaryDirectory(named: "current-snapshot-vs-refresh")
    let library = MediaLibrary(rootURL: root)
    _ = try await library.prepare()

    // Stage (but never commit) a transaction directly on disk, mirroring a
    // completed-but-uncommitted transaction left by a previous process. This
    // is the same setup as testCompleteStagingIsRecoveredDuringLiveRefresh.
    let staged = try await library.stage(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )

    // currentSnapshot() must not discover it: it never touches disk, only
    // the actor's own in-memory index, which nothing has told about this
    // staged item yet.
    let lightweight = await library.currentSnapshot()
    XCTAssertTrue(lightweight.items.isEmpty)
    XCTAssertFalse(lightweight.diagnostics.contains { $0.code == .recoveredStagedItem })

    // refreshSnapshot() is the explicit, disk-reconciling path and does
    // recover it, exactly as testCompleteStagingIsRecoveredDuringLiveRefresh
    // already establishes for the pre-existing API.
    let reconciled = try await library.refreshSnapshot()
    XCTAssertEqual(reconciled.items.map(\.id), [staged.item.id])
    XCTAssertTrue(reconciled.diagnostics.contains { $0.code == .recoveredStagedItem })

    // Once refreshSnapshot() has folded the recovered item into the
    // in-memory index, currentSnapshot() reflects it too without needing
    // another disk scan.
    let afterReconciliation = await library.currentSnapshot()
    XCTAssertEqual(afterReconciliation.items.map(\.id), [staged.item.id])
  }

  func testCurrentSnapshotSkipsReconciliationOfExternallyWrittenCommittedItems() async throws {
    let root = try temporaryDirectory(named: "current-snapshot-vs-refresh-committed")
    let library = MediaLibrary(rootURL: root)
    _ = try await library.prepare()

    // Write a fully-formed committed item directly to disk, bypassing this
    // actor's stage/commit path entirely. This is a deterministic stand-in
    // for a directory that appeared without this actor ever being told
    // about it (a previous process's commit, or a file manager change),
    // exercising reconcileCommittedItems specifically rather than the
    // staged-creation path above.
    let foreignID = UUID()
    let foreignItem = TestMediaFactory.makeItem(id: foreignID)
    let itemDirectory =
      root
      .appendingPathComponent(MediaLibraryPaths.media)
      .appendingPathComponent(foreignID.uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
    try Data("external-photo".utf8).write(
      to: itemDirectory.appendingPathComponent("processed.jpg"))
    let metadata = try ApertureJSON.makeEncoder().encode(foreignItem)
    try metadata.write(to: itemDirectory.appendingPathComponent(MediaLibraryPaths.itemMetadata))

    // currentSnapshot() must not discover it: it only mirrors the actor's
    // in-memory index, and nothing on this actor has learned about this
    // directory.
    let lightweight = await library.currentSnapshot()
    XCTAssertTrue(lightweight.items.isEmpty)

    // refreshSnapshot() is the explicit, disk-reconciling path and does
    // recover it.
    let reconciled = try await library.refreshSnapshot()
    XCTAssertEqual(reconciled.items.map(\.id), [foreignID])
    XCTAssertTrue(reconciled.diagnostics.contains { $0.code == .recoveredCommittedItem })

    // Once reconciled, currentSnapshot() reflects it without another scan.
    let afterReconciliation = await library.currentSnapshot()
    XCTAssertEqual(afterReconciliation.items.map(\.id), [foreignID])
  }

  /// Opt-in, non-flaky performance measurement: repeated `currentSnapshot()`
  /// against repeated `refreshSnapshot()` over a committed library of many
  /// tiny items. It only prints observed timings (there is no pass/fail
  /// threshold, since simulator/CI hardware speed varies) so it never fails
  /// the ordinary suite. Run explicitly with:
  ///   TEST_RUNNER_APERTURE_RUN_SNAPSHOT_PERF=1 xcodebuild ... \
  ///     -only-testing:ApertureTests/MediaLibraryTests/testSnapshotPerformanceCurrentVersusRefresh test
  func testSnapshotPerformanceCurrentVersusRefresh() async throws {
    guard ProcessInfo.processInfo.environment["APERTURE_RUN_SNAPSHOT_PERF"] != nil else {
      throw XCTSkip(
        "Set APERTURE_RUN_SNAPSHOT_PERF=1 to run this opt-in performance measurement.")
    }

    let root = try temporaryDirectory(named: "snapshot-performance")
    let library = MediaLibrary(rootURL: root)
    _ = try await library.prepare()

    let itemCount = 100
    for _ in 0..<itemCount {
      _ = try await library.createAndCommit(
        TestMediaFactory.makeWriteRequest(),
        processed: MediaAssetPayload(data: Data("tiny".utf8), fileExtension: "jpg")
      )
    }

    let iterations = 20
    let lightweightElapsed = await measureSeconds {
      for _ in 0..<iterations {
        _ = await library.currentSnapshot()
      }
    }
    let reconcilingElapsed = try await measureSeconds {
      for _ in 0..<iterations {
        _ = try await library.refreshSnapshot()
      }
    }

    print(
      """
      [snapshot-performance] \(itemCount) items, \(iterations) iterations each:
        currentSnapshot()  total \(lightweightElapsed) s, \
      \(lightweightElapsed / Double(iterations)) s/call
        refreshSnapshot()  total \(reconcilingElapsed) s, \
      \(reconcilingElapsed / Double(iterations)) s/call
      """)

    // No speed assertion: only a sanity check that both paths still agree on
    // the item count, so a broken measurement harness fails loudly instead
    // of silently reporting bogus numbers.
    let finalLightweight = await library.currentSnapshot()
    XCTAssertEqual(finalLightweight.items.count, itemCount)
  }

  private func measureSeconds(_ work: () async throws -> Void) async rethrows -> Double {
    let start = DispatchTime.now()
    try await work()
    let end = DispatchTime.now()
    return Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
  }

  func testIncompleteStagingIsQuarantinedWithoutPublishingItem() async throws {
    let root = try temporaryDirectory(named: "library")
    let firstLibrary = MediaLibrary(rootURL: root)
    let staged = try await firstLibrary.stage(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )
    let stagedAsset =
      root
      .appendingPathComponent(MediaLibraryPaths.staging)
      .appendingPathComponent("create-\(staged.stagingIdentifier.uuidString.lowercased())")
      .appendingPathComponent("processed.jpg")
    try FileManager.default.removeItem(at: stagedAsset)

    let relaunchedLibrary = MediaLibrary(rootURL: root)
    let snapshot = try await relaunchedLibrary.prepare()
    XCTAssertTrue(snapshot.items.isEmpty)
    XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .quarantinedIncompleteStaging })
    let recovery = root.appendingPathComponent(MediaLibraryPaths.recovery)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
  }

  func testLegacyMigrationIsNonDestructiveAndIdempotent() async throws {
    let parent = try temporaryDirectory(named: "migration")
    let root = parent.appendingPathComponent("new-library")
    let legacy = parent.appendingPathComponent("photos")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

    let legacyData = Data("legacy-image".utf8)
    let filename = "legacy-capture.heic"
    try legacyData.write(to: legacy.appendingPathComponent(filename))
    let sidecar = LegacyFixture(
      filename: filename, timestamp: Date(timeIntervalSince1970: 1_600_000_000))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(sidecar).write(to: legacy.appendingPathComponent("legacy-capture.json"))

    let library = MediaLibrary(rootURL: root, legacyPhotosDirectory: legacy)
    let first = try await library.prepare()
    XCTAssertEqual(first.items.count, 1)
    XCTAssertTrue(first.diagnostics.contains { $0.code == .legacyItemMigrated })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: legacy.appendingPathComponent(filename).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: legacy.appendingPathComponent("legacy-capture.json").path))
    let migratedURLValue = try await library.assetURL(for: first.items[0], kind: .processed)
    let migratedURL = try XCTUnwrap(migratedURLValue)
    XCTAssertEqual(try Data(contentsOf: migratedURL), legacyData)

    let relaunched = MediaLibrary(rootURL: root, legacyPhotosDirectory: legacy)
    let second = try await relaunched.prepare()
    XCTAssertEqual(second.items.count, 1)
    XCTAssertEqual(second.items[0].id, first.items[0].id)
    XCTAssertFalse(second.diagnostics.contains { $0.code == .legacyItemMigrated })

    _ = try await relaunched.delete(id: first.items[0].id)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: legacy.appendingPathComponent(filename).path))
    XCTAssertEqual(
      try Data(contentsOf: legacy.appendingPathComponent(filename)),
      legacyData
    )

    let afterDeletion = MediaLibrary(rootURL: root, legacyPhotosDirectory: legacy)
    let deletionSnapshot = try await afterDeletion.prepare()
    XCTAssertTrue(deletionSnapshot.items.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: legacy.appendingPathComponent(filename).path))
  }

  func testCorruptLegacyDeletionLedgerBlocksMigrationAndPreservesBackup() async throws {
    let parent = try temporaryDirectory(named: "corrupt-ledger")
    let root = parent.appendingPathComponent("new-library")
    let legacy = parent.appendingPathComponent("photos")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

    let filename = "legacy-capture.heic"
    let sourceURL = legacy.appendingPathComponent(filename)
    try Data("legacy-image".utf8).write(to: sourceURL)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(
      LegacyFixture(
        filename: filename,
        timestamp: Date(timeIntervalSince1970: 1_600_000_000)
      )
    ).write(to: legacy.appendingPathComponent("legacy-capture.json"))

    try Data("not-json".utf8).write(
      to: root.appendingPathComponent(MediaLibraryPaths.legacyDeletionLedger),
      options: .atomic
    )

    let library = MediaLibrary(rootURL: root, legacyPhotosDirectory: legacy)
    let snapshot = try await library.prepare()
    XCTAssertTrue(snapshot.items.isEmpty)
    XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .corruptLegacyDeletionLedger })
    XCTAssertEqual(try Data(contentsOf: sourceURL), Data("legacy-image".utf8))

    let recovery = root.appendingPathComponent(MediaLibraryPaths.recovery)
    let recoveryEntries = try FileManager.default.contentsOfDirectory(atPath: recovery.path)
    XCTAssertTrue(recoveryEntries.contains { $0.hasPrefix("corrupt-legacy-deletions-") })
  }

  func testMissingAndCorruptFilesProduceDiagnostics() async throws {
    let root = try temporaryDirectory(named: "library")
    let library = MediaLibrary(rootURL: root)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )
    let assetValue = try await library.assetURL(for: item, kind: .processed)
    let asset = try XCTUnwrap(assetValue)
    try FileManager.default.removeItem(at: asset)

    let relaunched = MediaLibrary(rootURL: root)
    let snapshot = try await relaunched.prepare()
    XCTAssertTrue(
      snapshot.diagnostics.contains { diagnostic in
        diagnostic.code == .missingFile && diagnostic.itemID == item.id
      })
  }

  func testRelaunchReconcilesNewerItemMetadataAndRemovesSupersededOrphans() async throws {
    let root = try temporaryDirectory(named: "reconcile")
    let library = MediaLibrary(rootURL: root)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )
    let itemDirectory =
      root
      .appendingPathComponent(MediaLibraryPaths.media)
      .appendingPathComponent(item.id.uuidString.lowercased())
    let orphan = itemDirectory.appendingPathComponent("processed-old-orphan.jpg")
    try Data("orphan".utf8).write(to: orphan)

    var newer = item
    newer.isFavorite = true
    let metadata = try ApertureJSON.makeEncoder().encode(newer)
    try metadata.write(
      to: itemDirectory.appendingPathComponent(MediaLibraryPaths.itemMetadata), options: .atomic)

    let relaunched = MediaLibrary(rootURL: root)
    let snapshot = try await relaunched.prepare()
    XCTAssertEqual(snapshot.items.first?.isFavorite, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertTrue(
      snapshot.diagnostics.contains {
        $0.code == .recoveredCommittedItem && $0.itemID == item.id
      })
  }

  func testRelaunchDoesNotDeleteViableOrphanWhenMetadataReferencesMissingAsset() async throws {
    let root = try temporaryDirectory(named: "missing-replacement")
    let library = MediaLibrary(rootURL: root)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )
    let oldAssetValue = try await library.assetURL(for: item, kind: .processed)
    let oldAsset = try XCTUnwrap(oldAssetValue)
    var damaged = item
    damaged.files = MediaFileSet(
      processed: "media/\(item.id.uuidString.lowercased())/missing-replacement.jpg",
      original: nil,
      thumbnail: nil
    )
    let itemDirectory =
      root
      .appendingPathComponent(MediaLibraryPaths.media)
      .appendingPathComponent(item.id.uuidString.lowercased())
    let metadata = try ApertureJSON.makeEncoder().encode(damaged)
    try metadata.write(
      to: itemDirectory.appendingPathComponent(MediaLibraryPaths.itemMetadata),
      options: .atomic
    )

    let relaunched = MediaLibrary(rootURL: root)
    let snapshot = try await relaunched.prepare()
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldAsset.path))
    XCTAssertTrue(
      snapshot.diagnostics.contains {
        $0.code == .orphanCleanupSkipped && $0.itemID == item.id
      })
  }

  func testFailedStageDoesNotLeavePartialTransactionDirectoryAndMapsLowStorage() async throws {
    let root = try temporaryDirectory(named: "failed-stage")
    let source = root.appendingPathComponent("source.heic")
    try Data("original".utf8).write(to: source)
    let fileManager = FailingCopyFileManager()
    let library = MediaLibrary(
      rootURL: root.appendingPathComponent("library"),
      fileSystem: MediaLibraryFileSystem(fileManager)
    )
    let request = TestMediaFactory.makeWriteRequest()
    do {
      _ = try await library.stage(
        request,
        processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg"),
        original: MediaAssetPayload(fileURL: source)
      )
      XCTFail("Expected the simulated out-of-space failure")
    } catch let error as MediaLibraryError {
      guard case .insufficientStorage = error else {
        return XCTFail("Expected insufficientStorage, got \(error)")
      }
    }
    let stagingURL = root.appendingPathComponent("library").appendingPathComponent(
      MediaLibraryPaths.staging)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil)
        .isEmpty)
  }

  func testCorruptManifestIsPreservedAndRebuiltFromItemMetadata() async throws {
    let root = try temporaryDirectory(named: "library")
    let library = MediaLibrary(rootURL: root)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: Data("photo".utf8), fileExtension: "jpg")
    )
    let manifestURL = root.appendingPathComponent(MediaLibraryPaths.manifest)
    try Data("{ definitely-not-json".utf8).write(to: manifestURL, options: .atomic)

    let relaunched = MediaLibrary(rootURL: root)
    let snapshot = try await relaunched.prepare()
    XCTAssertEqual(snapshot.items.map(\.id), [item.id])
    XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .corruptManifest })
    XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .recoveredCommittedItem })

    let recoveryURL = root.appendingPathComponent(MediaLibraryPaths.recovery)
    let backups = try FileManager.default.contentsOfDirectory(atPath: recoveryURL.path)
    XCTAssertTrue(backups.contains { $0.hasPrefix("corrupt-manifest-") })
    _ = try ApertureJSON.makeDecoder().decode(
      RebuiltManifestFixture.self,
      from: Data(contentsOf: manifestURL)
    )
  }

  func testReplacementRollbackFailureRetainsBothPayloadsForRecovery() async throws {
    let root = try temporaryDirectory(named: "replacement-rollback")
    let failures = DataWriteFailurePlan()
    let fileSystem = MediaLibraryFileSystem(FileManager.default) { data, url, options in
      try failures.write(data, to: url, options: options)
    }
    let library = MediaLibrary(rootURL: root, fileSystem: fileSystem)
    let oldData = Data("old-developed-photo".utf8)
    let item = try await library.createAndCommit(
      TestMediaFactory.makeWriteRequest(),
      processed: MediaAssetPayload(data: oldData, fileExtension: "jpg")
    )
    let oldURLValue = try await awaitAssetURL(library, item: item)
    let oldURL = try XCTUnwrap(oldURLValue)

    // Permit the replacement item.json write, then fail the manifest commit
    // and the metadata rollback write that follows it.
    failures.failNextManifestWrite = true
    failures.metadataWritesBeforeFailure = 1
    let newData = Data("new-developed-photo".utf8)
    do {
      _ = try await library.replaceProcessedAsset(
        for: item.id,
        with: MediaAssetPayload(data: newData, fileExtension: "jpg"),
        dimensions: item.dimensions
      )
      XCTFail("Expected the injected manifest and metadata rollback failures")
    } catch let error as MediaLibraryError {
      guard case .transactionRollbackFailed = error else {
        return XCTFail("Expected transactionRollbackFailed, got \(error)")
      }
    }

    let itemDirectory = oldURL.deletingLastPathComponent()
    let payloads = try FileManager.default.contentsOfDirectory(
      at: itemDirectory,
      includingPropertiesForKeys: [.isRegularFileKey]
    ).filter { $0.lastPathComponent != MediaLibraryPaths.itemMetadata }
    XCTAssertEqual(payloads.count, 2)
    // On device, `contentsOfDirectory` returns `/private/var/...` while the
    // library hands back the symlink-resolved `/var/...` form, so compare by
    // resolved path rather than URL equality.
    let payloadPaths = Set(payloads.map { $0.resolvingSymlinksInPath().path })
    XCTAssertTrue(payloadPaths.contains(oldURL.resolvingSymlinksInPath().path))
    XCTAssertTrue(payloads.contains { (try? Data(contentsOf: $0)) == newData })

    let relaunched = MediaLibrary(rootURL: root)
    let snapshot = try await relaunched.prepare()
    let recovered = try XCTUnwrap(snapshot.items.first)
    let recoveredURLValue = try await awaitAssetURL(relaunched, item: recovered)
    let recoveredURL = try XCTUnwrap(recoveredURLValue)
    XCTAssertEqual(try Data(contentsOf: recoveredURL), newData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))
  }

  func testPathTraversalIsRejected() async throws {
    let root = try temporaryDirectory(named: "library")
    let library = MediaLibrary(rootURL: root)
    do {
      _ = try await library.assetURL(for: "../private.jpg")
      XCTFail("Expected unsafe path rejection")
    } catch let error as MediaLibraryError {
      XCTAssertEqual(error, .invalidRelativePath("../private.jpg"))
    }
  }

  private struct LegacyFixture: Encodable {
    let filename: String
    let timestamp: Date
  }

  private struct RebuiltManifestFixture: Decodable {
    let schemaVersion: Int
    let items: [MediaItem]
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApertureTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func awaitAssetURL(_ library: MediaLibrary, item: MediaItem) async throws -> URL? {
    try await library.assetURL(for: item, kind: .processed)
  }
}

private final class FailingCopyFileManager: FileManager {
  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    throw NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileWriteOutOfSpaceError,
      userInfo: [NSLocalizedDescriptionKey: "The volume is full."]
    )
  }
}

private final class DataWriteFailurePlan: @unchecked Sendable {
  var failNextManifestWrite = false
  var metadataWritesBeforeFailure: Int?

  func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
    if url.lastPathComponent == MediaLibraryPaths.manifest, failNextManifestWrite {
      failNextManifestWrite = false
      throw NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSLocalizedDescriptionKey: "Injected manifest write failure."]
      )
    }
    if url.lastPathComponent == MediaLibraryPaths.itemMetadata,
      let remaining = metadataWritesBeforeFailure
    {
      if remaining == 0 {
        metadataWritesBeforeFailure = nil
        throw NSError(
          domain: NSCocoaErrorDomain,
          code: NSFileWriteUnknownError,
          userInfo: [NSLocalizedDescriptionKey: "Injected metadata rollback failure."]
        )
      }
      metadataWritesBeforeFailure = remaining - 1
    }
    try data.write(to: url, options: options)
  }
}
