import AVKit
import SwiftUI
import UIKit

struct PhotoDetailView: View {
  let itemID: UUID
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var currentID: UUID
  @State private var showDeleteConfirmation = false
  @State private var shareURL: URL?
  @State private var isSharing = false
  @State private var isExporting = false
  @State private var localNotice: String?

  init(itemID: UUID, model: AppModel) {
    self.itemID = itemID
    self.model = model
    _currentID = State(initialValue: itemID)
  }

  var body: some View {
    ZStack {
      ApertureStyle.ink.ignoresSafeArea()
      if model.items.isEmpty {
        Text("This media is no longer in the Lab.")
          .foregroundStyle(ApertureStyle.muted)
      } else {
        TabView(selection: $currentID) {
          ForEach(model.items) { item in
            DetailPage(item: item, model: model)
              .tag(item.id)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text(currentTitle)
          .font(.caption.weight(.semibold)).foregroundStyle(ApertureStyle.muted)
      }
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        if let item = currentItem {
          Button {
            Task { await model.setFavorite(item, isFavorite: !item.isFavorite) }
          } label: {
            Image(systemName: item.isFavorite ? "star.fill" : "star")
          }
          .foregroundStyle(item.isFavorite ? ApertureStyle.amber : ApertureStyle.bone)
          .accessibilityLabel(
            item.isFavorite
              ? "Remove favorite from this \(mediaNoun(for: item))"
              : "Favorite this \(mediaNoun(for: item))")
          Button {
            isSharing = true
            Task {
              do {
                shareURL = try await model.processedURL(for: item)
              } catch { model.errorMessage = error.localizedDescription }
              isSharing = false
            }
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          .disabled(isSharing || item.processing.phase != .ready)
          .accessibilityIdentifier("detail-share")
          .accessibilityLabel("Share \(mediaNoun(for: item))")
          .accessibilityHint(
            item.processing.phase == .ready
              ? "Share this \(mediaNoun(for: item))" : "Available after development finishes")
          Button {
            isExporting = true
            Task {
              if await model.export([item]) { localNotice = "Saved to Photos." }
              isExporting = false
            }
          } label: {
            Image(systemName: "photo.badge.arrow.down")
          }
          .disabled(isExporting || item.processing.phase != .ready)
          .accessibilityIdentifier("detail-export")
          .accessibilityLabel("Save \(mediaNoun(for: item)) to Photos")
          .accessibilityHint(
            item.processing.phase == .ready
              ? "Export this \(mediaNoun(for: item)) to the Photos app"
              : "Available after development finishes")
          Button {
            showDeleteConfirmation = true
          } label: {
            Image(systemName: "trash")
          }
          .foregroundStyle(.red)
          .accessibilityIdentifier("detail-delete")
          .accessibilityLabel("Delete \(mediaNoun(for: item))")
          .accessibilityHint("Delete this \(mediaNoun(for: item)) from the Lab")
        }
      }
    }
    .confirmationDialog(
      "Delete this media?", isPresented: $showDeleteConfirmation, titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let item = currentItem else { return }
        Task {
          if await model.delete(item) { dismiss() }
        }
      }
      .accessibilityIdentifier("detail-delete-confirm")
      Button("Cancel", role: .cancel) {}
    }
    .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
      if let shareURL { ShareSheet(activityItems: [shareURL]) }
    }
    .alert(
      "Aperture",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .overlay(alignment: .top) {
      if let localNotice {
        Button(localNotice) { self.localNotice = nil }
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(ApertureStyle.bone)
          .frame(minHeight: 44)
          .padding(.horizontal, 14)
          .background(ApertureStyle.panelRaised, in: Capsule())
          .overlay(Capsule().stroke(.white.opacity(0.12)))
          .padding(.top, 12)
          .accessibilityHint("Dismiss message")
      }
    }
    .onChange(of: model.items) { _, items in
      if !items.contains(where: { $0.id == currentID }) {
        if let fallback = items.first { currentID = fallback.id } else { dismiss() }
      }
    }
  }

  private var currentItem: MediaItem? {
    model.items.first(where: { $0.id == currentID })
      ?? model.items.first(where: { $0.id == itemID })
  }

  private var currentTitle: String {
    guard let item = currentItem else { return "Media" }
    let recipe = item.recipe.identifier.rawValue
      .replacingOccurrences(of: "aperture.", with: "")
      .capitalized
    return "\(mediaNoun(for: item).capitalized) · \(recipe)"
  }

  private func mediaNoun(for item: MediaItem) -> String {
    item.mediaType == .video ? "video" : "photo"
  }
}

private struct DetailPage: View {
  let item: MediaItem
  @ObservedObject var model: AppModel
  @State private var image: UIImage?
  @State private var loadError: String?
  @State private var player: AVPlayer?

