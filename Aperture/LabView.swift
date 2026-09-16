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
  @State private var favoritesOnly = false

  private static let gridSpacing: CGFloat = 2
  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: gridSpacing),
    count: 3
  )

  var body: some View {
    NavigationStack {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ApertureStyle.ink.ignoresSafeArea())
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button {
              dismiss()
            } label: {
              Image(systemName: "xmark")
            }
            .foregroundStyle(ApertureStyle.bone)
            .accessibilityLabel("Close Lab")
          }
          ToolbarItemGroup(placement: .primaryAction) {
            if !model.items.isEmpty {
              if !selectionMode {
                Button {
                  favoritesOnly.toggle()
                } label: {
                  Image(systemName: favoritesOnly ? "star.fill" : "star")
                }
                .foregroundStyle(favoritesOnly ? ApertureStyle.amber : ApertureStyle.bone)
                .accessibilityLabel("Favorites only")
                .accessibilityValue(favoritesOnly ? "On" : "Off")
                .accessibilityHint(favoritesOnly ? "Show all frames" : "Show only favorite frames")
              }
              Button(selectionMode ? "Done" : "Select") {
                selectionMode.toggle()
                if !selectionMode { selectedIDs.removeAll() }
              }
              .fontWeight(.semibold)
              .foregroundStyle(selectionMode ? ApertureStyle.amber : ApertureStyle.bone)
              .accessibilityIdentifier("lab-select")
            }
          }
          if selectionMode && !selectedIDs.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
              shareSelectionButton
              Spacer()
              exportSelectionButton
              deleteSelectionButton
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
      Button("Cancel", role: .cancel) {
        // A context-menu delete seeds the selection; don't let a cancelled
        // one leak into the next Select session.
        if !selectionMode { selectedIDs.removeAll() }
      }
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
        Button(localNotice) { self.localNotice = nil }
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(ApertureStyle.bone)
          .frame(minHeight: 44)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(ApertureStyle.panelRaised, in: Capsule())
          .overlay(Capsule().stroke(ApertureStyle.line))
          .padding(.top, 12)
          .accessibilityHint("Dismiss message")
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if !model.isPrepared {
      ProgressView().tint(ApertureStyle.amber)
    } else if model.items.isEmpty {
      emptyState
    } else if visibleItems.isEmpty {
      favoritesEmptyState
    } else {
      ScrollView {
        LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
          ForEach(visibleItems) { item in
            tile(item)
          }
        }
        // Keep the gutter at the screen edges too. Measured on the iOS 26.5
        // simulator: when this grid spanned the scroll view's full width, the
        // first row was laid out under the navigation bar (tile y=2 instead
        // of y=103). The horizontal inset is load-bearing, not cosmetic;
        // testLabGridStartsBelowNavigationBar guards it.
        .padding(.horizontal, Self.gridSpacing)
        .padding(.top, Self.gridSpacing)
        .padding(.bottom, 24)
      }
      .scrollIndicators(.hidden)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(ApertureStyle.amber)
      Text("Nothing developed yet")
        .font(.headline).foregroundStyle(ApertureStyle.bone)
      Text("Shoot something and it shows up here.")
        .font(.subheadline).foregroundStyle(ApertureStyle.muted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("lab-empty")
  }

  private var favoritesEmptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "star")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(ApertureStyle.amber)
      Text("No favorites yet")
        .font(.headline)
        .foregroundStyle(ApertureStyle.bone)
      Text("Touch and hold a frame to add one.")
        .font(.subheadline)
        .foregroundStyle(ApertureStyle.muted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var shareSelectionButton: some View {
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
    .foregroundStyle(ApertureStyle.bone)
    .accessibilityIdentifier("lab-share")
    .accessibilityLabel("Share selected \(selectedMediaDescription)")
    .accessibilityHint("Share the selected media")
  }

  private var exportSelectionButton: some View {
    Button {
      isExporting = true
      let items = selectedItems
      Task {
        if await model.export(items) {
          localNotice =
            items.count == 1
            ? "Saved to Photos." : "Saved \(items.count) media items to Photos."
        }
        isExporting = false
      }
    } label: {
      Image(systemName: "photo.badge.arrow.down")
    }
    .disabled(isExporting)
    .foregroundStyle(ApertureStyle.bone)
    .accessibilityIdentifier("lab-export")
    .accessibilityLabel("Save selected \(selectedMediaDescription) to Photos")
    .accessibilityHint("Export the selected media to the Photos app")
  }

  private var deleteSelectionButton: some View {
    Button {
      showDeleteConfirmation = true
    } label: {
      Image(systemName: "trash")
    }
    .foregroundStyle(ApertureStyle.danger)
    .accessibilityIdentifier("lab-delete")
    .accessibilityLabel("Delete selected \(selectedMediaDescription)")
    .accessibilityHint("Delete the selected media from the Lab")
  }

  @ViewBuilder
  private func tile(_ item: MediaItem) -> some View {
    let isSelected = selectedIDs.contains(item.id)
    // The square owns the size so the grid stays stable before the
    // asynchronous thumbnail arrives; letting UIImage report its intrinsic
    // size can collapse a row and paint the next frame over it.
    let card = Rectangle()
      .fill(ApertureStyle.panelRaised)
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        MediaThumbnailView(
          item: item,
          mediaLibrary: model.mediaLibrary,
          thumbnailService: model.thumbnailService,
          maximumPixelDimension: 480
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      }
      .clipped()
      .overlay(alignment: .bottomLeading) {
        if item.mediaType == .video {
          Image(systemName: "video.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 2)
            .padding(6)
        }
      }
      .overlay(alignment: .topLeading) {
        if item.isFavorite {
          Image(systemName: "star.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(ApertureStyle.amber)
            .shadow(color: .black.opacity(0.7), radius: 2)
            .padding(6)
        }
      }
      .overlay {
        if selectionMode && isSelected {
          Rectangle().fill(.black.opacity(0.3))
        }
      }
      .overlay(alignment: .topTrailing) {
        if selectionMode {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .symbolRenderingMode(.palette)
            .foregroundStyle(
              isSelected ? ApertureStyle.ink : ApertureStyle.bone,
              isSelected ? ApertureStyle.amber : .black.opacity(0.4)
            )
            .padding(5)
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

  private var visibleItems: [MediaItem] {
    favoritesOnly ? model.items.filter(\.isFavorite) : model.items
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
