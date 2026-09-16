import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Deterministic, local Core Image development for still captures.
///
/// The processor never consults app settings, the current date, locale, or a
/// global random source while rendering. Every visual choice comes from the
/// `AppliedFilmRecipe` snapshot and the explicit persisted date-stamp text.
final class FilmProcessor: @unchecked Sendable {
  static let shared = FilmProcessor()

  private let context: CIContext
  private let renderQueue = DispatchQueue(
    label: "com.aperture.film-processor",
    qos: .userInitiated,
    attributes: .concurrent,
    autoreleaseFrequency: .workItem
  )
  private let permits = DispatchSemaphore(value: 2)
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  init(context: CIContext? = nil) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    self.context =
      context
      ?? CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: true,
      ])
  }

  /// Build a lazy Core Image graph synchronously. `processAsync` and
  /// `renderedCGImage` provide bounded off-main-queue variants.
  func process(
    _ source: CIImage,
    recipe: AppliedFilmRecipe,
    orientation: CGImagePropertyOrientation = .up,
    renderSize: FilmRenderSize = .full
  ) throws -> CIImage {
    try withPermit {
      try build(source, recipe: recipe, orientation: orientation, renderSize: renderSize)
    }
  }

  func process(
    _ source: CGImage,
    recipe: AppliedFilmRecipe,
    orientation: CGImagePropertyOrientation = .up,
    renderSize: FilmRenderSize = .full
  ) throws -> CIImage {
    try process(
      CIImage(cgImage: source), recipe: recipe, orientation: orientation, renderSize: renderSize)
  }

  /// Decode a camera still and preserve its EXIF orientation before the
  /// effects graph is built. The resulting CIImage is always upright.
  func process(
    _ data: Data,
    recipe: AppliedFilmRecipe,
    renderSize: FilmRenderSize = .full
  ) throws -> CIImage {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    else {
      throw FilmProcessorError.decodeFailed
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
    let orientationValue = properties?[kCGImagePropertyOrientation] as? NSNumber
    let orientation =
      orientationValue.flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
    return try process(cgImage, recipe: recipe, orientation: orientation, renderSize: renderSize)
  }

  func processAsync(
    _ source: CIImage,
    recipe: AppliedFilmRecipe,
    orientation: CGImagePropertyOrientation = .up,
    renderSize: FilmRenderSize = .full
  ) async throws -> CIImage {
    try await withCheckedThrowingContinuation { continuation in
      renderQueue.async {
        do {
          continuation.resume(
            returning: try self.process(
              source,
              recipe: recipe,
              orientation: orientation,
              renderSize: renderSize
            ))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Render the graph to a concrete sRGB image. The semaphore bounds graph
  /// construction and the potentially expensive GPU/CPU evaluation.
  func renderedCGImage(
    _ source: CIImage,
    recipe: AppliedFilmRecipe,
    orientation: CGImagePropertyOrientation = .up,
    renderSize: FilmRenderSize = .full
  ) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      renderQueue.async {
        do {
          let output = try self.withPermit {
            let image = try self.build(
              source,
              recipe: recipe,
              orientation: orientation,
              renderSize: renderSize
            )
            let extent = try Self.finiteExtent(image.extent)
            guard
              let output = self.context.createCGImage(
                image,
                from: extent,
                format: .RGBA8,
                colorSpace: self.sRGB
              )
            else {
              throw FilmProcessorError.renderFailed
            }
            return output
          }
          continuation.resume(returning: output)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Encode a finite sRGB Core Image image through Image I/O.
  func encode(
    _ image: CIImage,
    to url: URL,
    format: FilmOutputFormat,
    quality: CGFloat = 0.92
  ) throws {
    try withPermit {
      let extent = try Self.finiteExtent(image.extent)
      guard
        let cgImage = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: sRGB)
      else {
        throw FilmProcessorError.renderFailed
      }
      guard
        let destination = CGImageDestinationCreateWithURL(
          url as CFURL,
          format.uniformTypeIdentifier as CFString,
          1,
          nil
        )
      else {
        throw FilmProcessorError.cannotCreateDestination
      }
      let clampedQuality = min(max(quality.isFinite ? quality : 0.92, 0), 1)
      let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: clampedQuality]
      CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw FilmProcessorError.cannotFinalizeDestination
      }
    }
  }

  func encodedData(
    _ image: CIImage,
    format: FilmOutputFormat,
    quality: CGFloat = 0.92
  ) throws -> Data {
    try withPermit {
      let extent = try Self.finiteExtent(image.extent)
      guard
        let cgImage = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: sRGB)
      else {
        throw FilmProcessorError.renderFailed
      }
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          output,
          format.uniformTypeIdentifier as CFString,
          1,
          nil
        )
      else {
        throw FilmProcessorError.cannotCreateDestination
      }
      let clampedQuality = min(max(quality.isFinite ? quality : 0.92, 0), 1)
      let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: clampedQuality]
      CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw FilmProcessorError.cannotFinalizeDestination
      }
      return output as Data
    }
  }

  /// Downsample a processed image without changing full-resolution output.
  func thumbnail(_ image: CIImage, maxPixelDimension: Int) throws -> CGImage {
    try withPermit {
      guard maxPixelDimension > 0 else { throw FilmProcessorError.invalidRenderSize }
      let extent = try Self.finiteExtent(image.extent)
      let scale = min(1, CGFloat(maxPixelDimension) / max(extent.width, extent.height))
      let target = CGRect(
        x: 0,
        y: 0,
        width: max(1, (extent.width * scale).rounded(.down)),
        height: max(1, (extent.height * scale).rounded(.down))
      )
      let transformed =
        image
        .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .cropped(to: target)
      guard
        let result = context.createCGImage(
          transformed, from: target, format: .RGBA8, colorSpace: sRGB)
      else {
        throw FilmProcessorError.renderFailed
      }
      return result
    }
  }

  private func build(
    _ source: CIImage,
    recipe: AppliedFilmRecipe,
    orientation: CGImagePropertyOrientation,
    renderSize: FilmRenderSize
  ) throws -> CIImage {
    guard FilmRecipeVersion.supported.contains(recipe.version) else {
      throw FilmProcessorError.unsupportedRecipeVersion(recipe.version)
    }
    let dateStampText = recipe.resolvedSettings.dateStampText
    if recipe.resolvedSettings.dateStampConfiguration.mode != .off, dateStampText == nil {
      throw FilmProcessorError.missingDateStampText
    }

    let normalized = try Self.normalized(source, orientation: orientation)
    let sized = try Self.scaled(normalized, to: renderSize)
    let bounds = try Self.finiteExtent(sized.extent)
    let decision = FilmProcessingDecision.make(for: recipe)

    var image = sized.cropped(to: bounds)
    for stage in recipe.stages {
      switch stage {
      case .colorGrade(let grade):
        image = applyColorGrade(image, grade: grade, extent: bounds)
      case .halation(let halationStage):
        image = applyHalation(image, stage: halationStage, extent: bounds)
      case .softness(let softnessStage):
        image = applySoftness(image, stage: softnessStage, extent: bounds)
      case .chromaticAberration(let aberrationStage):
        image = applyChromaticAberration(
          image, stage: aberrationStage, decision: decision, extent: bounds)
      case .grain(let grainStage):
        image = applyGrain(image, stage: grainStage, seed: decision.grainSeed, extent: bounds)
      case .lightLeak(let leakStage):
        if let leak = decision.leak {
          image = applyLightLeak(
            image, decision: leak, strength: leakStage.strength, alphaCap: leakStage.alphaCap,
            extent: bounds)
        }
      case .vignette(let vignetteStage):
        image = applyVignette(image, stage: vignetteStage, extent: bounds)
      case .dateStamp(let dateStampStage):
        if let dateStampText,
          recipe.resolvedSettings.dateStampConfiguration.mode != .off
        {
          image = applyDateStamp(
            image, text: dateStampText, extent: bounds, style: dateStampStage.style)
        }
      }
    }
    return image.cropped(to: bounds)
  }

  private func withPermit<T>(_ operation: () throws -> T) rethrows -> T {
    permits.wait()
    defer { permits.signal() }
    return try operation()
  }
}
