import CoreGraphics
import Foundation

/// A target size for deterministic full-resolution or preview rendering.
struct FilmRenderSize: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case full
    case preview(maxPixelDimension: Int)
  }

  let kind: Kind

  static let full = FilmRenderSize(kind: .full)

  static func preview(maxPixelDimension: Int) -> FilmRenderSize {
    FilmRenderSize(kind: .preview(maxPixelDimension: maxPixelDimension))
  }
}

enum FilmOutputFormat: Hashable, Sendable {
  case heic
  case jpeg

  var uniformTypeIdentifier: String {
    switch self {
    case .heic: "public.heic"
    case .jpeg: "public.jpeg"
    }
  }
}

enum FilmProcessorError: LocalizedError, Equatable {
  case invalidSourceExtent
  case decodeFailed
  case invalidRenderSize
  case unsupportedRecipeVersion(Int)
  case missingDateStampText
  case renderFailed
  case cannotCreateDestination
  case cannotFinalizeDestination
  case unsupportedOutputFormat(FilmOutputFormat)

  var errorDescription: String? {
    switch self {
    case .invalidSourceExtent: "The source image has no finite, drawable extent."
    case .decodeFailed: "The source image data could not be decoded."
    case .invalidRenderSize: "The requested render size is invalid."
    case .unsupportedRecipeVersion(let version): "Unsupported film recipe version: \(version)."
    case .missingDateStampText:
      "The applied recipe requests a date stamp but has no persisted stamp text."
    case .renderFailed: "Core Image could not render the processed image."
    case .cannotCreateDestination: "The requested image destination could not be created."
    case .cannotFinalizeDestination: "The image destination failed to finalize."
    case .unsupportedOutputFormat(let format): "The output format is not supported: \(format)."
    }
  }
}

/// All random choices are made from the applied recipe snapshot and are safe to
/// persist in tests, thumbnail keys, and media metadata.
struct FilmProcessingDecision: Hashable, Sendable {
  let seed: UInt64
  let leak: LightLeakDecision?
  let grainSeed: UInt64
  let redChannelShift: Double
  let blueChannelShift: Double

  static func make(for recipe: AppliedFilmRecipe) -> FilmProcessingDecision {
    var random = SeededRandomNumberGenerator(seed: recipe.seed ^ 0xA5A5_5A5A_3141_5926)
    let leak: LightLeakDecision?
    if recipe.resolvedSettings.lightLeakApplied,
      let leakStage = recipe.stages.lightLeak,
      leakStage.probability > 0,
      leakStage.strength > 0
    {
      let edges = leakStage.edges.isEmpty ? LightLeakDecision.Edge.allCases : leakStage.edges
      leak = LightLeakDecision(
        edge: edges[Int(random.next() % UInt64(edges.count))],
        position: random.value(in: leakStage.minPosition...leakStage.maxPosition),
        width: random.value(in: leakStage.minWidth...leakStage.maxWidth),
        angle: random.value(in: leakStage.minAngle...leakStage.maxAngle),
        color: leakStage.palette[Int(random.next() % UInt64(leakStage.palette.count))],
        intensity: random.value(in: leakStage.minIntensity...leakStage.maxIntensity)
      )
    } else {
      leak = nil
    }

    return FilmProcessingDecision(
      seed: recipe.seed,
      leak: leak,
      grainSeed: random.next(),
      redChannelShift: random.value(in: 0.25...1.0),
      blueChannelShift: random.value(in: 0.25...1.0)
    )
  }
}

struct LightLeakDecision: Hashable, Sendable {
  enum Edge: String, CaseIterable, Codable, Hashable, Sendable {
    case left
    case right
    case top
    case bottom
  }

  let edge: Edge
  let position: Double
  let width: Double
  let angle: Double
  let color: LightLeakColor
  let intensity: Double

  static let palette: [LightLeakColor] = LightLeakStage.defaultPalette
}

struct LightLeakColor: Codable, Hashable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
}

