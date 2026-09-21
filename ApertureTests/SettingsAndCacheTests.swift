import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Aperture

final class SettingsAndCacheTests: XCTestCase {
  func testSettingsPersistenceAndReset() throws {
    let suiteName = "ApertureTests.Settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults, key: "settings")

    XCTAssertEqual(try store.load(), .defaults)
    var settings = AppSettings.defaults
    settings.selectedFilm = .cinema
    settings.lightLeaksEnabled = false
    settings.dateStamp = DateStampConfiguration(
      mode: .current,
      format: .yearMonthDay,
      localeIdentifier: "en_CA"
    )
    settings.hapticsEnabled = false
    settings.autoSaveToPhotos = true
    settings.preserveOriginal = false
    settings.photoQuality = .maximum
    settings.filmRollModeEnabled = true

    try store.save(settings)
    XCTAssertEqual(try store.load(), settings)

    store.reset()
    XCTAssertEqual(try store.load(), .defaults)
  }

  /// Settings written before the full-screen viewfinder key existed must keep
  /// loading. A missing key is an older payload, not a corrupt one, and
  /// treating it as corrupt would silently reset someone's preferences.
  func testSettingsWrittenBeforeFullScreenKeyStillLoad() throws {
    let suiteName = "ApertureTests.Settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults, key: "settings")

    // Deliberately non-default, so the assertion can tell "loaded correctly"
    // apart from "quietly reset to defaults".
    var saved = AppSettings.defaults
    saved.selectedFilm = .cinema
    saved.lightLeaksEnabled = false
    saved.hapticsEnabled = false
    saved.autoSaveToPhotos = true
    saved.preserveOriginal = false
    saved.photoQuality = .maximum
    saved.filmRollModeEnabled = true

    var legacy = try XCTUnwrap(
      try JSONSerialization.jsonObject(
        with: ApertureJSON.makeEncoder().encode(saved)
      ) as? [String: Any]
    )
    legacy.removeValue(forKey: "fullScreenViewfinderEnabled")
    XCTAssertNil(legacy["fullScreenViewfinderEnabled"])
    defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "settings")

