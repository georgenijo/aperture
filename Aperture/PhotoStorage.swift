import Foundation

struct PhotoMetadata: Codable {
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

    static func savePhoto(_ imageData: Data) -> String? {
        ensureDirectoryExists()

        let id = UUID().uuidString
        let filename = "\(id).jpg"
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
