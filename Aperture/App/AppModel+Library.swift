import AVFoundation
import Foundation
import UIKit

extension AppModel {
  static func makeFallbackLibrary() -> MediaLibrary {
    let base =
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return MediaLibrary(
      rootURL: base.appendingPathComponent("ApertureMediaLibrary", isDirectory: true))
  }

  func setFavorite(_ item: MediaItem, isFavorite: Bool) async {
    do {
      try await mediaLibrary.setFavorite(isFavorite, for: item.id)
      await syncAfterMutation()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func delete(_ item: MediaItem) async -> Bool {
    do {
      _ = try await mediaLibrary.delete(id: item.id)
      try? await thumbnailService.invalidate(itemID: item.id)
      await syncAfterMutation()
      return true
    } catch {
      // The manifest may already have committed when directory cleanup
      // failed. Refresh in both cases so the Lab reflects authority.
      try? await thumbnailService.invalidate(itemID: item.id)
      await refresh()
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Successfully saved assets and selected items skipped because they were
  /// not ready. Missing files and Photos failures remain errors, not success.
  struct ExportOutcome: Equatable {
    let exportedCount: Int
    let skippedCount: Int
  }

  /// The selection split into items ready to export and a count of the rest.
  /// `export(_:)` builds its asset list from `readyItems`, so tests that call
  /// this directly are exercising the same plan the exporter uses.
  nonisolated static func exportPlan(for items: [MediaItem]) -> (readyItems: [MediaItem], skippedCount: Int) {
    let readyItems = items.filter { $0.processing.phase == .ready }
    return (readyItems, items.count - readyItems.count)
  }

  /// The notice text callers (Lab, the detail view) show locally after a
  /// successful export, built from the actual outcome rather than the raw
  /// selection count.
  nonisolated static func exportNoticeText(for outcome: ExportOutcome) -> String {
    let saved =
      outcome.exportedCount == 1
      ? "Saved to Photos." : "Saved \(outcome.exportedCount) media items to Photos."
    guard outcome.skippedCount > 0 else { return saved }
    let skipped =
      outcome.skippedCount == 1
      ? "1 item wasn’t ready yet and was skipped."
      : "\(outcome.skippedCount) items weren’t ready yet and were skipped."
    return saved + " " + skipped
  }

  func export(_ items: [MediaItem]) async -> ExportOutcome? {
    do {
      let plan = Self.exportPlan(for: items)
      var assets: [PhotosExportAsset] = []
      for item in plan.readyItems {
        if let url = try await mediaLibrary.assetURL(for: item, kind: .processed) {
          assets.append(
            PhotosExportAsset(url: url, mediaType: item.mediaType, capturedAt: item.capturedAt))
        }
      }
      guard !assets.isEmpty else {
        errorMessage = "There is no developed media to export yet."
        return nil
      }
      // Callers (Lab, the detail view) already show their own local
      // "Saved to Photos" notice, built from the outcome below; publishing a
      // second, global one here would show it twice. Capture's auto-export
      // path is unrelated to this method and keeps its own failure notice,
      // since nothing else surfaces that outcome.
      try await photosExporter.export(assets)
      return ExportOutcome(
        exportedCount: assets.count, skippedCount: items.count - assets.count)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func processedURL(for item: MediaItem) async throws -> URL? {
    try await mediaLibrary.assetURL(for: item, kind: .processed)
  }

  func originalOrProcessedURL(for item: MediaItem) async throws -> URL? {
    if let original = try await mediaLibrary.assetURL(for: item, kind: .original) {
      return original
    }
    return try await mediaLibrary.assetURL(for: item, kind: .processed)
  }

  func retry(_ item: MediaItem) {
    guard item.processing.phase == .failed,
      item.processing.failure?.isRecoverable != false,
      !processingIDs.contains(item.id)
    else { return }
    processingIDs.insert(item.id)
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.developExisting(item)
    }
  }

  func clearMessages() {
    notice = nil
    errorMessage = nil
    dismissCameraIssue()
  }

}
