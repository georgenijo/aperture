import AVFoundation
import CoreImage
import CoreMedia
import Foundation

enum VideoProcessorError: LocalizedError, Equatable, Sendable {
  case sourceMissing
  case sourceUnreadable
  case noVideoTrack
  case unsupportedRecipeVersion(Int)
  case missingDateStampText
  case cannotCreateExporter
  case unsupportedOutputType
  case exportFailed(String)
  case cancelled
  case outputMissing

  var errorDescription: String? {
    switch self {
    case .sourceMissing: "The source movie is missing."
    case .sourceUnreadable: "The source movie could not be opened."
    case .noVideoTrack: "The source movie contains no video track."
    case .unsupportedRecipeVersion(let version): "Unsupported film recipe version: \(version)."
    case .missingDateStampText: "The saved film recipe is missing its date-stamp text."
    case .cannotCreateExporter: "A video exporter could not be created on this device."
    case .unsupportedOutputType: "This device cannot write a compatible movie format."
    case .exportFailed(let message): "The film treatment could not be rendered: \(message)"
    case .cancelled: "Video development was cancelled."
    case .outputMissing: "Video development finished without an output movie."
    }
  }
}

/// Film rendering for clips is deliberately a lean, temporally stable path.
/// Tone, color, halation, vignette, and leaks are constant for the whole clip;
/// grain uses a deterministic frame seed and a very small transform so it can
/// evolve without rebuilding the still processor's CPU noise image per frame.
final class VideoProcessor: @unchecked Sendable {
  static let shared = VideoProcessor()

  struct Progress: Sendable, Equatable {
    let fraction: Double
    let frameIndex: Int
  }

  struct FrameTreatment: Sendable, Equatable {
    let grainPhase: CGFloat
    let staticLeak: LightLeakDecision?
    let staticContrast: Double
    let staticSaturation: Double
  }

  private let context: CIContext
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

