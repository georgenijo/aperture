import SwiftUI
import UIKit

struct MediaThumbnailView: View {
  let item: MediaItem
  let mediaLibrary: MediaLibrary
  let thumbnailService: ThumbnailService
  var maximumPixelDimension: Int = 420

  @State private var image: UIImage?
  @State private var failed = false

  var body: some View {
    ZStack {
      ApertureStyle.panelRaised
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      } else if failed {
        Image(systemName: item.processing.phase == .failed ? "exclamationmark.triangle" : "photo")
          .font(.title3)
          .foregroundStyle(ApertureStyle.muted)
      } else {
        ProgressView()
          .tint(ApertureStyle.amber)
      }
      if item.processing.phase == .processing {
        VStack {
          Spacer()
          HStack(spacing: 5) {
            ProgressView().controlSize(.mini).tint(ApertureStyle.amber)
            Text("Developing")
              .font(.caption2.weight(.semibold))
          }
          .foregroundStyle(ApertureStyle.bone)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(.black.opacity(0.72), in: Capsule())
          .padding(7)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .task(
      id: item.id.uuidString + "-" + item.files.processed + "-" + item.processing.phase.rawValue
        + "-" + String(maximumPixelDimension)
    ) {
      await load()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }

  private func load() async {
    do {
      guard let sourceURL = try await mediaLibrary.assetURL(for: item, kind: .processed) else {
        failed = true
        return
      }
      let rendered = try await thumbnailService.image(
        for: item,
        sourceURL: sourceURL,
        maximumPixelDimension: maximumPixelDimension
      )
      guard !Task.isCancelled else { return }
      image = rendered
      failed = false
    } catch {
      guard !Task.isCancelled else { return }
      failed = true
    }
  }

  private var accessibilityLabel: String {
    let noun = item.mediaType == .video ? "Video" : "Photo"
    return item.processing.phase == .failed ? "\(noun) with a development error" : noun
  }

  private var accessibilityValue: String {
    switch item.processing.phase {
    case .pending, .processing: return "Developing"
    case .failed: return "Development failed"
    case .ready: return item.isFavorite ? "Ready, Favorite" : "Ready"
    }
  }
}
