import SwiftUI

struct PhotoDetailView: View {
    let photo: PhotoMetadata
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showDeleteConfirmation = true } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                PhotoStorage.deletePhoto(photo)
                onDelete?()
                dismiss()
            }
        }
        .onAppear { loadImage() }
    }

    private func loadImage() {
        let url = PhotoStorage.photoURL(for: photo.filename)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: url),
                  let loaded = UIImage(data: data) else { return }
            DispatchQueue.main.async { image = loaded }
        }
    }
}
