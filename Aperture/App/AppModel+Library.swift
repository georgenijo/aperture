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
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func delete(_ item: MediaItem) async -> Bool {
    do {
      _ = try await mediaLibrary.delete(id: item.id)
      try? await thumbnailService.invalidate(itemID: item.id)
      await refresh()
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

  func export(_ items: [MediaItem]) async -> Bool {
    do {
      var assets: [PhotosExportAsset] = []
      for item in items where item.processing.phase == .ready {
        if let url = try await mediaLibrary.assetURL(for: item, kind: .processed) {
          assets.append(
            PhotosExportAsset(url: url, mediaType: item.mediaType, capturedAt: item.capturedAt))
        }
      }
      guard !assets.isEmpty else {
        errorMessage = "There is no developed media to export yet."
        return false
      }
      try await photosExporter.export(assets)
      notice =
        assets.count == 1 ? "Saved to Photos." : "Saved \(assets.count) media items to Photos."
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
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
