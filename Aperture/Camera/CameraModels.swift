@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

extension CameraPosition {
  var avPosition: AVCaptureDevice.Position {
    switch self {
    case .back: .back
    case .front: .front
    case .unspecified: .unspecified
    }
  }

  var accessibilityName: String {
    switch self {
    case .back: "Rear camera"
    case .front: "Front camera"
    case .unspecified: "Camera"
    }
  }
}

enum CameraSessionQueue {
  /// All AVCapture graph, device, output, and connection mutations use this queue.
  static let shared = DispatchQueue(
    label: "com.georgenijo.Aperture.camera-session", qos: .userInitiated)
}

enum CameraFlashMode: String, Codable, CaseIterable, Sendable {
  case auto
  case on
  case off

  var avMode: AVCaptureDevice.FlashMode {
    switch self {
    case .auto: .auto
    case .on: .on
    case .off: .off
    }
  }

  var label: String {
    switch self {
    case .auto: "Auto"
    case .on: "On"
    case .off: "Off"
    }
  }

  var systemImage: String {
    switch self {
    case .auto: "bolt.badge.a"
    case .on: "bolt.fill"
    case .off: "bolt.slash.fill"
    }
  }

  init?(avMode: AVCaptureDevice.FlashMode) {
    switch avMode {
    case .auto: self = .auto
    case .on: self = .on
    case .off: self = .off
    @unknown default: return nil
    }
  }
}

struct CameraFlashDecision: Equatable {
  let avMode: CameraFlashMode
  let metadataMode: CameraFlashMode
  let usesScreenFlash: Bool
}

enum CameraFlashLogic {
  /// Front cameras have no hardware flash. `.on` is intentionally retained
  /// as metadata and is fulfilled by the view's screen-flash snapshot.
  static func decision(
    requested: CameraFlashMode,
    position: CameraPosition,
    supportedModes: [CameraFlashMode]
  ) -> CameraFlashDecision {
    if position == .front, requested == .on {
      return CameraFlashDecision(avMode: .off, metadataMode: .on, usesScreenFlash: true)
    }

    let avMode = supportedModes.contains(requested) ? requested : .off
    return CameraFlashDecision(avMode: avMode, metadataMode: avMode, usesScreenFlash: false)
  }

  /// The modes the picker may offer. `.on` is only listed where `decision`
  /// can honor it: a hardware flash, or the front camera's screen flash.
  static func availableModes(hasFlash: Bool, position: CameraPosition) -> [CameraFlashMode] {
    if hasFlash { return CameraFlashMode.allCases }
    return position == .front ? [.off, .on] : [.off]
  }
}

enum CameraRecordingLogic {
  /// `AVCaptureFileOutput.recordedDuration` reports zero once the file has
  /// been closed, which is when the finish delegate runs. A zero duration
  /// would be rejected by the library and the movie discarded, so fall back
  /// to the wall clock whenever the output has nothing usable to say.
  static func completedDuration(
    recordedSeconds: Double, startedAt: Date?, now: Date = Date()
  ) -> TimeInterval {
    if recordedSeconds.isFinite, recordedSeconds > 0 { return recordedSeconds }
    guard let startedAt else { return 0 }
    return max(0, now.timeIntervalSince(startedAt))
  }
}

enum CameraLifecycleLogic {
  /// Whether a session the system stopped (interruption, pressure shutdown)
  /// should be restarted now. AVFoundation only resumes sessions it stopped
  /// itself; a graph we stopped explicitly stays down until we start it.
  static func shouldResumeSession(
    isWanted: Bool, isRunning: Bool, isInterrupted: Bool, isRecording: Bool,
    isDeviceConnected: Bool = true
  ) -> Bool {
    isWanted && !isRunning && !isInterrupted && !isRecording && isDeviceConnected
  }
}

/// The capture mode is intentionally tiny: still photography remains the
/// default, while video is a secondary surface next to the shutter.
enum CameraCaptureMode: String, Codable, CaseIterable, Sendable {
  case photo
  case video

  var label: String {
    switch self {
    case .photo: "Photo"
    case .video: "Video"
    }
  }
}

enum CameraLifecycleState: Equatable, Sendable {
  case idle
  case configuring
  case ready
  case interrupted(reason: String)
  case unavailable
  case failed
}

struct CameraIssue: Error, Identifiable, Equatable, Sendable {
  enum Kind: String, Sendable {
    case configuration
    case capture
    case focus
    case interruption
    case pressure
    case recording
  }

  let id = UUID()
  let kind: Kind
  let title: String
  let message: String
  let recoverySuggestion: String?

  static func == (lhs: CameraIssue, rhs: CameraIssue) -> Bool {
    lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.message == rhs.message
  }
}

struct LensOption: Identifiable, Hashable, Sendable {
  let rawZoomFactor: CGFloat
  let displayZoomFactor: CGFloat
  let isOpticalTransition: Bool

  var id: String { String(format: "%.3f", rawZoomFactor) }

  var label: String {
    let rounded = displayZoomFactor.rounded()
    if abs(displayZoomFactor - rounded) < 0.04 {
      return "\(Int(rounded))×"
    }
    return String(format: "%.1f×", displayZoomFactor)
  }
}

struct CameraCapabilities: Equatable, Sendable {
  var position: CameraPosition
  var lensOptions: [LensOption]
  var selectedDisplayZoom: CGFloat
  var minimumDisplayZoom: CGFloat
  var maximumDisplayZoom: CGFloat
  var hasFlash: Bool
  var supportsFocusPoint: Bool
  var supportsExposurePoint: Bool
  var supportsResponsiveCapture: Bool
  var supportsFastCapture: Bool
  var supportsZeroShutterLag: Bool
  var supportsMacroFallback: Bool

