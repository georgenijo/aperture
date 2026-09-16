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
  @State private var galleryFilter: GalleryFilter = .all

  private let columns = [
    GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 12, alignment: .top),
    GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 12, alignment: .top),
  ]

  private enum GalleryFilter: String, CaseIterable {
    case all = "All frames"
    case favorites = "Favorites"
  }

  var body: some View {
    NavigationStack {
      ZStack {
        ApertureStyle.ink.ignoresSafeArea()
        content
      }
      .navigationTitle("Gallery")
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
            .foregroundStyle(selectionMode ? ApertureStyle.amber : ApertureStyle.bone)
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
              .foregroundStyle(ApertureStyle.danger)
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
      VStack(spacing: 14) {
        ProgressView().tint(ApertureStyle.amber)
        Text("Opening the Lab…").font(.subheadline).foregroundStyle(ApertureStyle.muted)
      }
    } else if model.items.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          labHeader
          galleryFilterBar
          if visibleItems.isEmpty {
            favoritesEmptyState
          } else {
            latestDevelopment
            if earlierItems.isEmpty == false {
              ApertureSectionLabel("Earlier frames", detail: "Newest first")
                .padding(.horizontal, 18)
              LazyVGrid(columns: columns, spacing: 12) {
                ForEach(earlierItems) { item in
                  tile(item)
                }
              }
              .padding(.horizontal, 14)
            }
          }
        }
        .padding(.bottom, 18)
      }
      .scrollIndicators(.hidden)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 22) {
      ZStack {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(ApertureStyle.panel)
          .frame(width: 92, height: 92)
        Image(systemName: "photo.on.rectangle.angled")
          .font(.system(size: 35, weight: .light))
          .foregroundStyle(ApertureStyle.amber)
      }
      VStack(spacing: 8) {
        Text("Nothing developed yet")
          .font(.title3.weight(.semibold)).foregroundStyle(ApertureStyle.bone)
        Text(
          "Your photos and videos will appear here after you capture them. The Lab keeps the camera simple and the archive yours."
        )
        .font(.subheadline).foregroundStyle(ApertureStyle.muted)
        .multilineTextAlignment(.center).padding(.horizontal, 42)
      }
      HStack(spacing: 6) {
        Circle().fill(ApertureStyle.amber).frame(width: 6, height: 6)
        Text("Take a photo or video to begin")
          .font(.caption.weight(.semibold)).foregroundStyle(ApertureStyle.amber)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("lab-empty")
  }

  @ViewBuilder
  private func tile(_ item: MediaItem, featured: Bool = false) -> some View {
    let cornerRadius: CGFloat = featured ? 20 : 14
    let ratio: CGFloat = featured ? 4.0 / 3.0 : 1
    // The ratio-owning rectangle gives LazyVGrid a stable size before the
    // asynchronous thumbnail arrives. Letting UIImage report its intrinsic
    // size here can make a grid row collapse and paint the next photo over it.
    let card = Rectangle()
    .fill(ApertureStyle.panelRaised)
    .aspectRatio(ratio, contentMode: .fit)
    .overlay {
      MediaThumbnailView(
        item: item,
        mediaLibrary: model.mediaLibrary,
        thumbnailService: model.thumbnailService,
        maximumPixelDimension: featured ? 1_200 : 620
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      LinearGradient(
        colors: [.clear, .black.opacity(featured ? 0.74 : 0.54)],
        startPoint: featured ? .top : .center,
        endPoint: .bottom
      )
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .allowsHitTesting(false)
    }
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(ApertureStyle.line, lineWidth: 1)
        .allowsHitTesting(false)
    )
    .overlay(alignment: .topLeading) {
      if item.isFavorite {
        Image(systemName: "star.fill")
          .font(.caption2.weight(.bold))
          .foregroundStyle(ApertureStyle.amber)
          .padding(8)
      }
    }
    .overlay(alignment: .bottomLeading) {
      VStack(alignment: .leading, spacing: featured ? 5 : 3) {
        if featured {
          Text("LATEST DEVELOPMENT")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(ApertureStyle.amber)
        }
        HStack(spacing: 5) {
          Image(systemName: item.mediaType == .video ? "video.fill" : "camera.fill")
          Text(tileDate(for: item, includesTime: featured))
        }
      }
      .font(.system(size: featured ? 13 : 10, weight: .semibold, design: .rounded))
      .foregroundStyle(ApertureStyle.bone.opacity(0.9))
      .padding(featured ? 16 : 9)
      .allowsHitTesting(false)
    }
    .overlay(alignment: .topTrailing) {
      if selectionMode {
        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
          .font(.title3).symbolRenderingMode(.palette)
          .foregroundStyle(
            selectedIDs.contains(item.id) ? ApertureStyle.amber : ApertureStyle.bone,
            .black.opacity(0.55)
          )
          .padding(9)
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
      .frame(maxWidth: .infinity)
      .clipped()
      .buttonStyle(.plain)
      .accessibilityIdentifier("lab-item-\(item.id.uuidString)")
      .accessibilityLabel("Select \(mediaNoun(for: item))")
      .accessibilityValue(selectionValue(for: item))
      .accessibilityHint("Double tap to select or deselect this \(mediaNoun(for: item))")
    } else {
      NavigationLink(value: item) { card }
        .frame(maxWidth: .infinity)
        .clipped()
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

  private var labHeader: some View {
    AperturePanel {
      HStack(spacing: 18) {
        ZStack {
          RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(ApertureStyle.amber.opacity(0.14))
          Image(systemName: "rectangle.stack.fill")
            .font(.title3.weight(.medium))
            .foregroundStyle(ApertureStyle.amber)
        }
        .frame(width: 52, height: 52)

        VStack(alignment: .leading, spacing: 4) {
          Text("ON THIS IPHONE")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(ApertureStyle.quiet)
          Text("Your developed archive")
            .font(.headline.weight(.semibold))
            .foregroundStyle(ApertureStyle.bone)
          Text("Original captures and finished frames stay together.")
            .font(.caption)
            .foregroundStyle(ApertureStyle.muted)
            .lineLimit(2)
        }
        Spacer(minLength: 4)
        VStack(spacing: 2) {
          Text("\(model.items.count)")
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(ApertureStyle.bone)
          Text(model.items.count == 1 ? "FRAME" : "FRAMES")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(ApertureStyle.quiet)
        }
      }
      .padding(16)
    }
    .padding(.horizontal, 18)
    .padding(.top, 8)
  }

  private var galleryFilterBar: some View {
    HStack(spacing: 8) {
      ForEach(GalleryFilter.allCases, id: \.self) { filter in
        Button {
          galleryFilter = filter
        } label: {
          HStack(spacing: 6) {
            if filter == .favorites { Image(systemName: "star.fill") }
            Text(filter.rawValue)
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(
            galleryFilter == filter ? ApertureStyle.ink : ApertureStyle.bone)
          .padding(.horizontal, 14)
          .frame(minHeight: 38)
          .background(
            galleryFilter == filter ? ApertureStyle.amber : ApertureStyle.panel,
            in: Capsule()
          )
          .overlay(Capsule().stroke(ApertureStyle.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
    .padding(.horizontal, 18)
  }

  @ViewBuilder
  private var latestDevelopment: some View {
    if let latest = visibleItems.first {
      tile(latest, featured: true)
        .padding(.horizontal, 14)
    }
  }

  private var favoritesEmptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "star")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(ApertureStyle.amber)
      Text("No favorites yet")
        .font(.headline)
        .foregroundStyle(ApertureStyle.bone)
      Text("Touch and hold a frame to add it here.")
        .font(.subheadline)
        .foregroundStyle(ApertureStyle.muted)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 54)
  }

  private var visibleItems: [MediaItem] {
    switch galleryFilter {
    case .all: return model.items
    case .favorites: return model.items.filter(\.isFavorite)
    }
  }

  private var earlierItems: ArraySlice<MediaItem> {
    visibleItems.dropFirst()
  }

  private func tileDate(for item: MediaItem, includesTime: Bool) -> String {
    let style = includesTime
      ? Date.FormatStyle.dateTime.month(.abbreviated).day().year().hour().minute()
      : Date.FormatStyle.dateTime.month(.abbreviated).day()
    return item.capturedAt.formatted(style)
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
