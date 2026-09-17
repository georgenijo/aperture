import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Native Core Image overlays shared by still and video processing. The
/// factory owns geometry and rasterization caps so previews and exports use
/// the same placement without allocating a full-resolution bitmap.
enum FilmOverlayFactory {
  static func dateStampLayout(text: String, canvasSize: CGSize) -> FilmDateStampLayout? {
    FilmDateStampLayout.make(text: text, canvasSize: canvasSize)
  }

  static func dateStampImage(
    text: String, extent: CGRect, style: DateStampStage.Style = .monospaced
  ) -> CIImage? {
    guard let layout = dateStampLayout(text: text, canvasSize: extent.size),
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
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else { return nil }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    let fontSize = layout.fontPointSize * scale
    let fontName: CFString
    switch style {
    case .monospaced: fontName = "SFMono-Semibold" as CFString
    }
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
}
