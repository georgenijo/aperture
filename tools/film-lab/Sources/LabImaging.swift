import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct LabImageInfo: Sendable {
  let typeIdentifier: String
  /// Upright (orientation-applied) dimensions.
  let width: Int
  let height: Int
  let orientation: UInt32
  let colorModel: String?
  let profileName: String?
}

enum LabImaging {
  static let supportedTypes: Set<String> = [
    "public.jpeg", "public.png", "public.heic", "public.heif",
  ]
  static let defaultMaximumPixels = 60_000_000

  /// Reads the header only; nothing is decoded until the pixel budget passes.
  static func inspect(_ url: URL, maximumPixels: Int = defaultMaximumPixels) throws -> LabImageInfo {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
      let type = CGImageSourceGetType(source) as String?
    else {
      throw LabError("unsupported-image", "The file is not a readable image.")
    }
    guard supportedTypes.contains(type) else {
      throw LabError("unsupported-image", "Only JPEG, PNG and HEIC photographs are supported.")
    }
    // ImageIO decodes a cut-off PNG or JPEG leniently (grey below the cut)
    // and still reports it complete, which would silently skew a reference.
    guard CGImageSourceGetStatus(source) == .statusComplete, hasCompleteTrailer(url, type: type)
    else {
      throw LabError("unsupported-image", "The image file is incomplete or damaged.")
    }
    guard CGImageSourceGetCount(source) >= 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
      let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      pixelWidth > 0, pixelHeight > 0
    else {
      throw LabError("unsupported-image", "The image has no readable dimensions.")
    }
    guard pixelWidth <= 20_000, pixelHeight <= 20_000,
      pixelWidth * pixelHeight <= maximumPixels
    else {
      throw LabError(
        "image-too-large",
        "The image is \(pixelWidth)×\(pixelHeight); the limit is \(maximumPixels / 1_000_000) MP.")
    }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    let swapsAxes = (5...8).contains(orientation)
    return LabImageInfo(
      typeIdentifier: type,
      width: swapsAxes ? pixelHeight : pixelWidth,
      height: swapsAxes ? pixelWidth : pixelHeight,
      orientation: orientation,
      colorModel: properties[kCGImagePropertyColorModel] as? String,
      profileName: properties[kCGImagePropertyProfileName] as? String)
  }

  /// A PNG's IEND chunk and a JPEG's EOI marker sit in the last kilobyte
  /// (writers may append a short trailer). HEIC is left to ImageIO.
  static func hasCompleteTrailer(_ url: URL, type: String) -> Bool {
    guard type == "public.png" || type == "public.jpeg" else { return true }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return false }
    let window: UInt64 = 1024
    guard (try? handle.seek(toOffset: size > window ? size - window : 0)) != nil,
      let tail = try? handle.readToEnd()
    else { return false }
    let bytes = [UInt8](tail)
    if type == "public.png" {
      let iend: [UInt8] = [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
      return bytes.count >= iend.count
        && (0...(bytes.count - iend.count)).contains { Array(bytes[$0..<($0 + iend.count)]) == iend }
    }
    return zip(bytes, bytes.dropFirst()).contains { $0 == 0xFF && $1 == 0xD9 }
  }

  /// An effect-free recipe: the source goes through the shared decode,
  /// orientation and resize path and nothing else, so an "original" preview
  /// is pixel-aligned with the processed preview at the same size.
  static let originalRecipe = AppliedFilmRecipe(
    identifier: FilmRecipeIdentifier(rawValue: "aperture.film-lab.original"),
    version: FilmRecipeVersion.current,
    seed: 0,
    stages: [],
    resolvedSettings: FilmResolvedSettings(
      lightLeakApplied: false, dateStampConfiguration: .off, dateStampText: nil,
      timeZoneIdentifier: "UTC"))

  /// Renders through `FilmProcessor.shared` exactly as the app's still path
  /// does: `process(Data, …)` decodes and orients, the graph is built from the
  /// applied recipe, then `encodedData` writes the JPEG. No source metadata is
  /// forwarded, so camera EXIF and GPS never reach the output; ImageIO still
  /// writes its own minimal Exif block (pixel dimensions and colour space).
  static func renderJPEG(
    source: URL, recipe: AppliedFilmRecipe, renderSize: FilmRenderSize, quality: Double,
    maximumPixels: Int = defaultMaximumPixels
  ) throws -> (data: Data, width: Int, height: Int) {
    _ = try inspect(source, maximumPixels: maximumPixels)
    return try autoreleasepool {
      let sourceData = try Data(contentsOf: source)
      let image = try FilmProcessor.shared.process(
        sourceData, recipe: recipe, renderSize: renderSize)
      let data = try FilmProcessor.shared.encodedData(
        image, format: .jpeg, quality: CGFloat(quality), metadataSource: nil)
      return (data, Int(image.extent.width), Int(image.extent.height))
    }
  }

  /// The same graph rendered to RGBA8 without JPEG loss, for fidelity checks.
  static func renderRGBA(
    source: URL, recipe: AppliedFilmRecipe, renderSize: FilmRenderSize
  ) throws -> LabBitmap {
    try autoreleasepool {
      let sourceData = try Data(contentsOf: source)
      let image = try FilmProcessor.shared.process(
        sourceData, recipe: recipe, renderSize: renderSize)
      // `thumbnail` at the image's own size is a scale-1 render through the
      // shared context (`FilmOutputFormat` offers no lossless format).
      let extent = image.extent
      let cgImage = try FilmProcessor.shared.thumbnail(
        image, maxPixelDimension: Int(max(extent.width, extent.height)))
      return try LabBitmap(cgImage)
    }
  }

  static func writeAtomically(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: [.atomic])
    } catch {
      throw LabError("write-failed", "Cannot write the rendered image.")
    }
  }
}

/// Canonical sRGB RGBA8 pixels, drawn the way `GoldenRenderTests` compares.
struct LabBitmap: Equatable {
  let width: Int
  let height: Int
  let bytes: [UInt8]

  init(width: Int, height: Int, bytes: [UInt8]) {
    self.width = width
    self.height = height
    self.bytes = bytes
  }

  init(decoding data: Data) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw LabError("decode-failed", "Cannot decode image data.") }
    try self.init(image)
  }

  init(_ image: CGImage) throws {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { throw LabError("decode-failed", "Cannot rasterize image.") }
    self.init(width: width, height: height, bytes: bytes)
  }

  struct Difference {
    let maximum: Int
    let mean: Double
    let over1: Int
  }

  func difference(from other: LabBitmap) -> Difference? {
    guard width == other.width, height == other.height else { return nil }
    var maximum = 0
    var total = 0
    var over1 = 0
    for index in bytes.indices where index % 4 != 3 {
      let delta = abs(Int(bytes[index]) - Int(other.bytes[index]))
      maximum = max(maximum, delta)
      total += delta
      if delta > 1 { over1 += 1 }
    }
    return Difference(
      maximum: maximum, mean: Double(total) / Double(width * height * 3), over1: over1)
  }

  var meanLuminance: Double {
    var total = 0.0
    for pixel in stride(from: 0, to: bytes.count, by: 4) {
      total += 0.2126 * Double(bytes[pixel]) + 0.7152 * Double(bytes[pixel + 1])
        + 0.0722 * Double(bytes[pixel + 2])
    }
    return total / Double(width * height)
  }
}
