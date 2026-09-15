import Foundation

extension MediaLibrary {
  /// Atomically publishes a developed asset while retaining the durable
  /// camera payload until both item metadata and the library index commit.
  @discardableResult
  func replaceProcessedAsset(
    for id: UUID,
    with processed: MediaAssetPayload,
    dimensions: PixelDimensions?,
    durationSeconds: Double? = nil,
    processing: MediaProcessingState = .ready
  ) throws -> MediaItem {
    _ = try prepare()
    guard let index = manifest.items.firstIndex(where: { $0.id == id }) else {
      throw MediaLibraryError.itemNotFound(id)
    }

    var item = manifest.items[index]
    let validationRequest = MediaWriteRequest(
      id: item.id,
      mediaType: item.mediaType,
      dimensions: dimensions,
      durationSeconds: durationSeconds,
      capturedAt: item.capturedAt,
      recipe: item.recipe,
      camera: item.camera,
      isFavorite: item.isFavorite,
      processing: processing,
      provenance: item.provenance
    )
    try validate(request: validationRequest, processed: processed, original: nil, thumbnail: nil)

    let fileExtension = try validatedFileExtension(processed.fileExtension)
    let fileName = "processed-\(UUID().uuidString.lowercased()).\(fileExtension)"
    let itemDirectory = committedDirectory(for: id)
    let newURL = itemDirectory.appendingPathComponent(fileName)
    let relativeParent = "\(MediaLibraryPaths.media)/\(id.uuidString.lowercased())"
    let oldProcessedPath = item.files.processed
    let oldThumbnailPath = item.files.thumbnail

    try materialize(processed, at: newURL)
    item.files = MediaFileSet(
      processed: "\(relativeParent)/\(fileName)",
      original: item.files.original,
      thumbnail: nil
    )
    item.dimensions = dimensions
    item.durationSeconds = durationSeconds
    item.processing = processing

    do {
      try update(item, at: index)
    } catch {
      if let libraryError = error as? MediaLibraryError,
        case .transactionRollbackFailed = libraryError
      {
        // The metadata rollback is uncertain. Keep the new asset so the
        // next launch can reconcile metadata and retain at least one valid
        // media payload instead of deleting the only referenced file.
        throw error
      }
      do {
        try fileManager.removeItem(at: newURL)
      } catch {
        let cleanupError = fileError("remove replacement asset", url: newURL, error: error)
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .error,
            code: .transactionRollbackFailed,
            message:
              "The replacement failed and its uncommitted asset could not be removed. It was retained for reconciliation: \(cleanupError.localizedDescription)",
            relativePath: item.files.processed,
            itemID: item.id
          )
        )
        throw MediaLibraryError.transactionRollbackFailed(
          operation: "remove replacement asset",
          path: newURL.lastPathComponent,
          details: cleanupError.localizedDescription
        )
      }
      throw error
    }

    // Cleanup is deliberately after the index commit. If the process exits
    // before this point, the result is an orphaned old file, never lost media.
    let retainedPaths = Set(item.files.allPaths)
    for oldPath in [oldProcessedPath, oldThumbnailPath].compactMap({ $0 })
    where !retainedPaths.contains(oldPath) {
      let oldURL = try validatedAssetURL(for: oldPath)
      guard fileManager.fileExists(atPath: oldURL.path) else { continue }
      do {
        try fileManager.removeItem(at: oldURL)
      } catch {
        throw fileError("remove superseded asset", url: oldURL, error: error)
      }
    }
    return item
  }
}