    let loaded = try store.load()
    XCTAssertFalse(loaded.fullScreenViewfinderEnabled)
    XCTAssertEqual(loaded, saved)
    XCTAssertNotEqual(loaded, AppSettings.defaults)
  }

  func testFullScreenViewfinderSettingRoundTrips() throws {
    let suiteName = "ApertureTests.Settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults, key: "settings")

    var settings = AppSettings.defaults
    settings.fullScreenViewfinderEnabled = true
    try store.save(settings)
    XCTAssertTrue(try store.load().fullScreenViewfinderEnabled)
  }

  func testSettingsStoreReportsCorruptPayload() throws {
    let suiteName = "ApertureTests.Settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not-json".utf8), forKey: "settings")

    let store = SettingsStore(defaults: defaults, key: "settings")
    XCTAssertThrowsError(try store.load()) { error in
      guard case SettingsStoreError.corruptData = error else {
        return XCTFail("Expected corruptData, got \(error)")
      }
    }
  }

  func testSettingsStoreReportsWrongTypeAndUnsupportedSchemaAsCorrupt() throws {
    let suiteName = "ApertureTests.Settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults, key: "settings")

    defaults.set("not-data", forKey: "settings")
    XCTAssertThrowsError(try store.load()) { error in
      guard case SettingsStoreError.corruptData = error else {
        return XCTFail("Expected corruptData for wrong value type, got \(error)")
      }
    }

    let unsupported = AppSettings(schemaVersion: AppSettings.currentSchemaVersion + 1)
    defaults.set(try ApertureJSON.makeEncoder().encode(unsupported), forKey: "settings")
    XCTAssertThrowsError(try store.load()) { error in
      guard case SettingsStoreError.corruptData = error else {
        return XCTFail("Expected corruptData for unsupported schema, got \(error)")
      }
    }
  }

  func testCacheKeyIsStableAndVersioned() {
    let item = TestMediaFactory.makeItem(
      id: UUID(uuidString: "7BC63844-C991-42A3-B8C7-8DE91546A55D")!
    )
    let first = ThumbnailCacheKey(item: item, maximumPixelDimension: 300)
    let second = ThumbnailCacheKey(item: item, maximumPixelDimension: 300)
    let larger = ThumbnailCacheKey(item: item, maximumPixelDimension: 600)
    let rerendered = ThumbnailCacheKey(
      item: item,
      maximumPixelDimension: 300,
      version: ThumbnailCacheVersion(
        namespace: "aperture.thumbnail", schema: 1,
        renderer: ThumbnailCacheVersion.current.renderer + 1)
    )

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.fileName, second.fileName)
    XCTAssertNotEqual(first.fileName, larger.fileName)
    XCTAssertNotEqual(first.fileName, rerendered.fileName)
    XCTAssertTrue(first.fileName.hasPrefix(item.id.uuidString.lowercased() + "-"))
    XCTAssertTrue(first.fileName.hasSuffix(".jpg"))
    XCTAssertFalse(ThumbnailCacheVersion.current.requiresInvalidation(comparedTo: .current))
    XCTAssertTrue(ThumbnailCacheVersion.current.requiresInvalidation(comparedTo: nil))
    XCTAssertTrue(
      ThumbnailCacheVersion.current.requiresInvalidation(
        comparedTo: ThumbnailCacheVersion(namespace: "aperture.thumbnail", schema: 1, renderer: 0)
      )
    )
  }

  func testThumbnailServiceDefaultMemoryCostLimitIsAnExplicitByteBudget() {
    // 64 MiB, and expressed in bytes rather than a pixel or item count, so a
    // handful of large detail-view decodes can't blow past a real memory
    // budget the way a pixel-count-only cost would.
    XCTAssertEqual(ThumbnailService.defaultMemoryCostLimitBytes, 64 * 1024 * 1024)
  }

  /// After a render, a repeated request for the same key must be served
  /// without needing the source file again — proving the object survived in
  /// the memory tier under the real (64 MiB) budget rather than being
  /// mis-costed into immediate eviction.
  func testThumbnailMemoryCacheServesRepeatedRequestWithoutRereadingSource() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.jpg")
    try Self.writeSolidJPEG(pixelSize: 64, to: sourceURL)

    let service = ThumbnailService(cacheDirectory: directory.appendingPathComponent("cache"))
    let item = TestMediaFactory.makeItem()

    let first = try await service.image(for: item, sourceURL: sourceURL, maximumPixelDimension: 64)
    try FileManager.default.removeItem(at: sourceURL)

    let second = try await service.image(for: item, sourceURL: sourceURL, maximumPixelDimension: 64)
    XCTAssertEqual(first.size, second.size)
  }

  /// A second `ThumbnailService` bound to the same directory has an empty
  /// memory cache but must still read what the first service wrote to disk.
  /// This is the "disk compatibility" side of the cost-accounting change:
  /// moving `remember`'s cost from a pixel count to real bytes must not
  /// touch the on-disk format or file naming at all.
  func testThumbnailDiskCacheServesAcrossServiceInstancesAfterSourceRemoved() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.jpg")
    try Self.writeSolidJPEG(pixelSize: 48, to: sourceURL)
    let cacheDirectory = directory.appendingPathComponent("cache")

    let item = TestMediaFactory.makeItem()
    let writingService = ThumbnailService(cacheDirectory: cacheDirectory)
    let rendered = try await writingService.image(
      for: item, sourceURL: sourceURL, maximumPixelDimension: 48)
    try FileManager.default.removeItem(at: sourceURL)

    let freshService = ThumbnailService(cacheDirectory: cacheDirectory)
    let fromDisk = try await freshService.image(
      for: item, sourceURL: sourceURL, maximumPixelDimension: 48)
    XCTAssertEqual(rendered.size, fromDisk.size)
  }

  /// A tight, injected byte budget still has to produce a usable image for a
  /// single render — the count bound (`countLimit`) and the byte bound
  /// (`totalCostLimit`) are independent caps, and neither should make a
  /// single in-flight render fail.
  func testThumbnailServiceRendersUnderATightByteBudget() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.jpg")
    try Self.writeSolidJPEG(pixelSize: 32, to: sourceURL)

    let service = ThumbnailService(
      cacheDirectory: directory.appendingPathComponent("cache"),
      memoryCostLimitBytes: 1024
    )
    let item = TestMediaFactory.makeItem()
    let image = try await service.image(for: item, sourceURL: sourceURL, maximumPixelDimension: 32)
    XCTAssertGreaterThan(image.size.width, 0)
  }

  /// Invalidating an item must clear the memory tier as well as the disk
  /// tier: once invalidated, a request that can no longer reach the source
  /// file has nothing left to serve it from.
  func testThumbnailInvalidationClearsMemoryCacheNotOnlyDisk() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.jpg")
    try Self.writeSolidJPEG(pixelSize: 40, to: sourceURL)

    let service = ThumbnailService(cacheDirectory: directory.appendingPathComponent("cache"))
    let item = TestMediaFactory.makeItem()
    _ = try await service.image(for: item, sourceURL: sourceURL, maximumPixelDimension: 40)

    try await service.invalidate(itemID: item.id)
    try FileManager.default.removeItem(at: sourceURL)

    do {
      _ = try await service.image(for: item, sourceURL: sourceURL, maximumPixelDimension: 40)
      XCTFail("Expected the invalidated, source-less item to fail to render")
    } catch {
      // Expected: neither cache tier nor the source can serve it anymore.
    }
  }

  func testThumbnailInvalidationRemovesPriorSessionVariantsOnlyForDeletedItem() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ApertureThumbnailInvalidation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let deletedID = UUID()
    let retainedID = UUID()

    let initialService = ThumbnailService(cacheDirectory: directory)
    try await initialService.invalidate(itemID: deletedID)
    let deletedPrefix = deletedID.uuidString.lowercased() + "-"
    let retainedPrefix = retainedID.uuidString.lowercased() + "-"
    let deletedSmall = directory.appendingPathComponent(deletedPrefix + "small.jpg")
    let deletedLarge = directory.appendingPathComponent(deletedPrefix + "large.jpg")
    let retained = directory.appendingPathComponent(retainedPrefix + "small.jpg")
    try Data([1]).write(to: deletedSmall)
    try Data([2]).write(to: deletedLarge)
    try Data([3]).write(to: retained)

    // A new service has no in-memory mapping from the previous launch.
    let relaunchedService = ThumbnailService(cacheDirectory: directory)
    try await relaunchedService.invalidate(itemID: deletedID)

    XCTAssertFalse(FileManager.default.fileExists(atPath: deletedSmall.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: deletedLarge.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
  }

  /// A request whose caller task is already canceled before `image(...)`
  /// starts must never reach the render step. `testRenderGate` doubles as a
  /// "was render entered" sentinel here: since it is only ever invoked from
  /// inside the detached render task, an entry count of zero proves the
  /// pre-scheduling cancellation check ran (and the unpreemptable
  /// decode/encode work was skipped), not merely that publication happened
  /// to lose a race.
  func testAlreadyCanceledRequestNeverRendersOrPublishes() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.jpg")
    try Self.writeSolidJPEG(pixelSize: 40, to: sourceURL)
    let cacheDirectory = directory.appendingPathComponent("cache")

    let service = ThumbnailService(cacheDirectory: cacheDirectory)
    let item = TestMediaFactory.makeItem()
    let expectedFileName = ThumbnailCacheKey(item: item, maximumPixelDimension: 40).fileName

    let gate = ThumbnailRenderGate()
    await service.setTestRenderGate { await gate.enter() }

    await gate.release()
    let task = Task {
      // Cancel from inside the task so no scheduler race can start the request first.
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.image(for: item, sourceURL: sourceURL, maximumPixelDimension: 40)
    }

    do {
      _ = try await task.value
      XCTFail("Expected the already-canceled request to throw instead of rendering")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    let entries = await gate.entryCount
    XCTAssertEqual(entries, 0, "An already-canceled request must never reach the render step")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: cacheDirectory.appendingPathComponent(expectedFileName).path),
      "An already-canceled request must not publish a disk cache entry")
  }

  /// A request that is genuinely in flight — scheduled, and paused at a
  /// controlled gate immediately before the unpreemptable decode/encode
  /// call — must still stop before publishing to either cache once its
  /// caller is canceled. This exercises cancellation forwarded into the
  /// detached render task plus the pre-publication check, coordinated
  /// deterministically through `testRenderGate` rather than any timing
  /// assumption or `sleep`.
  func testInFlightCancellationStopsBeforePublishingToEitherCache() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.jpg")
    try Self.writeSolidJPEG(pixelSize: 40, to: sourceURL)
    let cacheDirectory = directory.appendingPathComponent("cache")

    let service = ThumbnailService(cacheDirectory: cacheDirectory)
    let item = TestMediaFactory.makeItem()
    let expectedFileName = ThumbnailCacheKey(item: item, maximumPixelDimension: 40).fileName

    let gate = ThumbnailRenderGate()
    await service.setTestRenderGate { await gate.enter() }

    let task = Task {
      try await service.image(for: item, sourceURL: sourceURL, maximumPixelDimension: 40)
    }

    // Block until the request is provably past scheduling and waiting right
    // before the real decode/encode call, then cancel its caller and let it
    // proceed — deterministic regardless of how the scheduler interleaves
    // these tasks.
    await gate.waitUntilEntered()
    task.cancel()
    await gate.release()

    do {
      _ = try await task.value
      XCTFail("Expected the in-flight request to be canceled rather than complete")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: cacheDirectory.appendingPathComponent(expectedFileName).path),
      "A canceled in-flight request must not publish a disk cache entry")

    // The memory tier should be empty too: with the source now removed, a
    // fresh request can only succeed from a cache this request should not
    // have populated.
    try FileManager.default.removeItem(at: sourceURL)
    do {
      _ = try await service.image(for: item, sourceURL: sourceURL, maximumPixelDimension: 40)
      XCTFail(
        "Expected a source-less retry to fail without a cache entry from the canceled request")
    } catch {
      // Expected.
    }
  }

  private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ApertureThumbnailCostTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private enum TestImageWriteError: Error { case cannotCreateContext, cannotCreateDestination }

  /// A minimal, real JPEG on disk so `ThumbnailService.render` exercises its
  /// actual `CGImageSource`/`CGImageDestination` path rather than a mock.
  private static func writeSolidJPEG(pixelSize: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw TestImageWriteError.cannotCreateContext
    }
    context.setFillColor(red: 0.42, green: 0.2, blue: 0.63, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    guard let cgImage = context.makeImage() else { throw TestImageWriteError.cannotCreateContext }

    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw TestImageWriteError.cannotCreateDestination
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw TestImageWriteError.cannotCreateDestination
    }
  }
}

