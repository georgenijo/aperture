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

/// One place to tune how the camera moves. Springs rather than easing: a
/// camera control should feel like it has mass and settle, not like it is
/// playing a timed animation. Short responses keep it quick to the hand.
enum ApertureMotion {
  /// Small state flips: a symbol changing, a pill sliding.
  static func snap(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82)
  }

  /// Shape and frame changes that the eye tracks across the screen.
  static func morph(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.84)
  }
}

extension View {
  /// Liquid Glass where the system has it, the app's own smoked panel where
  /// it does not. Routing both through one modifier keeps the fallback from
  /// drifting away from the real thing.
  @ViewBuilder
  func apertureGlassCapsule(isEnabled: Bool = true) -> some View {
    if !isEnabled {
      self
    } else if #available(iOS 26.0, *) {
      glassEffect(.regular.interactive(), in: Capsule())
    } else {
      // Liquid Glass adapts its own contrast to what is behind it. This
      // fallback cannot, and it may sit over a white wall in full-screen
      // mode, so it is opaque enough to carry bone and amber on its own.
      background(.black.opacity(0.62), in: Capsule())
        .overlay(Capsule().stroke(ApertureStyle.line, lineWidth: 1))
    }
  }

  /// Groups nearby glass so the system can blend and morph the shapes into
  /// one another instead of stacking independent panes. A no-op before 26.
  @ViewBuilder
  func apertureGlassGroup(spacing: CGFloat = 22) -> some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { self }
    } else {
      self
    }
  }

  /// Controls that sit on the app's own dark surface need no help. Over a
  /// live image they do, so full-screen mode carries a soft drop shadow
  /// rather than a scrim that would dim the photograph.
  @ViewBuilder
  func cameraControlLegibility(_ isOverLiveImage: Bool) -> some View {
    if isOverLiveImage {
      shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 1)
    } else {
      self
    }
  }
}

struct ApertureIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Over a live image the disc and its hairline disappear and only the glyph
  /// remains. This is a parameter rather than a second style so the button
  /// keeps one identity, and so Reduce Motion is still read from the
  /// environment of the style that SwiftUI actually installs.
  var isTransparent = false

  func makeBody(configuration: Configuration) -> some View {
    let side = isTransparent ? ApertureStyle.bareControlSize : ApertureStyle.controlSize
    return configuration.label
      .font(isTransparent ? .system(size: 18, weight: .medium) : nil)
      .frame(width: side, height: side)
      .foregroundStyle(ApertureStyle.bone.opacity(isEnabled ? 1 : 0.4))
      .background(
        Circle()
          .fill(
            ApertureStyle.panel
              .opacity(isTransparent ? 0 : (configuration.isPressed ? 0.98 : 0.86)))
      )
      .overlay(Circle().stroke(isTransparent ? Color.clear : ApertureStyle.line, lineWidth: 1))
      .contentShape(Circle())
      .opacity(isTransparent && configuration.isPressed ? 0.6 : 1)
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
