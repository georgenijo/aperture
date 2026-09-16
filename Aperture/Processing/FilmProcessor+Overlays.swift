import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Native Core Image overlays shared by still and video processing. The
/// factory owns geometry and rasterization caps so previews and exports use
/// the same placement without allocating a full-resolution bitmap.
enum FilmOverlayFactory {
  static func dateStampLayout(
    text: String, canvasSize: CGSize, stage: DateStampStage = DateStampStage()
  ) -> FilmDateStampLayout? {
    FilmDateStampLayout.make(text: text, canvasSize: canvasSize, style: stage)
  }

  static func dateStampImage(
    text: String, extent: CGRect, stage: DateStampStage = DateStampStage()
  ) -> CIImage? {
    guard let layout = dateStampLayout(text: text, canvasSize: extent.size, stage: stage),
      extent.width.isFinite,
      extent.height.isFinite,
      extent.width > 0,
      extent.height > 0
    else { return nil }

    // Keep CPU memory bounded for full-resolution stills while preserving
    // the exact normalized layout when the overlay is scaled back up.
    let cap = min(4096, max(1, Int(ceil(max(extent.width, extent.height)))))
    let scale = min(1, CGFloat(cap) / max(extent.width, extent.height))
    let width = max(1, Int(ceil(extent.width * scale)))
    let height = max(1, Int(ceil(extent.height * scale)))
    guard width <= 4096,
      height <= 4096,
      width <= Int.max / 4,
      height <= Int.max / (width * 4)
    else { return nil }

    switch stage.style {
    case .monospaced:
      return monospacedImage(text: text, extent: extent, layout: layout, scale: scale, width: width, height: height)
    case .sevenSegment:
      return sevenSegmentImage(
        text: text, extent: extent, stage: stage, layout: layout, scale: scale, width: width,
        height: height)
    }
  }