  /// A pure temporal decision helper used by tests and by the frame filter.
  /// Keeping it independent of AVFoundation makes cancellation and seed
  /// behavior testable without camera hardware.
  static func temporalSeed(baseSeed: UInt64, frameIndex: Int) -> UInt64 {
    var value = baseSeed &+ UInt64(max(frameIndex, 0)) &* 0x9E37_79B9_7F4A_7C15
    value ^= value >> 30
    value &*= 0xBF58_476D_1CE4_E5B9
    value ^= value >> 27
    value &*= 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  static func grainPhase(baseSeed: UInt64, frameIndex: Int) -> CGFloat {
    let seed = temporalSeed(baseSeed: baseSeed, frameIndex: frameIndex)
    return CGFloat(Double(seed & 0xffff) / Double(0xffff))
  }

  /// Pure description of the frame recipe. Tests use this to ensure that
  /// only grain evolves over time; color and leak choices remain constant.
  static func frameTreatment(recipe: AppliedFilmRecipe, frameIndex: Int) -> FrameTreatment {
    let decision = FilmProcessingDecision.make(for: recipe)
    return FrameTreatment(
      grainPhase: grainPhase(baseSeed: recipe.seed, frameIndex: frameIndex),
      staticLeak: decision.leak,
      staticContrast: recipe.colorGrade.contrast,
      staticSaturation: recipe.colorGrade.saturation
    )
  }

  /// Geometry and falloff for the procedural video light leak. Keeping these
  /// values pure makes the edge orientation and width semantics testable
  /// without requiring an export session.
  static func lightLeakGradientPoints(
    edge: LightLeakDecision.Edge, position: Double, width: Double, extent: CGRect
  ) -> (start: CGPoint, end: CGPoint) {
    let clampedPosition = CGFloat(min(max(position, 0), 1))
    let clampedWidth = CGFloat(min(max(width, 0), 1))
    let start: CGPoint
    let end: CGPoint
    switch edge {
    case .left:
      start = CGPoint(x: extent.minX, y: extent.minY + clampedPosition * extent.height)
      end = CGPoint(x: extent.minX + clampedWidth * extent.width, y: start.y)
    case .right:
      start = CGPoint(x: extent.maxX, y: extent.minY + clampedPosition * extent.height)
      end = CGPoint(x: extent.maxX - clampedWidth * extent.width, y: start.y)
    case .top:
      start = CGPoint(x: extent.minX + clampedPosition * extent.width, y: extent.maxY)
      end = CGPoint(x: start.x, y: extent.maxY - clampedWidth * extent.height)
    case .bottom:
      start = CGPoint(x: extent.minX + clampedPosition * extent.width, y: extent.minY)
      end = CGPoint(x: start.x, y: extent.minY + clampedWidth * extent.height)
    }
    return (start, end)
  }

  static func lightLeakOpacity(distance: CGFloat, width: CGFloat) -> CGFloat {
    guard distance.isFinite, width.isFinite, distance >= 0, width > 0 else { return 0 }
    return max(0, min(1, 1 - distance / width))
  }

  func process(
    sourceURL: URL,
    recipe: AppliedFilmRecipe,
    destinationURL: URL? = nil,
    progress: (@Sendable (Progress) -> Void)? = nil
  ) async throws -> URL {
    guard FilmRecipeVersion.supported.contains(recipe.version) else {
      throw VideoProcessorError.unsupportedRecipeVersion(recipe.version)
    }
    if recipe.resolvedSettings.dateStampConfiguration.mode != .off,
      recipe.resolvedSettings.dateStampText == nil
    {
      throw VideoProcessorError.missingDateStampText
    }
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw VideoProcessorError.sourceMissing
    }
    let asset = AVURLAsset(url: sourceURL)
    let isPlayable = try await asset.load(.isPlayable)
    guard isPlayable else { throw VideoProcessorError.sourceUnreadable }
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let videoTrack = tracks.first else { throw VideoProcessorError.noVideoTrack }
    let duration = try await asset.load(.duration)
    let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
    let frameRate = max(
      Double(nominalFrameRate.isFinite && nominalFrameRate > 1 ? nominalFrameRate : 30), 1)
    let naturalSize = try await videoTrack.load(.naturalSize)
    let preferredTransform = try await videoTrack.load(.preferredTransform)
    let transformedSize = Self.transformedVideoSize(
      naturalSize: naturalSize, transform: preferredTransform)
    guard transformedSize.width > 0, transformedSize.height > 0 else {
      throw VideoProcessorError.sourceUnreadable
    }

    let outputURL =
      destinationURL
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "aperture-developed-\(UUID().uuidString).mov")
    try? FileManager.default.removeItem(at: outputURL)
    guard let exporter = AVAssetExportSession(asset: asset, presetName: Self.exportPreset) else {
      throw VideoProcessorError.cannotCreateExporter
    }
    guard exporter.supportedFileTypes.contains(.mov) || exporter.supportedFileTypes.contains(.mp4)
    else {
      throw VideoProcessorError.unsupportedOutputType
    }
    let outputType: AVFileType = exporter.supportedFileTypes.contains(.mov) ? .mov : .mp4
    let finalURL: URL
    if outputType == .mov {
      finalURL =
        outputURL.pathExtension.lowercased() == "mov"
        ? outputURL : outputURL.deletingPathExtension().appendingPathExtension("mov")
    } else {
      finalURL =
        outputURL.pathExtension.lowercased() == "mp4"
        ? outputURL : outputURL.deletingPathExtension().appendingPathExtension("mp4")
    }
    try? FileManager.default.removeItem(at: finalURL)

    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(frameRate.rounded()))))
    let renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
    let noiseBank = Self.makeNoiseBank(seed: recipe.seed, count: 8, size: 384)
    let decision = FilmProcessingDecision.make(for: recipe)
    let colorCubes = FilmColorCube.data(for: recipe)
    let videoComposition = AVMutableVideoComposition(asset: asset) { [weak self] request in
      guard let self else {
        request.finish(
          with: NSError(
            domain: "Aperture.VideoProcessor", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Video processor was released."]))
        return
      }
      let source = request.sourceImage
      guard source.extent.width > 0, source.extent.height > 0 else {
        request.finish(
          with: NSError(
            domain: "Aperture.VideoProcessor", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Video frame was unavailable."]))
        return
      }
      let index = max(0, Int((request.compositionTime.seconds * frameRate).rounded(.down)))
      do {
        let output = try self.apply(
          recipe: recipe, image: source, extent: source.extent, frameIndex: index,
          decision: decision, noiseBank: noiseBank, colorCubes: colorCubes)
        request.finish(with: output, context: self.context)
        let fraction =
          duration.seconds > 0
          ? min(1, max(0, request.compositionTime.seconds / duration.seconds)) : 0
        progress?(Progress(fraction: fraction, frameIndex: index))
      } catch {
        request.finish(with: error)
      }
    }
    videoComposition.frameDuration = frameDuration
    videoComposition.renderSize = renderSize
    exporter.videoComposition = videoComposition
    exporter.outputURL = finalURL
    exporter.outputFileType = outputType
    exporter.shouldOptimizeForNetworkUse = false

    let controller = ExportController(exporter: exporter)
    do {
      try await withTaskCancellationHandler {
        try await controller.export()
      } onCancel: {
        controller.cancel()
      }
      guard FileManager.default.fileExists(atPath: finalURL.path) else {
        throw VideoProcessorError.outputMissing
      }
      let renderedAsset = AVURLAsset(url: finalURL)
      guard try await renderedAsset.load(.isPlayable),
        !(try await renderedAsset.loadTracks(withMediaType: .video)).isEmpty
      else {
        throw VideoProcessorError.exportFailed("The developed movie is not playable.")
      }
      let sourceHasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
      let renderedHasAudio = !(try await renderedAsset.loadTracks(withMediaType: .audio)).isEmpty
      if sourceHasAudio && !renderedHasAudio {
        throw VideoProcessorError.exportFailed("The movie’s audio track could not be preserved.")
      }
      progress?(
        Progress(
          fraction: 1, frameIndex: max(0, Int((duration.seconds * frameRate).rounded(.down)))))
      return finalURL
    } catch {
      // Export sessions can leave a partial movie behind after
      // cancellation, low storage, or encoder failure.
      try? FileManager.default.removeItem(at: finalURL)
      throw error
    }
  }

  private static var exportPreset: String {
    if #available(iOS 17.0, *) { return AVAssetExportPresetHEVCHighestQuality }
    return AVAssetExportPresetHighestQuality
  }

  private static func transformedVideoSize(naturalSize: CGSize, transform: CGAffineTransform)
    -> CGSize
  {
    let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
    return CGSize(
      width: max(1, abs(rect.width).rounded()), height: max(1, abs(rect.height).rounded()))
  }

  private func apply(
    recipe: AppliedFilmRecipe, image: CIImage, extent: CGRect, frameIndex: Int,
    decision: FilmProcessingDecision, noiseBank: [CIImage], colorCubes: [Data]
  ) throws -> CIImage {
    guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
      throw VideoProcessorError.sourceUnreadable
    }
    let halationAmount = recipe.halation?.amount ?? 0
    let vignetteAmount = recipe.vignette?.amount ?? 0
    let lightLeakStrength = recipe.lightLeak?.strength ?? 0
    let lightLeakAlphaCap = recipe.lightLeak?.alphaCap ?? 0.68
    let grainAmount = recipe.grain?.amount ?? 0
    var output = image.cropped(to: extent)
    for cube in colorCubes {
      output = FilmColorCube.apply(output, cubeData: cube, extent: extent)
    }
    if halationAmount > 0.001, let bloom = CIFilter(name: "CIBloom") {
      bloom.setValue(output, forKey: kCIInputImageKey)
      bloom.setValue(min(1, halationAmount), forKey: kCIInputIntensityKey)
      bloom.setValue(max(1, extent.width * 0.008 * halationAmount), forKey: kCIInputRadiusKey)
      output = bloom.outputImage?.cropped(to: extent) ?? output
    }
    if vignetteAmount > 0.001, let vignette = CIFilter(name: "CIVignetteEffect") {
      vignette.setValue(output, forKey: kCIInputImageKey)
      vignette.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)
      vignette.setValue(max(extent.width, extent.height) * 0.52, forKey: kCIInputRadiusKey)
      vignette.setValue(vignetteAmount * 1.4, forKey: kCIInputIntensityKey)
      output = vignette.outputImage?.cropped(to: extent) ?? output
    }
    if let leak = decision.leak {
      output = applyLeak(
        output, leak: leak, strength: lightLeakStrength, alphaCap: lightLeakAlphaCap,
        extent: extent)
    }
    // CIRandomGenerator is evaluated by Core Image, not decoded into a
    // full-resolution CPU buffer. A deterministic subpixel translation per
    // frame keeps grain alive without changing the recipe's color/leak.
    if grainAmount > 0.001, !noiseBank.isEmpty,
      let colorMatrix = CIFilter(name: "CIColorMatrix")
    {
      let phase = Self.grainPhase(baseSeed: recipe.seed, frameIndex: frameIndex)
      let bankImage = noiseBank[frameIndex % noiseBank.count]
      let scaleX = extent.width / max(bankImage.extent.width, 1)
      let scaleY = extent.height / max(bankImage.extent.height, 1)
      colorMatrix.setValue(
        bankImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).transformed(
          by: CGAffineTransform(translationX: phase * 3, y: phase * 2)), forKey: kCIInputImageKey)
      // Keep the noise centered around middle gray at low amplitude;
      // overlaying raw random RGB would overwhelm the footage.
      colorMatrix.setValue(CIVector(x: 0.055, y: 0, z: 0, w: 0), forKey: "inputRVector")
      colorMatrix.setValue(CIVector(x: 0, y: 0.055, z: 0, w: 0), forKey: "inputGVector")
      colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0.055, w: 0), forKey: "inputBVector")
      colorMatrix.setValue(CIVector(x: 0.47, y: 0.47, z: 0.47, w: 0), forKey: "inputBiasVector")
      let noise = colorMatrix.outputImage?.cropped(to: extent)
      if let noise, let blend = CIFilter(name: "CIOverlayBlendMode") {
        blend.setValue(noise, forKey: kCIInputImageKey)
        blend.setValue(output, forKey: kCIInputBackgroundImageKey)
        output = blend.outputImage?.cropped(to: extent) ?? output
      }
    }
    if recipe.resolvedSettings.dateStampConfiguration.mode != .off,
      let text = recipe.resolvedSettings.dateStampText,
      let stamp = FilmOverlayFactory.dateStampImage(
        text: text, extent: extent, stage: recipe.stages.dateStamp ?? DateStampStage()),
      let composite = CIFilter(name: "CISourceOverCompositing")
    {
      composite.setValue(stamp, forKey: kCIInputImageKey)
      composite.setValue(output, forKey: kCIInputBackgroundImageKey)
      output = composite.outputImage?.cropped(to: extent) ?? output
    }
    return output.cropped(to: extent)
  }

  private static func makeNoiseBank(seed: UInt64, count: Int, size: Int) -> [CIImage] {
    guard count > 0, size > 0 else { return [] }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    return (0..<count).compactMap { index in
      var random = SeededRandomNumberGenerator(
        seed: seed ^ UInt64(index + 1) &* 0xD6E8_FEB8_6659_FD93)
      var bytes = Data(count: size * size * 4)
      bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for offset in stride(from: 0, to: size * size * 4, by: 4) {
          let value = UInt8(truncatingIfNeeded: random.next())
          base[offset] = value
          base[offset + 1] = value
          base[offset + 2] = value
          base[offset + 3] = 255
        }
      }
      return CIImage(
        bitmapData: bytes, bytesPerRow: size * 4, size: CGSize(width: size, height: size),
        format: .RGBA8, colorSpace: colorSpace)
    }
  }

  /// The leak's peak alpha at the frame edge: the persisted strength scaled
  /// by the seeded intensity, never above the stage's `alphaCap`. Legacy
  /// recipes never reach their cap (strength ≤ 0.48), so their frames are
  /// unchanged; the 1998 recipe's 0.16 cap is what keeps its leaks subtle.
  static func lightLeakBaseAlpha(strength: Double, intensity: Double, alphaCap: Double) -> Double
  {
    min(max(0, alphaCap), max(0, strength) * max(0, intensity))
  }

  private func applyLeak(
    _ image: CIImage, leak: LightLeakDecision, strength: Double, alphaCap: Double,
    extent: CGRect
  ) -> CIImage {
    guard let gradient = CIFilter(name: "CILinearGradient"),
      let composite = CIFilter(name: "CISourceOverCompositing")
    else { return image }
    let points = Self.lightLeakGradientPoints(
      edge: leak.edge, position: leak.position, width: leak.width, extent: extent)
    let width = CGFloat(min(max(leak.width, 0), 1))
    let baseAlpha = CGFloat(
      Self.lightLeakBaseAlpha(strength: strength, intensity: leak.intensity, alphaCap: alphaCap))
    let color = CIColor(
      red: leak.color.red, green: leak.color.green, blue: leak.color.blue,
      alpha: baseAlpha * Self.lightLeakOpacity(distance: 0, width: width))
    let transparentColor = CIColor(
      red: color.red, green: color.green, blue: color.blue,
      alpha: baseAlpha * Self.lightLeakOpacity(distance: width, width: width))
    gradient.setValue(CIVector(cgPoint: points.start), forKey: "inputPoint0")
    gradient.setValue(CIVector(cgPoint: points.end), forKey: "inputPoint1")
    gradient.setValue(color, forKey: "inputColor0")
    gradient.setValue(transparentColor, forKey: "inputColor1")
    guard let overlay = gradient.outputImage?.cropped(to: extent) else { return image }
    // Source-over preserves the developed frame everywhere the procedural
    // leak is transparent; a white blend mask would replace it instead.
    composite.setValue(overlay, forKey: kCIInputImageKey)
    composite.setValue(image, forKey: kCIInputBackgroundImageKey)
    return composite.outputImage?.cropped(to: extent) ?? image
  }
}

private final class ExportController: @unchecked Sendable {
  private let exporter: AVAssetExportSession

  init(exporter: AVAssetExportSession) {
    self.exporter = exporter
  }

  func cancel() {
    exporter.cancelExport()
  }

  func export() async throws {
    try await withCheckedThrowingContinuation { continuation in
      exporter.exportAsynchronously {
        switch self.exporter.status {
        case .completed:
          continuation.resume()
        case .cancelled:
          continuation.resume(throwing: VideoProcessorError.cancelled)
        case .failed:
          continuation.resume(
            throwing: VideoProcessorError.exportFailed(
              self.exporter.error?.localizedDescription ?? "Unknown export error."))
        default:
          continuation.resume(
            throwing: VideoProcessorError.exportFailed("The exporter ended unexpectedly."))
        }
      }
    }
  }
}