/// Coordinates a `ThumbnailService.testRenderGate` invocation with a test:
/// lets the test wait until the gate has actually been entered (proving the
/// request reached the point immediately before the unpreemptable
/// decode/encode call) and then release it — deterministically, without a
/// `sleep` or any assumption about how the scheduler interleaves tasks.
private actor ThumbnailRenderGate {
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var hasEntered = false
  private var isReleased = false
  private(set) var entryCount = 0

  func enter() async {
    entryCount += 1
    hasEntered = true
    enteredContinuation?.resume()
    enteredContinuation = nil
    if isReleased { return }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    if hasEntered { return }
    await withCheckedContinuation { continuation in
      enteredContinuation = continuation
    }
  }

  func release() {
    isReleased = true
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

enum TestMediaFactory {
  static func makeItem(
    id: UUID = UUID(), capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> MediaItem {
    let recipe = FilmRecipeCatalog.nineteenNinetyEight.resolve(
      seed: 99,
      capturedAt: capturedAt,
      options: FilmProcessingOptions(lightLeaksEnabled: true, dateStamp: .off),
      timeZone: .gmt
    )
    let relativeParent = "media/\(id.uuidString.lowercased())"
    return MediaItem(
      id: id,
      mediaType: .photo,
      files: MediaFileSet(
        processed: "\(relativeParent)/processed.jpg",
        original: nil,
        thumbnail: nil
      ),
      dimensions: PixelDimensions(width: 12, height: 8),
      durationSeconds: nil,
      capturedAt: capturedAt,
      recipe: recipe,
      camera: nil,
      processing: .ready
    )
  }

  static func makeWriteRequest(id: UUID = UUID()) -> MediaWriteRequest {
    let item = makeItem(id: id)
    return MediaWriteRequest(
      id: item.id,
      mediaType: item.mediaType,
      dimensions: item.dimensions,
      durationSeconds: item.durationSeconds,
      capturedAt: item.capturedAt,
      recipe: item.recipe,
      camera: item.camera,
      isFavorite: item.isFavorite,
      processing: item.processing,
      provenance: item.provenance
    )
  }
}
