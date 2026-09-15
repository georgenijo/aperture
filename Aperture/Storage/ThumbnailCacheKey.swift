import Foundation

struct ThumbnailCacheVersion: Codable, Hashable, Sendable {
  static let current = ThumbnailCacheVersion(
    namespace: "aperture.thumbnail", schema: 1, renderer: 2)

  let namespace: String
  let schema: Int
  let renderer: Int

  var token: String { "\(namespace)-s\(schema)-r\(renderer)" }

  func isCompatible(with other: ThumbnailCacheVersion) -> Bool {
    self == other
  }

  func requiresInvalidation(comparedTo storedVersion: ThumbnailCacheVersion?) -> Bool {
    storedVersion != self
  }
}

struct ThumbnailCacheKey: Codable, Hashable, Sendable {
  let itemID: UUID
  let sourceFingerprint: String
  let maximumPixelDimension: Int
  let version: ThumbnailCacheVersion

  init(
    item: MediaItem,
    maximumPixelDimension: Int,
    version: ThumbnailCacheVersion = .current
  ) {
    itemID = item.id
    sourceFingerprint = [
      item.files.processed,
      item.recipe.identifier.rawValue,
      String(item.recipe.version),
      String(item.recipe.seed),
      item.dimensions.map { "\($0.width)x\($0.height)" } ?? "unknown",
    ].joined(separator: "|")
    self.maximumPixelDimension = max(1, maximumPixelDimension)
    self.version = version
  }

  var fileName: String {
    let source =
      "\(version.token)|\(itemID.uuidString.lowercased())|\(sourceFingerprint)|\(maximumPixelDimension)"
    // The item prefix makes every derivative discoverable after relaunch, so
    // deleting a Lab item removes every cached size without an in-memory map.
    return "\(itemID.uuidString.lowercased())-\(Self.fnv1a64Hex(source)).jpg"
  }

  private static func fnv1a64Hex(_ value: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01B3
    }
    let unpadded = String(hash, radix: 16, uppercase: false)
    return String(repeating: "0", count: max(0, 16 - unpadded.count)) + unpadded
  }
}
