import SwiftUI

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
