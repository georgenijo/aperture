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
          .padding(.top, proxy.safeAreaInsets.top + (isLandscape ? 8 : Layout.portraitTopReserve))
          .padding(.horizontal, 16)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
        if showFlash {
          Color.white.ignoresSafeArea().opacity(0.9).allowsHitTesting(false)
        }
      }
    }
    // The layout below measures from the physical screen and insets the
    // controls itself, so this reader has to span the unsafe regions too.
    // Without it a full-screen preview stops at the status bar and the home
    // indicator. On a region that already spans the screen this is a no-op.
    .ignoresSafeArea()
  }

  private enum Layout {
    /// One row of 44pt controls and little else. Every point taken off this
    /// reserve is a point the image gains, which matters most in video mode
    /// where the 16:9 preview is height-bound rather than width-bound.
    static let portraitTopReserve: CGFloat = 48
    /// Mode strip, shutter row, and their spacing below the image.
    static let portraitBottomReserve: CGFloat = 156
  }

  /// Edge-to-edge preview with the controls floating over it, rather than an
  /// aspect-correct image framed by the app's own surface.
  private var isFullScreenViewfinder: Bool {
    model.settings.fullScreenViewfinderEnabled
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
    let availableWidth = isLandscape
      ? max(1, proxy.size.width - dockWidth - safeLeading - safeTrailing)
      : max(1, proxy.size.width - safeLeading - safeTrailing)
    let availableHeight = isLandscape
      ? max(1, proxy.size.height - safeTop - safeBottom)
      : max(
        1,
        proxy.size.height - safeTop - safeBottom - Layout.portraitTopReserve
          - Layout.portraitBottomReserve)
    let orientedPreviewAspectRatio = isLandscape ? previewAspectRatio : 1 / previewAspectRatio
    let framedWidth = min(availableWidth, availableHeight * orientedPreviewAspectRatio)
    // The preview layer already fills by aspect, so a full-screen frame crops
    // the sensor image rather than stretching it. Capture framing is unchanged.
    let previewWidth = isFullScreenViewfinder ? proxy.size.width : framedWidth
    let previewHeight =
      isFullScreenViewfinder ? proxy.size.height : framedWidth / orientedPreviewAspectRatio
    let previewCenterX =
      isFullScreenViewfinder ? proxy.size.width / 2 : safeLeading + (availableWidth / 2)
    let previewCenterY: CGFloat
    if isFullScreenViewfinder {
      previewCenterY = proxy.size.height / 2
    } else if isLandscape {
      previewCenterY = safeTop + (availableHeight / 2)
    } else {
      previewCenterY = safeTop + Layout.portraitTopReserve + (previewHeight / 2)
    }

    return ZStack(alignment: .topLeading) {
      viewfinder
        .frame(width: previewWidth, height: previewHeight)
        .overlay(alignment: .bottom) {
          // Full-screen mode moves the rail into the control dock, where it
          // cannot land underneath the shutter.
          if !isFullScreenViewfinder {
            lensRail
              .padding(.bottom, 10)
          }
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
      VStack(spacing: 12) {
        HStack(spacing: 0) {
          flashButton
          Spacer(minLength: 0)
          settingsButton
        }
        filmButton
        Spacer(minLength: 4)
        if isFullScreenViewfinder { lensRail }
        modeRow
        shutterRow
      }
      .cameraControlLegibility(isFullScreenViewfinder)
      .padding(.horizontal, 12)
      .padding(.top, safeTop + 8)
      .padding(.bottom, safeBottom)
      .frame(width: dockWidth, height: proxy.size.height)
      .position(
        x: proxy.size.width - safeTrailing - (dockWidth / 2),
        y: proxy.size.height / 2
      )
    } else {
      VStack(spacing: 0) {
        topBar
        Spacer(minLength: 0)
        bottomBar
      }
      .cameraControlLegibility(isFullScreenViewfinder)
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
        if let focusPoint {
          FocusIndicator()
            .position(x: focusPoint.x * proxy.size.width, y: focusPoint.y * proxy.size.height)
            .id(focusToken)
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            .allowsHitTesting(false)
        }
      }
      .clipped()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Camera viewfinder")
    .accessibilityHint("Double tap to focus at the center")
  }

  /// Flash on the left, film in the middle, settings on the right. The film
  /// chip is the only text above the image, so it stays small and bare.
  private var topBar: some View {
    ZStack {
      HStack(spacing: 0) {
        flashButton
        Spacer(minLength: 0)
        settingsButton
      }
      filmButton
    }
    .padding(.horizontal, 12)
    .padding(.top, 2)
  }

  @ViewBuilder
  private var flashButton: some View {
    if model.captureMode == .photo {
      Button {
        showFlashMenu.toggle()
      } label: {
        Image(systemName: displayFlashMode.systemImage)
          .foregroundStyle(
            displayFlashMode == .off ? ApertureStyle.bone : ApertureStyle.amber)
      }
      .buttonStyle(ApertureBareIconButtonStyle())
      .accessibilityLabel("Flash")
      .accessibilityValue(displayFlashMode.label)
      .accessibilityHint("Choose flash mode")
      .confirmationDialog("Flash", isPresented: $showFlashMenu, titleVisibility: .visible) {
        ForEach(flashOptions, id: \.self) { mode in
          Button(mode.label) { model.setFlash(mode) }
        }
      }
    } else {
      Color.clear.frame(width: ApertureStyle.bareControlSize, height: ApertureStyle.bareControlSize)
    }
  }

  private var filmButton: some View {
    Button {
      showFilmPicker = true
    } label: {
      HStack(spacing: 6) {
        Circle()
          .fill(ApertureStyle.accent(for: model.settings.selectedFilm))
          .frame(width: 6, height: 6)
        Text(selectedFilmName.uppercased())
          .font(.system(.caption, design: .rounded).weight(.bold))
          .tracking(1.4)
          .lineLimit(1)
      }
      .foregroundStyle(ApertureStyle.bone)
      .padding(.horizontal, 12)
      .frame(minHeight: ApertureStyle.bareControlSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Film")
    .accessibilityValue(selectedFilmName)
    .accessibilityHint("Choose a film recipe")
  }

  private var switchCameraButton: some View {
    Button {
      model.switchCamera()
    } label: {
      Image(systemName: "arrow.triangle.2.circlepath.camera")
    }
    .buttonStyle(ApertureIconButtonStyle(isTransparent: isFullScreenViewfinder))
    .accessibilityLabel("Switch camera")
    .accessibilityHint("Switch between the back and front cameras")
  }

  private var settingsButton: some View {
    Button {
      showSettings = true
    } label: {
      Image(systemName: "gearshape")
    }
    .buttonStyle(ApertureBareIconButtonStyle())
    .accessibilityIdentifier("camera-settings")
    .accessibilityLabel("Settings")
    .accessibilityHint("Open camera and processing settings")
  }

  private var lensRail: some View {
    CameraZoomControl(
      options: model.cameraManager.capabilities.lensOptions,
      selectedDisplayZoom: model.cameraManager.currentDisplayZoom,
      isTransparent: isFullScreenViewfinder
    ) { option in
      model.zoom(to: option.rawZoomFactor)
    }
  }

  private var bottomBar: some View {
    VStack(spacing: 10) {
      if isFullScreenViewfinder { lensRail }
      modeRow
      shutterRow
    }
    .padding(.horizontal, 28)
    .padding(.top, 8)
  }

  /// The row above the shutter: the mode words normally, the elapsed time
  /// while recording. Both occupy the same 44pt slot, so the timer never
  /// has to float over the shutter or steal space from the mode labels.
  @ViewBuilder
  private var modeRow: some View {
    if model.isRecording {
      recordingReadout
    } else {
      modeStrip
    }
  }

  private var recordingReadout: some View {
    HStack(spacing: 6) {
      Circle().fill(.red).frame(width: 8, height: 8)
      Text(formattedDuration)
        .font(.system(.caption, design: .rounded).weight(.bold))
        .monospacedDigit()
        .foregroundStyle(.red)
    }
    .frame(minHeight: ApertureStyle.bareControlSize)
    // The shutter button already reports the elapsed time as its value.
    .accessibilityHidden(true)
  }

  /// Two words instead of a boxed segmented control.
  private var modeStrip: some View {
    HStack(spacing: 26) {
      ForEach(CameraCaptureMode.allCases, id: \.self) { mode in
        let isSelected = model.captureMode == mode
        Button {
          model.setCaptureMode(mode)
        } label: {
          Text(mode.label.uppercased())
            .font(.system(.caption, design: .rounded).weight(.bold))
            .tracking(1.6)
            .foregroundStyle(isSelected ? ApertureStyle.amber : ApertureStyle.quiet)
            .frame(minWidth: ApertureStyle.bareControlSize, minHeight: ApertureStyle.bareControlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      }
    }
    .disabled(model.isRecording)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Capture mode")
    .accessibilityValue(model.captureMode.label)
  }

  private var shutterRow: some View {
    HStack(alignment: .center) {
      labButton
      Spacer(minLength: 0)
      shutterButton
      Spacer(minLength: 0)
      switchCameraButton
    }
  }

  private var labButton: some View {
    Button {
      showLab = true
    } label: {
      ZStack(alignment: .topTrailing) {
        if let item = model.latestItem {
          MediaThumbnailView(
            item: item, mediaLibrary: model.mediaLibrary,
            thumbnailService: model.thumbnailService, maximumPixelDimension: 120,
            showsProcessingBadge: false
          )
          .frame(width: 48, height: 48)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(ApertureStyle.line, lineWidth: 1)
          )
        } else {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isFullScreenViewfinder ? Color.clear : ApertureStyle.panel)
            .frame(width: 48, height: 48)
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                // With no fill behind it the outline is the only affordance,
                // so it carries more contrast over a live image.
                .stroke(
                  isFullScreenViewfinder ? ApertureStyle.bone.opacity(0.75) : ApertureStyle.line,
                  lineWidth: 1)
            )
        }
        if !model.processingIDs.isEmpty {
          ProgressView()
            .controlSize(.mini)
            .tint(ApertureStyle.ink)
            .frame(width: 18, height: 18)
            .background(ApertureStyle.amber, in: Circle())
            .offset(x: 5, y: -5)
            .accessibilityHidden(true)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("camera-lab")
    .accessibilityLabel("Lab")
    .accessibilityValue(model.items.isEmpty ? "Empty" : "\(model.items.count) media")
  }

  private var shutterButton: some View {
    Button {
      captureAction()
    } label: {
      ZStack {
        Circle()
          .stroke(model.isRecording ? .red : ApertureStyle.amber, lineWidth: 2.5)
          .frame(width: 82, height: 82)
        if model.isRecording {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.red)
            .frame(width: 30, height: 30)
        } else {
          Circle().fill(ApertureStyle.bone).frame(width: 68, height: 68)
        }
      }
      .frame(width: 84, height: 84)
    }
    .buttonStyle(.plain)
    .disabled(!shutterIsReady)
    .opacity(shutterIsReady ? 1 : 0.45)
    .accessibilityIdentifier("camera-shutter")
    .accessibilityLabel(
      model.isRecording
        ? "Stop recording"
        : (model.captureMode == .video ? "Start recording" : "Take photograph")
    )
    .accessibilityValue(shutterAccessibilityValue)
    .accessibilityHint(shutterAccessibilityHint)
  }

  private var cameraUnavailableSurface: some View {
    VStack(spacing: 0) {
      Spacer()
      Image(systemName: "camera.fill")
        .font(.system(size: 44, weight: .light))
        .foregroundStyle(ApertureStyle.amber)
        .padding(.bottom, 18)
      Text(unavailableTitle)
        .font(.title3.weight(.semibold)).foregroundStyle(ApertureStyle.bone)
      Text(unavailableMessage)
        .font(.subheadline).foregroundStyle(ApertureStyle.muted)
        .multilineTextAlignment(.center).padding(.horizontal, 40).padding(.top, 6)
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
      return "Turn on camera access in Settings to shoot. Your Lab is still here."
    }
    return model.cameraIssue?.message ?? "The viewfinder can’t start right now."
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
