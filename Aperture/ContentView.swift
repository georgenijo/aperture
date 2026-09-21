import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// What a scene-phase change should do to the camera. Kept as its own pure
/// decision so it can be tested without a live `ScenePhase` environment or a
/// real `AppModel`.
///
/// `.inactive` covers transient system UI (the control center swipe, an
/// incoming call banner, the app switcher) as well as the moment just
/// before `.background`; tearing the session down there would restart it
/// needlessly and visibly for interruptions the user never asked for.  Only
/// `.background` actually leaves the app not visible, so only it stops the
/// camera. Returning to `.active` must not reactivate the camera underneath
/// a presented Lab or Settings screen.
enum CameraScenePolicy {
  enum Action: Equatable {
    case activate
    case stopRecordingAndDeactivate
    case doNothing
  }

  static func action(
    for phase: ScenePhase, isLabPresented: Bool, isSettingsPresented: Bool
  ) -> Action {
    switch phase {
    case .active:
      return (isLabPresented || isSettingsPresented) ? .doNothing : .activate
    case .background:
      return .stopRecordingAndDeactivate
    case .inactive:
      return .doNothing
    @unknown default:
      return .doNothing
    }
  }
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @State private var showLab = false
  @State private var showSettings = false
  @State private var showFilmPicker = false
  @State private var showFlashMenu = false
  @State private var focusPoint: CGPoint?
  @State private var focusToken = UUID()
  @State private var showFlash = false
  /// The front-camera screen-flash sequence: a fixed 90ms of white before the
  /// actual capture (so the "flash" has time to light the subject) and 170ms
  /// after (so it reads as a flash rather than a blink). Held here, rather
  /// than fired as a bare detached `Task`, so a second tap during that window
  /// can be refused instead of layering a second capture into the same
  /// flash, and so the whole sequence can be cancelled outright if the scene
  /// backgrounds or another screen comes up before the capture fires -
  /// otherwise that capture still happens once the delay elapses, late and
  /// unseen, aimed at whatever is on screen by then.
  @State private var screenFlashTask: Task<Void, Never>?
  @State private var recordingFeedback = UIImpactFeedbackGenerator(style: .medium)
  /// Lets the selected-mode pill slide between the words instead of blinking
  /// out of one and into the other.
  @Namespace private var chrome
  /// The control row and film chip grow with Dynamic Type, so the space the
  /// layout reserves for them has to grow too. Pinned numbers would clip the
  /// labels at accessibility sizes.
  @ScaledMetric(relativeTo: .caption) private var controlRowHeight: CGFloat = 58
  @ScaledMetric(relativeTo: .caption) private var chipHeight: CGFloat = 44

