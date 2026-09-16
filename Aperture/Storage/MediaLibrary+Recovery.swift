import Foundation

extension MediaLibrary {
  func recoverInterruptedDeletions() throws -> Bool {
    let entries = try directoryEntries(at: stagingDirectory)
      .filter { $0.lastPathComponent.hasPrefix("delete-") }
    var changed = false

    for directory in entries {
      let rawID = String(directory.lastPathComponent.dropFirst("delete-".count))
      guard let id = UUID(uuidString: rawID) else {
        try quarantine(directory, reason: "unrecognized-deletion")
        changed = true
        continue
      }

      if manifest.items.contains(where: { $0.id == id }) {
        let destination = committedDirectory(for: id)
        guard !fileManager.fileExists(atPath: destination.path) else {
          try quarantine(directory, reason: "duplicate-deletion")
          changed = true
          continue
        }
        do {
          try fileManager.moveItem(at: directory, to: destination)
        } catch {
          throw fileError("roll back interrupted deletion", url: directory, error: error)
        }
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .information,
            code: .rolledBackInterruptedDeletion,
            message: "An interrupted deletion was rolled back without losing the item.",
            relativePath: nil,
            itemID: id
          )
        )
      } else {
        do {
          try fileManager.removeItem(at: directory)
        } catch {
          throw fileError("finish interrupted deletion", url: directory, error: error)
        }
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .information,
            code: .completedInterruptedDeletion,
            message: "An interrupted deletion was safely completed.",
            relativePath: nil,
            itemID: id
          )
        )
      }
      changed = true
    }
    return changed
  }

  func reconcileCommittedItems() throws -> Bool {
    var indexesByID: [UUID: Int] = [:]
    for (index, item) in manifest.items.enumerated() {
      // Keep the first entry if a damaged manifest contains duplicates;
      // the duplicate remains visible for diagnostics rather than
      // making preparation fail while constructing this lookup.
      if indexesByID[item.id] == nil {
        indexesByID[item.id] = index
      }
    }
    var changed = false

    for directory in try directoryEntries(at: mediaDirectory) {
      guard isDirectory(directory) else { continue }
      do {
        let item = try readItemMetadata(in: directory)
        guard directory.lastPathComponent.caseInsensitiveCompare(item.id.uuidString) == .orderedSame
        else {
          latestDiagnostics.append(
            MediaLibraryDiagnostic(
              severity: .error,
              code: .invalidMetadata,
              message: "The item identifier does not match its directory.",
              relativePath: "\(MediaLibraryPaths.media)/\(directory.lastPathComponent)",
              itemID: item.id
            )
          )
          continue
        }
        try validateItemLayout(item)
        if let index = indexesByID[item.id] {
          // Item metadata is written before the index. If the app
          // exits between those atomic writes, metadata is the
          // durable source of truth and must replace the stale
          // manifest entry on the next launch.
          if manifest.items[index] != item {
            manifest.items[index] = item
            changed = true
            latestDiagnostics.append(
              MediaLibraryDiagnostic(
                severity: .information,
                code: .recoveredCommittedItem,
                message:
                  "Committed item metadata was newer than the library index and was reconciled.",
                relativePath: nil,
                itemID: item.id
              )
            )
          }
        } else {
          indexesByID[item.id] = manifest.items.count
          manifest.items.append(item)
          changed = true
          latestDiagnostics.append(
            MediaLibraryDiagnostic(
              severity: .information,
              code: .recoveredCommittedItem,
              message: "A committed item missing from the library index was recovered.",
              relativePath: nil,
              itemID: item.id
            )
          )
        }
        changed = try removeUnreferencedAssets(in: directory, for: item) || changed
      } catch {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .error,
            code: .corruptItemMetadata,
            message:
              "An item directory contains unreadable metadata: \(error.localizedDescription)",
            relativePath: "\(MediaLibraryPaths.media)/\(directory.lastPathComponent)",
            itemID: nil
          )
        )
      }
    }
    return changed
  }

  /// A replacement publishes its new asset before removing the old one so
  /// that a crash cannot lose media. Once valid item metadata is available,
  /// any other regular file in the committed directory is an orphan from a
  /// superseded transaction and can be safely removed. All referenced assets
  /// must be present first; otherwise retaining every candidate is safer than
  /// deleting the only surviving copy of a damaged item.
  private func removeUnreferencedAssets(in directory: URL, for item: MediaItem) throws -> Bool {
    for path in item.files.allPaths {
      do {
        let url = try validatedAssetURL(for: path)
        let isRegularFile =
          try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        guard fileManager.fileExists(atPath: url.path), isRegularFile else {
          latestDiagnostics.append(
            MediaLibraryDiagnostic(
              severity: .warning,
              code: .orphanCleanupSkipped,
              message:
                "Orphan cleanup was skipped because a metadata-referenced asset is missing or not a regular file.",
              relativePath: path,
              itemID: item.id
            )
          )
          return false
        }
      } catch {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .error,
            code: .orphanCleanupSkipped,
            message:
              "Orphan cleanup was skipped because a metadata-referenced asset is invalid: \(error.localizedDescription)",
            relativePath: path,
            itemID: item.id
          )
        )
        return false
      }
    }

    let referencedNames = Set(
      item.files.allPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
    )
    .union([MediaLibraryPaths.itemMetadata])
    var changed = false
    for entry in try directoryEntries(at: directory) {
      guard !isDirectory(entry), !referencedNames.contains(entry.lastPathComponent) else {
        continue
      }
      do {
        try fileManager.removeItem(at: entry)
        changed = true
      } catch {
        throw fileError("remove orphaned asset", url: entry, error: error)
      }
    }
    return changed
  }

  func recoverStagedCreations() throws -> Bool {
    let entries = try directoryEntries(at: stagingDirectory)
      .filter { $0.lastPathComponent.hasPrefix("create-") }
    var changed = false

    for directory in entries {
      do {
        let item = try readItemMetadata(in: directory)
        guard try stagedDirectoryIsComplete(directory, expectedItem: item) else {
          try quarantine(directory, reason: "incomplete-staging")
          latestDiagnostics.append(
            MediaLibraryDiagnostic(
              severity: .warning,
              code: .quarantinedIncompleteStaging,
              message:
                "An incomplete capture was moved to recovery without touching existing media.",
              relativePath: nil,
              itemID: item.id
            )
          )
          changed = true
          continue
        }

        if manifest.items.contains(where: { $0.id == item.id }) {
          try quarantine(directory, reason: "duplicate-staging")
          changed = true
          continue
        }

        let destination = committedDirectory(for: item.id)
        if fileManager.fileExists(atPath: destination.path) {
          try quarantine(directory, reason: "destination-exists")
          changed = true
          continue
        }
        try fileManager.moveItem(at: directory, to: destination)
        manifest.items.append(item)
        changed = true
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .information,
            code: .recoveredStagedItem,
            message: "A complete capture interrupted before commit was recovered.",
            relativePath: nil,
            itemID: item.id
          )
        )
      } catch {
        try quarantine(directory, reason: "unreadable-staging")
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .warning,
            code: .quarantinedIncompleteStaging,
            message: "Unreadable staged data was moved to recovery: \(error.localizedDescription)",
            relativePath: nil,
            itemID: nil
          )
        )
        changed = true
      }
    }
    return changed
  }
}
