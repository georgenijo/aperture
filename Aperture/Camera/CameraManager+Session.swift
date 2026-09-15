@preconcurrency import AVFoundation
import Foundation
import OSLog

extension CameraManager {
  func configureGraphIfNeeded() -> Bool {
    if let currentInput, !session.inputs.contains(currentInput) {
      self.currentInput = nil
    }
    if currentInput == nil {
      guard addInputOnQueue(for: sessionPosition) else {
        publish { $0.lifecycleState = .unavailable }
        return false
      }
    }
    session.beginConfiguration()
    if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
    if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
    }
    if sessionCaptureMode == .video {
      if !configureVideoGraphInsideConfigurationOnQueue() {
        removeVideoGraphInsideConfigurationOnQueue()
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        sessionCaptureMode = .photo
        publish { $0.publishVideoMode(.photo) }
        publishIssue(
          .configuration, title: "Video unavailable",
          message: "The video output could not be configured.",
          recovery: "Try switching to Photo and back to Video.")
      }
    } else {
      removeVideoGraphInsideConfigurationOnQueue()
    }
    if let device = currentInput?.device { configureOutputForDeviceOnQueue(device) }
    session.commitConfiguration()
    guard session.outputs.contains(photoOutput), currentInput != nil else {
      publishIssue(
        .configuration, title: "Camera unavailable",
        message: "A still-photo output could not be configured.",
        recovery: "Try closing and reopening Aperture.")
      publish { $0.lifecycleState = .failed }
      return false
    }
    updateCapabilitiesOnQueue()
    installReadinessCoordinatorOnQueue()
    return true
  }

  func addInputOnQueue(for position: CameraPosition) -> Bool {
    guard let device = discoverDevice(for: position) else {
      publishIssue(
        .configuration, title: "Camera unavailable", message: "No compatible camera was found.",
        recovery: "Check camera access and try again.")
      return false
    }
    do {
      let input = try AVCaptureDeviceInput(device: device)
      session.beginConfiguration()
      // The mirror can be cleared after a disconnect/reset while the AV
      // session still exposes the stale video input.
      for input in session.inputs where input.ports.contains(where: { $0.mediaType == .video }) {
        session.removeInput(input)
      }
      guard session.canAddInput(input) else {
        session.commitConfiguration()
        publishIssue(
          .configuration, title: "Camera unavailable",
          message: "The selected camera could not be added.", recovery: "Try switching cameras.")
        return false
      }
      session.addInput(input)
      session.commitConfiguration()
      currentInput = input
      sessionPosition = position
      installPressureObservationOnQueue()
      let rawZoom = device.videoZoomFactor
      let displayZoom = currentDisplayZoomForCurrentDevice()
      publish {
        $0.currentPosition = position
        $0.activeDevice = device
        $0.currentRawZoom = rawZoom
        $0.currentDisplayZoom = displayZoom
      }
      return true
    } catch {
      publishIssue(
        .configuration, title: "Camera setup failed", message: error.localizedDescription,
        recovery: "Try closing and reopening Aperture.")
      return false
    }
  }

  func switchCameraOnQueue(to position: CameraPosition) {
    guard captureRequests.isEmpty, recordingStartedAt == nil, !movieOutput.isRecording else {
      publishIssue(
        .configuration, title: "Camera busy",
        message: "Finish the current capture before switching cameras.",
        recovery: "Wait for the photo to finish processing.")
      return
    }
    guard position != sessionPosition else { return }
    guard let device = discoverDevice(for: position) else {
      publishIssue(
        .configuration, title: "Camera unavailable",
        message: "No compatible camera was found in that position.",
        recovery: "Try switching cameras again.")
      return
    }
    let previousDisplayZoom = currentDisplayZoomForCurrentDevice()
    focusResetWorkItem?.cancel()
    do {
      let newInput = try AVCaptureDeviceInput(device: device)
      let oldInput = currentInput
      session.beginConfiguration()
      if let oldInput { session.removeInput(oldInput) }
      guard session.canAddInput(newInput) else {
        if let oldInput, session.canAddInput(oldInput) { session.addInput(oldInput) }
        session.commitConfiguration()
        if let oldInput, !session.inputs.contains(oldInput) { currentInput = nil }
        publishIssue(
          .configuration, title: "Camera switch failed",
          message: "The selected camera could not be added.",
          recovery: "The previous camera remains active.")
        return
      }
      session.addInput(newInput)
      configureOutputForDeviceOnQueue(newInput.device)
      if sessionCaptureMode == .video {
        guard session.outputs.contains(movieOutput) else {
          session.removeInput(newInput)
          if let oldInput, session.canAddInput(oldInput) {
            session.addInput(oldInput)
            configureOutputForDeviceOnQueue(oldInput.device)
          }
          session.commitConfiguration()
          if let oldInput, !session.inputs.contains(oldInput) { currentInput = nil }
          publishIssue(
            .configuration, title: "Camera switch failed",
            message: "The video output is no longer available for the selected camera.",
            recovery: "The previous camera remains active.")
          return
        }
        configureMovieOutputForDeviceOnQueue(newInput.device)
      }
      session.commitConfiguration()
      currentInput = newInput
      sessionPosition = position
      installPressureObservationOnQueue()
      updateCapabilitiesOnQueue()
      setZoomOnQueue(previousDisplayZoom / displayMultiplier(for: newInput.device), ramp: false)
      let rawZoom = newInput.device.videoZoomFactor
      let displayZoom = currentDisplayZoomForCurrentDevice()
      publish {
        $0.currentPosition = position
        $0.activeDevice = newInput.device
        $0.currentDisplayZoom = displayZoom
        $0.currentRawZoom = rawZoom
        $0.issue = nil
      }
      logger.debug("camera switched to \(position.rawValue, privacy: .public)")
    } catch {
      publishIssue(
        .configuration, title: "Camera switch failed", message: error.localizedDescription,
        recovery: "The previous camera remains active.")
    }
  }

  func discoverDevice(for position: CameraPosition) -> AVCaptureDevice? {
    let types: [AVCaptureDevice.DeviceType]
    switch position {
    case .back:
      types = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        .builtInUltraWideCamera, .builtInTelephotoCamera,
      ]
    case .front:
      types = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
    case .unspecified: return nil
    }
    for type in types {
      let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [type], mediaType: .video, position: position.avPosition)
      if let device = discovery.devices.first { return device }
    }
    return nil
  }
  func installNotifications() {
    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(
        forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
      ) { [weak self] note in
        guard let manager = self else { return }
        let reason =
          note.userInfo?[AVCaptureSessionInterruptionReasonKey]
          .map(String.init(describing:)) ?? "Camera interrupted"
        manager.sessionQueue.async { manager.handleInterruptionOnQueue(reason: reason) }
      })
    notificationTokens.append(
      center.addObserver(
        forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
      ) { [weak self] _ in
        guard let manager = self else { return }
        manager.sessionQueue.async { manager.handleInterruptionEndedOnQueue() }
      })
    notificationTokens.append(
      center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
      ) { [weak self] note in
        guard let manager = self else { return }
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let message = error?.localizedDescription ?? "The camera stopped unexpectedly."
        let mediaServicesWereReset = error?.code == .mediaServicesWereReset
        manager.sessionQueue.async {
          manager.handleRuntimeErrorOnQueue(
            message: message,
            mediaServicesWereReset: mediaServicesWereReset
          )
        }
      })
    notificationTokens.append(
      center.addObserver(
        forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
      ) { [weak self] note in
        guard let manager = self,
          let deviceID = (note.object as? AVCaptureDevice)?.uniqueID
        else { return }
        manager.sessionQueue.async { manager.handleDisconnectedOnQueue(deviceID: deviceID) }
      })
    notificationTokens.append(
      center.addObserver(
        forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil
      ) { [weak self] note in
        guard let manager = self,
          let deviceID = (note.object as? AVCaptureDevice)?.uniqueID
        else { return }
        manager.sessionQueue.async { manager.handleSubjectAreaChangeOnQueue(deviceID: deviceID) }
      })
  }

  func installPressureObservationOnQueue() {
    pressureObservation?.invalidate()
    // The observation is not `.initial`, so seed the shutdown flag from the
    // new device rather than inheriting whatever the previous one left.
    pressureShutdownActive = currentInput?.device.systemPressureState.level == .shutdown
    pressureObservation = currentInput?.device.observe(
      \AVCaptureDevice.systemPressureState, options: [.new]
    ) { [weak self] device, _ in
      guard let manager = self else { return }
      let deviceID = device.uniqueID
      let level = device.systemPressureState.level
      manager.sessionQueue.async { manager.handlePressureOnQueue(deviceID: deviceID, level: level) }
    }
  }

  func handleSubjectAreaChangeOnQueue(deviceID: String) {
    guard deviceID == currentInput?.device.uniqueID else { return }
    focusResetWorkItem?.cancel()
    let reset = DispatchWorkItem { [weak self] in self?.resetToContinuousOnQueue() }
    focusResetWorkItem = reset
    sessionQueue.async(execute: reset)
  }

  func handleInterruptionOnQueue(reason: String) {
    if recordingStartedAt != nil || movieOutput.isRecording {
      // AVFoundation may stop the session as part of the interruption.
      // Let the file output delegate close the movie first, then stop the
      // graph so the completed portion remains valid and deliverable.
      stopSessionWhenRecordingFinishes = true
      stopRecordingOnQueue(
        reason: CameraIssue(
          kind: .interruption, title: "Recording interrupted", message: reason,
          recoverySuggestion: "The completed portion will be kept in the Lab."))
    }
    publish {
      $0.lifecycleState = .interrupted(reason: reason)
      $0.issue = CameraIssue(
        kind: .interruption, title: "Camera interrupted", message: reason,
        recoverySuggestion: "Move to a clear camera context and try again.")
    }
  }

  func handleInterruptionEndedOnQueue() {
    publish { $0.issue = nil }
    // A recording interruption stopped the graph explicitly, and
    // AVFoundation only resumes sessions it stopped itself.
    resumeSessionIfWantedOnQueue()
    let isRunning = session.isRunning
    publish { $0.lifecycleState = isRunning ? .ready : .idle }
  }

  func handleRuntimeErrorOnQueue(message: String, mediaServicesWereReset: Bool) {
    publishIssue(
      .configuration, title: "Camera runtime error", message: message,
      recovery: "Try restarting the camera.")
    if mediaServicesWereReset, AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
      rebuildAfterRecordingFinishes = true
      if recordingStartedAt != nil || movieOutput.isRecording {
        stopSessionWhenRecordingFinishes = true
        stopRecordingOnQueue(
          reason: CameraIssue(
            kind: .interruption, title: "Recording interrupted",
            message:
              "The camera service restarted while recording. The completed portion will be kept in the Lab.",
            recoverySuggestion: "Try recording again when the camera is ready."))
      } else {
        rebuildGraphAfterMediaServicesResetOnQueue()
      }
    }
  }

  /// Media Services reset invalidates the old graph. Rebuild every input and
  /// output on the session queue, retaining the queue-owned position/mode
  /// mirrors so the user's selected camera and mode survive the reset.
  func rebuildGraphAfterMediaServicesResetOnQueue() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      rebuildAfterRecordingFinishes = false
      publish { $0.lifecycleState = .unavailable }
      return
    }
    sessionStartRequested = false
    if session.isRunning { session.stopRunning() }
    session.beginConfiguration()
    for input in session.inputs { session.removeInput(input) }
    for output in session.outputs { session.removeOutput(output) }
    session.commitConfiguration()
    currentInput = nil
    microphoneInput = nil
    pressureObservation?.invalidate()
    pressureObservation = nil
    readinessCoordinator = nil
    readinessDelegate = nil
    rebuildAfterRecordingFinishes = false
    startSessionOnQueue()
  }

  func handleDisconnectedOnQueue(deviceID: String) {
    guard deviceID == currentInput?.device.uniqueID else { return }
    if recordingStartedAt != nil || movieOutput.isRecording {
      stopSessionWhenRecordingFinishes = true
      stopRecordingOnQueue(
        reason: CameraIssue(
          kind: .interruption, title: "Recording interrupted",
          message:
            "The active camera was disconnected. The completed portion will be kept in the Lab.",
          recoverySuggestion: "Reconnect the camera before recording again."))
      publish {
        $0.lifecycleState = .unavailable
        $0.issue = CameraIssue(
          kind: .configuration, title: "Camera disconnected",
          message: "The active camera is no longer available.",
          recoverySuggestion: "Reconnect the camera and try again.")
      }
      return
    }
    if session.isRunning { session.stopRunning() }
    session.beginConfiguration()
    for input in session.inputs { session.removeInput(input) }
    session.commitConfiguration()
    currentInput = nil
    pressureObservation?.invalidate()
    pressureObservation = nil
    pressureShutdownActive = false
    publish {
      $0.lifecycleState = .unavailable
      $0.issue = CameraIssue(
        kind: .configuration, title: "Camera disconnected",
        message: "The active camera is no longer available.",
        recoverySuggestion: "Reconnect the camera and try again.")
    }
  }

  func handlePressureOnQueue(deviceID: String, level: AVCaptureDevice.SystemPressureState.Level) {
    guard deviceID == currentInput?.device.uniqueID else { return }
    guard level == .serious || level == .critical || level == .shutdown else {
      pressureShutdownActive = false
      publish { if $0.issue?.kind == .pressure { $0.issue = nil } }
      resumeSessionIfWantedOnQueue()
      return
    }
    publishIssue(
      .pressure, title: "Camera under pressure",
      message: "The camera is running hot and may slow down.",
      recovery: "Pause briefly before taking another photo.")
    if level == .shutdown {
      pressureShutdownActive = true
      if recordingStartedAt != nil || movieOutput.isRecording {
        stopSessionWhenRecordingFinishes = true
        stopRecordingOnQueue(
          reason: CameraIssue(
            kind: .pressure, title: "Recording stopped",
            message: "The camera is too hot to continue recording safely.",
            recoverySuggestion: "Pause briefly before recording again."))
      } else {
        if session.isRunning { session.stopRunning() }
        publish {
          $0.lifecycleState = .idle
          $0.isCaptureReady = false
        }
      }
    }
  }
}