struct FilmDateStampLayout: Hashable, Sendable {
  let text: String
  let frame: CGRect
  let fontPointSize: CGFloat
  /// Radians. The frame above is defined in the *unrotated* local space;
  /// renderers apply this rotation about `frame.origin` so the raster is
  /// drawn already rotated. `0` for every layout except portrait
  /// `.sevenSegment`, which reads bottom-to-top along the left edge.
  let rotation: CGFloat

  /// The layout is defined as a fraction of the final pixel canvas, so a
  /// preview and a full-resolution render use the same geometry. Defaults to
  /// `.monospaced` so existing call sites keep working unchanged.
  static func make(text: String, canvasSize: CGSize) -> FilmDateStampLayout? {
    make(text: text, canvasSize: canvasSize, style: DateStampStage())
  }

  /// `style` carries both the rendering style and the geometry knobs
  /// `.sevenSegment` needs (font/margin scales); `.monospaced` ignores them
  /// and keeps its original hard-coded geometry byte-identical.
  static func make(text: String, canvasSize: CGSize, style: DateStampStage)
    -> FilmDateStampLayout?
  {
    guard !text.isEmpty,
      canvasSize.width.isFinite,
      canvasSize.height.isFinite,
      canvasSize.width > 0,
      canvasSize.height > 0
    else { return nil }

    switch style.style {
    case .monospaced:
      let shortestSide = min(canvasSize.width, canvasSize.height)
      let fontSize = max(10, shortestSide * 0.025)
      let width = min(
        canvasSize.width * 0.42, max(fontSize * CGFloat(text.count) * 0.61, fontSize * 2))
      let height = fontSize * 1.35
      let margin = shortestSide * 0.035
      return FilmDateStampLayout(
        text: text,
        frame: CGRect(
          x: canvasSize.width - width - margin,
          y: margin,
          width: width,
          height: height
        ),
        fontPointSize: fontSize,
        rotation: 0
      )

    case .sevenSegment:
      let shortestSide = min(canvasSize.width, canvasSize.height)
      let fontSize = max(10, shortestSide * CGFloat(style.fontSizeScale))
      let textWidth = Self.sevenSegmentTextWidth(text, fontSize: fontSize)
      let edgeMargin = shortestSide * CGFloat(style.edgeMarginScale)
      let endMargin = shortestSide * CGFloat(style.endMarginScale)
      let isPortrait = canvasSize.height > canvasSize.width

      if isPortrait {
        // Bottom-left origin coordinate space (Core Graphics/Core Image
        // convention: y increases upward). The frame below is the
        // *unrotated* text box with width = textWidth (the advance
        // direction) and height = fontSize (the glyph cell). Rotating it by
        // +90° about its own origin sweeps the advance direction from +x to
        // +y — the text climbs upward from that pivot — while the glyph-cell
        // height sweeps from +y to -x, so the glyphs occupy
        // x: [pivot - fontSize, pivot]. Pivoting at `edgeMargin + fontSize`
        // therefore leaves exactly `edgeMargin` between the image's left
        // edge and the nearest glyph edge, regardless of font size.
        return FilmDateStampLayout(
          text: text,
          frame: CGRect(
            x: edgeMargin + fontSize, y: endMargin, width: textWidth, height: fontSize),
          fontPointSize: fontSize,
          rotation: .pi / 2
        )
      } else {
        // Landscape: no rotation. Anchor the box's right edge `edgeMargin`
        // from the canvas's right edge and its bottom `endMargin` from the
        // canvas's bottom, i.e. bottom-right.
        return FilmDateStampLayout(
          text: text,
          frame: CGRect(
            x: canvasSize.width - edgeMargin - textWidth,
            y: endMargin,
            width: textWidth,
            height: fontSize
          ),
          fontPointSize: fontSize,
          rotation: 0
        )
      }
    }
  }

  /// Deterministic glyph advances for the seven-segment style: no fonts
  /// involved, so width is a simple per-character sum.
  static func sevenSegmentAdvance(for character: Character, fontSize: CGFloat) -> CGFloat {
    switch character {
    case " ": return fontSize * 0.45
    case "'": return fontSize * 0.25
    default: return fontSize * 0.62
    }
  }

  static func sevenSegmentTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
    text.reduce(CGFloat(0)) { $0 + sevenSegmentAdvance(for: $1, fontSize: fontSize) }
  }
}