  var body: some View {
    ZStack {
      ApertureStyle.ink.ignoresSafeArea()
      #if DEBUG
        if model.cameraAuthorizationStatus == .authorized && model.cameraIsAvailable
          && !model.uiTestCameraDenied
        {
          cameraSurface
        } else if isUITestCameraPreviewFixture {
          // Real chrome, real interactivity, no real camera: this exists so
          // the UI test target can drive the surrounding controls without
          // a simulator camera or hardware permission grant. AppModel is
          // never told this fixture exists.
          cameraSurface
        } else {
          cameraUnavailableSurface
        }
      #else
        if model.cameraAuthorizationStatus == .authorized && model.cameraIsAvailable
          && !model.uiTestCameraDenied
        {
          cameraSurface
        } else {
          cameraUnavailableSurface
        }
      #endif
    }
    .preferredColorScheme(.dark)
    // Volume buttons, the Camera Control on the newer phones, and AirPods
    // stem clicks all arrive here. Apple's guidance is to fire on release,
    // not on press, so a half press that slides to adjust does not shoot.
    .modifier(HardwareShutter(isEnabled: hardwareShutterIsEnabled) {
      captureAction()
    })
    .onChange(of: model.captureMode) { previous, mode in
      guard previous != mode else { return }
      PerformanceLog.shared.end("Switch to \(mode.label)")
    }
    .onChange(of: model.cameraManager.currentPosition) { _, _ in
      PerformanceLog.shared.end("Flip camera")
      // A stale indicator from the previous lens has no meaning once the
      // camera underneath it has changed.
      clearFocusIndicator()
    }
    .onChange(of: displayFlashMode) { _, _ in
      PerformanceLog.shared.end("Change flash")
    }
    .onChange(of: model.cameraManager.isCapturing) { wasCapturing, isCapturing in
      // Ends on the capture itself finishing rather than on a new library
      // item, which can also arrive from an import or a re-development.
      if wasCapturing && !isCapturing { PerformanceLog.shared.end("Shutter") }
    }
    .task { await model.prepare() }
    .onAppear { model.activateCamera() }
    .onDisappear {
      model.deactivateCamera()
      clearFocusIndicator()
      cancelScreenFlashIfNeeded()
    }
    .onChange(of: scenePhase) { _, phase in
      switch CameraScenePolicy.action(
        for: phase, isLabPresented: showLab, isSettingsPresented: showSettings)
      {
      case .activate:
        model.activateCamera()
      case .stopRecordingAndDeactivate:
        if model.isRecording { model.stopRecording() }
        // Backgrounding is exactly the "aimed at whatever is on screen by
        // then" case a pending screen-flash capture must not survive.
        cancelScreenFlashIfNeeded()
        model.deactivateCamera()
      case .doNothing:
        break
      }
    }
    .onChange(of: showLab) { _, isShowing in
      if isShowing {
        // A clip already rolling must not be torn down just because the
        // user tapped Lab in the brief window before recording is gated.
        if !isRecordingOrStarting { model.deactivateCamera() }
        cancelScreenFlashIfNeeded()
      } else if scenePhase == .active {
        model.activateCamera()
      }
    }
    .onChange(of: showSettings) { _, isShowing in
      if isShowing {
        if !isRecordingOrStarting { model.deactivateCamera() }
        cancelScreenFlashIfNeeded()
      } else if scenePhase == .active && !showLab {
        model.activateCamera()
      }
    }
    .onChange(of: showFilmPicker) { _, isShowing in
      // Film and settings/lab are reached through buttons already disabled
      // while a screen flash is in flight; this is the defensive backstop
      // for any other path (VoiceOver, a queued action) that could still
      // present the sheet in that same narrow window.
      if isShowing { cancelScreenFlashIfNeeded() }
    }
    .onChange(of: model.cameraManager.authorizationStatus) { _, status in
      if status == .authorized && !showLab && !showSettings { model.activateCamera() }
    }
    .onChange(of: model.cameraIssue) { _, issue in
      guard let issue else { return }
      UIAccessibility.post(
        notification: .announcement, argument: "\(issue.title). \(issue.message)")
    }
    .onChange(of: model.errorMessage) { _, message in
      // An alert covering the screen is the same "capture would land late,
      // aimed at whatever is on screen by then" case as a sheet or the app
      // backgrounding.
      if message != nil { cancelScreenFlashIfNeeded() }
    }
    .fullScreenCover(isPresented: $showLab) {
      LabView(model: model)
        .onAppear { PerformanceLog.shared.end("Open Lab") }
    }
    .sheet(isPresented: $showSettings, onDismiss: { PerformanceLog.shared.cancel("Open Settings") }) {
      SettingsView(
        settings: Binding(get: { model.settings }, set: { model.updateSettings($0) })
      )
      .onAppear { PerformanceLog.shared.end("Open Settings") }
    }
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
          .padding(.top, proxy.safeAreaInsets.top + (isLandscape ? 8 : portraitTopReserve))
          .padding(.horizontal, 16)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
        if showFlash {
          Color.white.ignoresSafeArea().opacity(0.9).allowsHitTesting(false)
        }
      }
    }
  }

  private enum Layout {
    /// The gap that keeps the film chip clear of the status bar, and the air
    /// below it. In photo mode the 4:3 preview is width-bound, so trimming
    /// this does not enlarge the image; full-screen mode is what does.
    static let chipTopPadding: CGFloat = 10
    static let chipBottomAir: CGFloat = 6
    static let shutterHeight: CGFloat = 84
    static let stackTopPadding: CGFloat = 8
    static let stackSpacing: CGFloat = 12
  }

  /// Measured rather than guessed, so both reserves track Dynamic Type.
  private var portraitTopReserve: CGFloat {
    Layout.chipTopPadding + chipHeight + Layout.chipBottomAir
  }

  private var portraitBottomReserve: CGFloat {
    Layout.stackTopPadding + controlRowHeight + Layout.stackSpacing + Layout.shutterHeight
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
        proxy.size.height - safeTop - safeBottom - portraitTopReserve
          - portraitBottomReserve)
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
      previewCenterY = safeTop + portraitTopReserve + (previewHeight / 2)
    }

    return ZStack(alignment: .topLeading) {
      if isFullScreenViewfinder {
        // Filling rather than framing: a flexible view that ignores the safe
        // area covers the status bar and home indicator, which an explicitly
        // framed one cannot. The rail moves to the dock in this mode, so the
        // preview carries no overlay.
        viewfinder
          .ignoresSafeArea()
      } else {
        // Photo is 4:3 and video is 16:9, so switching modes changes the
        // frame. Animating it means the image reshapes in place rather than
        // snapping to a different size.
        viewfinder
          .frame(width: previewWidth, height: previewHeight)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(alignment: .bottom) {
            lensRail
              .padding(.bottom, 10)
          }
          .position(x: previewCenterX, y: previewCenterY)
          .animation(ApertureMotion.morph(reduceMotion), value: model.captureMode)
      }

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
        filmButton
        Spacer(minLength: 4)
        if isFullScreenViewfinder { lensRail }
        shutterRow
        controlBar(stacked: true)
      }
      .apertureGlassGroup()
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
        #if DEBUG
          if isUITestCameraPreviewFixture {
            fixturePlaceholder
          } else {
            cameraPreviewLayer
          }
        #else
          cameraPreviewLayer
        #endif
        if let focusPoint {
          FocusIndicator()
            .position(x: focusPoint.x * proxy.size.width, y: focusPoint.y * proxy.size.height)
            .id(focusToken)
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityIdentifier("camera-focus-indicator")
        }
      }
      .clipped()
    }
    // No SwiftUI-level accessibility here: CameraPreview.PreviewView already
    // makes itself an accessibility element with a label, hint, and a
    // double-tap-to-focus activation, so a second element on top of it would
    // duplicate what VoiceOver announces.
  }

  private var cameraPreviewLayer: some View {
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
  }

  #if DEBUG
    /// Whether this run should present the interactive chrome over an inert
    /// placeholder instead of the real capture preview. Used only by the UI
    /// test target, and only ever alongside `-ui-test-camera-denied`, which
    /// already keeps `AppModel` from starting the real session; this flag
    /// only changes what `ContentView` draws in place of `CameraPreview`.
    private var isUITestCameraPreviewFixture: Bool {
      ProcessInfo.processInfo.arguments.contains("-ui-test-camera-preview")
    }

    /// A clearly-labeled stand-in for the live camera feed. It requests no
    /// hardware and claims no real capture or autofocus; tapping it reuses
    /// the same indicator timer as a real focus tap purely as a visual echo; no
    /// device focus is set. Exists so UI tests can exercise the surrounding
    /// chrome (film, flash, switch camera, Lab, Settings) without a
    /// simulator camera.
    private var fixturePlaceholder: some View {
      ZStack {
        Rectangle().fill(ApertureStyle.panel)
        VStack(spacing: 10) {
          Image(systemName: "camera.viewfinder")
            .font(.system(size: 36, weight: .light))
            .foregroundStyle(ApertureStyle.muted)
          Text("UI Test Preview Fixture")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ApertureStyle.muted)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { showFocus(at: CGPoint(x: 0.5, y: 0.5)) }
      .accessibilityIdentifier("camera-preview-fixture")
      .accessibilityLabel("Camera preview fixture")
    }
  #endif

  /// Nothing above the image but the film it is being shot on. Flash and
  /// settings moved down into the thumb's reach, which also leaves the top
  /// corners free of targets that fight the status bar.
  private var topBar: some View {
    filmButton
      .padding(.horizontal, 12)
      .padding(.top, Layout.chipTopPadding)
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
          // The bolt redraws through its own glyph rather than cross-fading.
          // A nil transaction animation does not stop a symbol effect, so
          // Reduce Motion has to opt out of the transition itself.
          .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
      }
      .buttonStyle(ApertureBareIconButtonStyle())
      .disabled(isRecordingOrStarting || isScreenFlashInFlight)
      .animation(ApertureMotion.snap(reduceMotion), value: displayFlashMode)
      .accessibilityIdentifier("camera-flash")
      .accessibilityLabel("Flash")
      .accessibilityValue(displayFlashMode.label)
      .accessibilityHint("Choose flash mode")
      .confirmationDialog("Flash", isPresented: $showFlashMenu, titleVisibility: .visible) {
        ForEach(flashOptions, id: \.self) { mode in
          Button(mode.label) {
            // Choosing the mode that is already active publishes nothing.
            guard mode != displayFlashMode else { return }
            PerformanceLog.shared.begin("Change flash")
            model.setFlash(mode)
            scheduleTimingCancel("Change flash")
          }
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
      HStack(spacing: 7) {
        Circle()
          .fill(ApertureStyle.accent(for: model.settings.selectedFilm))
          .frame(width: 6, height: 6)
        Text(selectedFilmName.uppercased())
          .font(.system(.caption, design: .rounded).weight(.bold))
          .tracking(1.4)
          .lineLimit(1)
      }
      .foregroundStyle(ApertureStyle.bone)
      .padding(.horizontal, 14)
      .frame(minHeight: ApertureStyle.bareControlSize)
      .apertureGlassCapsule()
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isRecordingOrStarting || isScreenFlashInFlight)
    .animation(ApertureMotion.snap(reduceMotion), value: model.settings.selectedFilm)
    .accessibilityIdentifier("camera-film")
    .accessibilityLabel("Film")
    .accessibilityValue(selectedFilmName)
    .accessibilityHint("Choose a film recipe")
  }

  private var switchCameraButton: some View {
    Button {
      PerformanceLog.shared.begin("Flip camera")
      model.switchCamera()
      scheduleTimingCancel("Flip camera")
    } label: {
      Image(systemName: "arrow.triangle.2.circlepath.camera")
    }
    .buttonStyle(ApertureIconButtonStyle(isTransparent: isFullScreenViewfinder))
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    .disabled(isRecordingOrStarting || isScreenFlashInFlight)
    .accessibilityIdentifier("camera-switch")
    .accessibilityLabel("Switch camera")
    .accessibilityHint("Switch between the back and front cameras")
  }

  private var settingsButton: some View {
    Button {
      PerformanceLog.shared.begin("Open Settings")
      showSettings = true
    } label: {
      Image(systemName: "gearshape")
    }
    .buttonStyle(ApertureBareIconButtonStyle())
    .disabled(isRecordingOrStarting || isScreenFlashInFlight)
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
    VStack(spacing: 12) {
      if isFullScreenViewfinder { lensRail }
      shutterRow
      // At accessibility Dynamic Type sizes, flash / mode / settings cannot
      // share one row without truncating or clipping; the landscape dock's
      // stacked layout already solves exactly this, so it is reused here.
      controlBar(stacked: dynamicTypeSize.isAccessibilitySize)
    }
    .padding(.horizontal, 22)
    .padding(.top, 8)
    .apertureGlassGroup()
  }

  /// Flash, capture mode, and settings together, low enough to reach with a
  /// thumb. While recording the middle becomes the elapsed time, so the timer
  /// occupies space the layout already had.
  ///
  /// The landscape dock is only ~220pt wide. Two 44pt icons and the mode
  /// words cannot share one line there without truncating, so that layout
  /// stacks the icons above the words instead of squeezing them.
  @ViewBuilder
  private func controlBar(stacked: Bool) -> some View {
    let core = Group {
      if stacked {
        VStack(spacing: 2) {
          HStack(spacing: 0) {
            flashButton
            Spacer(minLength: 0)
            settingsButton
          }
          controlBarCenter
        }
      } else {
        HStack(spacing: 0) {
          flashButton
          Spacer(minLength: 0)
          controlBarCenter
          Spacer(minLength: 0)
          settingsButton
        }
      }
    }

    core
      .padding(.horizontal, 8)
      .frame(minHeight: stacked ? nil : controlRowHeight)
      .padding(.vertical, stacked ? 6 : 0)
      .apertureGlassCapsule()
      .animation(ApertureMotion.morph(reduceMotion), value: model.isRecording)
  }

  @ViewBuilder
  private var controlBarCenter: some View {
    if model.isRecording {
      recordingReadout
        .transition(reduceMotion ? .opacity : .scale(scale: 0.86).combined(with: .opacity))
    } else {
      modeStrip
        .transition(reduceMotion ? .opacity : .scale(scale: 0.86).combined(with: .opacity))
    }
  }

  private var recordingReadout: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(.red)
        .frame(width: 8, height: 8)
      Text(formattedDuration)
        .font(.system(.caption, design: .rounded).weight(.bold))
        .monospacedDigit()
        .foregroundStyle(.red)
        // Digits roll over rather than blinking between seconds.
        .contentTransition(.numericText())
        .animation(ApertureMotion.snap(reduceMotion), value: formattedDuration)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: ApertureStyle.bareControlSize)
    // The shutter button already reports the elapsed time as its value.
    .accessibilityHidden(true)
  }

  /// Two words with one pill. The pill is a single view that moves between
  /// them, so the selection travels instead of blinking from place to place.
  private var modeStrip: some View {
    HStack(spacing: 2) {
      ForEach(CameraCaptureMode.allCases, id: \.self) { mode in
        let isSelected = model.captureMode == mode
        Button {
          guard !isSelected else { return }
          // Deliberately not wrapped in withAnimation: the mode is applied on
          // the camera queue and published back later, so that transaction
          // would be long finished. The animation is keyed to the published
          // value at the end of this view instead.
          PerformanceLog.shared.begin("Switch to \(mode.label)")
          model.setCaptureMode(mode)
          // A refused switch never publishes, so give it a deadline of its
          // own rather than letting the next attempt inherit the start.
          scheduleTimingCancel("Switch to \(mode.label)")
        } label: {
          Text(mode.label.uppercased())
            .font(.system(.caption, design: .rounded).weight(.bold))
            .tracking(1.5)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(isSelected ? ApertureStyle.ink : ApertureStyle.bone)
            .padding(.horizontal, 15)
            .frame(minHeight: ApertureStyle.bareControlSize)
            .background {
              if isSelected {
                Capsule()
                  .fill(ApertureStyle.amber)
                  .matchedGeometryEffect(id: "capture-mode", in: chrome)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      }
    }
    .disabled(isRecordingOrStarting || isScreenFlashInFlight)
    .animation(ApertureMotion.morph(reduceMotion), value: model.captureMode)
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
      PerformanceLog.shared.begin("Open Lab")
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
    .disabled(isRecordingOrStarting || isScreenFlashInFlight)
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
          .stroke(model.isRecording ? Color.red : ApertureStyle.amber, lineWidth: 2.5)
          .frame(width: 82, height: 82)
        // A single rounded rectangle carries the whole state change: at a
        // corner radius of half its side it is a disc, and it rounds down
        // into the stop square as it shrinks. Two swapped shapes cannot
        // interpolate; one shape can.
        RoundedRectangle(
          cornerRadius: model.isRecording ? 9 : 34, style: .continuous
        )
        .fill(model.isRecording ? Color.red : ApertureStyle.bone)
        .frame(
          width: model.isRecording ? 32 : 68,
          height: model.isRecording ? 32 : 68)
      }
      .frame(width: 84, height: 84)
      .animation(ApertureMotion.morph(reduceMotion), value: model.isRecording)
      .scaleEffect(shutterIsReady ? 1 : 0.94)
      .animation(ApertureMotion.snap(reduceMotion), value: shutterIsReady)
    }
    .buttonStyle(.plain)
    .disabled(!shutterIsReady || isScreenFlashInFlight)
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
      unavailableActionButton
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

  /// Copy is keyed off the real authorization status rather than a single
  /// generic "unavailable" message, so a user who has never been asked and a
  /// user who explicitly said no see accurate, actionable text instead of
  /// the same failure-shaped copy.
  private var unavailableTitle: String {
    switch model.cameraAuthorizationStatus {
    case .notDetermined: return "Camera access needed"
    case .restricted: return "Camera access restricted"
    case .denied: return "Camera access is off"
    case .authorized: return model.cameraIssue?.title ?? "Preparing your camera"
    @unknown default: return model.cameraIssue?.title ?? "Camera unavailable"
    }
  }

  private var unavailableMessage: String {
    switch model.cameraAuthorizationStatus {
    case .notDetermined:
      return "Aperture needs camera access to shoot. Allow access when prompted."
    case .restricted:
      return "Camera access is restricted on this device, likely by parental controls or a configuration profile. Your Lab is still here."
    case .denied:
      return "Turn on camera access in Settings to shoot. Your Lab is still here."
    case .authorized:
      return model.cameraIssue?.message ?? "Getting the viewfinder ready."
    @unknown default:
      return model.cameraIssue?.message ?? "The viewfinder can’t start right now."
    }
  }

  @ViewBuilder
  private var unavailableActionButton: some View {
    switch model.cameraAuthorizationStatus {
    case .notDetermined:
      Button("Allow Camera Access") { model.cameraManager.requestPermission() }
        .buttonStyle(.borderedProminent).tint(ApertureStyle.amber).foregroundStyle(
          ApertureStyle.ink
        ).padding(.top, 20)
    case .restricted:
      EmptyView()
    case .denied:
      Button("Open Settings") { openSystemSettings() }
        .buttonStyle(.borderedProminent).tint(ApertureStyle.amber).foregroundStyle(
          ApertureStyle.ink
        ).padding(.top, 20)
    case .authorized:
      if model.cameraIssue != nil {
        Button("Try Again") { model.retryCameraIssue() }
          .buttonStyle(.borderedProminent).tint(ApertureStyle.amber).foregroundStyle(
            ApertureStyle.ink
          ).padding(.top, 20)
      }
    @unknown default:
      if model.cameraIssue != nil {
        Button("Try Again") { model.retryCameraIssue() }
          .buttonStyle(.borderedProminent).tint(ApertureStyle.amber).foregroundStyle(
            ApertureStyle.ink
          ).padding(.top, 20)
      }
    }
  }

  /// Each tap gets its own token so a newer tap's indicator cannot be hidden
  /// by an older tap's hide timer firing after it (see `FocusIndicatorLogic`).
  private func showFocus(at point: CGPoint) {
    let token = UUID()
    focusToken = token
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { focusPoint = point }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      guard FocusIndicatorLogic.shouldExpire(scheduledToken: token, currentToken: focusToken)
      else { return }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { focusPoint = nil }
    }
  }

  /// Drops any indicator (and its pending hide timer's relevance) outright,
  /// for cases where the reason it was showing has itself gone away: the
  /// lens it pointed at just changed, or the view is leaving the hierarchy.
  private func clearFocusIndicator() {
    focusToken = UUID()
    focusPoint = nil
  }

  /// Whether a screen-flash photo capture has been committed but has not yet
  /// fired (or is still showing its post-capture white). Further shutter
  /// presses and navigation away are refused for the same reason: the tap
  /// already promised a capture, and either one would leave that promise
  /// broken or answered late.
  private var isScreenFlashInFlight: Bool { screenFlashTask != nil }

  /// Cancels an in-flight screen-flash sequence outright rather than letting
  /// it resolve on its own schedule: the capture it was about to take is no
  /// longer of anything the user is looking at, so taking it late would be
  /// worse than not taking it. Cooperative cancellation inside the task
  /// itself is what stops `model.capture()` from still firing after this
  /// runs; this only clears the visible flash and the in-flight flag.
  private func cancelScreenFlashIfNeeded() {
    guard screenFlashTask != nil else { return }
    screenFlashTask?.cancel()
    screenFlashTask = nil
    showFlash = false
  }

  private var shutterIsReady: Bool {
    model.isRecording || (!isRecordingOrStarting && model.cameraManager.isCaptureReady)
  }

  /// True from the moment a video capture is requested until `isRecording`
  /// actually publishes, which is a round trip through the camera queue.
  /// Anything gated on "is a clip in progress" must include this window too,
  /// or navigation could race the publish and stop a clip that had, from the
  /// user's perspective, already started.
  private var isRecordingOrStarting: Bool {
    model.isRecordingOrStarting
  }

  /// The hardware shutter (physical button, Camera Control) must not fire
  /// while a modal surface is up front, or while the app is not actually in
  /// the foreground: none of those are moments a capture should be able to
  /// start.
  private var hardwareShutterIsEnabled: Bool {
    shutterIsReady && scenePhase == .active && !showLab && !showSettings && !showFilmPicker
      && !showFlashMenu && model.errorMessage == nil && !isScreenFlashInFlight
  }

  /// Interactions that are refused by the camera publish nothing, so their
  /// measurement would sit open and be charged to the next attempt. Give
  /// each one a short deadline after which it is simply dropped.
  private func scheduleTimingCancel(_ name: String) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      PerformanceLog.shared.cancel(name)
    }
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
    // Runs from the tap until the capture itself reports finished, which is
    // what the flash convergence wait shows up in.
    PerformanceLog.shared.begin("Shutter")
    scheduleTimingCancel("Shutter")
    let needsScreenFlash =
      model.cameraManager.currentPosition == .front
      && model.cameraManager.flashMode == .on
    guard needsScreenFlash else {
      model.capture()
      return
    }
    // The shutter, and everything that could navigate away from it, are
    // disabled for as long as `screenFlashTask` is non-nil, but a hardware
    // button and the on-screen control can still land in the same runloop
    // turn; this guard is the actual reentrancy fence, not just the visible
    // disabled state.
    guard screenFlashTask == nil else { return }
    showFlash = true
    // Deliberately not `defer { screenFlashTask = nil }`: a cancelled task
    // still reaches its own end, and if a new capture had already started
    // its own task by then, an unconditional clear here would erase *that*
    // task's reference rather than this one's, reopening the very
    // reentrancy window this guard exists to close. Each path below only
    // clears state it is actually responsible for; a cancelled run clears
    // nothing; `cancelScreenFlashIfNeeded` clears both when it cancels.
    screenFlashTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(90))
      // A cancellation during the pre-flash delay means the scene
      // backgrounded, another screen came up, or the view disappeared: the
      // capture would land late, aimed at whatever is on screen by then, so
      // it must not fire at all.
      guard !Task.isCancelled else { return }
      model.capture()
      try? await Task.sleep(for: .milliseconds(170))
      guard !Task.isCancelled else { return }
      showFlash = false
      screenFlashTask = nil
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

/// Routes the phone's physical capture buttons to the shutter.
///
/// The SwiftUI modifier arrived in iOS 18; the project still targets 17, so
/// this wraps it rather than applying it inline. On earlier systems the
/// hardware buttons keep their system behaviour and the on-screen shutter is
/// the only way to capture.
private struct HardwareShutter: ViewModifier {
  let isEnabled: Bool
  let capture: () -> Void

  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content.onCameraCaptureEvent(isEnabled: isEnabled) { event in
        // Release, not press: a half press on the Camera Control is the
        // gesture that adjusts rather than shoots.
        if event.phase == .ended { capture() }
      }
    } else {
      content
    }
  }
}
