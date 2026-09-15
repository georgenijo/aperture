@preconcurrency import Foundation

actor MediaLibrary {
  static let manifestSchemaVersion = 1

  let rootURL: URL
  let legacyPhotosDirectory: URL?

  let fileSystem: MediaLibraryFileSystem
  var fileManager: FileManager { fileSystem.fileManager }
  var writeData: MediaLibraryFileSystem.DataWriter { fileSystem.writeData }
  var manifest = LibraryManifest(schemaVersion: MediaLibrary.manifestSchemaVersion, items: [])
  var legacyDeletionIdentifiers = Set<String>()
  var legacyDeletionLedgerAvailable = true
  var latestDiagnostics: [MediaLibraryDiagnostic] = []
  var isPrepared = false

  init(
    rootURL: URL,
    legacyPhotosDirectory: URL? = nil,
    fileSystem: MediaLibraryFileSystem = MediaLibraryFileSystem()
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.legacyPhotosDirectory = legacyPhotosDirectory?.standardizedFileURL
    self.fileSystem = fileSystem
  }

  static func makeDefault(fileManager: FileManager = .default) throws -> MediaLibrary {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw MediaLibraryError.fileOperation(
        operation: "locate",
        path: "Application Support",
        details: "No user Application Support directory is available."
      )
    }
    let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    return MediaLibrary(
      rootURL: applicationSupport.appendingPathComponent(
        "Aperture/MediaLibrary", isDirectory: true),
      legacyPhotosDirectory: documents?.appendingPathComponent("photos", isDirectory: true),
      fileSystem: MediaLibraryFileSystem(fileManager)
    )
  }

  @discardableResult
  func prepare() throws -> MediaLibrarySnapshot {
    if isPrepared {
      return snapshot()
    }

    try createLibraryDirectories()
    latestDiagnostics = []
    manifest = try loadManifestRecoveringIfNeeded()
    legacyDeletionIdentifiers = loadLegacyDeletionIdentifiersRecoveringIfNeeded()

    var changed = false
    changed = try recoverInterruptedDeletions() || changed
    changed = try reconcileCommittedItems() || changed
    changed = try recoverStagedCreations() || changed
    changed = try migrateLegacyPhotos() || changed

    if changed || !fileManager.fileExists(atPath: manifestURL.path) {
      try writeManifest(manifest)
    }

    appendValidationDiagnostics()
    isPrepared = true
    return snapshot()
  }

  func items() throws -> [MediaItem] {
    _ = try prepare()
    return sortedItems(manifest.items)
  }

  func diagnostics() throws -> [MediaLibraryDiagnostic] {
    _ = try prepare()
    return latestDiagnostics
  }

  func stage(
    _ request: MediaWriteRequest,
    processed: MediaAssetPayload,
    original: MediaAssetPayload? = nil,
    thumbnail: MediaAssetPayload? = nil
  ) throws -> StagedMediaItem {
    _ = try prepare()
    try validate(request: request, processed: processed, original: original, thumbnail: thumbnail)

    guard !manifest.items.contains(where: { $0.id == request.id }),
      !fileManager.fileExists(atPath: committedDirectory(for: request.id).path)
    else {
      throw MediaLibraryError.duplicateItem(request.id)
    }

    let stagingIdentifier = UUID()
    let stagingDirectory = creationStagingDirectory(for: stagingIdentifier)
    do {
      try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)

      let processedExtension = try validatedFileExtension(processed.fileExtension)
      let processedName = "processed.\(processedExtension)"
      let originalName = try original.map {
        "original.\(try validatedFileExtension($0.fileExtension))"
      }
      let thumbnailName = try thumbnail.map {
        "thumbnail.\(try validatedFileExtension($0.fileExtension))"
      }
      let relativeParent = "\(MediaLibraryPaths.media)/\(request.id.uuidString.lowercased())"

      let item = MediaItem(
        id: request.id,
        mediaType: request.mediaType,
        files: MediaFileSet(
          processed: "\(relativeParent)/\(processedName)",
          original: originalName.map { "\(relativeParent)/\($0)" },
          thumbnail: thumbnailName.map { "\(relativeParent)/\($0)" }
        ),
        dimensions: request.dimensions,
        durationSeconds: request.durationSeconds,
        capturedAt: request.capturedAt,
        recipe: request.recipe,
        camera: request.camera,
        isFavorite: request.isFavorite,
        processing: request.processing,
        provenance: request.provenance
      )

      try materialize(processed, at: stagingDirectory.appendingPathComponent(processedName))
      if let original, let originalName {
        try materialize(original, at: stagingDirectory.appendingPathComponent(originalName))
      }
      if let thumbnail, let thumbnailName {
        try materialize(thumbnail, at: stagingDirectory.appendingPathComponent(thumbnailName))
      }
      try writeItemMetadata(item, in: stagingDirectory)
      // The directory is intentionally retained only after all payloads
      // and metadata have been written. A crash can therefore be
      // recovered, while an ordinary failure does not strand a partial
      // transaction.
      return StagedMediaItem(stagingIdentifier: stagingIdentifier, item: item)
    } catch let error as MediaLibraryError {
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      throw fileError("stage", url: stagingDirectory, error: error)
    }
  }

  @discardableResult
  func commit(_ staged: StagedMediaItem) throws -> MediaItem {
    _ = try prepare()
    let stagingDirectory = creationStagingDirectory(for: staged.stagingIdentifier)
    guard fileManager.fileExists(atPath: stagingDirectory.path) else {
      throw MediaLibraryError.stagedItemNotFound(staged.stagingIdentifier)
    }
    guard try stagedDirectoryIsComplete(stagingDirectory, expectedItem: staged.item) else {
      throw MediaLibraryError.stagedItemIncomplete(staged.stagingIdentifier)
    }
    guard !manifest.items.contains(where: { $0.id == staged.item.id }) else {
      throw MediaLibraryError.duplicateItem(staged.item.id)
    }

    let destination = committedDirectory(for: staged.item.id)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw MediaLibraryError.duplicateItem(staged.item.id)
    }

    do {
      try fileManager.moveItem(at: stagingDirectory, to: destination)
      var updated = manifest
      updated.items.append(staged.item)
      do {
        try writeManifest(updated)
        manifest = updated
        return staged.item
      } catch {
        try? fileManager.moveItem(at: destination, to: stagingDirectory)
        // A synchronous commit failure is not an interrupted crash.
        // Roll back the moved directory and discard the transaction so
        // a later launch cannot unexpectedly publish a failed capture.
        try? fileManager.removeItem(at: stagingDirectory)
        throw error
      }
    } catch let error as MediaLibraryError {
      throw error
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      throw fileError("commit", url: destination, error: error)
    }
  }

  @discardableResult
  func createAndCommit(
    _ request: MediaWriteRequest,
    processed: MediaAssetPayload,
    original: MediaAssetPayload? = nil,
    thumbnail: MediaAssetPayload? = nil
  ) throws -> MediaItem {
    let staged = try stage(
      request,
      processed: processed,
      original: original,
      thumbnail: thumbnail
    )
    return try commit(staged)
  }

  @discardableResult
  func delete(id: UUID) throws -> MediaItem {
    _ = try prepare()
    guard let index = manifest.items.firstIndex(where: { $0.id == id }) else {
      throw MediaLibraryError.itemNotFound(id)
    }

    let item = manifest.items[index]
    let source = committedDirectory(for: id)
    guard fileManager.fileExists(atPath: source.path) else {
      throw MediaLibraryError.fileOperation(
        operation: "delete",
        path: source.lastPathComponent,
        details: "The item directory is missing."
      )
    }

    let deletionDirectory = deletionStagingDirectory(for: id)
    do {
      if fileManager.fileExists(atPath: deletionDirectory.path) {
        throw MediaLibraryError.fileOperation(
          operation: "stage deletion of",
          path: id.uuidString,
          details: "An earlier deletion transaction is still present."
        )
      }

      if case .legacyImport(let identifier) = item.provenance,
        !legacyDeletionIdentifiers.contains(identifier)
      {
        guard legacyDeletionLedgerAvailable else {
          throw MediaLibraryError.fileOperation(
            operation: "delete",
            path: id.uuidString,
            details:
              "The legacy deletion ledger is unavailable; repair it before deleting this imported item."
          )
        }
        var updatedIdentifiers = legacyDeletionIdentifiers
        updatedIdentifiers.insert(identifier)
        try writeLegacyDeletionIdentifiers(updatedIdentifiers)
        legacyDeletionIdentifiers = updatedIdentifiers
      }
      try fileManager.moveItem(at: source, to: deletionDirectory)

      var updated = manifest
      updated.items.remove(at: index)
      do {
        try writeManifest(updated)
        manifest = updated
      } catch {
        // A legacy tombstone is intentionally monotonic. If this transaction
        // rolls back, keeping it is harmless while the item remains indexed,
        // and it prevents the untouched legacy source from resurrecting if
        // the live item is removed successfully later.
        try? fileManager.moveItem(at: deletionDirectory, to: source)
        throw error
      }

      do {
        try fileManager.removeItem(at: deletionDirectory)
      } catch {
        throw fileError("finish deletion of", url: deletionDirectory, error: error)
      }
      return item
    } catch let error as MediaLibraryError {
      throw error
    } catch {
      throw fileError("delete", url: source, error: error)
    }
  }

  func setFavorite(_ isFavorite: Bool, for id: UUID) throws {
    _ = try prepare()
    guard let index = manifest.items.firstIndex(where: { $0.id == id }) else {
      throw MediaLibraryError.itemNotFound(id)
    }
    var item = manifest.items[index]
    item.isFavorite = isFavorite
    try update(item, at: index)
  }

  func updateProcessing(_ processing: MediaProcessingState, for id: UUID) throws {
    _ = try prepare()
    guard let index = manifest.items.firstIndex(where: { $0.id == id }) else {
      throw MediaLibraryError.itemNotFound(id)
    }
    var item = manifest.items[index]
    item.processing = processing
    try update(item, at: index)
  }

  func assetURL(for relativePath: String) throws -> URL {
    try validatedAssetURL(for: relativePath)
  }

  func assetURL(for item: MediaItem, kind: MediaAssetKind) throws -> URL? {
    let path: String?
    switch kind {
    case .processed: path = item.files.processed
    case .original: path = item.files.original
    case .thumbnail: path = item.files.thumbnail
    }
    return try path.map(validatedAssetURL(for:))
  }
}
