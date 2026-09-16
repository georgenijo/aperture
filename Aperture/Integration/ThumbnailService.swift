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
  private static let versionMarkerName = ".aperture-thumbnail-version"

  init(
    fileManager: FileManager = .default,
    cacheDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    let systemCache =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let base =
      cacheDirectory
      ?? systemCache.appendingPathComponent("ApertureThumbnails", isDirectory: true)
    self.cacheDirectory = base
    memory.countLimit = 240
  }

  func image(
    for item: MediaItem,
    sourceURL: URL,
    maximumPixelDimension: Int
  ) async throws -> UIImage {
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
    let rendered = try await Task.detached(priority: .utility) {
      try Task.checkCancellation()
      return try Self.render(sourceURL: sourceURL, maximumPixelDimension: maximumPixel)
    }.value

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
    memory.setObject(
      image, forKey: key as NSString, cost: Int(image.size.width * image.size.height))
    memoryKeysByItem[itemID, default: []].insert(key)
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
