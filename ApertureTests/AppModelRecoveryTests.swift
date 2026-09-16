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
}
