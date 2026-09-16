@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension CameraManager {
  func configureOutputForDeviceOnQueue(_ device: AVCaptureDevice) {
    if #available(iOS 17.0, *) {
      photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
      if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
      if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
      if photoOutput.isFastCapturePrioritizationSupported {
        photoOutput.isFastCapturePrioritizationEnabled = true
      }
    }
    // Scene monitoring is what makes `isFlashScene` meaningful. Without a
    // settings object to monitor, that property never becomes true and the
    // dark-scene convergence below could never trigger.
    let monitoring = AVCapturePhotoSettings()
    monitoring.flashMode = photoOutput.supportedFlashModes.contains(.auto) ? .auto : .off
    photoOutput.photoSettingsForSceneMonitoring = monitoring
    let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
    if let largest = supportedDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
      photoOutput.maxPhotoDimensions = largest
    }
  }

  func installReadinessCoordinatorOnQueue() {
    guard #available(iOS 17.0, *) else { return }
    // The delegate arrives on the main queue. Rather than publish from
    // there, hop to the camera queue so this write is ordered against every
    // other readiness write instead of racing them.
    let delegate = ReadinessDelegate { [weak self] _ in
      guard let self else { return }
      self.sessionQueue.async { [weak self] in self?.publishReadinessOnQueue() }
    }
    let coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
    coordinator.delegate = delegate
    readinessDelegate = delegate
    readinessCoordinator = coordinator
    publishReadinessOnQueue()
  }

  var captureReadinessIsReady: Bool {
    if #available(iOS 17.0, *) { return readinessCoordinator?.captureReadiness == .ready }
    return session.isRunning
  }
  func capturePhotoOnQueue(completion: (@Sendable (Result<CapturedPhoto, CameraIssue>) -> Void)?) {
    guard session.isRunning, session.outputs.contains(photoOutput), currentInput != nil else {
      finishImmediately(
        .failure(
          CameraIssue(
            kind: .capture, title: "Camera not ready", message: "The camera is still starting.",
            recoverySuggestion: "Try again in a moment.")), completion: completion)
      return
    }
    guard captureRequests.count < maximumOverlappingCaptures else {
      finishImmediately(
        .failure(
          CameraIssue(
            kind: .capture, title: "Capture busy",
            message: "The camera is processing recent photos.",
            recoverySuggestion: "Wait for the previous capture to finish.")), completion: completion
      )
      return
    }
    guard let device = currentInput?.device else {
      finishImmediately(
        .failure(
          CameraIssue(
            kind: .capture, title: "Camera not ready", message: "No active camera is available.",
            recoverySuggestion: "Try again in a moment.")), completion: completion)
      return
    }
    let settings: AVCapturePhotoSettings =
      photoOutput.availablePhotoCodecTypes.contains(.hevc)
      ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
      : AVCapturePhotoSettings()
    let supportedModes = photoOutput.supportedFlashModes
    let flashDecision = CameraFlashLogic.decision(
      requested: requestedFlashMode,
      position: sessionPosition,
      supportedModes: supportedModes.compactMap(CameraFlashMode.init(avMode:))
    )
    settings.flashMode = flashDecision.avMode.avMode
    settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization
    settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
    let multiplier = displayMultiplier(for: device)
    let switchOverFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map {
      CGFloat(truncating: $0)
    }
    let lensOptions = LensOptionMapper.options(
      minimumRawZoom: max(device.minAvailableVideoZoomFactor, 0.01),
      maximumRawZoom: device.maxAvailableVideoZoomFactor, switchOverFactors: switchOverFactors,
      secondaryNativeFactors: device.activeFormat.secondaryNativeResolutionZoomFactors,
      displayMultiplier: multiplier)
    let lensDisplayName = lensOptions.min(by: {
      abs($0.rawZoomFactor - device.videoZoomFactor)
        < abs($1.rawZoomFactor - device.videoZoomFactor)
    })?.label
    let snapshot = CaptureSnapshot(
      capturedAt: Date(), cameraPosition: sessionPosition, deviceType: device.deviceType.rawValue,
      deviceUniqueID: device.uniqueID, lensDisplayZoom: device.videoZoomFactor * multiplier,
      rawZoomFactor: device.videoZoomFactor, focalLength35mmEquivalent: nil,
      exposureDurationSeconds: device.exposureDuration.seconds, iso: device.iso,
      flashMode: flashDecision.metadataMode, videoRotationAngle: Double(captureRotationAngle),
      pixelWidth: 0, pixelHeight: 0,
      fileExtension: photoOutput.availablePhotoCodecTypes.contains(.hevc) ? "heic" : "jpg",
      virtualDeviceSwitchOverZoomFactors: switchOverFactors.map(Double.init),
      lensDisplayName: lensDisplayName, macroFallbackAvailable: macroFallbackAvailable(for: device))
    let request = CaptureRequest(settings: settings, snapshot: snapshot, completion: completion)
    request.delegate.manager = self
    request.delegate.requestID = settings.uniqueID
    captureRequests[settings.uniqueID] = request
    if #available(iOS 17.0, *), let coordinator = readinessCoordinator {
      guard coordinator.captureReadiness == .ready else {
        captureRequests.removeValue(forKey: settings.uniqueID)
        finishImmediately(
          .failure(
            CameraIssue(
              kind: .capture, title: "Capture busy",
              message: "The camera is not ready for another photo.",
              recoverySuggestion: "Try again in a moment.")), completion: completion)
        return
      }
      coordinator.startTrackingCaptureRequest(using: settings)
    }
    publish { $0.isCapturing = true }
    // Convergence runs only after the capture has been admitted and the
    // coordinator is tracking it. Readiness therefore already reads as busy,
    // so a second tap during the wait is rejected instead of queueing
    // another convergence behind this one.
    if converge(device: device) {
      request.restoreContinuousFocus = true
      convergedRequestsInFlight += 1
    }
    guard session.isRunning else {
      // The session stopped while the lens was travelling. Abandon the
      // capture rather than shooting into a torn-down graph, and give the
      // device back before leaving.
      captureRequests.removeValue(forKey: settings.uniqueID)
      if request.restoreContinuousFocus {
        convergedRequestsInFlight = max(0, convergedRequestsInFlight - 1)
        if convergedRequestsInFlight == 0 { resetToContinuousOnQueue() }
      }
      finishImmediately(
        .failure(
          CameraIssue(
            kind: .capture, title: "Capture cancelled",
            message: "The camera stopped before the photograph was taken.",
            recoverySuggestion: "Try again in a moment.")), completion: completion)
      return
    }
    photoOutput.capturePhoto(with: settings, delegate: request.delegate)
    logger.debug("photo capture requested \(settings.uniqueID, privacy: .public)")
  }

  func finishImmediately(
    _ result: Result<CapturedPhoto, CameraIssue>,
    completion: (@Sendable (Result<CapturedPhoto, CameraIssue>) -> Void)?
  ) {
    let callback = completion ?? onPhotoCaptured
    publish { $0.isCapturing = false }
    DispatchQueue.main.async { callback?(result) }
  }

  fileprivate func process(
    requestID: Int64, photo: AVCapturePhoto?, error: Error?,
    resolved: AVCaptureResolvedPhotoSettings?
  ) {
    let data = photo?.fileDataRepresentation()
    let processingIssue = error.map(captureIssue)
    let flashFired = resolved?.isFlashEnabled
    let dimensions = resolved?.photoDimensions
    sessionQueue.async { [weak self] in
      guard let self, let request = self.captureRequests[requestID], !request.finished else {
        return
      }
      request.processingIssue = processingIssue
      request.processedData = data
      if let flashFired { request.flashFired = flashFired }
      if let dimensions { request.dimensions = dimensions }
    }
  }

  fileprivate func markResolved(requestID: Int64, settings: AVCaptureResolvedPhotoSettings) {
    let flashFired = settings.isFlashEnabled
    let dimensions = settings.photoDimensions
    sessionQueue.async { [weak self] in
      self?.captureRequests[requestID]?.flashFired = flashFired
      self?.captureRequests[requestID]?.dimensions = dimensions
    }
  }

  fileprivate func markCaptureFinished(requestID: Int64, error: Error?) {
    let captureIssue = error.map(captureIssue)
    sessionQueue.async { [weak self] in
      guard let self, let request = self.captureRequests[requestID], !request.finished else {
        return
      }
      if let captureIssue {
        self.completeRequestOnQueue(requestID: requestID, result: .failure(captureIssue))
      } else if let issue = request.processingIssue {
        self.completeRequestOnQueue(requestID: requestID, result: .failure(issue))
      } else if let data = request.processedData {
        self.completeRequestOnQueue(
          requestID: requestID, result: .success(self.capturedPhoto(data: data, request: request)))
      } else {
        self.completeRequestOnQueue(
          requestID: requestID,
          result: .failure(
            CameraIssue(
              kind: .capture, title: "Photo processing failed",
              message: "The camera returned no photo data.",
              recoverySuggestion: "Try capturing again.")))
      }
    }
  }

  func capturedPhoto(data: Data, request: CaptureRequest) -> CapturedPhoto {
    let dimensions = request.dimensions
    let metadata = CameraCaptureInfo(
      cameraPosition: request.snapshot.cameraPosition, deviceType: request.snapshot.deviceType,
      deviceUniqueID: request.snapshot.deviceUniqueID,
      lensDisplayZoom: Double(request.snapshot.lensDisplayZoom),
      rawZoomFactor: Double(request.snapshot.rawZoomFactor),
      focalLength35mmEquivalent: request.snapshot.focalLength35mmEquivalent,
      exposureDurationSeconds: request.snapshot.exposureDurationSeconds, iso: request.snapshot.iso,
      flashMode: request.snapshot.flashMode, flashFired: request.flashFired,
      virtualDeviceSwitchOverZoomFactors: request.snapshot.virtualDeviceSwitchOverZoomFactors,
      lensDisplayName: request.snapshot.lensDisplayName,
      macroFallbackAvailable: request.snapshot.macroFallbackAvailable,
      videoRotationAngle: request.snapshot.videoRotationAngle)
    return CapturedPhoto(
      data: data,
      fileExtension: inferredFileExtension(data, fallback: request.snapshot.fileExtension),
      capturedAt: request.snapshot.capturedAt, pixelWidth: Int(dimensions.width),
      pixelHeight: Int(dimensions.height), metadata: metadata)
  }

  func inferredFileExtension(_ data: Data, fallback: String) -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let identifier = CGImageSourceGetType(source) as String?
    else { return fallback }
    if identifier == UTType.heic.identifier || identifier == UTType.heif.identifier {
      return "heic"
    }
    if identifier == UTType.jpeg.identifier { return "jpg" }
    if identifier == UTType.png.identifier { return "png" }
    return fallback
  }

  func completeRequestOnQueue(requestID: Int64, result: Result<CapturedPhoto, CameraIssue>) {
    guard let request = captureRequests.removeValue(forKey: requestID), !request.finished else {
      return
    }
    request.finished = true
    // A converged shot leaves focus and exposure locked. Only the last one
    // still outstanding hands the preview back, so an earlier photo
    // finishing cannot unlock the device out from under a newer one.
    if request.restoreContinuousFocus {
      convergedRequestsInFlight = max(0, convergedRequestsInFlight - 1)
      if convergedRequestsInFlight == 0 { resetToContinuousOnQueue() }
    }
    let isCapturing = !captureRequests.isEmpty
    publish { $0.isCapturing = isCapturing }
    publishReadinessOnQueue()
    let callback = request.completion ?? onPhotoCaptured
    DispatchQueue.main.async { callback?(result) }
  }

  /// In a dark room continuous autofocus has nothing to lock onto, so the
  /// shutter fires on whatever the lens happened to be set to and the flash
  /// lights a blurred frame. Before a flash capture in those conditions, run
  /// a one-shot focus and exposure pass at the centre and give it a moment
  /// to settle.
  ///
  /// The wait is bounded and the whole thing is skipped in decent light, so
  /// an ordinary daylight shot is as immediate as it was. Returns whether
  /// the device was left locked and therefore needs restoring afterwards.
  func converge(device: AVCaptureDevice) -> Bool {
    guard requestedFlashMode != .off, device.hasFlash else { return false }
    guard device.isFocusModeSupported(.autoFocus) else { return false }
    // `isFlashScene` is the system's own judgement about whether this frame
    // needs the flash, which is a far better signal than reading ISO and
    // guessing. It is only meaningful because scene monitoring is configured
    // when the output is set up.
    guard photoOutput.isFlashScene else { return false }
    // A tap-to-focus is an explicit instruction about what matters in the
    // frame. Only take the lens over when it is still on automatic.
    guard device.focusMode == .continuousAutoFocus else { return false }

    let centre = CGPoint(x: 0.5, y: 0.5)
    do {
      try device.lockForConfiguration()
      if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = centre }
      device.focusMode = .autoFocus
      if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = centre }
      if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
      device.unlockForConfiguration()
    } catch {
      return false
    }

    // Two phases. The lens does not begin moving the instant the mode is
    // set, so waiting only for "not adjusting" would sail straight past a
    // scan that had not started yet. Wait briefly for it to begin, then for
    // it to settle. Both waits are bounded, and a stopped session breaks out
    // immediately, so the camera queue is never held for long.
    let started = CFAbsoluteTimeGetCurrent() + Self.convergenceStartCeiling
    while !device.isAdjustingFocus && !device.isAdjustingExposure {
      guard CFAbsoluteTimeGetCurrent() < started, session.isRunning else { break }
      Thread.sleep(forTimeInterval: 0.01)
    }
    let deadline = CFAbsoluteTimeGetCurrent() + Self.convergenceCeiling
    while device.isAdjustingFocus || device.isAdjustingExposure {
      guard CFAbsoluteTimeGetCurrent() < deadline, session.isRunning else { break }
      Thread.sleep(forTimeInterval: 0.015)
    }
    return true
  }

  /// Long enough for a lens to travel in the dark, short enough that the
  /// delay reads as the camera working rather than the app hanging.
  static var convergenceCeiling: TimeInterval { 0.45 }
  /// Just enough for the scan to get going before the settle wait begins.
  static var convergenceStartCeiling: TimeInterval { 0.08 }

  func captureIssue(_ error: Error) -> CameraIssue {
    CameraIssue(
      kind: .capture, title: "Capture failed", message: error.localizedDescription,
      recoverySuggestion: "Try capturing again.")
  }
  final class CaptureRequest {
    let settings: AVCapturePhotoSettings
    let snapshot: CaptureSnapshot
    let completion: (@Sendable (Result<CapturedPhoto, CameraIssue>) -> Void)?
    let delegate: CaptureDelegate
    var flashFired = false
    var restoreContinuousFocus = false
    var dimensions = CMVideoDimensions(width: 0, height: 0)
    var processedData: Data?
    var processingIssue: CameraIssue?
    var finished = false

    init(
      settings: AVCapturePhotoSettings, snapshot: CaptureSnapshot,
      completion: (@Sendable (Result<CapturedPhoto, CameraIssue>) -> Void)?
    ) {
      self.settings = settings
      self.snapshot = snapshot
      self.completion = completion
      self.delegate = CaptureDelegate()
    }
  }

  struct CaptureSnapshot {
    let capturedAt: Date
    let cameraPosition: CameraPosition
    let deviceType: String
    let deviceUniqueID: String
    let lensDisplayZoom: CGFloat
    let rawZoomFactor: CGFloat
    let focalLength35mmEquivalent: Double?
    let exposureDurationSeconds: Double?
    let iso: Float?
    let flashMode: CameraFlashMode
    let videoRotationAngle: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let fileExtension: String
    let virtualDeviceSwitchOverZoomFactors: [Double]
    let lensDisplayName: String?
    let macroFallbackAvailable: Bool
  }

  final class CaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    weak var manager: CameraManager?
    var requestID: Int64 = 0

    func photoOutput(
      _ output: AVCapturePhotoOutput,
      willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) { manager?.markResolved(requestID: requestID, settings: resolvedSettings) }
    func photoOutput(
      _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
    ) {
      manager?.process(
        requestID: requestID, photo: photo, error: error, resolved: photo.resolvedSettings)
    }
    func photoOutput(
      _ output: AVCapturePhotoOutput,
      didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
    ) { manager?.markCaptureFinished(requestID: requestID, error: error) }
  }

  final class ReadinessDelegate: NSObject, AVCapturePhotoOutputReadinessCoordinatorDelegate {
    let callback: (AVCapturePhotoOutput.CaptureReadiness) -> Void
    init(callback: @escaping (AVCapturePhotoOutput.CaptureReadiness) -> Void) {
      self.callback = callback
    }
    func readinessCoordinator(
      _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
      captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) { callback(captureReadiness) }
  }
}
