@preconcurrency import AVFoundation
import CoreMedia
import Foundation

extension CameraManager {
  func setCaptureModeOnQueue(_ mode: CameraCaptureMode) {
    guard mode != sessionCaptureMode else {
      if mode == .video {
        requestMicrophonePermission()
        configureVideoGraphOnQueue()
      }
      return
    }
    guard recordingStartedAt == nil, !movieOutput.isRecording else {
      publishIssue(
        .recording, title: "Recording in progress",
        message: "Stop the recording before changing capture modes.",
        recovery: "Tap the shutter to stop recording.")
      return
    }
    // A mode mirror is committed only after the graph transaction succeeds.
    // That keeps subsequent queue work independent of asynchronously
    // published UI state and lets a failed switch roll back completely.
    guard currentInput != nil else {
      sessionCaptureMode = mode
      publish { $0.publishVideoMode(mode) }
      if mode == .video { requestMicrophonePermission() }
      return
    }

    if mode == .video {
      session.beginConfiguration()
      let configured = configureVideoGraphInsideConfigurationOnQueue()
      if configured, let device = currentInput?.device {
        configureOutputForDeviceOnQueue(device)
        configureMovieOutputForDeviceOnQueue(device)
      }
      session.commitConfiguration()
      guard configured else {
        session.beginConfiguration()
        removeVideoGraphInsideConfigurationOnQueue()
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        session.commitConfiguration()
        publishIssue(
          .configuration, title: "Video unavailable",
          message: "The video output could not be configured.",
          recovery: "Try switching to Video again.")
        return
      }
      sessionCaptureMode = mode
      publish { $0.publishVideoMode(mode) }
      publishReadinessOnQueue()
      requestMicrophonePermission()
    } else {
      session.beginConfiguration()
      removeVideoGraphInsideConfigurationOnQueue()
      if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
      session.commitConfiguration()
      sessionCaptureMode = mode
      publish { $0.publishVideoMode(mode) }
      publishReadinessOnQueue()
    }
  }



  func configureVideoGraphOnQueue() {
    guard sessionCaptureMode == .video, currentInput != nil else { return }
    session.beginConfiguration()
    let configured = configureVideoGraphInsideConfigurationOnQueue()
    session.commitConfiguration()
    if configured, let device = currentInput?.device {
      configureMovieOutputForDeviceOnQueue(device)
    } else if !configured {
      session.beginConfiguration()
      removeVideoGraphInsideConfigurationOnQueue()
      if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
      session.commitConfiguration()
      sessionCaptureMode = .photo
      publish { $0.publishVideoMode(.photo) }
      publishReadinessOnQueue()
    }
  }

  @discardableResult
  func configureVideoGraphInsideConfigurationOnQueue() -> Bool {
    if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
    if !session.outputs.contains(movieOutput) {
      guard session.canAddOutput(movieOutput) else {
        publishIssue(
          .recording, title: "Video unavailable",
          message: "The camera could not add its movie output.",
          recovery: "Try restarting the camera.")
        return false
      }
      session.addOutput(movieOutput)
    }
    guard session.outputs.contains(movieOutput) else { return false }

    // Recover a valid existing audio input if the mirror was lost, and
    // remove any accidental duplicates before adding a new one.
    let audioInputs = session.inputs.filter { $0.ports.contains { $0.mediaType == .audio } }
    if let existing = microphoneInput, session.inputs.contains(existing) {
      audioInputs.filter { $0 !== existing }.forEach(session.removeInput)
    } else if let existing = audioInputs.first as? AVCaptureDeviceInput {
      microphoneInput = existing
      audioInputs.dropFirst().forEach(session.removeInput)
    } else {
      audioInputs.forEach(session.removeInput)
      microphoneInput = nil
    }
    guard microphoneInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    else { return true }
    guard let microphone = AVCaptureDevice.default(for: .audio) else {
      publishIssue(
        .recording, title: "Microphone unavailable",
        message: "A microphone input could not be found for video recording.",
        recovery: "Check microphone access and try again.")
      return false
    }
    do {
      let input = try AVCaptureDeviceInput(device: microphone)
      guard session.canAddInput(input) else {
        publishIssue(
          .recording, title: "Microphone unavailable",
          message: "The microphone could not be added to the camera session.",
          recovery: "Close other apps using the microphone, then try again.")
        return false
      }
      session.addInput(input)
      microphoneInput = input
    } catch {
      publishIssue(
        .recording, title: "Microphone setup failed", message: error.localizedDescription,
        recovery: "Try recording again.")
      return false
    }
    return true
  }

