@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Mutable capture state is confined to `sessionQueue`; UI state is published
/// on main. The unchecked conformance documents that explicit ownership for
/// Dispatch's Swift 6 sendability checks.
final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {
  let session = AVCaptureSession()

  // Internal setters are required because queue-owned implementation is
  // split across same-module extensions; all writes still pass through
  // `publish` and therefore land on the main thread.
  @Published var authorizationStatus: AVAuthorizationStatus
  @Published var isCapturing = false
  @Published var lifecycleState: CameraLifecycleState = .idle
  @Published var capabilities = CameraCapabilities.unavailable
  @Published var currentPosition: CameraPosition = .back
  @Published var activeDevice: AVCaptureDevice?
  @Published var currentRawZoom: CGFloat = 1
  @Published var currentDisplayZoom: CGFloat = 1
  @Published var isCaptureReady = false
  @Published var issue: CameraIssue?
  @Published var flashMode: CameraFlashMode = .auto
  @Published var captureMode: CameraCaptureMode = .photo
  @Published var microphoneAuthorizationStatus: AVAuthorizationStatus
  @Published var isRecording = false
  @Published var recordingDuration: TimeInterval = 0

  /// Complete source photo or a user-facing error. Processing and storage remain app-owned.
  var onPhotoCaptured: (@Sendable (Result<CapturedPhoto, CameraIssue>) -> Void)?
  /// A completed movie is delivered only after AVFoundation has finished
  /// writing and closed the file.
  var onVideoCaptured: (@Sendable (Result<CapturedVideo, CameraIssue>) -> Void)?

  let sessionQueue = CameraSessionQueue.shared
  let logger = Logger(subsystem: "com.georgenijo.Aperture", category: "camera")
  let photoOutput = AVCapturePhotoOutput()
  let movieOutput = AVCaptureMovieFileOutput()
  var currentInput: AVCaptureDeviceInput?
  var microphoneInput: AVCaptureDeviceInput?
  var readinessCoordinator: AVCapturePhotoOutputReadinessCoordinator?
  var readinessDelegate: ReadinessDelegate?
  var captureRequests: [Int64: CaptureRequest] = [:]
  var requestedFlashMode: CameraFlashMode = .auto
  var sessionStartRequested = false
  var notificationTokens: [NSObjectProtocol] = []
  var pressureObservation: NSKeyValueObservation?
  var focusResetWorkItem: DispatchWorkItem?
  var captureRotationAngle: CGFloat = 0
  var recordingDelegate: MovieRecordingDelegate?
  var recordingCompletion: (@Sendable (Result<CapturedVideo, CameraIssue>) -> Void)?
  var recordingSnapshot: CaptureSnapshot?
  var recordingStartedAt: Date?
  var recordingTimer: DispatchSourceTimer?
  var stopSessionWhenRecordingFinishes = false
  var rebuildAfterRecordingFinishes = false
  /// Whether the UI currently wants the session running. System-initiated
  /// stops (interruptions, pressure shutdown) consult this to resume.
  var sessionWanted = false
  var pressureShutdownActive = false
  /// Session-queue-owned mirrors. Observable properties are published on
  /// main and must never be used to coordinate graph mutations.
  var sessionPosition: CameraPosition = .back
  var sessionCaptureMode: CameraCaptureMode = .photo
  let maximumOverlappingCaptures = 3

  override init() {
    authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    super.init()
    installNotifications()
  }

  deinit {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    focusResetWorkItem?.cancel()
    recordingTimer?.cancel()
  }

  func checkPermissions() {
    publish {
      $0.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
      $0.microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
  }

  func requestPermission() {
    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      self?.publish {
        $0.authorizationStatus = granted ? .authorized : .denied
        if !granted { $0.lifecycleState = .unavailable }
      }
    }
  }

  func startSession() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      publish { $0.lifecycleState = .unavailable }
      return
    }
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.sessionWanted = true
      self.startSessionOnQueue()
    }
  }

  /// Restart a session the system stopped, once the UI still wants it and
  /// nothing (interruption, pressure, an open movie file) blocks it.
  func resumeSessionIfWantedOnQueue() {
    let isBlocked = session.isInterrupted || pressureShutdownActive
    // A disconnect during recording keeps the stale input until the movie
    // closes; restarting on it would overwrite the "disconnected" state.
    let isDeviceConnected = currentInput?.device.isConnected ?? true
    guard
      CameraLifecycleLogic.shouldResumeSession(
        isWanted: sessionWanted, isRunning: session.isRunning, isInterrupted: isBlocked,
        isRecording: recordingStartedAt != nil || movieOutput.isRecording,
        isDeviceConnected: isDeviceConnected)
    else { return }
    startSessionOnQueue()
  }

  func startSessionOnQueue() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
      !sessionStartRequested,
      !session.isRunning
    else { return }
    sessionStartRequested = true
    publish { $0.lifecycleState = .configuring }
    guard configureGraphIfNeeded() else {
      sessionStartRequested = false
      return
    }
    session.startRunning()
    sessionStartRequested = false
    let isRunning = session.isRunning
    let isReady = captureReadinessIsReady
    publish {
      $0.lifecycleState = isRunning ? .ready : .failed
      $0.isCaptureReady = isReady
      if isRunning { $0.issue = nil }
    }
    logger.debug("camera session started")
  }

  func stopSession() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.sessionWanted = false
      self.sessionStartRequested = false
      if self.recordingStartedAt != nil || self.movieOutput.isRecording {
        self.stopSessionWhenRecordingFinishes = true
        self.stopRecordingOnQueue(
          reason: CameraIssue(
            kind: .recording, title: "Recording stopped",
            message: "The camera left the foreground, so the clip was closed safely.",
            recoverySuggestion: nil))
        return
      }
      guard self.session.isRunning else { return }
      self.session.stopRunning()
      self.publish {
        $0.lifecycleState = .idle
        $0.isCaptureReady = false
      }
      self.logger.debug("camera session stopped")
    }
  }

  func switchCamera(to position: CameraPosition) {
    guard position == .back || position == .front else { return }
    sessionQueue.async { [weak self] in self?.switchCameraOnQueue(to: position) }
  }

  func setFlashMode(_ mode: CameraFlashMode) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.requestedFlashMode = mode
      self.publish {
        $0.flashMode = mode
        $0.issue = nil
      }
    }
  }

  func setCaptureMode(_ mode: CameraCaptureMode) {
    sessionQueue.async { [weak self] in self?.setCaptureModeOnQueue(mode) }
  }

  func requestMicrophonePermission() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    guard status == .notDetermined else {
      publish { $0.microphoneAuthorizationStatus = status }
      return
    }
    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
      guard let manager = self else { return }
      manager.publish { $0.microphoneAuthorizationStatus = granted ? .authorized : .denied }
      guard granted else { return }
      manager.sessionQueue.async { manager.configureVideoGraphOnQueue() }
    }
  }

  func startRecording(completion: (@Sendable (Result<CapturedVideo, CameraIssue>) -> Void)? = nil) {
    sessionQueue.async { [weak self] in self?.startRecordingOnQueue(completion: completion) }
  }

  func stopRecording() {
    sessionQueue.async { [weak self] in self?.stopRecordingOnQueue(reason: nil) }
  }

  func setZoomFactor(_ rawZoomFactor: CGFloat) {
    sessionQueue.async { [weak self] in self?.setZoomOnQueue(rawZoomFactor, ramp: false) }
  }

  func rampZoom(to rawZoomFactor: CGFloat, rate: CGFloat = 4) {
    sessionQueue.async { [weak self] in self?.setZoomOnQueue(rawZoomFactor, ramp: true, rate: rate)
    }
  }

  func setDisplayZoom(_ displayZoomFactor: CGFloat) {
    sessionQueue.async { [weak self] in
      guard let self, let device = self.currentInput?.device else { return }
      self.setZoomOnQueue(displayZoomFactor / self.displayMultiplier(for: device), ramp: false)
    }
  }

  /// Point is in AVCapture's normalized device coordinate space.
  func focusAndExpose(at point: CGPoint) {
    sessionQueue.async { [weak self] in self?.focusAndExposeOnQueue(at: point) }
  }

  func focusAndExpose(at event: CameraFocusEvent) {
    focusAndExpose(at: event.devicePoint)
  }

  func resetFocusAndExposure() { focusAndExpose(at: CGPoint(x: 0.5, y: 0.5)) }

  /// Called by the preview's RotationCoordinator with the capture angle. The
  /// preview angle is applied to its own layer; this one belongs to the photo connection.
  func setCaptureRotationAngle(_ angle: CGFloat) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.captureRotationAngle = angle
      if let connection = self.photoOutput.connection(with: .video),
        connection.isVideoRotationAngleSupported(angle)
      {
        connection.videoRotationAngle = angle
      }
      if let connection = self.movieOutput.connection(with: .video),
        connection.isVideoRotationAngleSupported(angle)
      {
        connection.videoRotationAngle = angle
      }
    }
  }

  /// Fire-and-forget remains source compatible; callers may provide a per-request callback.
  func capturePhoto(completion: (@Sendable (Result<CapturedPhoto, CameraIssue>) -> Void)? = nil) {
    sessionQueue.async { [weak self] in self?.capturePhotoOnQueue(completion: completion) }
  }

  func publishIssue(_ kind: CameraIssue.Kind, title: String, message: String, recovery: String?) {
    let issue = CameraIssue(
      kind: kind, title: title, message: message, recoverySuggestion: recovery)
    publish { $0.issue = issue }
    logger.error("\(title, privacy: .public): \(message, privacy: .public)")
  }

  func publish(_ update: @escaping @Sendable (CameraManager) -> Void) {
    if Thread.isMainThread {
      update(self)
    } else {
      DispatchQueue.main.async { [weak self] in if let self { update(self) } }
    }
  }

  // Video capture lives in a focused extension. These small state writers
  // keep @Published setters encapsulated in the owning declaration.
  func publishVideoMode(_ mode: CameraCaptureMode) {
    captureMode = mode
    issue = nil
  }
  func publishVideoReadiness(_ ready: Bool) { isCaptureReady = ready }
  func publishVideoStopped() {
    lifecycleState = .idle
    isCaptureReady = false
  }
  func publishRecordingStarted() {
    isRecording = true
    recordingDuration = 0
    issue = nil
  }
  func publishRecordingDuration(_ duration: TimeInterval) { recordingDuration = duration }
  func publishRecordingIssue(_ issue: CameraIssue) { self.issue = issue }
  func publishRecordingFinished(duration: TimeInterval) {
    isRecording = false
    recordingDuration = duration
  }
}
