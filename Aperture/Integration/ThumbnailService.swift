import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ThumbnailError: LocalizedError, Sendable {
  case sourceUnavailable
  case decodeFailed
  case encodeFailed
  case invalidated
  case cacheFailure(String)

  var errorDescription: String? {
    switch self {
    case .sourceUnavailable: "The media file is unavailable."
    case .decodeFailed: "A preview couldn’t be created for this item."
    case .encodeFailed: "The preview couldn’t be encoded."
    case .invalidated: "The preview request is no longer current."
    case .cacheFailure(let details): "The preview cache failed: \(details)"
    }
  }
}

actor ThumbnailService {
  private struct RenderedThumbnail {
    let image: UIImage
    let encodedData: Data
  }

  private let fileManager: FileManager
  private let cacheDirectory: URL
  private let memory = NSCache<NSString, UIImage>()
  private var memoryKeysByItem: [UUID: Set<String>] = [:]
  private var itemGeneration: [UUID: UInt64] = [:]
  private var globalGeneration: UInt64 = 0
  private var didPrepareCache = false
  /// Test-only synchronization point invoked immediately before the
  /// unpreemptable decode/encode call in `render(...)`. `nil` on every
  /// production path; a deterministic test can set this (via
  /// `setTestRenderGate(_:)`) to pause a request mid-flight — instead of
  /// racing on a `sleep` — to exercise cancellation while work is
  /// outstanding.
  private var testRenderGate: (@Sendable () async -> Void)?
  private static let versionMarkerName = ".aperture-thumbnail-version"
  /// Default byte budget for the in-memory cache, independent of the disk
  /// cache format (changing it does not require a
  /// `ThumbnailCacheVersion`/marker bump — nothing about the persisted JPEG
  /// bytes or their file names is affected).
  static let defaultMemoryCostLimitBytes = 64 * 1024 * 1024

  init(
    fileManager: FileManager = .default,
    cacheDirectory: URL? = nil,
    memoryCostLimitBytes: Int = ThumbnailService.defaultMemoryCostLimitBytes
  ) {
    self.fileManager = fileManager
    let systemCache =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let base =
      cacheDirectory
      ?? systemCache.appendingPathComponent("ApertureThumbnails", isDirectory: true)
    self.cacheDirectory = base
    // NSCache treats both limits as advisory. Cost accounts for decoded
    // bytes, including larger detail-view previews, rather than points.
    memory.countLimit = 240
    memory.totalCostLimit = memoryCostLimitBytes
  }

  func image(
    for item: MediaItem,
    sourceURL: URL,
    maximumPixelDimension: Int
  ) async throws -> UIImage {
    try Task.checkCancellation()
    let key = ThumbnailCacheKey(item: item, maximumPixelDimension: maximumPixelDimension)
    let memoryKey = key.fileName as NSString
    if let cached = memory.object(forKey: memoryKey) {
      return cached
    }

    try prepareCacheDirectory()
    let cachedURL = cacheDirectory.appendingPathComponent(key.fileName, isDirectory: false)
    if let data = try? Data(contentsOf: cachedURL), let cached = UIImage(data: data) {
      remember(cached, key: key.fileName, itemID: item.id)
      return cached
    }

    let itemToken = itemGeneration[item.id, default: 0]
    let globalToken = globalGeneration
    let maximumPixel = max(1, maximumPixelDimension)

    // Nothing above this point has suspended, so this reflects the caller's
    // own task — e.g. a detail page's `.task(id:)` that SwiftUI just
    // canceled on a swipe. Check it before handing work to the unstructured
    // task below: `Task.detached` has its own independent cancellation
    // state and is never otherwise told the caller gave up.
    try Task.checkCancellation()

    let renderGate = testRenderGate
    let detachedRender = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      await renderGate?()
      try Task.checkCancellation()
      return try Self.render(sourceURL: sourceURL, maximumPixelDimension: maximumPixel)
    }
    // Forward the caller's cancellation into the detached task. A
    // synchronous Image I/O call already underway inside `Self.render`
    // cannot be preempted by this — it runs to completion regardless — but
    // this stops a request that is still queued, or between its decode and
    // encode steps, from doing further avoidable work.
    let rendered = try await withTaskCancellationHandler {
      try await detachedRender.value
    } onCancel: {
      detachedRender.cancel()
    }

    // Re-check the caller's cancellation, not just the generation tokens,
    // before publishing to the disk and memory caches: a request that
    // finished rendering after its caller gave up should not populate the
    // cache with a result nobody asked for anymore.
    try Task.checkCancellation()
    guard itemGeneration[item.id, default: 0] == itemToken,
      globalGeneration == globalToken
    else {
      throw ThumbnailError.invalidated
    }
    do {
      try rendered.encodedData.write(to: cachedURL, options: .atomic)
    } catch {
      throw ThumbnailError.cacheFailure(error.localizedDescription)
    }
    remember(rendered.image, key: key.fileName, itemID: item.id)
    return rendered.image
  }

  /// Test-only hook. Production callers never invoke this; it exists so a
  /// deterministic test can gate an in-flight render (see `testRenderGate`)
  /// without any timing assumption.
  func setTestRenderGate(_ gate: (@Sendable () async -> Void)?) {
    testRenderGate = gate
  }

  func invalidate(itemID: UUID) throws {
    itemGeneration[itemID, default: 0] &+= 1
    for key in memoryKeysByItem.removeValue(forKey: itemID) ?? [] {
      memory.removeObject(forKey: key as NSString)
      let url = cacheDirectory.appendingPathComponent(key, isDirectory: false)
      if fileManager.fileExists(atPath: url.path) {
        do {
          try fileManager.removeItem(at: url)
        } catch {
          throw ThumbnailError.cacheFailure(error.localizedDescription)
        }
      }
    }
    try prepareCacheDirectory()
    let prefix = itemID.uuidString.lowercased() + "-"
    do {
      for url in try fileManager.contentsOfDirectory(
        at: cacheDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ) where url.lastPathComponent.hasPrefix(prefix) {
        try fileManager.removeItem(at: url)
      }
    } catch {
      throw ThumbnailError.cacheFailure(error.localizedDescription)
    }
  }

  func clear() throws {
    globalGeneration &+= 1
    itemGeneration.removeAll()
    memoryKeysByItem.removeAll()
    memory.removeAllObjects()
    if fileManager.fileExists(atPath: cacheDirectory.path) {
      do {
        try fileManager.removeItem(at: cacheDirectory)
      } catch {
        throw ThumbnailError.cacheFailure(error.localizedDescription)
      }
    }
    didPrepareCache = false
    try prepareCacheDirectory()
  }

  private func remember(_ image: UIImage, key: String, itemID: UUID) {
    memory.setObject(image, forKey: key as NSString, cost: Self.byteCost(of: image))
    memoryKeysByItem[itemID, default: []].insert(key)
  }

  /// Resident bytes for `image`, used as the `NSCache` cost so
  /// `totalCostLimit` reflects actual memory rather than a pixel count (and,
  /// prior to this, `UIImage.size` in *points* rather than pixels, which
  /// under-counted anything with `scale` > 1).
  private static func byteCost(of image: UIImage) -> Int {
    guard let cgImage = image.cgImage else {
      // No CGImage backing (unusual for these decoded thumbnails): estimate
      // generously at 4 bytes/pixel from the pixel dimensions rather than
      // under-costing the cache.
      let pixelWidth = image.size.width * image.scale
      let pixelHeight = image.size.height * image.scale
      return max(1, Int(pixelWidth * pixelHeight) * 4)
    }
    return max(1, cgImage.bytesPerRow * cgImage.height)
  }

  private func prepareCacheDirectory() throws {
    guard !didPrepareCache else { return }
    let marker = cacheDirectory.appendingPathComponent(Self.versionMarkerName)
    do {
      if fileManager.fileExists(atPath: cacheDirectory.path) {
        let storedVersion = try? String(contentsOf: marker, encoding: .utf8)
        if storedVersion != ThumbnailCacheVersion.current.token {
          try fileManager.removeItem(at: cacheDirectory)
        }
      }
      try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
      try Data(ThumbnailCacheVersion.current.token.utf8).write(to: marker, options: .atomic)
      didPrepareCache = true
    } catch {
      throw ThumbnailError.cacheFailure(error.localizedDescription)
    }
  }

  nonisolated private static func render(
    sourceURL: URL,
    maximumPixelDimension: Int
  ) throws -> RenderedThumbnail {
    let source: CGImage
    if sourceURL.pathExtension.lowercased() == "mov"
      || sourceURL.pathExtension.lowercased() == "mp4"
      || sourceURL.pathExtension.lowercased() == "m4v"
    {
      let asset = AVURLAsset(url: sourceURL)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: maximumPixelDimension, height: maximumPixelDimension)
      do {
        source = try generator.copyCGImage(at: .zero, actualTime: nil)
      } catch {
        throw ThumbnailError.decodeFailed
      }
    } else {
      guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          imageSource, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
          ] as CFDictionary)
      else {
        throw ThumbnailError.sourceUnavailable
      }
      source = image
    }

    // The decode above is a synchronous Image I/O call that cannot be
    // interrupted once started, so cancellation requested mid-decode is
    // only observed here, after it finishes. Checking now at least avoids
    // spending the (also synchronous and non-preemptable) JPEG encode below
    // on a result the caller no longer wants.
    try Task.checkCancellation()

    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw ThumbnailError.encodeFailed
    }
    CGImageDestinationAddImage(
      destination,
      source,
      [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      throw ThumbnailError.encodeFailed
    }
    return RenderedThumbnail(image: UIImage(cgImage: source), encodedData: data as Data)
  }
}
