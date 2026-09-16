import SwiftUI

enum ApertureStyle {
  // Aperture is a darkroom, not a black canvas. The small lift between these
  // surfaces makes hierarchy legible while keeping the photographs in charge.
  static let ink = Color(red: 0.035, green: 0.037, blue: 0.041)
  static let panel = Color(red: 0.095, green: 0.098, blue: 0.105)
  static let panelDeep = Color(red: 0.065, green: 0.068, blue: 0.074)
  static let panelRaised = Color(red: 0.145, green: 0.145, blue: 0.15)
  static let bone = Color(red: 0.94, green: 0.92, blue: 0.86)
  static let amber = Color(red: 0.84, green: 0.56, blue: 0.29)
  static let muted = Color(red: 0.60, green: 0.60, blue: 0.59)
  static let quiet = Color(red: 0.43, green: 0.44, blue: 0.44)
  static let line = Color.white.opacity(0.11)
  static let danger = Color(red: 0.9, green: 0.36, blue: 0.31)

  static let controlSize: CGFloat = 48
  static let smallControlSize: CGFloat = 40
  static let bareControlSize: CGFloat = 44
  static let cardRadius: CGFloat = 16

  static func accent(for id: FilmRecipeIdentifier) -> Color {
    switch id {
    case .night: return Color(red: 0.40, green: 0.52, blue: 0.65)
    case .cinema: return Color(red: 0.70, green: 0.62, blue: 0.48)
    default: return amber
    }
  }
}

struct ApertureIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: ApertureStyle.controlSize, height: ApertureStyle.controlSize)
      .foregroundStyle(ApertureStyle.bone.opacity(isEnabled ? 1 : 0.4))
      .background(
        Circle()
          .fill(ApertureStyle.panel.opacity(configuration.isPressed ? 0.98 : 0.86))
      )
      .overlay(Circle().stroke(ApertureStyle.line, lineWidth: 1))
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// An icon with a full-size hit target and no chrome, for controls that sit
/// on the camera's own black surface rather than over the live image.
struct ApertureBareIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 18, weight: .medium))
      .frame(width: ApertureStyle.bareControlSize, height: ApertureStyle.bareControlSize)
      .contentShape(Circle())
      .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.92 : 1))
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct ApertureToolbarButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: ApertureStyle.smallControlSize, height: ApertureStyle.smallControlSize)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(ApertureStyle.panel.opacity(configuration.isPressed ? 1 : 0.72))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(ApertureStyle.line, lineWidth: 1)
      )
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.95 : 1))
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct ApertureSectionLabel: View {
  let title: String
  let detail: String?

  init(_ title: String, detail: String? = nil) {
    self.title = title
    self.detail = detail
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title.uppercased())
        .font(.caption.weight(.bold))
        .tracking(1.5)
        .foregroundStyle(ApertureStyle.muted)
      Rectangle()
        .fill(ApertureStyle.line)
        .frame(height: 1)
      if let detail {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(ApertureStyle.quiet)
      }
    }
  }
}

struct AperturePanel<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .background(ApertureStyle.panel, in: RoundedRectangle(cornerRadius: ApertureStyle.cardRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: ApertureStyle.cardRadius, style: .continuous)
          .stroke(ApertureStyle.line, lineWidth: 1)
      )
  }
}
