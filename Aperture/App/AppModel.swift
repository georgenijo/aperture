import AVFoundation
import Combine
import Foundation
import UIKit
import os

@MainActor
final class AppModel: ObservableObject {
  let cameraManager: CameraManager
  let mediaLibrary: MediaLibrary
  let thumbnailService: ThumbnailService
  let photosExporter: PhotosExporter
  private let settingsStore: SettingsStore

  @Published var settings: AppSettings
  @Published private(set) var items: [MediaItem] = []
  @Published private(set) var diagnostics: [MediaLibraryDiagnostic] = []
  @Published private(set) var isPrepared = false
  @Published var processingIDs: Set<UUID> = []
  @Published private(set) var captureMode: CameraCaptureMode = .photo
  @Published private(set) var isRecording = false
  @Published private(set) var recordingDuration: TimeInterval = 0
  @Published var notice: String?
  @Published var errorMessage: String?
  /// Camera failures are kept separate from storage/development errors so
  /// transient capture problems can be shown inline without alert spam.
  @Published var cameraIssue: CameraIssue?

  let uiTestCameraDenied: Bool
  let uiTestEmptyLibrary: Bool
  let uiTestSeededLibrary: Bool

  var recordingContext: RecordingContext?
  private var cancellables: Set<AnyCancellable> = []
  var dismissedCameraIssue: CameraIssue?