  private static func makeContext(width: Int, height: Int) -> CGContext? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    return CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )
  }

  // MARK: - Monospaced (SF Mono, CoreText). Kept byte-identical to the
  // pre-existing render so `GoldenRenderTests` are unaffected.

  private static func monospacedImage(
    text: String, extent: CGRect, layout: FilmDateStampLayout, scale: CGFloat, width: Int,
    height: Int
  ) -> CIImage? {
    guard let context = makeContext(width: width, height: height) else { return nil }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    let fontSize = layout.fontPointSize * scale
    let fontName = "SFMono-Semibold" as CFString
    let font = CTFontCreateWithName(fontName, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
        red: 1.0, green: 0.58, blue: 0.22, alpha: 0.90),
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
    let frame = CGRect(
      x: layout.frame.minX * scale,
      y: layout.frame.minY * scale,
      width: layout.frame.width * scale,
      height: layout.frame.height * scale
    )
    context.textPosition = CGPoint(
      x: frame.minX, y: frame.minY + max(0, (frame.height - fontSize) * 0.35))
    context.setShadow(
      offset: CGSize(width: fontSize * 0.07, height: -fontSize * 0.07),
      blur: fontSize * 0.08,
      color: CGColor(gray: 0.02, alpha: 0.82)
    )
    CTLineDraw(line, context)
    guard let cgImage = context.makeImage() else { return nil }
    return CIImage(cgImage: cgImage)
      .transformed(
        by: CGAffineTransform(
          scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
      )
      .cropped(to: CGRect(x: 0, y: 0, width: extent.width, height: extent.height))
  }

  // MARK: - Seven-segment (no fonts; CGPath rectangles), with an orange
  // glow. Used by the Huji-style 1998 recipe.

  /// a=top, b=top-right, c=bottom-right, d=bottom, e=bottom-left,
  /// f=top-left, g=middle. Standard LED digit table.
  private static let sevenSegmentTable: [Int: Set<Character>] = [
    0: ["a", "b", "c", "d", "e", "f"],
    1: ["b", "c"],
    2: ["a", "b", "d", "e", "g"],
    3: ["a", "b", "c", "d", "g"],
    4: ["b", "c", "f", "g"],
    5: ["a", "c", "d", "f", "g"],
    6: ["a", "c", "d", "e", "f", "g"],
    7: ["a", "b", "c"],
    8: ["a", "b", "c", "d", "e", "f", "g"],
    9: ["a", "b", "c", "d", "f", "g"],
  ]

  /// Exposed for tests: the standard lit-segment set for a digit 0-9, or
  /// `nil` outside that range.
  static func sevenSegmentLitSegments(for digit: Int) -> Set<Character>? {
    sevenSegmentTable[digit]
  }

  private static func sevenSegmentDigitPath(
    _ digit: Int, boxWidth bw: CGFloat, boxHeight bh: CGFloat, thickness t: CGFloat
  ) -> CGPath {
    let path = CGMutablePath()
    guard let lit = sevenSegmentTable[digit] else { return path }
    // Classic LED layout: the three horizontal bars sit between the vertical
    // bars (not over them), and every bar stops one `gap` short of its
    // neighbours so the segments read as separate lit strips rather than a
    // fused blob or a row of dots.
    let gap = t * 0.30
    let horizontalX = t + gap
    let horizontalWidth = max(0, bw - 2 * (t + gap))
    if lit.contains("a") {
      path.addRect(CGRect(x: horizontalX, y: bh - t, width: horizontalWidth, height: t))
    }
    if lit.contains("d") {
      path.addRect(CGRect(x: horizontalX, y: 0, width: horizontalWidth, height: t))
    }
    if lit.contains("g") {
      path.addRect(CGRect(x: horizontalX, y: (bh - t) / 2, width: horizontalWidth, height: t))
    }
    let topVertStart = bh / 2 + t / 2 + gap
    let topVertEnd = bh - t - gap
    let bottomVertStart = t + gap
    let bottomVertEnd = bh / 2 - t / 2 - gap
    let topVertHeight = max(0, topVertEnd - topVertStart)
    let bottomVertHeight = max(0, bottomVertEnd - bottomVertStart)
    if lit.contains("f") {
      path.addRect(CGRect(x: 0, y: topVertStart, width: t, height: topVertHeight))
    }
    if lit.contains("b") {
      path.addRect(CGRect(x: bw - t, y: topVertStart, width: t, height: topVertHeight))
    }
    if lit.contains("e") {
      path.addRect(CGRect(x: 0, y: bottomVertStart, width: t, height: bottomVertHeight))
    }
    if lit.contains("c") {
      path.addRect(CGRect(x: bw - t, y: bottomVertStart, width: t, height: bottomVertHeight))
    }
    return path
  }

  private static func sevenSegmentApostrophePath(
    advance: CGFloat, fontSize: CGFloat, thickness t: CGFloat
  ) -> CGPath {
    let path = CGMutablePath()
    let w = max(1, t * 0.85)
    let h = max(1, t * 1.5)
    let x = max(0, (advance - w) / 2)
    let y = fontSize * 0.74
    path.addRect(CGRect(x: x, y: y, width: w, height: h))
    return path
  }

  /// Builds the complete, already-skewed glyph path for `text` in local
  /// coordinates: x runs 0...textWidth along the advance direction, y runs
  /// 0 (baseline) ... fontSize (glyph cell top). Callers translate/rotate
  /// this path into place with a CGContext transform.
  private static func sevenSegmentPath(for text: String, fontSize: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let thickness = fontSize * 0.11
    var x: CGFloat = 0
    for character in text {
      let advance = FilmDateStampLayout.sevenSegmentAdvance(for: character, fontSize: fontSize)
      if character.isNumber, let digit = character.wholeNumberValue, (0...9).contains(digit) {
        let boxWidth = fontSize * 0.50
        let boxHeight = fontSize * 0.92
        let dx = x + max(0, (advance - boxWidth) / 2)
        let dy = (fontSize - boxHeight) / 2
        let digitPath = sevenSegmentDigitPath(
          digit, boxWidth: boxWidth, boxHeight: boxHeight, thickness: thickness)
        path.addPath(digitPath, transform: CGAffineTransform(translationX: dx, y: dy))
      } else if character == "'" {
        let apostrophePath = sevenSegmentApostrophePath(
          advance: advance, fontSize: fontSize, thickness: thickness)
        path.addPath(apostrophePath, transform: CGAffineTransform(translationX: x, y: 0))
      }
      x += advance
    }
    // A slight italic shear for the LED look.
    var skew = CGAffineTransform(a: 1, b: 0, c: tan(6 * CGFloat.pi / 180), d: 1, tx: 0, ty: 0)
    return path.copy(using: &skew) ?? path
  }

  private static func sevenSegmentImage(
    text: String, extent: CGRect, stage: DateStampStage, layout: FilmDateStampLayout,
    scale: CGFloat, width: Int, height: Int
  ) -> CIImage? {
    let fontSize = layout.fontPointSize * scale
    let frame = CGRect(
      x: layout.frame.minX * scale,
      y: layout.frame.minY * scale,
      width: layout.frame.width * scale,
      height: layout.frame.height * scale
    )
    let glyphPath = sevenSegmentPath(for: text, fontSize: fontSize)
    // Tag the fill colour explicitly as sRGB (matching the raster context's
    // colour space) rather than using the `CGColor(red:green:blue:alpha:)`
    // convenience initializer, which creates a Device RGB colour and gets
    // silently colour-matched (brightened) when filled into an sRGB
    // context — that shift would fight the persisted (red, green, blue).
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let color =
      CGColor(
        colorSpace: colorSpace,
        components: [CGFloat(stage.red), CGFloat(stage.green), CGFloat(stage.blue), 1]
      )
      ?? CGColor(red: CGFloat(stage.red), green: CGFloat(stage.green), blue: CGFloat(stage.blue), alpha: 1)

    func rasterize(alpha: CGFloat) -> CIImage? {
      guard let context = makeContext(width: width, height: height) else { return nil }
      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      context.saveGState()
      context.translateBy(x: frame.minX, y: frame.minY)
      if layout.rotation != 0 {
        context.rotate(by: layout.rotation)
      }
      context.setAlpha(alpha)
      context.setFillColor(color)
      context.addPath(glyphPath)
      context.fillPath()
      context.restoreGState()
      guard let cgImage = context.makeImage() else { return nil }
      return CIImage(cgImage: cgImage)
    }

    guard let crisp = rasterize(alpha: CGFloat(stage.alpha)) else { return nil }
    guard let glowSource = rasterize(alpha: CGFloat(stage.glowAlpha)) else { return nil }

    let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
    blur.setValue(glowSource, forKey: kCIInputImageKey)
    blur.setValue(CGFloat(stage.glowRadiusScale) * fontSize, forKey: kCIInputRadiusKey)
    guard let glow = blur.outputImage?.cropped(to: bounds) else { return nil }

    guard let composite = CIFilter(name: "CISourceOverCompositing") else { return nil }
    composite.setValue(crisp, forKey: kCIInputImageKey)
    composite.setValue(glow, forKey: kCIInputBackgroundImageKey)
    guard let combined = composite.outputImage?.cropped(to: bounds) else { return nil }

    return combined
      .transformed(
        by: CGAffineTransform(
          scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
      )
      .cropped(to: CGRect(x: 0, y: 0, width: extent.width, height: extent.height))
  }
}
