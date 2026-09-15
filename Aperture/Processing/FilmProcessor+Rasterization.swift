import CoreGraphics
import CoreImage
import Foundation

extension FilmProcessor {
  static func normalized(_ image: CIImage, orientation: CGImagePropertyOrientation) throws
    -> CIImage
  {
    let oriented = image.oriented(forExifOrientation: Int32(bitPattern: orientation.rawValue))
    let extent = try finiteExtent(oriented.extent)
    return
      oriented
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
      .cropped(to: CGRect(origin: .zero, size: extent.size))
  }

  static func scaled(_ image: CIImage, to renderSize: FilmRenderSize) throws -> CIImage {
    let extent = try finiteExtent(image.extent)
    let scale: CGFloat
    switch renderSize.kind {
    case .full:
      scale = 1
    case .preview(let maxPixelDimension):
      guard maxPixelDimension > 0 else { throw FilmProcessorError.invalidRenderSize }
      scale = min(1, CGFloat(maxPixelDimension) / max(extent.width, extent.height))
    }
    let width = max(1, (extent.width * scale).rounded(.down))
    let height = max(1, (extent.height * scale).rounded(.down))
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    return
      image
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .cropped(to: bounds)
  }

  static func finiteExtent(_ extent: CGRect) throws -> CGRect {
    guard extent.origin.x.isFinite,
      extent.origin.y.isFinite,
      extent.width.isFinite,
      extent.height.isFinite,
      extent.width > 0,
      extent.height > 0,
      extent.width <= CGFloat(Int32.max),
      extent.height <= CGFloat(Int32.max)
    else {
      throw FilmProcessorError.invalidSourceExtent
    }
    return extent
  }

  static func makeNoiseImage(extent: CGRect, grainSize: Double, seed: UInt64) -> CIImage? {
    let scale = max(0.25, min(3, grainSize))
    let width = min(2048, max(1, Int(ceil(extent.width / scale))))
    let height = min(2048, max(1, Int(ceil(extent.height / scale))))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    var random = SeededRandomNumberGenerator(seed: seed)
    for index in 0..<width * height {
      let value = UInt8(truncatingIfNeeded: random.next() >> 56)
      let offset = index * 4
      bytes[offset] = value
      bytes[offset + 1] = value
      bytes[offset + 2] = value
      bytes[offset + 3] = 255
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard
      let cgImage = bytes.withUnsafeMutableBytes({ buffer -> CGImage? in
        guard let baseAddress = buffer.baseAddress,
          let bitmap = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
          )
        else { return nil }
        return bitmap.makeImage()
      })
    else { return nil }
    let noise = CIImage(cgImage: cgImage)
    return
      noise
      .transformed(
        by: CGAffineTransform(
          scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
      )
      .cropped(to: CGRect(x: 0, y: 0, width: extent.width, height: extent.height))
  }

  static func makeLightLeakImage(
    extent: CGRect,
    decision: LightLeakDecision,
    strength: Double
  ) -> CIImage? {
    let width = min(2048, max(1, Int(ceil(extent.width))))
    let height = min(2048, max(1, Int(ceil(extent.height))))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let color = decision.color
    for y in 0..<height {
      for x in 0..<width {
        let u = Double(x) / Double(max(1, width - 1))
        let v = Double(y) / Double(max(1, height - 1))
        let edgeDistance: Double
        let along: Double
        switch decision.edge {
        case .left:
          edgeDistance = u
          along = v
        case .right:
          edgeDistance = 1 - u
          along = v
        case .top:
          edgeDistance = 1 - v
          along = u
        case .bottom:
          edgeDistance = v
          along = u
        }
        let alongOffset = along - decision.position
        let edgeFalloff = exp(-edgeDistance / max(0.035, decision.width))
        let stripe = exp(
          -(alongOffset * alongOffset) / max(0.018, decision.width * decision.width * 0.34))
        let directional = 0.82 + 0.18 * sin((u + v) * 12 + decision.angle * 5)
        let alpha = min(
          0.85, max(0, strength) * decision.intensity * edgeFalloff * stripe * directional)
        let offset = (y * width + x) * 4
        // The bitmap declares premultiplied alpha; write premultiplied
        // RGB to avoid bright fringes at transparent leak edges.
        bytes[offset] = UInt8(min(255, max(0, color.red * alpha * 255)))
        bytes[offset + 1] = UInt8(min(255, max(0, color.green * alpha * 255)))
        bytes[offset + 2] = UInt8(min(255, max(0, color.blue * alpha * 255)))
        bytes[offset + 3] = UInt8(min(255, max(0, alpha * 255)))
      }
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard
      let cgImage = bytes.withUnsafeMutableBytes({ buffer -> CGImage? in
        guard let baseAddress = buffer.baseAddress,
          let bitmap = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
          )
        else { return nil }
        return bitmap.makeImage()
      })
    else { return nil }
    return CIImage(cgImage: cgImage)
      .transformed(
        by: CGAffineTransform(
          scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
      )
      .cropped(to: CGRect(x: 0, y: 0, width: extent.width, height: extent.height))
  }
}
