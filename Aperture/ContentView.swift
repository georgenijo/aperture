import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
  @ObservedObject var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var showLab = false
  @State private var showSettings = false
  @State private var showFilmPicker = false
  @State private var showFlashMenu = false
  @State private var focusPoint: CGPoint?
  @State private var focusToken = UUID()
  @State private var showFlash = false
  @State private var recordingFeedback = UIImpactFeedbackGenerator(style: .medium)

  var body: some View {
    ZStack {
      ApertureStyle.ink.ignoresSafeArea()
      if model.cameraAuthorizationStatus == .authorized && model.cameraIsAvailable
        && !model.uiTestCameraDenied
      {
        cameraSurface
      } else {
        cameraUnavailableSurface
      }
    }
    .preferredColorScheme(.dark)
    .task { await model.prepare() }
    .onAppear { model.activateCamera() }
    .onDisappear { model.deactivateCamera() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        if !showLab && !showSettings { model.activateCamera() }
      } else {
        if model.isRecording { model.stopRecording() }
        model.deactivateCamera()
      }
    }
    .onChange(of: showLab) { _, isShowing in
      if isShowing {
        model.deactivateCamera()
      } else if scenePhase == .active {
        model.activateCamera()
      }
    }
    .onChange(of: showSettings) { _, isShowing in
      if isShowing {
        model.deactivateCamera()
      } else if scenePhase == .active && !showLab {
        model.activateCamera()
      }
    }
    .onChange(of: model.cameraManager.authorizationStatus) { _, status in
      if status == .authorized && !showLab && !showSettings { model.activateCamera() }
    }
    .onChange(of: model.cameraIssue) { _, issue in
      guard let issue else { return }
      UIAccessibility.post(
        notification: .announcement, argument: "\(issue.title). \(issue.message)")
    }
    .fullScreenCover(isPresented: $showLab) { LabView(model: model) }
    .sheet(isPresented: $showFilmPicker) {
      FilmPickerView(
        selectedFilm: Binding(
          get: { model.settings.selectedFilm },
          set: { value in
            var settings = model.settings
            settings.selectedFilm = value
            model.updateSettings(settings)
          }
        )
      )
    }
    .sheet(isPresented: $showSettings) {
      SettingsView(
        settings: Binding(get: { model.settings }, set: { model.updateSettings($0) })
      )
    }
    .alert("Aperture", isPresented: errorBinding) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .overlay(alignment: .top) {
      if let notice = model.notice {
        NoticeBanner(text: notice) { model.notice = nil }
          .padding(.top, 12)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
      }
    }
  }

  private var errorBinding: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private var cameraSurface: some View {
    GeometryReader { proxy in
      let isLandscape = proxy.size.width > proxy.size.height

      ZStack {
        ApertureStyle.ink.ignoresSafeArea()
        persistentCameraLayout(proxy: proxy, isLandscape: isLandscape)
        if let issue = model.cameraIssue {
          CameraIssueBanner(
            issue: issue,
            retry: { model.retryCameraIssue() },
            dismiss: { model.dismissCameraIssue() }
          )
          .padding(.top, proxy.safeAreaInsets.top + (isLandscape ? 8 : 62))
          .padding(.horizontal, isLandscape ? 16 : 16)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
        if showFlash {
          Color.white.ignoresSafeArea().opacity(0.9).allowsHitTesting(false)
        }
      }
    }
  }

  private var previewAspectRatio: CGFloat {
    // Photos use the camera's native 4:3 sensor framing. The video session is
    // configured with AVCaptureSession.Preset.high, which is normally 16:9.
    model.captureMode == .photo ? 4.0 / 3.0 : 16.0 / 9.0
  }

  /// Keeps a single CameraPreview in the hierarchy while the phone rotates.
  /// Only its frame and the surrounding chrome change, so AVFoundation does
  /// not lose its live preview layer during a portrait/landscape transition.
  private func persistentCameraLayout(proxy: GeometryProxy, isLandscape: Bool) -> some View {
    let safeTop = proxy.safeAreaInsets.top
    let safeBottom = max(proxy.safeAreaInsets.bottom, 12)
    let safeLeading = proxy.safeAreaInsets.leading
    let safeTrailing = proxy.safeAreaInsets.trailing
    let dockWidth = isLandscape ? min(max(220, proxy.size.width * 0.28), 300) : 0
    let portraitTopReserve: CGFloat = 68
    let portraitBottomReserve: CGFloat = 170
    let availableWidth = isLandscape
      ? max(1, proxy.size.width - dockWidth - safeLeading - safeTrailing)
      : max(1, proxy.size.width - safeLeading - safeTrailing)
    let availableHeight = isLandscape
      ? max(1, proxy.size.height - safeTop - safeBottom)
      : max(
        1,
        proxy.size.height - safeTop - safeBottom - portraitTopReserve - portraitBottomReserve)
    let orientedPreviewAspectRatio = isLandscape ? previewAspectRatio : 1 / previewAspectRatio
    let previewWidth = min(availableWidth, availableHeight * orientedPreviewAspectRatio)
    let previewHeight = previewWidth / orientedPreviewAspectRatio
    let previewCenterX = isLandscape
      ? safeLeading + (availableWidth / 2)
      : safeLeading + (availableWidth / 2)
    let previewCenterY = isLandscape
      ? safeTop + (availableHeight / 2)
      : safeTop + portraitTopReserve + (previewHeight / 2)

    return ZStack(alignment: .topLeading) {
      viewfinder
        .frame(width: previewWidth, height: previewHeight)
        .overlay(alignment: .bottom) {
          lensRail
            .padding(.bottom, 12)
        }
        .position(x: previewCenterX, y: previewCenterY)

      cameraChrome(
        proxy: proxy,
        isLandscape: isLandscape,
        dockWidth: dockWidth,
        safeTop: safeTop,
        safeBottom: safeBottom,
        safeTrailing: safeTrailing
      )
    }
  }

  @ViewBuilder
  private func cameraChrome(
    proxy: GeometryProxy,
    isLandscape: Bool,
    dockWidth: CGFloat,
    safeTop: CGFloat,
    safeBottom: CGFloat,
    safeTrailing: CGFloat
  ) -> some View {
    if isLandscape {
      VStack(spacing: 8) {
        topBar(landscape: true)
        Spacer(minLength: 4)
        bottomBar
      }
      .padding(.top, safeTop)
      .padding(.bottom, safeBottom)
      .frame(width: dockWidth, height: proxy.size.height)
      .position(
        x: proxy.size.width - safeTrailing - (dockWidth / 2),
        y: proxy.size.height / 2
      )
    } else {
      VStack(spacing: 0) {
        topBar(landscape: false)
        Spacer(minLength: 0)
        bottomBar
      }
      .padding(.top, safeTop)
      .padding(.bottom, safeBottom)
      .frame(width: proxy.size.width, height: proxy.size.height)
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
  }

  private var viewfinder: some View {
    GeometryReader { proxy in
      ZStack {
        ApertureStyle.ink
        CameraPreview(
          session: model.cameraManager.session, device: model.cameraManager.activeDevice,
          initialZoomFactor: model.cameraManager.currentRawZoom,
          onFocus: { event in
            if model.focus(at: event.devicePoint) {
              showFocus(at: event.viewPoint)
              UIAccessibility.post(notification: .announcement, argument: "Focus set")
            }
          },
          onPinchZoom: { rawZoom in model.zoom(to: rawZoom) },
          onCaptureRotation: model.cameraManager.setCaptureRotationAngle(_:))
        LinearGradient(
          colors: [.black.opacity(0.58), .clear, .black.opacity(0.78)],
          startPoint: .top,
          endPoint: .bottom
        )
        .allowsHitTesting(false)
        if let focusPoint {
          FocusIndicator()
            .position(x: focusPoint.x * proxy.size.width, y: focusPoint.y * proxy.size.height)
            .id(focusToken)
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            .allowsHitTesting(false)
        }
      }
      .clipped()
      .overlay(Rectangle().stroke(.white.opacity(0.1), lineWidth: 1))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Camera viewfinder")
    .accessibilityHint("Double tap to focus at the center")
  }

  @ViewBuilder
  private func topBar(landscape: Bool) -> some View {
    if landscape {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          flashButton
          Spacer(minLength: 0)
          filmButton
        }
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          switchCameraButton
          settingsButton
        }
      }
      .padding(.horizontal, 8)
      .padding(.top, 8)
    } else {
      HStack(spacing: 12) {
        flashButton
        Spacer(minLength: 0)
        filmButton
        switchCameraButton
        settingsButton
      }
      .padding(.horizontal, 18)
      .padding(.top, 8)
    }
  }

  @ViewBuilder
  private var flashButton: some View {
    if model.captureMode == .photo {
      Button {
        showFlashMenu.toggle()
      } label: {
        Label(displayFlashMode.label, systemImage: displayFlashMode.systemImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(ApertureStyle.bone)
          .padding(.horizontal, 11)
          .frame(minHeight: 44)
          .background(ApertureStyle.panel.opacity(0.82), in: Capsule())
      }
      .lineLimit(1)
      .accessibilityLabel("Flash")
      .accessibilityValue(displayFlashMode.label)
      .accessibilityHint("Choose flash mode")
      .confirmationDialog("Flash", isPresented: $showFlashMenu, titleVisibility: .visible) {
        ForEach(flashOptions, id: \.self) { mode in
          Button(mode.label) { model.setFlash(mode) }
        }
      }
    }
  }

  private var filmButton: some View {
    Button {
      showFilmPicker = true
    } label: {
      HStack(spacing: 5) {
        Circle().fill(ApertureStyle.amber).frame(width: 7, height: 7)
        Text(selectedFilmName).font(.caption.weight(.bold)).lineLimit(1)
      }
      .foregroundStyle(ApertureStyle.bone)
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .background(ApertureStyle.panel.opacity(0.82), in: Capsule())
    }
    .layoutPriority(1)
    .accessibilityLabel("Film")
    .accessibilityValue(selectedFilmName)
    .accessibilityHint("Choose a film recipe")
  }

  private var switchCameraButton: some View {
    Button {
      model.switchCamera()
    } label: {
      Image(systemName: "camera.rotate")
    }
    .buttonStyle(ApertureIconButtonStyle())
    .accessibilityLabel("Switch camera")
    .accessibilityHint("Switch between the back and front cameras")
  }

  private var settingsButton: some View {
    Button {
      showSettings = true
    } label: {
      Image(systemName: "gearshape")
    }
    .buttonStyle(ApertureIconButtonStyle())
    .accessibilityIdentifier("camera-settings")
    .accessibilityLabel("Settings")
    .accessibilityHint("Open camera and processing settings")
  }

  private var lensRail: some View {
    CameraZoomControl(
      options: model.cameraManager.capabilities.lensOptions,
      selectedDisplayZoom: model.cameraManager.currentDisplayZoom
    ) { option in
      model.zoom(to: option.rawZoomFactor)
    }
  }

  private var bottomBar: some View {
    VStack(spacing: 10) {
      modeCapsule
      HStack(alignment: .center) {
        Button {
          showLab = true
        } label: {
          ZStack(alignment: .topTrailing) {
            if let item = model.latestItem {
              MediaThumbnailView(
                item: item, mediaLibrary: model.mediaLibrary,
                thumbnailService: model.thumbnailService, maximumPixelDimension: 120
              )
              .frame(width: 52, height: 52)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
              Image(systemName: "square.stack.3d.down.right")
                .font(.title3)
                .foregroundStyle(ApertureStyle.bone)
                .frame(width: 52, height: 52)
                .background(
                  ApertureStyle.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !model.processingIDs.isEmpty {
              ProgressView()
                .controlSize(.small)
                .tint(ApertureStyle.ink)
                .frame(width: 24, height: 24)
                .background(ApertureStyle.amber, in: Circle())
                .offset(x: 6, y: -6)
                .accessibilityHidden(true)
            } else if !model.items.isEmpty {
              Text("\(model.items.count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ApertureStyle.ink)
                .padding(4)
                .background(ApertureStyle.amber, in: Circle())
                .offset(x: 5, y: -5)
            }
          }
        }
        .accessibilityIdentifier("camera-lab")
        .accessibilityLabel("Lab")
        .accessibilityValue(model.items.isEmpty ? "Empty" : "\(model.items.count) media")
        Spacer()
        VStack(spacing: 7) {
          if model.isRecording {
            Text(formattedDuration)
              .font(.caption.monospacedDigit().weight(.bold))
              .foregroundStyle(.red)
              .accessibilityHidden(true)
          }
          Button {
            captureAction()
          } label: {
            ZStack {
              Circle().fill(model.isRecording ? .red : ApertureStyle.bone).frame(
                width: 76, height: 76)
              Circle().stroke(
                model.isRecording ? .red.opacity(0.32) : ApertureStyle.amber, lineWidth: 3
              ).frame(width: 88, height: 88)
              if model.isRecording {
                RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 23, height: 23)
              }
            }
          }
          .buttonStyle(.plain)
          .disabled(!shutterIsReady)
          .accessibilityIdentifier("camera-shutter")
          .accessibilityLabel(
            model.isRecording
              ? "Stop recording"
              : (model.captureMode == .video ? "Start recording" : "Take photograph")
          )
          .accessibilityValue(shutterAccessibilityValue)
          .accessibilityHint(shutterAccessibilityHint)
        }
        Spacer()
        Color.clear.frame(width: 52, height: 52)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
  }

  private var modeCapsule: some View {
    Picker(
      "Capture mode",
      selection: Binding(
        get: { model.captureMode },
        set: { model.setCaptureMode($0) }
      )
    ) {
      ForEach(CameraCaptureMode.allCases, id: \.self) { mode in
        Text(mode.label).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 142)
    .frame(minHeight: 44)
    .disabled(model.isRecording)
    .accessibilityLabel("Capture mode")
    .accessibilityValue(model.captureMode.label)
    .accessibilityHint("Choose Photo or Video")
  }

  private var cameraUnavailableSurface: some View {
    VStack(spacing: 0) {
      Spacer()
      Image(systemName: "camera.fill")
        .font(.system(size: 50, weight: .light))
        .foregroundStyle(ApertureStyle.amber)
        .padding(.bottom, 18)
      Text(unavailableTitle)
        .font(.title2.weight(.semibold)).foregroundStyle(ApertureStyle.bone)
      Text(unavailableMessage)
        .font(.subheadline).foregroundStyle(ApertureStyle.muted)
        .multilineTextAlignment(.center).padding(.horizontal, 34).padding(.top, 8)
      if model.cameraAuthorizationStatus == .denied {
        Button("Open Settings") { openSystemSettings() }
          .buttonStyle(.borderedProminent).tint(ApertureStyle.amber).foregroundStyle(
            ApertureStyle.ink
          ).padding(.top, 20)
      } else if model.cameraIssue != nil {
        Button("Try Again") { model.retryCameraIssue() }
          .buttonStyle(.borderedProminent).tint(ApertureStyle.amber).foregroundStyle(
            ApertureStyle.ink
          ).padding(.top, 20)
      }
      Spacer()
      HStack(spacing: 12) {
        Button {
          showLab = true
        } label: {
          Label("Lab", systemImage: "square.stack.3d.down.right")
        }
        .accessibilityIdentifier("camera-lab")
        Button {
          showSettings = true
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .accessibilityIdentifier("camera-settings")
      }
      .buttonStyle(.bordered).tint(ApertureStyle.bone).padding(.bottom, 32)
    }
    .padding(.horizontal, 20)
  }

  private var selectedFilmName: String {
    FilmRecipeCatalog.recipe(for: model.settings.selectedFilm)?.displayName ?? "Film"
  }

  private var displayFlashMode: CameraFlashMode {
    if !model.cameraManager.capabilities.hasFlash && model.cameraManager.flashMode == .auto {
      return .off
    }
    return model.cameraManager.flashMode
  }

  private var flashOptions: [CameraFlashMode] {
    CameraFlashLogic.availableModes(
      hasFlash: model.cameraManager.capabilities.hasFlash,
      position: model.cameraManager.currentPosition)
  }

  private var unavailableTitle: String {
    if model.cameraAuthorizationStatus == .denied { return "Camera access is off" }
    return model.cameraIssue?.title ?? "Camera unavailable"
  }

  private var unavailableMessage: String {
    if model.cameraAuthorizationStatus == .denied {
      return
        "Aperture can still show your Lab and settings. Enable camera access to make new photographs."
    }
    return model.cameraIssue?.message
      ?? "Aperture can’t start the viewfinder right now. Your local Lab is still available."
  }

  private func showFocus(at point: CGPoint) {
    focusToken = UUID()
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { focusPoint = point }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { focusPoint = nil }
    }
  }

  private var shutterIsReady: Bool {
    model.isRecording || model.cameraManager.isCaptureReady
  }

  private var shutterAccessibilityValue: String {
    if model.isRecording { return formattedDuration }
    if !shutterIsReady { return "Camera preparing" }
    return "Ready"
  }

  private var shutterAccessibilityHint: String {
    if model.isRecording { return "Double tap to stop recording and develop this video" }
    if !shutterIsReady { return "The camera is preparing; try again in a moment" }
    return model.captureMode == .video
      ? "Double tap to start recording a video with sound"
      : "Double tap to take a photo"
  }

  private func captureAction() {
    if model.isRecording {
      if model.settings.hapticsEnabled { recordingFeedback.impactOccurred() }
      model.stopRecording()
      return
    }
    guard shutterIsReady else {
      model.notice = "The camera is still preparing. Try again in a moment."
      return
    }
    if model.captureMode == .video {
      if model.settings.hapticsEnabled { recordingFeedback.prepare() }
      model.startRecording()
      if model.settings.hapticsEnabled { recordingFeedback.impactOccurred() }
      return
    }
    if model.settings.hapticsEnabled {
      let feedback = UIImpactFeedbackGenerator(style: .light)
      feedback.prepare()
      feedback.impactOccurred()
    }
    let needsScreenFlash =
      model.cameraManager.currentPosition == .front
      && model.cameraManager.flashMode == .on
    guard needsScreenFlash else {
      model.capture()
      return
    }
    showFlash = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(90))
      model.capture()
      try? await Task.sleep(for: .milliseconds(170))
      showFlash = false
    }
  }

  private var formattedDuration: String {
    let seconds = Int(model.recordingDuration.rounded(.down))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }

  private func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}
