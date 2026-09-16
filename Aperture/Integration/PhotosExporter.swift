import Foundation
import Photos

enum PhotosExportError: LocalizedError, Equatable, Sendable {
  case permissionDenied
  case missingFile(String)
  case libraryFailure(String)

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Photos access wasn’t granted. Your media is still safe in Aperture."
    case .missingFile(let name):
      "Aperture couldn’t find \(name) to export."
    case .libraryFailure(let details):
      "Photos couldn’t save the selection: \(details)"
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .permissionDenied:
      "Allow Add Photos Only access in Settings, then try again."
    case .missingFile:
      "Return to the Lab and retry development if it is available."
    case .libraryFailure:
      "Check available storage and Photos permissions, then try again."
    }
  }
}

struct PhotosExportAsset: Sendable {
  let url: URL
  let mediaType: MediaType
  let capturedAt: Date
}

actor PhotosExporter {
  func authorizationStatus() -> PHAuthorizationStatus {
    PHPhotoLibrary.authorizationStatus(for: .addOnly)
  }

  func export(_ assets: [PhotosExportAsset]) async throws {
    guard !assets.isEmpty else { return }
    for asset in assets where !FileManager.default.fileExists(atPath: asset.url.path) {
      throw PhotosExportError.missingFile(asset.url.lastPathComponent)
    }

    let status = await requestAuthorizationIfNeeded()
    guard status == .authorized || status == .limited else {
      throw PhotosExportError.permissionDenied
    }

    do {
      try await PHPhotoLibrary.shared().performChanges {
        for asset in assets {
          let request = PHAssetCreationRequest.forAsset()
          request.creationDate = asset.capturedAt
          let resourceType: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
          request.addResource(with: resourceType, fileURL: asset.url, options: nil)
        }
      }
    } catch {
      throw PhotosExportError.libraryFailure(error.localizedDescription)
    }
  }

  private func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
    let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    guard current == .notDetermined else { return current }
    return await withCheckedContinuation { continuation in
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        continuation.resume(returning: status)
      }
    }
  }
}
