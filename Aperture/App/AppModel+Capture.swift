import AVFoundation
import Foundation
import UIKit

extension AppModel {
  func handleCapture(_ result: Result<CapturedPhoto, CameraIssue>) {
    switch result {
    case .success(let captured):
      dismissedCameraIssue = nil
      cameraIssue = nil
      processCapture(captured)
    case .failure(let issue):
      presentCameraIssue(issue)
    }
  }

  func handleVideoCapture(_ result: Result<CapturedVideo, CameraIssue>) {
    switch result {
    case .failure(let issue):
      recordingContext = nil
      presentCameraIssue(issue)
    case .success(let captured):
      dismissedCameraIssue = nil
      cameraIssue = nil
      let context = recordingContext ?? fallbackRecordingContext(capturedAt: captured.capturedAt)
      recordingContext = nil
      processVideoCapture(captured, context: context)
    }
  }

  private func fallbackRecordingContext(capturedAt: Date) -> RecordingContext {
    let baseRecipe =
      FilmRecipeCatalog.recipe(for: settings.selectedFilm) ?? FilmRecipeCatalog.cinema
    return RecordingContext(
      recipe: baseRecipe.resolve(
        seed: UInt64.random(in: UInt64.min...UInt64.max),
        capturedAt: capturedAt,
        options: processingOptions,
        timeZone: .autoupdatingCurrent
      ),
      preserveOriginal: settings.preserveOriginal,
      autoSaveToPhotos: settings.autoSaveToPhotos
    )
  }