  static let unavailable = CameraCapabilities(
    position: .back,
    lensOptions: [],
    selectedDisplayZoom: 1,
    minimumDisplayZoom: 1,
    maximumDisplayZoom: 1,
    hasFlash: false,
    supportsFocusPoint: false,
    supportsExposurePoint: false,
    supportsResponsiveCapture: false,
    supportsFastCapture: false,
    supportsZeroShutterLag: false,
    supportsMacroFallback: false
  )
}

struct CameraFocusEvent: Equatable, Sendable {
  let viewPoint: CGPoint
  let devicePoint: CGPoint

  init(viewPoint: CGPoint, devicePoint: CGPoint) {
    self.viewPoint = LensOptionMapper.normalizedFocusPoint(viewPoint)
    self.devicePoint = LensOptionMapper.normalizedFocusPoint(devicePoint)
  }
}

struct CameraCaptureInfo: Codable, Equatable, Sendable {
  let cameraPosition: CameraPosition
  let deviceType: String
  let deviceUniqueID: String
  let lensDisplayZoom: Double
  let rawZoomFactor: Double
  let focalLength35mmEquivalent: Double?
  let exposureDurationSeconds: Double?
  let iso: Float?
  let flashMode: CameraFlashMode
  let flashFired: Bool
  let virtualDeviceSwitchOverZoomFactors: [Double]
  let lensDisplayName: String?
  let macroFallbackAvailable: Bool
  let videoRotationAngle: Double?
}

struct CapturedPhoto: Sendable {
  let data: Data
  let fileExtension: String
  let capturedAt: Date
  let pixelWidth: Int
  let pixelHeight: Int
  let metadata: CameraCaptureInfo
}

/// A completed movie is handed off as a file URL. Keeping the payload on disk
/// is important for clips, which can be hundreds of megabytes in size.
struct CapturedVideo: Sendable {
  let fileURL: URL
  let capturedAt: Date
  let durationSeconds: Double
  let pixelWidth: Int
  let pixelHeight: Int
  let metadata: CameraCaptureInfo
}

enum LensOptionMapper {
  /// Creates camera-style focal stops from virtual-device switch points and
  /// high-fidelity crop positions. Values stay in AVFoundation's raw zoom space.
  static func options(
    minimumRawZoom: CGFloat,
    maximumRawZoom: CGFloat,
    switchOverFactors: [CGFloat],
    secondaryNativeFactors: [CGFloat],
    displayMultiplier: CGFloat,
    sensibleMaximumDisplayZoom: CGFloat = 10
  ) -> [LensOption] {
    guard minimumRawZoom.isFinite,
      maximumRawZoom.isFinite,
      displayMultiplier.isFinite,
      minimumRawZoom > 0,
      maximumRawZoom >= minimumRawZoom,
      displayMultiplier > 0,
      sensibleMaximumDisplayZoom.isFinite,
      sensibleMaximumDisplayZoom > 0
    else {
      return []
    }

    let maximumRawForProduct = max(
      minimumRawZoom,
      min(
        maximumRawZoom,
        sensibleMaximumDisplayZoom / displayMultiplier
      ))
    let optical = switchOverFactors.filter { $0.isFinite && $0 > 0 }
    let candidates =
      [minimumRawZoom] + optical + secondaryNativeFactors.filter { $0.isFinite && $0 > 0 }
    var unique: [CGFloat] = []

    for value in candidates.sorted() {
      // Lens buttons represent native/switchover positions. A native
      // factor beyond the product's zoom ceiling must be omitted, not
      // clamped into an invented digital lens stop.
      guard value >= minimumRawZoom, value <= maximumRawForProduct else { continue }
      if unique.contains(where: { abs($0 - value) < 0.04 }) { continue }
      unique.append(value)
    }

    // A physical single-camera device still needs a clear 1× position.
    if unique.isEmpty {
      unique = [minimumRawZoom]
    }

    return unique.map { factor in
      LensOption(
        rawZoomFactor: factor,
        displayZoomFactor: factor * displayMultiplier,
        isOpticalTransition: optical.contains(where: { abs($0 - factor) < 0.04 })
          || factor == minimumRawZoom
      )
    }
  }

  static func inferredDisplayMultiplier(
    deviceType: AVCaptureDevice.DeviceType,
    switchOverFactors: [CGFloat]
  ) -> CGFloat {
    switch deviceType {
    case .builtInTripleCamera, .builtInDualWideCamera:
      guard
        let mainWideTransition = switchOverFactors.filter({ $0.isFinite && $0 > 0 }).sorted().first
      else {
        return 0.5
      }
      return 1 / mainWideTransition
    default:
      return 1
    }
  }

  static func clamp(
    rawZoomFactor: CGFloat,
    minimumRawZoom: CGFloat,
    maximumRawZoom: CGFloat
  ) -> CGFloat {
    guard minimumRawZoom.isFinite,
      maximumRawZoom.isFinite,
      minimumRawZoom > 0,
      maximumRawZoom >= minimumRawZoom
    else {
      return 1
    }
    guard rawZoomFactor.isFinite else { return minimumRawZoom }
    return min(max(rawZoomFactor, minimumRawZoom), maximumRawZoom)
  }

  static func normalizedFocusPoint(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: min(max(point.x.isFinite ? point.x : 0.5, 0), 1),
      y: min(max(point.y.isFinite ? point.y : 0.5, 0), 1)
    )
  }
}
