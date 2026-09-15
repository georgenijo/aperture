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
      ZStack {
        CameraPreview(
          session: model.cameraManager.session,
          device: model.cameraManager.activeDevice,
          initialZoomFactor: model.cameraManager.currentRawZoom,
          onFocus: { event in
            if model.focus(at: event.devicePoint) {
              showFocus(at: event.viewPoint)
              UIAccessibility.post(notification: .announcement, argument: "Focus set")
            }
          },
          onPinchZoom: { rawZoom in model.zoom(to: rawZoom) },
          onCaptureRotation: model.cameraManager.setCaptureRotationAngle(_:)
        )
        .ignoresSafeArea()
        LinearGradient(
          colors: [.black.opacity(0.72), .clear, .black.opacity(0.88)],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        VStack(spacing: 0) {
          topBar
          Spacer()
          lensRail
          bottomBar
        }
        .padding(.top, proxy.safeAreaInsets.top)
        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12))
        if let issue = model.cameraIssue {
          CameraIssueBanner(
            issue: issue,
            retry: { model.retryCameraIssue() },
            dismiss: { model.dismissCameraIssue() }
          )
          .padding(.top, proxy.safeAreaInsets.top + 62)
          .padding(.horizontal, 16)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
        if let focusPoint {
          FocusIndicator()
            .position(x: focusPoint.x * proxy.size.width, y: focusPoint.y * proxy.size.height)
            .id(focusToken)
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            .allowsHitTesting(false)
        }
        if showFlash {
          Color.white.ignoresSafeArea().opacity(0.9).allowsHitTesting(false)
        }
      }
    }
  }

  private var topBar: some View {
    HStack(spacing: 12) {
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
        .accessibilityLabel("Flash")
        .accessibilityValue(displayFlashMode.label)
        .accessibilityHint("Choose flash mode")
        .confirmationDialog("Flash", isPresented: $showFlashMenu, titleVisibility: .visible) {
          ForEach(flashOptions, id: \.self) { mode in
            Button(mode.label) { model.setFlash(mode) }
          }
        }
      }
      Spacer()
      Button {
        showFilmPicker = true
      } label: {
        HStack(spacing: 5) {
          Circle().fill(ApertureStyle.amber).frame(width: 7, height: 7)
          Text(selectedFilmName).font(.caption.weight(.bold))
        }
        .foregroundStyle(ApertureStyle.bone)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(ApertureStyle.panel.opacity(0.82), in: Capsule())
      }
      .accessibilityLabel("Film")
      .accessibilityValue(selectedFilmName)
      .accessibilityHint("Choose a film recipe")
      Button {
        model.switchCamera()
      } label: {
        Image(systemName: "camera.rotate")
      }
      .buttonStyle(ApertureIconButtonStyle())
      .accessibilityLabel("Switch camera")
      .accessibilityHint("Switch between the back and front cameras")
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
    .padding(.horizontal, 18)
    .padding(.top, 8)
  }

  private var lensRail: some View {
    HStack(spacing: 8) {
      ForEach(model.cameraManager.capabilities.lensOptions) { option in
        Button(option.label) { model.zoom(to: option.rawZoomFactor) }
          .font(.caption.weight(.bold))
          .foregroundStyle(isSelected(option) ? ApertureStyle.ink : ApertureStyle.bone)
          .frame(minWidth: 44, minHeight: 44)
          .background(
            isSelected(option) ? ApertureStyle.amber : ApertureStyle.panel.opacity(0.82),
            in: Capsule()
          )
          .accessibilityLabel("Lens \(option.label)")
          .accessibilityValue(isSelected(option) ? "Selected" : "Not selected")
          .accessibilityAddTraits(isSelected(option) ? .isSelected : [])
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .background(.black.opacity(0.28), in: Capsule())
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
            if !model.items.isEmpty {
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
    model.cameraManager.capabilities.hasFlash ? CameraFlashMode.allCases : [.off, .on]
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

  private func isSelected(_ option: LensOption) -> Bool {
    abs(option.displayZoomFactor - model.cameraManager.currentDisplayZoom) < 0.08
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