  func removeVideoGraphInsideConfigurationOnQueue() {
    if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
    if let microphoneInput, session.inputs.contains(microphoneInput) {
      session.removeInput(microphoneInput)
    }
    // The mirror can be stale after a media-services reset; clean every
    // audio input so the next video configuration cannot duplicate it.
    session.inputs.filter { $0.ports.contains { $0.mediaType == .audio } }.forEach(
      session.removeInput)
    microphoneInput = nil
  }

  func configureMovieOutputForDeviceOnQueue(_ device: AVCaptureDevice) {
    guard let connection = movieOutput.connection(with: .video) else { return }
    if connection.isVideoRotationAngleSupported(captureRotationAngle) {
      connection.videoRotationAngle = captureRotationAngle
    }
    if connection.isVideoStabilizationSupported {
      connection.preferredVideoStabilizationMode = .auto
    }
  }

  func startRecordingOnQueue(completion: (@Sendable (Result<CapturedVideo, CameraIssue>) -> Void)?)
  {
    guard sessionCaptureMode == .video else {
      finishVideoImmediately(
        .failure(
          CameraIssue(
            kind: .recording, title: "Video mode is off",
            message: "Select Video beside the shutter before recording.",
            recoverySuggestion: "Choose Video and try again.")), completion: completion)
      return
    }
    guard session.isRunning, session.outputs.contains(movieOutput), currentInput != nil else {
      finishVideoImmediately(
        .failure(
          CameraIssue(
            kind: .recording, title: "Camera not ready", message: "The camera is still starting.",
            recoverySuggestion: "Try again in a moment.")), completion: completion)
      return
    }
    guard !movieOutput.isRecording, recordingStartedAt == nil else {
      finishVideoImmediately(
        .failure(
          CameraIssue(
            kind: .recording, title: "Already recording",
            message: "A video is already being recorded.",
            recoverySuggestion: "Tap the shutter to stop it.")), completion: completion)
      return
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      finishVideoImmediately(
        .failure(
          CameraIssue(
            kind: .recording, title: "Microphone access is off",
            message: "Aperture needs microphone access to record synchronized sound.",
            recoverySuggestion: "Enable Microphone in Settings, then try again.")),
        completion: completion)
      return
    }
    guard let device = currentInput?.device else {
      finishVideoImmediately(
        .failure(
          CameraIssue(
            kind: .recording, title: "Camera unavailable",
            message: "No active camera is available.", recoverySuggestion: "Try switching cameras.")
        ), completion: completion)
      return
    }

    configureMovieOutputForDeviceOnQueue(device)
    let extensionName = "mov"
    var url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aperture-video-\(UUID().uuidString).\(extensionName)")
    while FileManager.default.fileExists(atPath: url.path) {
      url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aperture-video-\(UUID().uuidString).\(extensionName)")
    }
    let multiplier = displayMultiplier(for: device)
    let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
    let options = LensOptionMapper.options(
      minimumRawZoom: max(device.minAvailableVideoZoomFactor, 0.01),
      maximumRawZoom: device.maxAvailableVideoZoomFactor, switchOverFactors: switchOvers,
      secondaryNativeFactors: device.activeFormat.secondaryNativeResolutionZoomFactors,
      displayMultiplier: multiplier)
    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    let capturedAt = Date()
    let snapshot = CaptureSnapshot(
      capturedAt: capturedAt, cameraPosition: sessionPosition,
      deviceType: device.deviceType.rawValue, deviceUniqueID: device.uniqueID,
      lensDisplayZoom: device.videoZoomFactor * multiplier, rawZoomFactor: device.videoZoomFactor,
      focalLength35mmEquivalent: nil, exposureDurationSeconds: device.exposureDuration.seconds,
      iso: device.iso, flashMode: .off, videoRotationAngle: Double(captureRotationAngle),
      pixelWidth: Int(dimensions.width), pixelHeight: Int(dimensions.height),
      fileExtension: extensionName,
      virtualDeviceSwitchOverZoomFactors: switchOvers.map(Double.init),
      lensDisplayName: options.min(by: {
        abs($0.rawZoomFactor - device.videoZoomFactor)
          < abs($1.rawZoomFactor - device.videoZoomFactor)
      })?.label, macroFallbackAvailable: macroFallbackAvailable(for: device))
    let delegate = MovieRecordingDelegate(manager: self)
    recordingDelegate = delegate
    recordingCompletion = completion
    recordingSnapshot = snapshot
    recordingStartedAt = capturedAt
    stopSessionWhenRecordingFinishes = false
    movieOutput.maxRecordedDuration = CMTime(seconds: 60, preferredTimescale: 600)
    movieOutput.startRecording(to: url, recordingDelegate: delegate)
    publish { $0.publishRecordingStarted() }
    startRecordingTimerOnQueue()
  }

  func stopRecordingOnQueue(reason: CameraIssue?) {
    guard recordingStartedAt != nil || movieOutput.isRecording else { return }
    if let reason { publish { $0.publishRecordingIssue(reason) } }
    movieOutput.stopRecording()
  }

