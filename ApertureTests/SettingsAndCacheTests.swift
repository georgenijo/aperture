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
      version: ThumbnailCacheVersion(namespace: "aperture.thumbnail", schema: 1, renderer: 3)
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
