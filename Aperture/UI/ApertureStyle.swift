import SwiftUI

enum ApertureStyle {
  static let ink = Color(red: 0.035, green: 0.038, blue: 0.035)
  static let panel = Color(red: 0.095, green: 0.098, blue: 0.09)
  static let panelRaised = Color(red: 0.14, green: 0.14, blue: 0.125)
  static let bone = Color(red: 0.94, green: 0.91, blue: 0.82)
  static let amber = Color(red: 0.96, green: 0.56, blue: 0.18)
  static let muted = Color(red: 0.62, green: 0.61, blue: 0.55)

  static let controlSize: CGFloat = 48
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
          .fill(ApertureStyle.panel.opacity(configuration.isPressed ? 0.95 : 0.78))
      )
      .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