  var body: some View {
    ZStack {
      if item.processing.phase == .failed {
        failedState
      } else if item.mediaType == .video, let player {
        VideoPlayer(player: player)
          .onDisappear { player.pause() }
          .padding(.horizontal, 6)
      } else if let image {
        ZoomableImageView(image: image)
          .padding(.horizontal, 6)
      } else if let loadError {
        loadFailureState(message: loadError)
      } else {
        VStack(spacing: 12) {
          ProgressView().tint(ApertureStyle.amber)
          Text(item.processing.phase == .processing ? "Developing…" : "Opening \(mediaNoun)…")
            .font(.subheadline).foregroundStyle(ApertureStyle.muted)
        }
      }
    }
    .task(
      id: item.id.uuidString + "-" + item.files.processed + "-" + item.processing.phase.rawValue
    ) {
      await load()
    }
    .overlay(alignment: .bottom) {
      VStack(spacing: 5) {
        Text(
          item.recipe.identifier.rawValue.replacingOccurrences(of: "aperture.", with: "")
            .uppercased()
        )
        .font(.caption2.weight(.bold)).tracking(1.4)
        Text(item.capturedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
      }
      .foregroundStyle(ApertureStyle.bone.opacity(0.72))
      .padding(.bottom, 20)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(mediaNoun.capitalized) detail")
    .accessibilityValue(detailAccessibilityValue)
  }

  private var failedState: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle").font(.system(size: 38)).foregroundStyle(
        ApertureStyle.amber)
      Text("Development failed").font(.headline).foregroundStyle(ApertureStyle.bone)
      Text(
        item.processing.failure?.message ?? loadError
          ?? ("The " + mediaNoun + " could not be developed.")
      )
      .font(.subheadline).foregroundStyle(ApertureStyle.muted).multilineTextAlignment(.center)
      .padding(.horizontal, 34)
      Button("Try Again") { model.retry(item) }
        .buttonStyle(.borderedProminent).tint(ApertureStyle.amber).foregroundStyle(
          ApertureStyle.ink)
    }
  }

  private func loadFailureState(message: String) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "photo.badge.exclamationmark")
        .font(.system(size: 38)).foregroundStyle(ApertureStyle.amber)
      Text(mediaNoun.capitalized + " unavailable").font(.headline).foregroundStyle(
        ApertureStyle.bone)
      Text(message).font(.subheadline).foregroundStyle(ApertureStyle.muted)
        .multilineTextAlignment(.center).padding(.horizontal, 34)
      Button("Try Again") { Task { await load() } }
        .buttonStyle(.borderedProminent).tint(ApertureStyle.amber).foregroundStyle(
          ApertureStyle.ink)
    }
  }

  private func load() async {
    guard item.processing.phase == .ready else { return }
    image = nil
    loadError = nil
    do {
      guard let url = try await model.processedURL(for: item) else {
        throw MediaLibraryError.fileOperation(
          operation: "read", path: item.id.uuidString, details: "The processed asset is missing.")
      }
      if item.mediaType == .video {
        let nextPlayer = AVPlayer(url: url)
        guard !Task.isCancelled else { return }
        player = nextPlayer
        image = nil
        return
      }
      let decoded = try await model.thumbnailService.image(
        for: item, sourceURL: url, maximumPixelDimension: 2400)
      guard !Task.isCancelled else { return }
      image = decoded
    } catch {
      guard !Task.isCancelled else { return }
      loadError = error.localizedDescription
    }
  }

  private var mediaNoun: String {
    item.mediaType == .video ? "video" : "photo"
  }

  private var detailAccessibilityValue: String {
    switch item.processing.phase {
    case .pending, .processing:
      return "Developing"
    case .failed:
      return "Development failed"
    case .ready:
      return item.mediaType == .video ? "Ready to play" : "Ready to view"
    }
  }
}
