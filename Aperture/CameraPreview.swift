@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession
  var device: AVCaptureDevice? = nil
  var initialZoomFactor: CGFloat = 1
  var onFocus: ((CameraFocusEvent) -> Void)? = nil
  var onPinchZoom: ((CGFloat) -> Void)? = nil
  var onCaptureRotation: ((CGFloat) -> Void)? = nil

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView(
      session: session, device: device, initialZoomFactor: initialZoomFactor, onFocus: onFocus,
      onPinchZoom: onPinchZoom, onCaptureRotation: onCaptureRotation)
    view.attachSessionOnSessionQueue()
    view.updateRotationCoordinator()
    return view
  }

  func updateUIView(_ uiView: PreviewView, context: Context) {
    uiView.session = session
    uiView.device = device
    uiView.initialZoomFactor = initialZoomFactor
    uiView.onFocus = onFocus
    uiView.onPinchZoom = onPinchZoom
    uiView.onCaptureRotation = onCaptureRotation
    uiView.attachSessionOnSessionQueue()
    uiView.updateRotationCoordinator()
  }

  final class PreviewView: UIView {
    var session: AVCaptureSession
    var device: AVCaptureDevice?
    var initialZoomFactor: CGFloat
    var onFocus: ((CameraFocusEvent) -> Void)?
    var onPinchZoom: ((CGFloat) -> Void)?
    var onCaptureRotation: ((CGFloat) -> Void)?

    private var pinchStartZoom: CGFloat = 1
    private var isPinching = false
    private var orientationObserver: NSObjectProtocol?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var rotationDeviceID: String?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

    init(
      session: AVCaptureSession, device: AVCaptureDevice?, initialZoomFactor: CGFloat,
      onFocus: ((CameraFocusEvent) -> Void)?, onPinchZoom: ((CGFloat) -> Void)?,
      onCaptureRotation: ((CGFloat) -> Void)?
    ) {
      self.session = session
      self.device = device
      self.initialZoomFactor = initialZoomFactor
      self.onFocus = onFocus
      self.onPinchZoom = onPinchZoom
      self.onCaptureRotation = onCaptureRotation
      super.init(frame: .zero)
      isAccessibilityElement = true
      accessibilityTraits = .button
      accessibilityLabel = "Camera viewfinder"
      accessibilityHint = "Double tap to focus at the center"
      installGestures()
      orientationObserver = NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.updateRotationCoordinator() }
      }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
      if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
      previewRotationObservation?.invalidate()
      captureRotationObservation?.invalidate()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      updateRotationCoordinator()
    }

    override func accessibilityActivate() -> Bool {
      onFocus?(
        CameraFocusEvent(viewPoint: CGPoint(x: 0.5, y: 0.5), devicePoint: CGPoint(x: 0.5, y: 0.5)))
      return true
    }

    private func installGestures() {
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
      tap.require(toFail: pinch)
      addGestureRecognizer(tap)
      addGestureRecognizer(pinch)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended, !isPinching else { return }
      guard let previewLayer else { return }
      let layerPoint = recognizer.location(in: self)
      let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
      guard bounds.width > 0, bounds.height > 0 else { return }
      let viewPoint = CGPoint(x: layerPoint.x / bounds.width, y: layerPoint.y / bounds.height)
      onFocus?(CameraFocusEvent(viewPoint: viewPoint, devicePoint: devicePoint))
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      switch recognizer.state {
      case .began:
        isPinching = true
        pinchStartZoom = max(initialZoomFactor, 1)
      case .changed:
        onPinchZoom?(pinchStartZoom * recognizer.scale)
      case .ended, .cancelled, .failed:
        isPinching = false
      default:
        break
      }
    }

    func updateRotationCoordinator() {
      guard #available(iOS 17.0, *), let device else {
        rotationDeviceID = nil
        rotationCoordinator = nil
        previewRotationObservation?.invalidate()
        captureRotationObservation?.invalidate()
        return
      }
      guard let previewLayer else { return }
      guard rotationDeviceID != device.uniqueID || rotationCoordinator == nil else { return }
      rotationDeviceID = device.uniqueID
      let coordinator = AVCaptureDevice.RotationCoordinator(
        device: device, previewLayer: previewLayer)
      rotationCoordinator = coordinator
      previewRotationObservation?.invalidate()
      captureRotationObservation?.invalidate()
      previewRotationObservation = coordinator.observe(
        \AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelPreview,
        options: [.initial, .new]
      ) { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.applyPreviewRotation() }
      }
      captureRotationObservation = coordinator.observe(
        \AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelCapture,
        options: [.initial, .new]
      ) { [weak self] _, _ in
        Task { @MainActor [weak self] in
          guard let self, let coordinator = self.rotationCoordinator else { return }
          self.onCaptureRotation?(coordinator.videoRotationAngleForHorizonLevelCapture)
        }
      }
      applyPreviewRotation()
      onCaptureRotation?(coordinator.videoRotationAngleForHorizonLevelCapture)
    }

    private func applyPreviewRotation() {
      guard let coordinator = rotationCoordinator else { return }
      let angle = coordinator.videoRotationAngleForHorizonLevelPreview
      let layer = CameraPreviewSendableReference(previewLayer)
      CameraSessionQueue.shared.async {
        guard let connection = layer.value?.connection,
          connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
      }
    }

    /// Preview-layer session and connection mutations share the capture
    /// queue with the manager's graph, avoiding races during camera swaps
    /// and media-services resets.
    func attachSessionOnSessionQueue() {
      let layer = CameraPreviewSendableReference(previewLayer)
      let captureSession = CameraPreviewSendableReference(session)
      CameraSessionQueue.shared.async {
        layer.value?.session = captureSession.value
        layer.value?.videoGravity = .resizeAspectFill
      }
    }
  }
}

/// AVFoundation's reference types predate Swift concurrency annotations. The
/// preview layer and session are only used inside the dedicated camera queue
/// in these closures, so this narrow wrapper documents that ownership rather
/// than making the UIKit view itself unchecked-Sendable.
private struct CameraPreviewSendableReference<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}
