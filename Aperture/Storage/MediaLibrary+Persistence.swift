import Foundation

extension MediaLibrary {
  struct LibraryManifest: Codable {
    let schemaVersion: Int
    var items: [MediaItem]
  }

  struct LegacyPhotoMetadata: Decodable {
    let filename: String
    let timestamp: Date
  }

  var manifestURL: URL {
    rootURL.appendingPathComponent(MediaLibraryPaths.manifest)
  }

  var mediaDirectory: URL {
    rootURL.appendingPathComponent(MediaLibraryPaths.media, isDirectory: true)
  }

  var stagingDirectory: URL {
    rootURL.appendingPathComponent(MediaLibraryPaths.staging, isDirectory: true)
  }

  var recoveryDirectory: URL {
    rootURL.appendingPathComponent(MediaLibraryPaths.recovery, isDirectory: true)
  }

  var legacyDeletionLedgerURL: URL {
    rootURL.appendingPathComponent(MediaLibraryPaths.legacyDeletionLedger)
  }

  func loadLegacyDeletionIdentifiersRecoveringIfNeeded() -> Set<String> {
    legacyDeletionLedgerAvailable = true
    guard fileManager.fileExists(atPath: legacyDeletionLedgerURL.path) else {
      return []
    }

    do {
      let data = try Data(contentsOf: legacyDeletionLedgerURL)
      let ledger = try ApertureJSON.makeDecoder().decode(LegacyDeletionLedger.self, from: data)
      guard ledger.schemaVersion == LegacyDeletionLedger.schemaVersion,
        ledger.identifiers.allSatisfy({ !$0.isEmpty }),
        Set(ledger.identifiers).count == ledger.identifiers.count
      else {
        throw MediaLibraryError.corruptMetadata("Unsupported or invalid legacy deletion ledger.")
      }
      return Set(ledger.identifiers)
    } catch {
      legacyDeletionLedgerAvailable = false
      let backup = recoveryDirectory.appendingPathComponent(
        "corrupt-legacy-deletions-\(UUID().uuidString.lowercased()).json"
      )
      let preservation = Result {
        try fileManager.copyItem(at: legacyDeletionLedgerURL, to: backup)
      }
      let details: String
      switch preservation {
      case .success:
        details =
          "A backup was preserved in recovery. Legacy migration is paused until the ledger is repaired."
      case .failure(let preservationError):
        details =
          "The corrupt ledger could not be preserved (\(preservationError.localizedDescription)). Legacy migration is paused."
      }
      latestDiagnostics.append(
        MediaLibraryDiagnostic(
          severity: .error,
          code: .corruptLegacyDeletionLedger,
          message: "The legacy deletion ledger is corrupt: \(details)",
          relativePath: MediaLibraryPaths.legacyDeletionLedger,
          itemID: nil
        )
      )
      return []
    }
  }

  func writeLegacyDeletionIdentifiers(_ identifiers: Set<String>) throws {
    let ledger = LegacyDeletionLedger(
      schemaVersion: LegacyDeletionLedger.schemaVersion,
      identifiers: identifiers.sorted()
    )
    do {
      let data = try ApertureJSON.makeEncoder().encode(ledger)
      try fileSystem.writeData(data, legacyDeletionLedgerURL, [.atomic])
    } catch {
      throw fileError("write legacy deletion ledger", url: legacyDeletionLedgerURL, error: error)
    }
  }

  func snapshot() -> MediaLibrarySnapshot {
    MediaLibrarySnapshot(items: sortedItems(manifest.items), diagnostics: latestDiagnostics)
  }

  func sortedItems(_ items: [MediaItem]) -> [MediaItem] {
    items.sorted {
      if $0.capturedAt == $1.capturedAt {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.capturedAt > $1.capturedAt
    }
  }

  func createLibraryDirectories() throws {
    for directory in [rootURL, mediaDirectory, stagingDirectory, recoveryDirectory] {
      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        throw fileError("create directory", url: directory, error: error)
      }
    }
  }

  func loadManifestRecoveringIfNeeded() throws -> LibraryManifest {
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      return LibraryManifest(schemaVersion: Self.manifestSchemaVersion, items: [])
    }

    do {
      let data = try Data(contentsOf: manifestURL)
      let decoded = try ApertureJSON.makeDecoder().decode(LibraryManifest.self, from: data)
      guard decoded.schemaVersion == Self.manifestSchemaVersion else {
        throw MediaLibraryError.corruptMetadata(
          "Unsupported manifest schema \(decoded.schemaVersion)."
        )
      }
      return decoded
    } catch {
      let backup = recoveryDirectory.appendingPathComponent(
        "corrupt-manifest-\(UUID().uuidString.lowercased()).json"
      )
      do {
        try fileManager.copyItem(at: manifestURL, to: backup)
      } catch {
        throw fileError("preserve corrupt manifest", url: backup, error: error)
      }
      latestDiagnostics.append(
        MediaLibraryDiagnostic(
          severity: .error,
          code: .corruptManifest,
          message:
            "The library index was corrupt. A backup was preserved and item metadata will be used to rebuild it.",
          relativePath: MediaLibraryPaths.manifest,
          itemID: nil
        )
      )
      return LibraryManifest(schemaVersion: Self.manifestSchemaVersion, items: [])
    }
  }

  func writeManifest(_ value: LibraryManifest) throws {
    do {
      let data = try ApertureJSON.makeEncoder().encode(value)
      try fileSystem.writeData(data, manifestURL, [.atomic])
    } catch {
      throw fileError("write library index", url: manifestURL, error: error)
    }
  }

  func writeItemMetadata(_ item: MediaItem, in directory: URL) throws {
    do {
      let data = try ApertureJSON.makeEncoder().encode(item)
      try fileSystem.writeData(
        data,
        directory.appendingPathComponent(MediaLibraryPaths.itemMetadata),
        [.atomic]
      )
    } catch {
      throw fileError("write item metadata", url: directory, error: error)
    }
  }

  func readItemMetadata(in directory: URL) throws -> MediaItem {
    let url = directory.appendingPathComponent(MediaLibraryPaths.itemMetadata)
    do {
      return try ApertureJSON.makeDecoder().decode(MediaItem.self, from: Data(contentsOf: url))
    } catch {
      throw MediaLibraryError.corruptMetadata(error.localizedDescription)
    }
  }

  func committedDirectory(for id: UUID) -> URL {
    mediaDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  func creationStagingDirectory(for id: UUID) -> URL {
    stagingDirectory.appendingPathComponent(
      "create-\(id.uuidString.lowercased())", isDirectory: true)
  }

  func deletionStagingDirectory(for id: UUID) -> URL {
    stagingDirectory.appendingPathComponent(
      "delete-\(id.uuidString.lowercased())", isDirectory: true)
  }
}
