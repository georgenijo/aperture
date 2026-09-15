@preconcurrency import Foundation

struct MediaAssetPayload: Sendable {
  enum Source: Sendable {
    case data(Data)
    case file(URL)
  }

  let source: Source
  let fileExtension: String

  init(data: Data, fileExtension: String) {
    source = .data(data)
    self.fileExtension = fileExtension
  }

  /// File-backed payloads are copied in bounded memory, which is required for video.
  init(fileURL: URL, fileExtension: String? = nil) {
    source = .file(fileURL)
    self.fileExtension = fileExtension ?? fileURL.pathExtension
  }

  var fileURL: URL? {
    guard case .file(let url) = source else { return nil }
    return url
  }

  var data: Data? {
    guard case .data(let data) = source else { return nil }
    return data
  }

  var isFileBacked: Bool {
    if case .file = source { return true }
    return false
  }

  init(source: Source, fileExtension: String) {
    self.source = source
    self.fileExtension = fileExtension
  }
}

struct MediaWriteRequest: Sendable {
  let id: UUID
  let mediaType: MediaType
  let dimensions: PixelDimensions?
  let durationSeconds: Double?
  let capturedAt: Date
  let recipe: AppliedFilmRecipe
  let camera: CameraCaptureMetadata?
  let isFavorite: Bool
  let processing: MediaProcessingState
  let provenance: MediaProvenance

  init(
    id: UUID = UUID(),
    mediaType: MediaType,
    dimensions: PixelDimensions?,
    durationSeconds: Double? = nil,
    capturedAt: Date = Date(),
    recipe: AppliedFilmRecipe,
    camera: CameraCaptureMetadata? = nil,
    isFavorite: Bool = false,
    processing: MediaProcessingState = .ready,
    provenance: MediaProvenance = .captured
  ) {
    self.id = id
    self.mediaType = mediaType
    self.dimensions = dimensions
    self.durationSeconds = durationSeconds
    self.capturedAt = capturedAt
    self.recipe = recipe
    self.camera = camera
    self.isFavorite = isFavorite
    self.processing = processing
    self.provenance = provenance
  }
}

struct StagedMediaItem: Codable, Hashable, Sendable {
  let stagingIdentifier: UUID
  let item: MediaItem
}

struct MediaLibrarySnapshot: Sendable {
  let items: [MediaItem]
  let diagnostics: [MediaLibraryDiagnostic]
}

struct MediaLibraryDiagnostic: Codable, Equatable, Sendable {
  enum Severity: String, Codable, Sendable {
    case information
    case warning
    case error
  }

  enum Code: String, Codable, Sendable {
    case corruptManifest
    case corruptItemMetadata
    case invalidPath
    case missingFile
    case invalidMetadata
    case recoveredCommittedItem
    case recoveredStagedItem
    case quarantinedIncompleteStaging
    case completedInterruptedDeletion
    case rolledBackInterruptedDeletion
    case legacyMetadataCorrupt
    case legacyFileMissing
    case legacyItemMigrated
    case legacyMigrationFailed
    case corruptLegacyDeletionLedger
    case transactionRollbackFailed
    case orphanCleanupSkipped
  }

  let severity: Severity
  let code: Code
  let message: String
  let relativePath: String?
  let itemID: UUID?
}

enum MediaLibraryError: Error, Equatable, LocalizedError, Sendable {
  case notPrepared
  case itemNotFound(UUID)
  case duplicateItem(UUID)
  case invalidRelativePath(String)
  case invalidFileExtension(String)
  case invalidMedia(String)
  case stagedItemNotFound(UUID)
  case stagedItemIncomplete(UUID)
  case corruptMetadata(String)
  case fileOperation(operation: String, path: String, details: String)
  case insufficientStorage(operation: String, path: String, details: String)
  case transactionRollbackFailed(operation: String, path: String, details: String)

  var errorDescription: String? {
    switch self {
    case .notPrepared:
      return "The media library has not finished preparing."
    case .itemNotFound(let id):
      return "The requested media item \(id.uuidString) no longer exists."
    case .duplicateItem(let id):
      return "A media item with identifier \(id.uuidString) already exists."
    case .invalidRelativePath(let path):
      return "The media path is unsafe: \(path)"
    case .invalidFileExtension(let value):
      return "The media file extension is invalid: \(value)"
    case .invalidMedia(let reason):
      return "The media item is invalid: \(reason)"
    case .stagedItemNotFound(let id):
      return "The staged media item \(id.uuidString) could not be found."
    case .stagedItemIncomplete(let id):
      return "The staged media item \(id.uuidString) is incomplete."
    case .corruptMetadata(let details):
      return "Media metadata could not be read: \(details)"
    case .fileOperation(let operation, let path, let details):
      return "Could not \(operation) \(path): \(details)"
    case .insufficientStorage(let operation, let path, _):
      return "There is not enough storage to \(operation) \(path). Free some space and try again."
    case .transactionRollbackFailed(let operation, let path, let details):
      return "Could not safely roll back \(operation) \(path): \(details)"
    }
  }
}

enum MediaLibraryPaths {
  static let manifest = "library.json"
  static let media = "media"
  static let staging = "staging"
  static let recovery = "recovery"
  static let itemMetadata = "item.json"
  static let legacyDeletionLedger = "legacy-deletions.json"
}

struct LegacyDeletionLedger: Codable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let identifiers: [String]
}

/// Foundation's FileManager operations are internally thread-safe, but older
/// SDK overlays do not declare the reference type Sendable. Actor isolation
/// ensures this injected instance is only used by one executor at a time.
struct MediaLibraryFileSystem: @unchecked Sendable {
  typealias DataWriter = @Sendable (Data, URL, Data.WritingOptions) throws -> Void

  let fileManager: FileManager
  let writeData: DataWriter

  init(
    _ fileManager: FileManager = .default,
    writeData: @escaping DataWriter = { data, url, options in
      try data.write(to: url, options: options)
    }
  ) {
    self.fileManager = fileManager
    self.writeData = writeData
  }
}

enum MediaAssetKind: String, Codable, CaseIterable, Sendable {
  case processed
  case original
  case thumbnail
}
