import SwiftUI

struct LabView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var selectionMode = false
  @State private var selectedIDs: Set<UUID> = []
  @State private var showDeleteConfirmation = false
  @State private var isExporting = false
  @State private var localNotice: String?
  @State private var shareURLs: [URL] = []

  private let columns = [
    GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3),
    GridItem(.flexible(), spacing: 3),
  ]

  var body: some View {
    NavigationStack {
      ZStack {
        ApertureStyle.ink.ignoresSafeArea()
        content
      }
      .navigationTitle("The Lab")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbarBackground(ApertureStyle.ink, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close Lab")
        }
        ToolbarItemGroup(placement: .primaryAction) {
          if !model.items.isEmpty {
            Button(selectionMode ? "Done" : "Select") {
              selectionMode.toggle()
              if !selectionMode { selectedIDs.removeAll() }
            }
            .accessibilityIdentifier("lab-select")
            if selectionMode && !selectedIDs.isEmpty {
              Button {
                isExporting = true
                Task {
                  if await model.export(selectedItems) {
                    localNotice =
                      selectedItems.count == 1
                      ? "Saved to Photos." : "Saved \(selectedItems.count) media items to Photos."
                  }
                  isExporting = false
                }
              } label: {
                Image(systemName: "photo.badge.arrow.down")
              }
              .disabled(isExporting)
              .accessibilityIdentifier("lab-export")
              .accessibilityLabel("Save selected \(selectedMediaDescription) to Photos")
              .accessibilityHint("Export the selected media to the Photos app")
              Button {
                Task {
                  do {
                    var urls: [URL] = []
                    for item in selectedItems where item.processing.phase == .ready {
                      if let url = try await model.processedURL(for: item) {
                        urls.append(url)
                      }
                    }
                    guard !urls.isEmpty else {
                      model.errorMessage = "There is no developed media to share yet."
                      return
                    }
                    shareURLs = urls
                  } catch {
                    model.errorMessage = error.localizedDescription
                  }
                }
              } label: {
                Image(systemName: "square.and.arrow.up")
              }
              .accessibilityIdentifier("lab-share")
              .accessibilityLabel("Share selected \(selectedMediaDescription)")
              .accessibilityHint("Share the selected media")
              Button {
                showDeleteConfirmation = true
              } label: {
                Image(systemName: "trash")
              }
              .foregroundStyle(.red)
              .accessibilityIdentifier("lab-delete")
              .accessibilityLabel("Delete selected \(selectedMediaDescription)")
              .accessibilityHint("Delete the selected media from the Lab")
            }
          }
        }
      }
      .navigationDestination(for: MediaItem.self) { item in
        PhotoDetailView(itemID: item.id, model: model)
      }
    }
    .task { await model.refresh() }
    .confirmationDialog(
      selectedIDs.count == 1 ? "Delete this media?" : "Delete \(selectedIDs.count) media items?",
      isPresented: $showDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        Task {
          let toDelete = selectedItems
          for item in toDelete { _ = await model.delete(item) }
          selectedIDs.removeAll()
          selectionMode = false
        }
      }
      .accessibilityIdentifier("lab-delete-confirm")
      Button("Cancel", role: .cancel) {}
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
    .sheet(isPresented: Binding(get: { !shareURLs.isEmpty }, set: { if !$0 { shareURLs = [] } })) {
      ShareSheet(activityItems: shareURLs.map { $0 as Any })
    }
    .overlay(alignment: .top) {
      if let localNotice {
        Text(localNotice)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(ApertureStyle.bone)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(ApertureStyle.panelRaised, in: Capsule())
          .overlay(Capsule().stroke(.white.opacity(0.12)))
          .padding(.top, 12)
          .onTapGesture { self.localNotice = nil }
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if !model.isPrepared {
      VStack(spacing: 14) {
        ProgressView().tint(ApertureStyle.amber)
        Text("Opening the Lab…").font(.subheadline).foregroundStyle(ApertureStyle.muted)
      }
    } else if model.items.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 3) {
          ForEach(model.items) { item in
            tile(item)
          }
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 18)
      }
      .scrollIndicators(.hidden)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.system(size: 45, weight: .light))
        .foregroundStyle(ApertureStyle.amber)
      Text("Nothing developed yet")
        .font(.title3.weight(.semibold)).foregroundStyle(ApertureStyle.bone)
      Text(
        "Your photos and videos will appear here after you capture them. The Lab keeps the camera simple and the archive yours."
      )
      .font(.subheadline).foregroundStyle(ApertureStyle.muted)
      .multilineTextAlignment(.center).padding(.horizontal, 42)
      Text("Take a photo or video to begin")
        .font(.caption.weight(.semibold)).foregroundStyle(ApertureStyle.amber)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("lab-empty")
  }

  @ViewBuilder
  private func tile(_ item: MediaItem) -> some View {
    let card = MediaThumbnailView(
      item: item,
      mediaLibrary: model.mediaLibrary,
      thumbnailService: model.thumbnailService,
      maximumPixelDimension: 520
    )
    .aspectRatio(1, contentMode: .fit)
    .overlay(alignment: .topLeading) {
      if item.isFavorite {
        Image(systemName: "star.fill").font(.caption2.weight(.bold)).foregroundStyle(
          ApertureStyle.amber
        ).padding(7)
      }
    }
    .overlay(alignment: .topTrailing) {
      if selectionMode {
        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
          .font(.title3).symbolRenderingMode(.palette)
          .foregroundStyle(
            selectedIDs.contains(item.id) ? ApertureStyle.amber : ApertureStyle.bone,
            .black.opacity(0.55)
          )
          .padding(8)
      }
    }
    .contentShape(Rectangle())
    .accessibilityHidden(true)

    if selectionMode {
      Button {
        toggleSelection(item)
      } label: {
        card
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("lab-item-\(item.id.uuidString)")
      .accessibilityLabel("Select \(mediaNoun(for: item))")
      .accessibilityValue(selectionValue(for: item))
      .accessibilityHint("Double tap to select or deselect this \(mediaNoun(for: item))")
    } else {
      NavigationLink(value: item) { card }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lab-item-\(item.id.uuidString)")
        .accessibilityLabel("Open \(mediaNoun(for: item))")
        .accessibilityValue(detailValue(for: item))
        .accessibilityHint("Double tap to open this \(mediaNoun(for: item))")
        .contextMenu {
          Button {
            Task { await model.setFavorite(item, isFavorite: !item.isFavorite) }
          } label: {
            Label(
              item.isFavorite ? "Remove Favorite" : "Favorite",
              systemImage: item.isFavorite ? "star.slash" : "star")
          }
          Button {
            selectedIDs = [item.id]
            showDeleteConfirmation = true
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
    }
  }

  private var selectedItems: [MediaItem] {
    model.items.filter { selectedIDs.contains($0.id) }
  }

  private var selectedMediaDescription: String {
    let selected = selectedItems
    guard selected.count > 1 else {
      return selected.first.map(mediaNoun(for:)) ?? "media"
    }
    let types = Set(selected.map { $0.mediaType })
    return types.count == 1
      ? "\(selected.count) \(selected.first.map(mediaNoun(for:)) ?? "media")s"
      : "\(selected.count) media items"
  }

  private func mediaNoun(for item: MediaItem) -> String {
    item.mediaType == .video ? "video" : "photo"
  }

  private func selectionValue(for item: MediaItem) -> String {
    selectedIDs.contains(item.id) ? "Selected" : "Not selected"
  }

  private func detailValue(for item: MediaItem) -> String {
    var parts: [String] = []
    if item.processing.phase == .processing { parts.append("Developing") }
    if item.processing.phase == .failed { parts.append("Development failed") }
    if item.isFavorite { parts.append("Favorite") }
    return parts.isEmpty ? "Ready" : parts.joined(separator: ", ")
  }

  private func toggleSelection(_ item: MediaItem) {
    if selectedIDs.contains(item.id) {
      selectedIDs.remove(item.id)
    } else {
      selectedIDs.insert(item.id)
    }
  }
}