  private func processVideoCapture(_ captured: CapturedVideo, context: RecordingContext) {
    let itemID = UUID()
    let cameraMetadata = makeCameraMetadata(from: captured.metadata)
    let dimensions: PixelDimensions? =
      captured.pixelWidth > 0 && captured.pixelHeight > 0
      ? PixelDimensions(width: captured.pixelWidth, height: captured.pixelHeight)
      : nil
    let request = MediaWriteRequest(
      id: itemID,
      mediaType: .video,
      dimensions: dimensions,
      durationSeconds: captured.durationSeconds,
      capturedAt: captured.capturedAt,
      recipe: context.recipe,
      camera: cameraMetadata,
      processing: .pending
    )
    // The movie remains file-backed through ingestion. MediaLibrary copies
    // it atomically into its authoritative folder before processing starts.
    let source = MediaAssetPayload(fileURL: captured.fileURL, fileExtension: "mov")
    processingIDs.insert(itemID)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { try? FileManager.default.removeItem(at: captured.fileURL) }
      do {
        let item = try await self.mediaLibrary.createAndCommit(
          request,
          processed: source,
          original: context.preserveOriginal ? source : nil
        )
        await self.refresh()
        try await self.mediaLibrary.updateProcessing(item.processing.nextAttempt, for: item.id)
        await self.refresh()
        await self.developVideo(item: item, autoSaveToPhotos: context.autoSaveToPhotos)
      } catch {
        var reportedError: Error = error
        // If the transaction was interrupted after all source files became
        // durable, refresh publishes that staged capture. Continue developing
        // it instead of leaving the user with an invisible photograph.
        await self.refresh()
        if let recovered = self.items.first(where: { $0.id == itemID }),
          recovered.processing.phase == .pending
        {
          do {
            try await self.mediaLibrary.updateProcessing(
              recovered.processing.nextAttempt, for: recovered.id)
            await self.refresh()
            await self.developVideo(
              item: recovered, autoSaveToPhotos: context.autoSaveToPhotos)
            return
          } catch {
            reportedError = error
          }
        }
        self.processingIDs.remove(itemID)
        await self.markProcessingFailed(itemID, error: reportedError)
        self.errorMessage = reportedError.localizedDescription
        await self.refresh()
      }
    }
  }

  private func processCapture(_ captured: CapturedPhoto) {
    let capturedAt = captured.capturedAt
    let seed = UInt64.random(in: UInt64.min...UInt64.max)
    guard let baseRecipe = FilmRecipeCatalog.recipe(for: settings.selectedFilm) else {
      errorMessage = "The selected film recipe is unavailable."
      return
    }
    let appliedRecipe = baseRecipe.resolve(
      seed: seed,
      capturedAt: capturedAt,
      options: processingOptions,
      timeZone: .autoupdatingCurrent
    )
    let itemID = UUID()
    let cameraMetadata = makeCameraMetadata(from: captured.metadata)
    let request = MediaWriteRequest(
      id: itemID,
      mediaType: .photo,
      dimensions: PixelDimensions(width: captured.pixelWidth, height: captured.pixelHeight),
      capturedAt: capturedAt,
      recipe: appliedRecipe,
      camera: cameraMetadata,
      processing: .pending
    )
    let original: MediaAssetPayload? =
      settings.preserveOriginal
      ? MediaAssetPayload(data: captured.data, fileExtension: captured.fileExtension)
      : nil

    processingIDs.insert(itemID)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        // The camera bytes become a committed item before development starts.
        let item = try await self.mediaLibrary.createAndCommit(
          request,
          processed: MediaAssetPayload(data: captured.data, fileExtension: captured.fileExtension),
          original: original
        )
        await self.refresh()
        try await self.mediaLibrary.updateProcessing(item.processing.nextAttempt, for: item.id)
        await self.refresh()
        try await self.develop(item: item, sourceData: captured.data)
      } catch {
        var reportedError: Error = error
        await self.refresh()
        if let recovered = self.items.first(where: { $0.id == itemID }),
          recovered.processing.phase == .pending
        {
          do {
            try await self.mediaLibrary.updateProcessing(
              recovered.processing.nextAttempt, for: recovered.id)
            await self.refresh()
            try await self.develop(item: recovered, sourceData: captured.data)
            return
          } catch {
            reportedError = error
          }
        }
        self.processingIDs.remove(itemID)
        await self.markProcessingFailed(itemID, error: reportedError)
        self.errorMessage = reportedError.localizedDescription
        await self.refresh()
      }
    }
  }

  func developExisting(_ item: MediaItem) async {
    if item.mediaType == .video {
      do {
        guard try await existingOriginalOrProcessedURL(for: item) != nil else {
          throw MediaLibraryError.fileOperation(
            operation: "read", path: item.id.uuidString, details: "The source file is missing.")
        }
        try await mediaLibrary.updateProcessing(item.processing.nextAttempt, for: item.id)
        await refresh()
        await developVideo(item: item, autoSaveToPhotos: settings.autoSaveToPhotos)
      } catch {
        processingIDs.remove(item.id)
        await markProcessingFailed(item.id, error: error)
        errorMessage = error.localizedDescription
        await refresh()
      }
      return
    }
    do {
      guard let sourceURL = try await existingOriginalOrProcessedURL(for: item) else {
        throw MediaLibraryError.fileOperation(
          operation: "read", path: item.id.uuidString, details: "The source file is missing.")
      }
      let sourceData = try await Task.detached(priority: .userInitiated) {
        try Data(contentsOf: sourceURL)
      }.value
      try await mediaLibrary.updateProcessing(item.processing.nextAttempt, for: item.id)
      await refresh()
      try await develop(item: item, sourceData: sourceData)
    } catch {
      processingIDs.remove(item.id)
      await markProcessingFailed(item.id, error: error)
      errorMessage = error.localizedDescription
      await refresh()
    }
  }

  /// Re-renders older 1998 captures from their untouched originals so the
  /// baked-in stamp reflects the real capture date and time. The migration is
  /// deliberately local-only: it never creates duplicate entries in Photos.
  func migrateLegacyPhotoTimestamps() async {
    var migratedCount = 0
    let digitalConfiguration = DateStampConfiguration(
      mode: .current,
      format: .digitalDateTime,
      localeIdentifier: "en_US_POSIX"
    )

    for item in items where item.mediaType == .photo
      && item.recipe.identifier == .nineteenNinetyEight
      && item.processing.phase == .ready
      && (item.recipe.resolvedSettings.dateStampConfiguration != digitalConfiguration
        || item.recipe.resolvedSettings.dateStampText?.contains(":") != true)
    {
      guard !Task.isCancelled else { return }
      guard let originalURL = try? await mediaLibrary.assetURL(for: item, kind: .original),
        FileManager.default.fileExists(atPath: originalURL.path)
      else {
        // Never develop a filtered JPEG a second time. Captures without a
        // preserved original keep their existing rendition.
        continue
      }

      let previousRecipe = item.recipe
      let previousProcessing = item.processing
      do {
        let timeZone =
          TimeZone(identifier: previousRecipe.resolvedSettings.timeZoneIdentifier)
          ?? .autoupdatingCurrent
        let stampText = ApertureDateStampFormatter.string(
          for: item.capturedAt,
          configuration: digitalConfiguration,
          timeZone: timeZone
        )
        let migratedRecipe = AppliedFilmRecipe(
          identifier: previousRecipe.identifier,
          version: previousRecipe.version,
          seed: previousRecipe.seed,
          stages: previousRecipe.stages,
          resolvedSettings: FilmResolvedSettings(
            lightLeakApplied: previousRecipe.resolvedSettings.lightLeakApplied,
            dateStampConfiguration: digitalConfiguration,
            dateStampText: stampText,
            timeZoneIdentifier: timeZone.identifier,
            compressionQuality: previousRecipe.resolvedSettings.compressionQuality
          )
        )
        let sourceData = try await Task.detached(priority: .utility) {
          try Data(contentsOf: originalURL)
        }.value
        let migratedItem = try await mediaLibrary.updateRecipe(migratedRecipe, for: item.id)
        try await mediaLibrary.updateProcessing(migratedItem.processing.nextAttempt, for: item.id)
        processingIDs.insert(item.id)
        await refresh()
        try await develop(
          item: migratedItem,
          sourceData: sourceData,
          autoSaveToPhotos: false,
          showCompletionNotice: false
        )
        migratedCount += 1
      } catch {
        // The previous developed file is still intact until replacement
        // succeeds, so restore its metadata and keep it usable on any error.
        _ = try? await mediaLibrary.updateRecipe(previousRecipe, for: item.id)
        try? await mediaLibrary.updateProcessing(previousProcessing, for: item.id)
        processingIDs.remove(item.id)
        errorMessage = error.localizedDescription
        await refresh()
      }
    }

    if migratedCount > 0 {
      notice = migratedCount == 1
        ? "Updated the photo timestamp."
        : "Updated (migratedCount) photo timestamps."
    }
  }

  private func develop(
    item: MediaItem,
    sourceData: Data,
    autoSaveToPhotos: Bool? = nil,
    showCompletionNotice: Bool = true
  ) async throws {
    let encoded = try await Task.detached(priority: .userInitiated) {
      let image = try FilmProcessor.shared.process(sourceData, recipe: item.recipe)
      // The applied recipe is the source of truth for repeatable output.
      return try FilmProcessor.shared.encodedData(
        image,
        format: .jpeg,
        quality: CGFloat(item.recipe.resolvedSettings.compressionQuality),
        metadataSource: sourceData
      )
    }.value

    let updatedItem = try await mediaLibrary.replaceProcessedAsset(
      for: item.id,
      with: MediaAssetPayload(data: encoded, fileExtension: "jpg"),
      dimensions: item.dimensions,
      durationSeconds: item.durationSeconds,
      processing: .ready
    )
    processingIDs.remove(item.id)
    await refresh()

    if autoSaveToPhotos ?? settings.autoSaveToPhotos,
      let url = try await mediaLibrary.assetURL(for: updatedItem, kind: .processed)
    {
      do {
        try await photosExporter.export([
          PhotosExportAsset(url: url, mediaType: .photo, capturedAt: item.capturedAt)
        ])
        notice = "Developed and saved to Photos."
      } catch {
        // The local item is already safe; auto-save is intentionally add-only.
        notice = "Developed locally. Photos could not be updated."
      }
    } else if showCompletionNotice {
      notice = "Developed."
    }
  }

  private func developVideo(item: MediaItem, autoSaveToPhotos: Bool) async {
    do {
      guard let sourceURL = try await existingOriginalOrProcessedURL(for: item) else {
        throw MediaLibraryError.fileOperation(
          operation: "read", path: item.id.uuidString, details: "The source movie is missing.")
      }
      let outputURL = try await VideoProcessor.shared.process(
        sourceURL: sourceURL, recipe: item.recipe
      ) { [weak self] update in
        guard let self else { return }
        Task { @MainActor in
          // Keep the UI responsive without making progress a source
          // of rapid SwiftUI invalidations.
          if update.fraction >= 1 { self.notice = "Finishing video…" }
        }
      }
      defer { try? FileManager.default.removeItem(at: outputURL) }
      let processed = MediaAssetPayload(fileURL: outputURL, fileExtension: outputURL.pathExtension)
      let updatedItem = try await mediaLibrary.replaceProcessedAsset(
        for: item.id,
        with: processed,
        dimensions: item.dimensions,
        durationSeconds: item.durationSeconds,
        processing: .ready
      )
      processingIDs.remove(item.id)
      await refresh()
      if autoSaveToPhotos,
        let url = try await mediaLibrary.assetURL(for: updatedItem, kind: .processed)
      {
        do {
          try await photosExporter.export([
            PhotosExportAsset(url: url, mediaType: .video, capturedAt: item.capturedAt)
          ])
          notice = "Developed and saved to Photos."
        } catch {
          notice = "Developed locally. Photos could not be updated."
        }
      } else {
        notice = "Developed video."
      }
    } catch {
      processingIDs.remove(item.id)
      await markProcessingFailed(item.id, error: error)
      errorMessage = error.localizedDescription
      await refresh()
    }
  }

  private func makeCameraMetadata(from info: CameraCaptureInfo) -> CameraCaptureMetadata {
    return CameraCaptureMetadata(
      position: info.cameraPosition,
      deviceType: info.deviceType,
      deviceUniqueID: info.deviceUniqueID.isEmpty ? nil : info.deviceUniqueID,
      lensDisplayName: info.lensDisplayName,
      zoomFactor: info.rawZoomFactor,
      nominalFocalLengthIn35mm: info.focalLength35mmEquivalent,
      virtualDeviceSwitchOverZoomFactors: info.virtualDeviceSwitchOverZoomFactors,
      flashMode: CapturedFlashMode(info.flashMode),
      // AVFoundation exposes whether the virtual device can fall back
      // to ultra-wide, but not a trustworthy per-capture "macro used"
      // flag. Do not persist capability as if it were capture fact.
      isMacroEnabled: false
    )
  }

  private func markProcessingFailed(_ id: UUID, error: Error) async {
    // The attempt that just failed is the one recorded on the item's
    // processing state; a failure never starts a new attempt.
    let attemptCount: Int
    if let item = try? await mediaLibrary.items(), let current = item.first(where: { $0.id == id })
    {
      attemptCount = max(1, current.processing.attemptCount)
    } else {
      attemptCount = 1
    }
    let failure = MediaProcessingFailure(
      code: Self.processingFailureCode(for: error),
      message: error.localizedDescription,
      isRecoverable: true,
      attemptCount: attemptCount
    )
    try? await mediaLibrary.updateProcessing(.failed(failure), for: id)
  }

  func presentCameraIssue(_ issue: CameraIssue) {
    dismissedCameraIssue = nil
    cameraIssue = issue
  }

  private static func processingFailureCode(for error: Error) -> MediaProcessingFailure.Code {
    if let error = error as? FilmProcessorError {
      switch error {
      case .decodeFailed: return .decodeFailed
      case .renderFailed: return .renderFailed
      default: return .unknown
      }
    }
    if error is VideoProcessorError { return .renderFailed }
    if error is MediaLibraryError { return .writeFailed }
    return .unknown
  }

}