  init(
    cameraManager: CameraManager = CameraManager(),
    mediaLibrary: MediaLibrary? = nil,
    thumbnailService: ThumbnailService = ThumbnailService(),
    photosExporter: PhotosExporter = PhotosExporter(),
    settingsStore: SettingsStore = SettingsStore()
  ) {
    self.cameraManager = cameraManager
    let resolvedLibrary: MediaLibrary
    let libraryBootstrapError: String?
    if let mediaLibrary {
      resolvedLibrary = mediaLibrary
      libraryBootstrapError = nil
    } else if let defaultLibrary = try? MediaLibrary.makeDefault() {
      resolvedLibrary = defaultLibrary
      libraryBootstrapError = nil
    } else {
      resolvedLibrary = Self.makeFallbackLibrary()
      libraryBootstrapError =
        "Aperture couldn’t open its preferred media folder. It is using a fallback folder; check available storage and try again."
    }
    self.mediaLibrary = resolvedLibrary
    self.thumbnailService = thumbnailService
    self.photosExporter = photosExporter
    self.settingsStore = settingsStore
    let loadedSettings: AppSettings
    let settingsLoadError: String?
    do {
      loadedSettings = try settingsStore.load()
      settingsLoadError = nil
    } catch {
      // Keep the app usable, but surface a corrupt persisted value.
      loadedSettings = .defaults
      settingsLoadError = error.localizedDescription
    }
    self.settings = loadedSettings
    let arguments = ProcessInfo.processInfo.arguments
    self.uiTestCameraDenied = arguments.contains("-ui-test-camera-denied")
    self.uiTestEmptyLibrary = arguments.contains("-ui-test-empty-library")
    self.uiTestSeededLibrary = arguments.contains("-ui-test-seeded-library")
    self.errorMessage = [libraryBootstrapError, settingsLoadError]
      .compactMap { $0 }
      .joined(separator: "\n")
    if self.errorMessage?.isEmpty == true { self.errorMessage = nil }

    cameraManager.onPhotoCaptured = { [weak self] result in
      Task { @MainActor [weak self] in
        self?.handleCapture(result)
      }
    }
    cameraManager.onVideoCaptured = { [weak self] result in
      Task { @MainActor [weak self] in
        self?.handleVideoCapture(result)
      }
    }
    cameraManager.$captureMode
      .receive(on: DispatchQueue.main)
      .sink { [weak self] mode in self?.captureMode = mode }
      .store(in: &cancellables)
    cameraManager.$isRecording
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.isRecording = value }
      .store(in: &cancellables)
    cameraManager.$recordingDuration
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.recordingDuration = value }
      .store(in: &cancellables)
    cameraManager.$issue
      .receive(on: DispatchQueue.main)
      .sink { [weak self] issue in
        guard let self else { return }
        guard let issue else {
          self.dismissedCameraIssue = nil
          self.cameraIssue = nil
          return
        }
        guard issue != self.dismissedCameraIssue else { return }
        self.cameraIssue = issue
      }
      .store(in: &cancellables)
    // ContentView owns AppModel, not a second observed camera object. Forward
    // every capability/readiness/lifecycle change so the shutter, lens rail,
    // flash, and permission surfaces cannot remain stale between mirrored
    // state updates.
    cameraManager.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  var cameraAuthorizationStatus: AVAuthorizationStatus {
    uiTestCameraDenied ? .denied : cameraManager.authorizationStatus
  }

  var cameraIsAvailable: Bool {
    cameraAuthorizationStatus == .authorized
      && cameraManager.lifecycleState != .unavailable
      && cameraManager.lifecycleState != .failed
  }

  var latestItem: MediaItem? { items.first }

  func prepare() async {
    guard !isPrepared else { return }
    do {
      _ = try await mediaLibrary.prepare()
      #if DEBUG
        if uiTestSeededLibrary && !uiTestEmptyLibrary {
          try await seedUITestLibraryIfNeeded()
        }
      #endif
      let snapshot = try await mediaLibrary.prepare()
      diagnostics = snapshot.diagnostics
      items = uiTestEmptyLibrary ? [] : snapshot.items
      isPrepared = true
      let candidates = uiTestEmptyLibrary ? [] : snapshot.items
      // Recovery is intentionally detached from preparation. It handles
      // one item at a time and yields through async processing so the
      // camera/Lab can render immediately after the index is opened.
      Task { @MainActor [weak self] in
        guard let self else { return }
        await self.recoverInterruptedItems(candidates)
        await self.migrateLegacyPhotoTimestamps()
      }
    } catch {
      errorMessage = error.localizedDescription
      isPrepared = true
    }
  }

  func refresh() async {
    do {
      let snapshot = try await mediaLibrary.refreshSnapshot()
      diagnostics = snapshot.diagnostics
      items = uiTestEmptyLibrary ? [] : snapshot.items
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func updateSettings(_ value: AppSettings) {
    settings = value
    do {
      try settingsStore.save(value)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func activateCamera() {
    cameraManager.checkPermissions()
    guard !uiTestCameraDenied else { return }
    switch cameraManager.authorizationStatus {
    case .authorized:
      cameraManager.startSession()
    case .notDetermined:
      cameraManager.requestPermission()
    default:
      break
    }
  }

  func deactivateCamera() {
    cameraManager.stopSession()
  }

  func setCaptureMode(_ mode: CameraCaptureMode) {
    guard !isRecording else {
      notice = "Stop the recording before changing modes."
      return
    }
    cameraManager.setCaptureMode(mode)
  }

  func capture() {
    guard cameraAuthorizationStatus == .authorized else {
      notice = "Camera access is required to capture a photograph."
      return
    }
    cameraManager.capturePhoto()
  }

  func startRecording() {
    guard cameraAuthorizationStatus == .authorized else {
      notice = "Camera access is required to record a video."
      return
    }
    guard captureMode == .video else {
      notice = "Choose Video beside the shutter first."
      return
    }
    guard let baseRecipe = FilmRecipeCatalog.recipe(for: settings.selectedFilm) else {
      errorMessage = "The selected film recipe is unavailable."
      return
    }
    let capturedAt = Date()
    let recipe = baseRecipe.resolve(
      seed: UInt64.random(in: UInt64.min...UInt64.max),
      capturedAt: capturedAt,
      options: processingOptions,
      timeZone: .autoupdatingCurrent
    )
    recordingContext = RecordingContext(
      recipe: recipe, preserveOriginal: settings.preserveOriginal,
      autoSaveToPhotos: settings.autoSaveToPhotos)
    cameraManager.startRecording()
  }

  func stopRecording() {
    cameraManager.stopRecording()
  }

  @discardableResult
  func focus(at point: CGPoint) -> Bool {
    guard
      cameraManager.capabilities.supportsFocusPoint
        || cameraManager.capabilities.supportsExposurePoint
    else {
      presentCameraIssue(
        CameraIssue(
          kind: .focus,
          title: "Focus unavailable",
          message: "This camera does not support tap to focus.",
          recoverySuggestion: "Try the other camera or continue shooting with automatic focus."
        ))
      return false
    }
    cameraManager.focusAndExpose(at: point)
    return true
  }

  func zoom(to rawZoomFactor: CGFloat) {
    cameraManager.rampZoom(to: rawZoomFactor)
  }

  func setFlash(_ mode: CameraFlashMode) {
    cameraManager.setFlashMode(mode)
  }

  func switchCamera() {
    let next: CameraPosition = cameraManager.currentPosition == .back ? .front : .back
    cameraManager.switchCamera(to: next)
  }

  func dismissCameraIssue() {
    dismissedCameraIssue = cameraIssue
    cameraIssue = nil
  }

  func retryCameraIssue() {
    dismissedCameraIssue = nil
    cameraIssue = nil
    activateCamera()
  }

  var processingOptions: FilmProcessingOptions {
    FilmProcessingOptions(
      lightLeaksEnabled: settings.lightLeaksEnabled,
      dateStamp: settings.dateStamp,
      photoQuality: settings.photoQuality
    )
  }

  /// Launch recovery re-develops an item at most this many times. Beyond it
  /// the item stays failed-but-recoverable for a manual retry, so a
  /// development that crashes deterministically cannot become a launch loop.
  static let maximumAutomaticRecoveryAttempts = 3

  func recoverInterruptedItems(_ candidates: [MediaItem]) async {
    // Sequential recovery bounds CPU, memory, and disk pressure while
    // allowing the main actor to service UI between each await.
    for item in candidates
    where item.processing.phase == .pending || item.processing.phase == .processing {
      guard !Task.isCancelled else { return }
      do {
        // A pending item never started; an interrupted one already counted
        // the attempt it was in when the app died.
        let attemptCount = item.processing.attemptCount
        let exhausted = attemptCount >= Self.maximumAutomaticRecoveryAttempts
        let interrupted = MediaProcessingFailure(
          code: .interrupted,
          message: exhausted
            ? "Development was interrupted \(attemptCount) times. Tap Retry to try again."
            : "Development was interrupted. Aperture will resume it from the saved source.",
          isRecoverable: true,
          attemptCount: attemptCount
        )
        try await mediaLibrary.updateProcessing(.failed(interrupted), for: item.id)
        await refresh()

        guard !exhausted, try await existingOriginalOrProcessedURL(for: item) != nil else {
          continue
        }
        let current = (try? await mediaLibrary.items())?.first(where: { $0.id == item.id }) ?? item
        processingIDs.insert(item.id)
        await developExisting(current)
      } catch {
        processingIDs.remove(item.id)
        errorMessage = error.localizedDescription
        await refresh()
      }
    }
  }

  func existingOriginalOrProcessedURL(for item: MediaItem) async throws -> URL? {
    for kind in [MediaAssetKind.original, .processed] {
      guard let url = try await mediaLibrary.assetURL(for: item, kind: kind) else { continue }
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  #if DEBUG
    private static let uiTestSeedID = UUID(uuidString: "A7B4A9E8-3F04-4B3A-9DD4-6EAFB4F4A198")!
    private static let uiTestSecondSeedID = UUID(
      uuidString: "B8C5BAF9-4015-4C4B-AEE5-7FBC5C05B209")!

    private func seedUITestLibraryIfNeeded() async throws {
      let existingIDs = Set(try await mediaLibrary.items().map(\.id))
      let size = CGSize(width: 320, height: 240)
      let seeds: [(id: UUID, capturedAt: Date, color: UIColor, seed: UInt64)] = [
        (
          Self.uiTestSeedID, Date(timeIntervalSince1970: 1_700_000_000),
          UIColor(red: 0.82, green: 0.29, blue: 0.16, alpha: 1), 0xA9E2_7E12
        ),
        (
          Self.uiTestSecondSeedID, Date(timeIntervalSince1970: 1_699_999_000),
          UIColor(red: 0.18, green: 0.42, blue: 0.72, alpha: 1), 0xB8F3_9D21
        ),
      ]

      for seedItem in seeds where !existingIDs.contains(seedItem.id) {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
          seedItem.color.setFill()
          context.fill(CGRect(origin: .zero, size: size))
          UIColor(red: 0.98, green: 0.74, blue: 0.28, alpha: 1).setFill()
          context.fill(CGRect(x: 48, y: 38, width: 224, height: 164))
        }
        guard
          let data = image.jpegData(
            compressionQuality: CGFloat(PhotoQualityPreference.maximum.compressionQuality))
        else {
          throw MediaLibraryError.invalidMedia("The UI-test seed image could not be encoded.")
        }
        let recipe = FilmRecipeCatalog.nineteenNinetyEight.resolve(
          seed: seedItem.seed,
          capturedAt: seedItem.capturedAt,
          options: FilmProcessingOptions(
            lightLeaksEnabled: false,
            dateStamp: .off,
            photoQuality: .maximum
          ),
          timeZone: .gmt
        )
        let request = MediaWriteRequest(
          id: seedItem.id,
          mediaType: .photo,
          dimensions: PixelDimensions(width: Int(size.width), height: Int(size.height)),
          capturedAt: seedItem.capturedAt,
          recipe: recipe,
          processing: .ready,
          provenance: .captured
        )
        _ = try await mediaLibrary.createAndCommit(
          request,
          processed: MediaAssetPayload(data: data, fileExtension: "jpg")
        )
      }
    }
  #endif
}

struct RecordingContext: Sendable {
  let recipe: AppliedFilmRecipe
  let preserveOriginal: Bool
  let autoSaveToPhotos: Bool
}

extension CapturedFlashMode {
  init(_ mode: CameraFlashMode) {
    switch mode {
    case .auto: self = .auto
    case .on: self = .on
    case .off: self = .off
    }
  }
}

/// Wall-clock timings for the interactions that are supposed to feel
/// instant: switching capture mode, opening the Lab or Settings, changing
/// flash, flipping the camera, and the shutter itself.
///
/// Each measurement runs from the tap to the moment the app state the tap
/// asked for actually arrives, which for camera work is a round trip through
/// the session queue. Samples live in memory only and are shown in Settings,
/// so the numbers can be read on the device instead of only in Instruments.
/// This lives here rather than in its own file because the project has no
/// synchronized groups, and a new file would mean editing the Xcode project.
@MainActor
final class PerformanceLog: ObservableObject {
  static let shared = PerformanceLog()

  struct Sample: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let milliseconds: Double
    let recordedAt: Date
  }

  struct Summary: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
    let median: Double
    let worst: Double
  }

  /// Enough history to see a pattern, small enough to stay free.
  private static let capacity = 60

  @Published private(set) var samples: [Sample] = []

  /// A monotonic clock: durations must not move when the wall clock does.
  private var pending: [String: DispatchTime] = [:]
  private let logger = Logger(subsystem: "com.georgenijo.Aperture", category: "interaction")

  /// Nothing the app measures should take this long. A measurement still
  /// outstanding past it belongs to an interaction that quietly failed or
  /// was a no-op, and letting it complete later would bill the next attempt
  /// for all the idle time in between.
  private static let staleAfter: TimeInterval = 10

  private init() {}

  /// Starting the same measurement twice keeps the earlier start, so a tap
  /// that lands while the previous one is still settling reports the whole
  /// wait rather than a flattering fraction of it.
  func begin(_ name: String) {
    guard pending[name] == nil else { return }
    pending[name] = DispatchTime.now()
  }

  func end(_ name: String) {
    guard let start = pending.removeValue(forKey: name) else { return }
    let elapsed =
      Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    guard elapsed < Self.staleAfter * 1000 else { return }
    logger.debug("\(name, privacy: .public) \(elapsed, privacy: .public) ms")
    samples.insert(Sample(name: name, milliseconds: elapsed, recordedAt: Date()), at: 0)
    if samples.count > Self.capacity {
      samples.removeLast(samples.count - Self.capacity)
    }
  }

  /// A measurement whose completion can no longer arrive, such as a sheet
  /// the user dismissed before it finished opening.
  func cancel(_ name: String) {
    pending.removeValue(forKey: name)
  }

  func clear() {
    pending.removeAll()
    samples.removeAll()
  }

  /// Median rather than mean: one thermal outlier should not hide the
  /// latency the interaction usually has.
  var summaries: [Summary] {
    Dictionary(grouping: samples, by: \.name)
      .map { name, group in
        let sorted = group.map(\.milliseconds).sorted()
        let median =
          sorted.count.isMultiple(of: 2)
          ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
          : sorted[sorted.count / 2]
        return Summary(
          name: name, count: sorted.count, median: median, worst: sorted.last ?? 0)
      }
      .sorted { $0.name < $1.name }
  }
}
