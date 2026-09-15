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
      recipe.parameters.lightLeakProbability > 0,
      recipe.parameters.lightLeakStrength > 0
    {
      leak = LightLeakDecision(
        edge: LightLeakDecision.Edge(rawValue: random.next() % 4) ?? .left,
        position: random.value(in: 0.16...0.84),
        width: random.value(in: 0.16...0.42),
        angle: random.value(in: -0.42...0.42),
        color: LightLeakDecision.palette[
          Int(random.next() % UInt64(LightLeakDecision.palette.count))],
        intensity: random.value(in: 0.68...1.0)
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
  enum Edge: UInt64, Hashable, Sendable {
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

  static let palette: [LightLeakColor] = [
    LightLeakColor(red: 1.0, green: 0.28, blue: 0.08),
    LightLeakColor(red: 1.0, green: 0.54, blue: 0.10),
    LightLeakColor(red: 0.98, green: 0.18, blue: 0.12),
    LightLeakColor(red: 1.0, green: 0.76, blue: 0.26),
  ]
}

struct LightLeakColor: Hashable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
}

struct FilmDateStampLayout: Hashable, Sendable {
  let text: String
  let frame: CGRect
  let fontPointSize: CGFloat

  /// The layout is defined as a fraction of the final pixel canvas, so a
  /// preview and a full-resolution render use the same geometry.
  static func make(text: String, canvasSize: CGSize) -> FilmDateStampLayout? {
    guard !text.isEmpty,
      canvasSize.width.isFinite,
      canvasSize.height.isFinite,
      canvasSize.width > 0,
      canvasSize.height > 0
    else { return nil }

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
      fontPointSize: fontSize
    )
  }
}
