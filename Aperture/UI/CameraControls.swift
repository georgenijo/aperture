import SwiftUI

/// A compact set of camera lens/zoom stops that sits over the live image.
///
/// `LensOption` deliberately carries both values used by the camera: the
/// user-facing `displayZoomFactor` and AVFoundation's `rawZoomFactor`. The
/// control renders the former and returns the complete option from its
/// action, so callers never have to reconstruct (or guess) the raw value from
/// a button's position or label.
struct CameraZoomControl: View {
  let options: [LensOption]
  let selectedDisplayZoom: CGFloat
  let onSelect: (LensOption) -> Void

  init(
    options: [LensOption],
    selectedDisplayZoom: CGFloat,
    onSelect: @escaping (LensOption) -> Void
  ) {
    self.options = options
    self.selectedDisplayZoom = selectedDisplayZoom
    self.onSelect = onSelect
  }

  var body: some View {
    Group {
      if options.isEmpty {
        EmptyView()
      } else {
        HStack(spacing: 0) {
          ForEach(options) { option in
            optionButton(for: option)
          }
        }
        .background(.black.opacity(0.5), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera zoom")
        .accessibilityHint("Choose a lens or zoom level")
      }
    }
  }

  @ViewBuilder
  private func optionButton(for option: LensOption) -> some View {
    let isSelected = selectedOptionID == option.id

    Button {
      onSelect(option)
    } label: {
      Text(option.label)
        .font(.caption2.weight(.bold))
        .monospacedDigit()
        .foregroundStyle(isSelected ? ApertureStyle.ink : ApertureStyle.bone)
        .frame(width: 38, height: 38)
        .background(
          isSelected ? ApertureStyle.amber : .clear,
          in: Circle()
        )
        // The disc stays small; the tap target does not.
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(CameraZoomOptionButtonStyle())
    .accessibilityLabel("Zoom \(option.label)")
    .accessibilityValue(isSelected ? "Selected" : "Available")
    .accessibilityHint("Set the camera to \(option.label)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// A ramped/pinch zoom can sit between presets. In that case no preset is
  /// marked selected rather than implying that the camera is at a stop it has
  /// not actually reached. The tolerance is only for floating-point noise
  /// from the capture device and is intentionally smaller than the mapper's
  /// option de-duplication threshold.
  private var selectedOptionID: String? {
    guard selectedDisplayZoom.isFinite else { return nil }

    let nearest = options
      .filter { $0.displayZoomFactor.isFinite }
      .min {
        abs($0.displayZoomFactor - selectedDisplayZoom)
          < abs($1.displayZoomFactor - selectedDisplayZoom)
      }
    guard let nearest else { return nil }

    let tolerance = max(0.01, abs(nearest.displayZoomFactor) * 0.005)
    return abs(nearest.displayZoomFactor - selectedDisplayZoom) <= tolerance
      ? nearest.id
      : nil
  }
}

private struct CameraZoomOptionButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.95 : 1))
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct FocusIndicator: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.88), lineWidth: 6)
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(ApertureStyle.amber, lineWidth: 2))
      .frame(width: 62, height: 62)
      .overlay(alignment: .topTrailing) {
        Circle().fill(ApertureStyle.amber).frame(width: 6, height: 6).offset(x: 3, y: -3)
      }
  }
}

struct NoticeBanner: View {
  let text: String
  let dismiss: () -> Void

  var body: some View {
    Button(action: dismiss) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(ApertureStyle.amber)
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(ApertureStyle.bone)
        Spacer(minLength: 8)
        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(ApertureStyle.muted)
      }
      .padding(.horizontal, 14).padding(.vertical, 12)
      .background(ApertureStyle.panelRaised, in: Capsule())
      .overlay(Capsule().stroke(.white.opacity(0.12)))
    }
    .buttonStyle(.plain).padding(.horizontal, 20)
  }
}

struct CameraIssueBanner: View {
  let issue: CameraIssue
  let retry: () -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: iconName)
          .foregroundStyle(ApertureStyle.amber)
        Text(issue.title)
          .font(.headline)
          .foregroundStyle(ApertureStyle.bone)
        Spacer(minLength: 8)
        Button(action: dismiss) {
          Image(systemName: "xmark")
            .font(.caption.weight(.bold))
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Dismiss camera message")
      }
      Text(issue.message)
        .font(.subheadline)
        .foregroundStyle(ApertureStyle.bone.opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
      if let recovery = issue.recoverySuggestion {
        Text(recovery)
          .font(.footnote)
          .foregroundStyle(ApertureStyle.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      if issue.kind == .configuration || issue.kind == .interruption {
        Button("Try Again", action: retry)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(ApertureStyle.ink)
          .frame(minWidth: 100, minHeight: 44)
          .padding(.horizontal, 12)
          .background(ApertureStyle.amber, in: Capsule())
          .accessibilityHint("Retry the camera operation")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(
      ApertureStyle.panelRaised.opacity(0.97),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.14)))
    .accessibilityElement(children: .contain)
  }

  private var iconName: String {
    switch issue.kind {
    case .focus: "scope"
    case .pressure: "thermometer.sun"
    case .interruption: "pause.circle"
    case .recording: "video.badge.exclamationmark"
    case .capture: "camera.badge.exclamationmark"
    case .configuration: "camera.metering.unknown"
    }
  }
}
