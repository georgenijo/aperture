@preconcurrency import AVFoundation
import Foundation

extension CameraManager {
  func updateCapabilitiesOnQueue() {
    guard let device = currentInput?.device else {
      publish { $0.capabilities = .unavailable }
      return
    }
    let multiplier = displayMultiplier(for: device)
    let secondary = device.activeFormat.secondaryNativeResolutionZoomFactors
    let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
    let minimumRaw = max(device.minAvailableVideoZoomFactor, 0.01)
    let options = LensOptionMapper.options(
      minimumRawZoom: minimumRaw, maximumRawZoom: device.maxAvailableVideoZoomFactor,
      switchOverFactors: switchOvers, secondaryNativeFactors: secondary,
      displayMultiplier: multiplier)
    let maximumRaw = LensOptionMapper.clamp(
      rawZoomFactor: 10 / multiplier, minimumRawZoom: minimumRaw,
      maximumRawZoom: device.maxAvailableVideoZoomFactor)
    let modes = photoOutput.supportedFlashModes
    let supportsMacroFallback = macroFallbackAvailable(for: device)
    let position = sessionPosition
    let rawZoom = device.videoZoomFactor
    let displayZoom = rawZoom * multiplier
    let newCapabilities = CameraCapabilities(
      position: position, lensOptions: options, selectedDisplayZoom: displayZoom,
      minimumDisplayZoom: device.minAvailableVideoZoomFactor * multiplier,
      maximumDisplayZoom: maximumRaw * multiplier,
      hasFlash: modes.contains(.on) || modes.contains(.auto),
      supportsFocusPoint: device.isFocusPointOfInterestSupported,
      supportsExposurePoint: device.isExposurePointOfInterestSupported,
      supportsResponsiveCapture: photoOutput.isResponsiveCaptureSupported,
      supportsFastCapture: photoOutput.isFastCapturePrioritizationSupported,
      supportsZeroShutterLag: photoOutput.isZeroShutterLagSupported,
      supportsMacroFallback: supportsMacroFallback)
    publish {
      $0.capabilities = newCapabilities
      $0.currentDisplayZoom = displayZoom
      $0.currentRawZoom = rawZoom
      $0.currentPosition = position
      $0.activeDevice = device
    }
  }

  func discoverPhysicalUltraWide(for position: CameraPosition) -> AVCaptureDevice? {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: position.avPosition)
    return discovery.devices.first
  }

  func macroFallbackAvailable(for device: AVCaptureDevice) -> Bool {
    device.isVirtualDevice
      && (device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera)
      && discoverPhysicalUltraWide(for: sessionPosition) != nil
  }

  func displayMultiplier(for device: AVCaptureDevice) -> CGFloat {
    if #available(iOS 18.0, *) { return max(device.displayVideoZoomFactorMultiplier, 0.01) }
    let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
    return max(
      LensOptionMapper.inferredDisplayMultiplier(
        deviceType: device.deviceType, switchOverFactors: switchOvers), 0.01)
  }

  func currentDisplayZoomForCurrentDevice() -> CGFloat {
    guard let device = currentInput?.device else { return 1 }
    return device.videoZoomFactor * displayMultiplier(for: device)
  }

  func setZoomOnQueue(_ requestedRawZoom: CGFloat, ramp: Bool, rate: CGFloat = 4) {
    guard let device = currentInput?.device else { return }
    let minimumRaw = max(device.minAvailableVideoZoomFactor, 0.01)
    let raw = LensOptionMapper.clamp(
      rawZoomFactor: requestedRawZoom, minimumRawZoom: minimumRaw,
      maximumRawZoom: min(device.maxAvailableVideoZoomFactor, 10 / displayMultiplier(for: device)))
    do {
      try device.lockForConfiguration()
      if ramp {
        device.ramp(toVideoZoomFactor: raw, withRate: Float(max(rate.isFinite ? rate : 4, 0.1)))
      } else {
        device.videoZoomFactor = raw
      }
      device.unlockForConfiguration()
      let displayZoom = raw * displayMultiplier(for: device)
      publish {
        $0.currentDisplayZoom = displayZoom
        $0.currentRawZoom = raw
        $0.issue = nil
      }
    } catch {
      publishIssue(
        .configuration, title: "Zoom unavailable", message: error.localizedDescription,
        recovery: nil)
    }
  }

  func focusAndExposeOnQueue(at point: CGPoint) {
    guard let device = currentInput?.device else { return }
    let focusPoint = LensOptionMapper.normalizedFocusPoint(point)
    focusResetWorkItem?.cancel()
    do {
      try device.lockForConfiguration()
      device.isSubjectAreaChangeMonitoringEnabled = true
      if device.isFocusPointOfInterestSupported {
        device.focusPointOfInterest = focusPoint
        if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
      }
      if device.isExposurePointOfInterestSupported {
        device.exposurePointOfInterest = focusPoint
        if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
      }
      device.unlockForConfiguration()
      publish { $0.issue = nil }
      let reset = DispatchWorkItem { [weak self] in self?.resetToContinuousOnQueue() }
      focusResetWorkItem = reset
      sessionQueue.asyncAfter(deadline: .now() + 3, execute: reset)
    } catch {
      publishIssue(
        .focus, title: "Focus unavailable", message: error.localizedDescription, recovery: nil)
    }
  }

  func resetToContinuousOnQueue() {
    guard let device = currentInput?.device else { return }
    do {
      try device.lockForConfiguration()
      let center = CGPoint(x: 0.5, y: 0.5)
      if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
      if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
      device.unlockForConfiguration()
    } catch {
      publishIssue(
        .focus, title: "Focus reset unavailable", message: error.localizedDescription, recovery: nil
      )
    }
  }
}
