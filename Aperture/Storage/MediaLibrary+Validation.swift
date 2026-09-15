import Foundation

extension MediaLibrary {
  func appendValidationDiagnostics() {
    for item in manifest.items {
      if item.schemaVersion != MediaItem.currentSchemaVersion {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .warning,
            code: .invalidMetadata,
            message: "The item uses unsupported metadata schema \(item.schemaVersion).",
            relativePath: nil,
            itemID: item.id
          )
        )
      }
      if let dimensions = item.dimensions, !dimensions.isValid {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .error,
            code: .invalidMetadata,
            message: "The item has invalid pixel dimensions.",
            relativePath: nil,
            itemID: item.id
          )
        )
      }
      if item.mediaType == .video,
        !(item.durationSeconds.map { $0.isFinite && $0 > 0 } ?? false)
      {
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .error,
            code: .invalidMetadata,
            message: "The video has no valid duration.",
            relativePath: nil,
            itemID: item.id
          )
        )
      }

      for path in item.files.allPaths {
        do {
          let url = try validatedAssetURL(for: path)
          if !fileManager.fileExists(atPath: url.path) || isDirectory(url) {
            latestDiagnostics.append(
              MediaLibraryDiagnostic(
                severity: .error,
                code: .missingFile,
                message: "A referenced media file is missing.",
                relativePath: path,
                itemID: item.id
              )
            )
          }
        } catch {
          latestDiagnostics.append(
            MediaLibraryDiagnostic(
              severity: .error,
              code: .invalidPath,
              message: error.localizedDescription,
              relativePath: path,
              itemID: item.id
            )
          )
        }
      }
    }
  }

  func validate(
    request: MediaWriteRequest,
    processed: MediaAssetPayload,
    original: MediaAssetPayload?,
    thumbnail: MediaAssetPayload?
  ) throws {
    guard try !payloadIsEmpty(processed) else {
      throw MediaLibraryError.invalidMedia("The processed asset is empty.")
    }
    if let original, try payloadIsEmpty(original) {
      throw MediaLibraryError.invalidMedia("The original asset is empty.")
    }
    if let thumbnail, try payloadIsEmpty(thumbnail) {
      throw MediaLibraryError.invalidMedia("The thumbnail asset is empty.")
    }
    if let dimensions = request.dimensions, !dimensions.isValid {
      throw MediaLibraryError.invalidMedia("Pixel dimensions must be positive.")
    }
    switch request.mediaType {
    case .photo:
      if request.durationSeconds != nil {
        throw MediaLibraryError.invalidMedia("A photo cannot have a duration.")
      }
    case .video:
      guard let duration = request.durationSeconds, duration.isFinite, duration > 0 else {
        throw MediaLibraryError.invalidMedia("A video requires a positive finite duration.")
      }
    }
    _ = try validatedFileExtension(processed.fileExtension)
    _ = try original.map { try validatedFileExtension($0.fileExtension) }
    _ = try thumbnail.map { try validatedFileExtension($0.fileExtension) }
  }

  func payloadIsEmpty(_ payload: MediaAssetPayload) throws -> Bool {
    switch payload.source {
    case .data(let data):
      return data.isEmpty
    case .file(let url):
      guard url.isFileURL else {
        throw MediaLibraryError.invalidMedia("The source must be a local file URL.")
      }
      do {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
          throw MediaLibraryError.invalidMedia("The source URL does not reference a regular file.")
        }
        return (values.fileSize ?? 0) <= 0
      } catch let error as MediaLibraryError {
        throw error
      } catch {
        throw fileError("inspect source asset", url: url, error: error)
      }
    }
  }

  func materialize(_ payload: MediaAssetPayload, at destination: URL) throws {
    switch payload.source {
    case .data(let data):
      do {
        try fileSystem.writeData(data, destination, [.atomic])
      } catch {
        throw fileError("write asset", url: destination, error: error)
      }
    case .file(let source):
      _ = try payloadIsEmpty(payload)
      let temporary = destination.deletingLastPathComponent().appendingPathComponent(
        ".incoming-\(UUID().uuidString.lowercased())"
      )
      do {
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.moveItem(at: temporary, to: destination)
      } catch {
        try? fileManager.removeItem(at: temporary)
        throw fileError("copy asset", url: destination, error: error)
      }
    }
  }

  func validateItemLayout(_ item: MediaItem) throws {
    for path in item.files.allPaths {
      try validateRelativePath(path)
      let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard components.count == 3,
        components[0] == MediaLibraryPaths.media,
        components[1].caseInsensitiveCompare(item.id.uuidString) == .orderedSame,
        isSafeLeafName(components[2])
      else {
        throw MediaLibraryError.invalidRelativePath(path)
      }
    }
  }

  func stagedDirectoryIsComplete(_ directory: URL, expectedItem: MediaItem) throws -> Bool {
    let storedItem = try readItemMetadata(in: directory)
    guard storedItem == expectedItem else { return false }
    try validateItemLayout(storedItem)
    for path in storedItem.files.allPaths {
      let stagedAsset = directory.appendingPathComponent(
        URL(fileURLWithPath: path).lastPathComponent)
      if !fileManager.fileExists(atPath: stagedAsset.path) || isDirectory(stagedAsset) {
        return false
      }
    }
    return true
  }

  func validatedAssetURL(for relativePath: String) throws -> URL {
    try validateRelativePath(relativePath)
    let result = rootURL.appendingPathComponent(relativePath).standardizedFileURL
    let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    let rootPath = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
    let resolvedResult = result.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedResult.path.hasPrefix(rootPath) else {
      throw MediaLibraryError.invalidRelativePath(relativePath)
    }
    return resolvedResult
  }

  func validateRelativePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !path.contains("\\"),
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      (path as NSString).standardizingPath == path
    else {
      throw MediaLibraryError.invalidRelativePath(path)
    }
  }

  func validatedFileExtension(_ value: String) throws -> String {
    let normalized = value.lowercased()
    let allowed = CharacterSet.alphanumerics
    guard !normalized.isEmpty,
      normalized.count <= 10,
      normalized.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw MediaLibraryError.invalidFileExtension(value)
    }
    return normalized
  }

  func update(_ item: MediaItem, at index: Int) throws {
    try validateItemLayout(item)
    let directory = committedDirectory(for: item.id)
    let metadataURL = directory.appendingPathComponent(MediaLibraryPaths.itemMetadata)
    let priorData: Data
    do {
      priorData = try Data(contentsOf: metadataURL)
      try writeItemMetadata(item, in: directory)
    } catch {
      throw fileError("update item metadata", url: metadataURL, error: error)
    }

    var updated = manifest
    updated.items[index] = item
    do {
      try writeManifest(updated)
      manifest = updated
    } catch {
      do {
        try fileSystem.writeData(priorData, metadataURL, [.atomic])
      } catch {
        let rollbackError = fileError("restore item metadata", url: metadataURL, error: error)
        latestDiagnostics.append(
          MediaLibraryDiagnostic(
            severity: .error,
            code: .transactionRollbackFailed,
            message:
              "The library index failed to commit and the previous item metadata could not be restored. The current metadata and media were retained for recovery: \(rollbackError.localizedDescription)",
            relativePath: "\(MediaLibraryPaths.media)/\(item.id.uuidString.lowercased())",
            itemID: item.id
          )
        )
        throw MediaLibraryError.transactionRollbackFailed(
          operation: "restore item metadata",
          path: metadataURL.lastPathComponent,
          details: rollbackError.localizedDescription
        )
      }
      throw error
    }
  }

  func quarantine(_ source: URL, reason: String) throws {
    let destination = recoveryDirectory.appendingPathComponent(
      "\(reason)-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    do {
      try fileManager.moveItem(at: source, to: destination)
    } catch {
      throw fileError("move incomplete data to recovery", url: source, error: error)
    }
  }

  func directoryEntries(at url: URL) throws -> [URL] {
    do {
      return try fileManager.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw fileError("read directory", url: url, error: error)
    }
  }

  func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  func isSafeLeafName(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.contains("/")
      && !value.contains("\\")
      && URL(fileURLWithPath: value).lastPathComponent == value
  }

  func fileError(_ operation: String, url: URL, error: Error) -> MediaLibraryError {
    let displayPath: String
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    if url.path.hasPrefix(rootPath) {
      displayPath = String(url.path.dropFirst(rootPath.count))
    } else {
      displayPath = url.lastPathComponent
    }
    if isInsufficientStorage(error) {
      return .insufficientStorage(
        operation: operation,
        path: displayPath,
        details: error.localizedDescription
      )
    }
    return .fileOperation(
      operation: operation, path: displayPath, details: error.localizedDescription)
  }

  private func isInsufficientStorage(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    var visited = Set<ObjectIdentifier>()
    while let candidate = current {
      let identity = ObjectIdentifier(candidate)
      guard visited.insert(identity).inserted else { break }
      if candidate.domain == NSCocoaErrorDomain,
        candidate.code == NSFileWriteOutOfSpaceError
      {
        return true
      }
      if candidate.domain == NSPOSIXErrorDomain,
        candidate.code == POSIXErrorCode.ENOSPC.rawValue
      {
        return true
      }
      current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }

  static func stableHash64(_ value: String, offset: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
    var hash = offset
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01B3
    }
    return hash
  }

  static func stableUUID(for value: String) -> UUID {
    let high = stableHash64(value)
    let low = stableHash64(value, offset: 0x8422_2325_cbf2_9ce4)
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in 0..<8 {
      bytes[index] = UInt8(truncatingIfNeeded: high >> UInt64((7 - index) * 8))
      bytes[index + 8] = UInt8(truncatingIfNeeded: low >> UInt64((7 - index) * 8))
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

extension MediaFileSet {
  var allPaths: [String] {
    [processed, original, thumbnail].compactMap { $0 }
  }
}
