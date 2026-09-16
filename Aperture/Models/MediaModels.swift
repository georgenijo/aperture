import Foundation

/// Authoritative metadata for one locally managed capture. Paths are always
/// relative to the media-library root so a library can be relocated safely.
struct MediaItem: Codable, Hashable, Identifiable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let id: UUID
  let mediaType: MediaType
  var files: MediaFileSet
  var dimensions: PixelDimensions?
  var durationSeconds: Double?
  let capturedAt: Date
  var recipe: AppliedFilmRecipe
  let camera: CameraCaptureMetadata?
  var isFavorite: Bool
  var processing: MediaProcessingState
  let provenance: MediaProvenance

  init(
    schemaVersion: Int = MediaItem.currentSchemaVersion,
    id: UUID = UUID(),
    mediaType: MediaType,
    files: MediaFileSet,
    dimensions: PixelDimensions?,
    durationSeconds: Double?,
    capturedAt: Date,
    recipe: AppliedFilmRecipe,
    camera: CameraCaptureMetadata?,
    isFavorite: Bool = false,
    processing: MediaProcessingState,
    provenance: MediaProvenance = .captured
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.mediaType = mediaType
    self.files = files
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

enum MediaType: String, Codable, CaseIterable, Hashable, Sendable {
  case photo
  case video
}

struct PixelDimensions: Codable, Hashable, Sendable {
  let width: Int
  let height: Int

  init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  var isValid: Bool { width > 0 && height > 0 }
}

struct MediaFileSet: Codable, Hashable, Sendable {
  /// The developed photo or film-treated video used for viewing and export.
  let processed: String
  /// The untouched camera capture, when preservation was enabled.
  let original: String?
  /// An optional persisted thumbnail. Rebuildable cache thumbnails are not listed here.
  let thumbnail: String?
}

struct CameraCaptureMetadata: Codable, Hashable, Sendable {
  let position: CameraPosition
  let deviceType: String
  let deviceUniqueID: String?
  let lensDisplayName: String?
  let zoomFactor: Double
  let nominalFocalLengthIn35mm: Double?
  let virtualDeviceSwitchOverZoomFactors: [Double]
  let flashMode: CapturedFlashMode
  let isMacroEnabled: Bool

  init(
    position: CameraPosition,
    deviceType: String,
    deviceUniqueID: String? = nil,
    lensDisplayName: String? = nil,
    zoomFactor: Double,
    nominalFocalLengthIn35mm: Double? = nil,
    virtualDeviceSwitchOverZoomFactors: [Double] = [],
    flashMode: CapturedFlashMode = .off,
    isMacroEnabled: Bool = false
  ) {
    self.position = position
    self.deviceType = deviceType
    self.deviceUniqueID = deviceUniqueID
    self.lensDisplayName = lensDisplayName
    self.zoomFactor = zoomFactor
    self.nominalFocalLengthIn35mm = nominalFocalLengthIn35mm
    self.virtualDeviceSwitchOverZoomFactors = virtualDeviceSwitchOverZoomFactors
    self.flashMode = flashMode
    self.isMacroEnabled = isMacroEnabled
  }
}

enum CameraPosition: String, Codable, Hashable, Sendable {
  case back
  case front
  case unspecified
}

enum CapturedFlashMode: String, Codable, Hashable, Sendable {
  case auto
  case on
  case off
  case screen
}

enum MediaProvenance: Codable, Hashable, Sendable {
  case captured
  case legacyImport(identifier: String)
}

struct MediaProcessingState: Codable, Hashable, Sendable {
  enum Phase: String, Codable, Hashable, Sendable {
    case pending
    case processing
    case ready
    case failed
  }

  let phase: Phase
  let failure: MediaProcessingFailure?
  /// Development attempts started so far. Persisted across every phase so a
  /// crash mid-development does not reset the count and launch recovery can
  /// stop retrying an item that keeps dying.
  let attemptCount: Int

  private init(phase: Phase, failure: MediaProcessingFailure?, attemptCount: Int) {
    self.phase = phase
    self.failure = failure
    self.attemptCount = attemptCount
  }

  static let pending = MediaProcessingState(phase: .pending, failure: nil, attemptCount: 0)
  static let ready = MediaProcessingState(phase: .ready, failure: nil, attemptCount: 0)

  static func processing(attemptCount: Int) -> MediaProcessingState {
    MediaProcessingState(phase: .processing, failure: nil, attemptCount: attemptCount)
  }

  static func failed(_ failure: MediaProcessingFailure) -> MediaProcessingState {
    MediaProcessingState(phase: .failed, failure: failure, attemptCount: failure.attemptCount)
  }

  /// The state to persist when starting one more development attempt.
  var nextAttempt: MediaProcessingState {
    .processing(attemptCount: attemptCount + 1)
  }

  private enum CodingKeys: String, CodingKey {
    case phase
    case failure
    case attemptCount
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let phase = try values.decode(Phase.self, forKey: .phase)
    let failure = try values.decodeIfPresent(MediaProcessingFailure.self, forKey: .failure)
    guard (phase == .failed) == (failure != nil) else {
      throw DecodingError.dataCorruptedError(
        forKey: .failure,
        in: values,
        debugDescription: "Only a failed processing state may carry failure details."
      )
    }
    // Manifests written before the count was persisted only knew it while failed.
    let attemptCount =
      try values.decodeIfPresent(Int.self, forKey: .attemptCount) ?? failure?.attemptCount ?? 0
    self.init(phase: phase, failure: failure, attemptCount: max(0, attemptCount))
  }
}

struct MediaProcessingFailure: Codable, Hashable, Sendable {
  enum Code: String, Codable, Hashable, Sendable {
    case decodeFailed
    case renderFailed
    case writeFailed
    case interrupted
    case insufficientStorage
    case sourceMissing
    case unknown
  }

  let code: Code
  let message: String
  let isRecoverable: Bool
  let attemptCount: Int
}