  private func startRecordingTimerOnQueue() {
    recordingTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self, let started = self.recordingStartedAt else { return }
      let duration = max(0, Date().timeIntervalSince(started))
      self.publish { $0.publishRecordingDuration(duration) }
    }
    recordingTimer = timer
    timer.resume()
  }

  func finishVideoImmediately(
    _ result: Result<CapturedVideo, CameraIssue>,
    completion: (@Sendable (Result<CapturedVideo, CameraIssue>) -> Void)?
  ) {
    let callback = completion ?? onVideoCaptured
    DispatchQueue.main.async { callback?(result) }
  }

  func finishRecording(url: URL, error: Error?) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard
        self.recordingStartedAt != nil || self.recordingSnapshot != nil
          || self.recordingCompletion != nil
      else { return }
      recordingTimer?.cancel()
      recordingTimer = nil
      let callback = recordingCompletion ?? onVideoCaptured
      let snapshot = recordingSnapshot
      let startedAt = recordingStartedAt
      let duration = CameraRecordingLogic.completedDuration(
        recordedSeconds: movieOutput.recordedDuration.seconds, startedAt: startedAt)
      recordingCompletion = nil
      recordingSnapshot = nil
      recordingStartedAt = nil
      recordingDelegate = nil
      publish { $0.publishRecordingFinished(duration: duration) }
      let completedDespiteError =
        (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
      let shouldStopSession = stopSessionWhenRecordingFinishes
      stopSessionWhenRecordingFinishes = false
      let shouldRebuild = rebuildAfterRecordingFinishes
      let movieExists = FileManager.default.fileExists(atPath: url.path)
      let recordingFailed = (error != nil && !completedDespiteError) || !movieExists
      if recordingFailed {
        removeFinishedMovieOnQueue(at: url)
        let message =
          (error as NSError?)?.localizedDescription
          ?? "The camera reported a completed movie, but no movie file was found."
        let issue = CameraIssue(
          kind: .recording, title: "Recording failed", message: message,
          recoverySuggestion: "Try recording again.")
        publish { $0.publishRecordingIssue(issue) }
        DispatchQueue.main.async { callback?(.failure(issue)) }
      } else if let snapshot {
        let metadata = CameraCaptureInfo(
          cameraPosition: snapshot.cameraPosition, deviceType: snapshot.deviceType,
          deviceUniqueID: snapshot.deviceUniqueID,
          lensDisplayZoom: Double(snapshot.lensDisplayZoom),
          rawZoomFactor: Double(snapshot.rawZoomFactor),
          focalLength35mmEquivalent: snapshot.focalLength35mmEquivalent,
          exposureDurationSeconds: snapshot.exposureDurationSeconds, iso: snapshot.iso,
          flashMode: snapshot.flashMode, flashFired: false,
          virtualDeviceSwitchOverZoomFactors: snapshot.virtualDeviceSwitchOverZoomFactors,
          lensDisplayName: snapshot.lensDisplayName,
          macroFallbackAvailable: snapshot.macroFallbackAvailable,
          videoRotationAngle: snapshot.videoRotationAngle)
        let captured = CapturedVideo(
          fileURL: url, capturedAt: snapshot.capturedAt, durationSeconds: duration,
          pixelWidth: snapshot.pixelWidth, pixelHeight: snapshot.pixelHeight, metadata: metadata)
        DispatchQueue.main.async { callback?(.success(captured)) }
      } else {
        let issue = CameraIssue(
          kind: .recording, title: "Recording failed",
          message: "The camera did not return a completed movie.",
          recoverySuggestion: "Try recording again.")
        removeFinishedMovieOnQueue(at: url)
        DispatchQueue.main.async { callback?(.failure(issue)) }
      }

      // Only stop/rebuild after the delegate has closed the file and the
      // result has been selected. A successful AVError must keep its URL.
      if shouldStopSession, session.isRunning {
        session.stopRunning()
        publish { $0.publishVideoStopped() }
        publishReadinessOnQueue()
      }
      if shouldRebuild {
        rebuildAfterRecordingFinishes = false
        rebuildGraphAfterMediaServicesResetOnQueue()
      } else if shouldStopSession {
        // The interruption that forced this stop may already be over.
        resumeSessionIfWantedOnQueue()
      }
    }
  }

  private func removeFinishedMovieOnQueue(at url: URL) {
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {
      logger.error(
        "Could not remove failed movie \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}

final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
  weak var manager: CameraManager?

  init(manager: CameraManager) { self.manager = manager }

  func fileOutput(
    _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {}

  func fileOutput(
    _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection], error: Error?
  ) {
    manager?.finishRecording(url: outputFileURL, error: error)
  }
}
