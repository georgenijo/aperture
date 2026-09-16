import Foundation

extension MediaLibrary {
  func migrateLegacyPhotos() throws -> Bool {
    guard legacyDeletionLedgerAvailable else {
      return false
    }
    guard let legacyPhotosDirectory,
      fileManager.fileExists(atPath: legacyPhotosDirectory.path)
    else {
      return false
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let metadataFiles = try directoryEntries(at: legacyPhotosDirectory)
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var changed = false

    for metadataURL in metadataFiles {
      let metadata: LegacyPhotoMetadata
      var staging: URL?
      do {
        metadata = try decoder.decode(LegacyPhotoMetadata.self, from: Data(contentsOf: metadataURL))
      } catch {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .warning,
            code: .legacyMetadataCorrupt,
            message: "Legacy photo metadata could not be read and was left untouched.",
            relativePath: metadataURL.lastPathComponent,
            itemID: nil
          )
        )
        continue
      }

      guard isSafeLeafName(metadata.filename) else {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .error,
            code: .invalidPath,
            message: "A legacy photo referenced an unsafe path and was not imported.",
            relativePath: metadataURL.lastPathComponent,
            itemID: nil
          )
        )
        continue
      }

      let migrationIdentifier = "legacy:\(metadataURL.lastPathComponent):\(metadata.filename)"
      if legacyDeletionIdentifiers.contains(migrationIdentifier) {
        continue
      }
      if manifest.items.contains(where: {
        if case .legacyImport(let identifier) = $0.provenance {
          return identifier == migrationIdentifier
        }
        return false
      }) {
        continue
      }

      let source = legacyPhotosDirectory.appendingPathComponent(metadata.filename)
      guard fileManager.fileExists(atPath: source.path), !isDirectory(source) else {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .warning,
            code: .legacyFileMissing,
            message: "Legacy photo data is missing; its metadata was left untouched.",
            relativePath: metadata.filename,
            itemID: nil
          )
        )
        continue
      }

      let id = Self.stableUUID(for: migrationIdentifier)
      if manifest.items.contains(where: { $0.id == id })
        || fileManager.fileExists(atPath: committedDirectory(for: id).path)
      {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .warning,
            code: .legacyMigrationFailed,
            message:
              "A stable identifier collision prevented a legacy import; the original remains untouched.",
            relativePath: metadata.filename,
            itemID: id
          )
        )
        continue
      }

      do {
        let fileExtension = try validatedFileExtension(
          source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        )
        let relativeParent = "\(MediaLibraryPaths.media)/\(id.uuidString.lowercased())"
        let processedName = "processed.\(fileExtension)"
        let seed = Self.stableHash64(migrationIdentifier)
        let appliedRecipe = FilmRecipeCatalog.legacyOriginal.resolve(
          seed: seed,
          capturedAt: metadata.timestamp,
          options: FilmProcessingOptions(lightLeaksEnabled: false, dateStamp: .off),
          timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt
        )
        let item = MediaItem(
          id: id,
          mediaType: .photo,
          files: MediaFileSet(
            processed: "\(relativeParent)/\(processedName)",
            original: nil,
            thumbnail: nil
          ),
          dimensions: nil,
          durationSeconds: nil,
          capturedAt: metadata.timestamp,
          recipe: appliedRecipe,
          camera: nil,
          processing: .ready,
          provenance: .legacyImport(identifier: migrationIdentifier)
        )

        let stagingIdentifier = UUID()
        staging = creationStagingDirectory(for: stagingIdentifier)
        guard let staging else {
          throw MediaLibraryError.fileOperation(
            operation: "stage",
            path: id.uuidString,
            details: "Could not create a staging location."
          )
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        try fileManager.copyItem(at: source, to: staging.appendingPathComponent(processedName))
        try writeItemMetadata(item, in: staging)
        try fileManager.moveItem(at: staging, to: committedDirectory(for: id))
        manifest.items.append(item)
        changed = true
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .information,
            code: .legacyItemMigrated,
            message:
              "A legacy capture was copied into the new library; its original files remain in place.",
            relativePath: metadata.filename,
            itemID: id
          )
        )
      } catch {
        // Migration is a copy operation and the legacy source remains
        // authoritative. Do not leave a partial new-library
        // transaction behind when one payload or metadata write fails.
        if let staging {
          try? fileManager.removeItem(at: staging)
        }
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .error,
            code: .legacyMigrationFailed,
            message:
              "A legacy capture could not be imported and remains untouched: \(error.localizedDescription)",
            relativePath: metadata.filename,
            itemID: id
          )
        )
      }
    }
    return changed
  }
}
