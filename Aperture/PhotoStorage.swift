import Foundation

struct PhotoMetadata: Codable, Hashable {
    let filename: String
    let timestamp: Date
}

struct PhotoStorage {
    private static var photosDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("photos", isDirectory: true)
    }

    static func ensureDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: photosDirectory.path) {
            try? fm.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        }
    }

    static func loadAllPhotos() -> [PhotoMetadata] {
        ensureDirectoryExists()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: photosDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let metadata = try? decoder.decode(PhotoMetadata.self, from: data) else {
                    return nil
                }
                return metadata
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    static func photoURL(for filename: String) -> URL {
        photosDirectory.appendingPathComponent(filename)
    }

    static func deletePhoto(_ metadata: PhotoMetadata) {
        let fm = FileManager.default
        let photoFile = photosDirectory.appendingPathComponent(metadata.filename)
        let id = (metadata.filename as NSString).deletingPathExtension
        let metadataFile = photosDirectory.appendingPathComponent("\(id).json")
        try? fm.removeItem(at: photoFile)
        try? fm.removeItem(at: metadataFile)

        // Clean cached thumbnail
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cachedThumb = caches.appendingPathComponent("thumbnails/\(id).jpg")
        try? fm.removeItem(at: cachedThumb)
    }

    static func savePhoto(_ imageData: Data, fileExtension: String = "jpg") -> String? {
        ensureDirectoryExists()

        let id = UUID().uuidString
        let filename = "\(id).\(fileExtension)"
        let photoURL = photosDirectory.appendingPathComponent(filename)
        let metadataURL = photosDirectory.appendingPathComponent("\(id).json")

        do {
            try imageData.write(to: photoURL)

            let metadata = PhotoMetadata(filename: filename, timestamp: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let metadataData = try encoder.encode(metadata)
            try metadataData.write(to: metadataURL)

            return filename
        } catch {
            print("Failed to save photo: \(error)")
            return nil
        }
    }
}
