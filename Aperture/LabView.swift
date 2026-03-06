import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct LabView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [PhotoMetadata] = []
    @State private var showDeleteAllConfirmation = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if photos.isEmpty {
                    emptyState
                } else {
                    galleryGrid
                }
            }
            .navigationTitle("The Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showDeleteAllConfirmation = true } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .opacity(photos.isEmpty ? 0 : 1)
                    .disabled(photos.isEmpty)
                }
            }
        }
        .onAppear {
            photos = PhotoStorage.loadAllPhotos()
        }
        .confirmationDialog("Delete all photos?", isPresented: $showDeleteAllConfirmation, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                for photo in photos {
                    PhotoStorage.deletePhoto(photo)
                }
                ThumbnailCache.shared.clearAll()
                photos = []
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.gray)
            Text("No photos yet")
                .font(.title3)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var galleryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(photos, id: \.filename) { photo in
                    NavigationLink(value: photo) {
                        ThumbnailView(photo: photo)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .navigationDestination(for: PhotoMetadata.self) { photo in
            PhotoDetailView(photo: photo) {
                photos.removeAll { $0.filename == photo.filename }
            }
        }
    }
}

private final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let queue = OperationQueue()
    private let cacheDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        memoryCache.countLimit = 200
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
    }

    private func cacheFileURL(for filename: String) -> URL {
        let id = (filename as NSString).deletingPathExtension
        return cacheDirectory.appendingPathComponent("\(id).jpg")
    }

    func removeCachedThumbnail(for filename: String) {
        let key = filename as NSString
        memoryCache.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: cacheFileURL(for: filename))
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func loadThumbnail(for photo: PhotoMetadata, completion: @escaping (UIImage?) -> Void) {
        let key = photo.filename as NSString

        if let cached = memoryCache.object(forKey: key) {
            completion(cached)
            return
        }

        queue.addOperation { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            let cachedFile = cacheFileURL(for: photo.filename)

            // Try JPEG cache on disk
            if let data = try? Data(contentsOf: cachedFile), let img = UIImage(data: data) {
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                print("[Thumbnail] \(photo.filename) — cache hit: \(String(format: "%.1f", ms))ms")
                self.memoryCache.setObject(img, forKey: key)
                DispatchQueue.main.async { completion(img) }
                return
            }

            // Decode from HEIC source and cache as JPEG
            let sourceURL = PhotoStorage.photoURL(for: photo.filename)
            let maxPixel = 150.0 * UIScreen.main.scale
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let img = UIImage(cgImage: cgImage)

            // Write JPEG cache to disk using CGImageDestination (avoids alpha warning)
            if let dest = CGImageDestinationCreateWithURL(cachedFile as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }

            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("[Thumbnail] \(photo.filename) — decoded: \(String(format: "%.1f", ms))ms, size: \(cgImage.width)x\(cgImage.height)")
            self.memoryCache.setObject(img, forKey: key)
            DispatchQueue.main.async { completion(img) }
        }
    }
}

private struct ThumbnailView: View {
    let photo: PhotoMetadata
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .onAppear {
            guard image == nil else { return }
            ThumbnailCache.shared.loadThumbnail(for: photo) { img in
                image = img
            }
        }
    }
}
