import SwiftUI

struct SettingsView: View {
  @Binding var settings: AppSettings
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          intro

          settingsGroup("Film", detail: "Shape the character of every developed frame") {
            settingRow("Film stock", detail: selectedFilmName) {
              Picker("Film stock", selection: setting(\.selectedFilm)) {
                ForEach(FilmRecipeCatalog.all) { film in
                  Text(film.displayName).tag(film.id)
                }
              }
              .pickerStyle(.menu)
              .tint(ApertureStyle.accent(for: settings.selectedFilm))
            }
            settingDivider()
            settingRow("Light leaks", detail: "Occasional edge flare") {
              Toggle("Light leaks", isOn: setting(\.lightLeaksEnabled))
                .labelsHidden()
                .tint(ApertureStyle.amber)
                .accessibilityLabel("Light Leaks")
            }
            settingDivider()
            settingRow("Date stamp", detail: settings.dateStamp.mode == .off ? "Hidden" : "Printed on frame") {
              Picker("Date stamp", selection: dateMode) {
                Text("Off").tag(DateStampMode.off)
                Text("Actual Date & Time").tag(DateStampMode.current)
                Text("1998 Date").tag(DateStampMode.nostalgic1998)
              }
              .pickerStyle(.menu)
              .tint(ApertureStyle.amber)
            }
            if settings.dateStamp.mode != .off {
              settingDivider()
              settingRow("Date format", detail: "How the stamp is printed") {
                Picker("Date format", selection: dateFormat) {
                  Text("Digital · 2026/09/15 20:44").tag(DateStampFormat.digitalDateTime)
                  Text("Huji · 9 15 '98").tag(DateStampFormat.huji)
                  Text("Local").tag(DateStampFormat.localeAware)
                  Text("Year Month Day").tag(DateStampFormat.yearMonthDay)
                  Text("Month Day Year").tag(DateStampFormat.monthDayYear)
                  Text("Day Month Year").tag(DateStampFormat.dayMonthYear)
                }
                .pickerStyle(.menu)
                .tint(ApertureStyle.amber)
              }
            }
          }

          settingsGroup("Capture", detail: "Small choices, saved with each capture") {
            settingRow("Haptics", detail: "Feedback when the shutter fires") {
              Toggle("Haptics", isOn: setting(\.hapticsEnabled))
                .labelsHidden()
                .tint(ApertureStyle.amber)
                .accessibilityLabel("Haptics")
            }
            settingDivider()
            settingRow("Preserve original", detail: "Keep an untouched camera copy") {
              Toggle("Preserve original", isOn: setting(\.preserveOriginal))
                .labelsHidden()
                .tint(ApertureStyle.amber)
                .accessibilityLabel("Preserve Original")
            }
            settingDivider()
            settingRow("Photo quality", detail: photoQualityDescription) {
              Picker("Photo quality", selection: setting(\.photoQuality)) {
                Text("Space Saving").tag(PhotoQualityPreference.spaceSaving)
                Text("Balanced").tag(PhotoQualityPreference.balanced)
                Text("Maximum").tag(PhotoQualityPreference.maximum)
              }
              .pickerStyle(.menu)
              .tint(ApertureStyle.amber)
            }
          }

          settingsGroup("Viewfinder", detail: "How the live image fills the screen") {
            settingRow("Full screen", detail: "Edge-to-edge preview, floating controls") {
              Toggle("Full screen", isOn: setting(\.fullScreenViewfinderEnabled))
                .labelsHidden()
                .tint(ApertureStyle.amber)
                .accessibilityLabel("Full Screen Viewfinder")
            }
            Text(
              "The preview fills the screen and crops what you see. Photos and films are still captured at the camera's own framing."
            )
            .font(.caption)
            .foregroundStyle(ApertureStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
          }

          settingsGroup("Photos", detail: "Exports are always initiated by you") {
            settingRow("Auto-save developed media", detail: "Add finished frames to Photos") {
              Toggle("Auto-save developed media", isOn: setting(\.autoSaveToPhotos))
                .labelsHidden()
                .tint(ApertureStyle.amber)
                .accessibilityLabel("Auto-save Developed Media")
            }
            Text(
              "Photos permission is requested only when you export or enable auto-save. Aperture remains usable without it."
            )
            .font(.caption)
            .foregroundStyle(ApertureStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
          }

          settingsGroup("Privacy", detail: "Your archive stays yours") {
            privacyRow("Processing stays on this iPhone", systemImage: "iphone.and.arrow.forward")
            settingDivider()
            privacyRow("No accounts, analytics, ads, or uploads", systemImage: "hand.raised.fill")
            Text(
              "Deleting media from the Lab removes Aperture’s local copy and rebuildable cache. Copies previously exported to Photos are managed in Photos."
            )
            .font(.caption)
            .foregroundStyle(ApertureStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
          }

          settingsGroup("About") {
            HStack {
              Text("Version").foregroundStyle(ApertureStyle.bone)
              Spacer()
              Text(version).foregroundStyle(ApertureStyle.muted).monospacedDigit()
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            Text(
              "Aperture is an original, private-by-design film camera made for simple shooting and surprising results."
            )
            .font(.caption)
            .foregroundStyle(ApertureStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 28)
      }
      .scrollIndicators(.hidden)
      .scrollContentBackground(.hidden)
      .background(ApertureStyle.ink)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .foregroundStyle(ApertureStyle.amber)
            .fontWeight(.semibold)
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Image(systemName: "slider.horizontal.3")
          .foregroundStyle(ApertureStyle.amber)
        Text("Darkroom notes")
          .font(.system(.caption, design: .rounded).weight(.bold))
          .tracking(1.4)
          .foregroundStyle(ApertureStyle.amber)
      }
      Text("Make it yours.")
        .font(.title2.weight(.semibold))
        .foregroundStyle(ApertureStyle.bone)
      Text("Aperture keeps the controls considered, so the moment stays in focus.")
        .font(.subheadline)
        .foregroundStyle(ApertureStyle.muted)
    }
    .padding(.horizontal, 4)
  }

  @ViewBuilder
  private func settingsGroup<Content: View>(
    _ title: String,
    detail: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ApertureSectionLabel(title, detail: detail)
      AperturePanel {
        VStack(spacing: 0) { content() }
      }
    }
  }

  private func settingRow<Control: View>(
    _ title: String,
    detail: String,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(ApertureStyle.bone)
        Text(detail)
          .font(.caption)
          .foregroundStyle(ApertureStyle.quiet)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      control()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }

  private func privacyRow(_ title: String, systemImage: String) -> some View {
    Label {
      Text(title)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(ApertureStyle.bone)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(ApertureStyle.amber)
        .frame(width: 22)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }

  private func settingDivider() -> some View {
    Rectangle()
      .fill(ApertureStyle.line)
      .frame(height: 1)
      .padding(.leading, 16)
  }

  private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { value in
        var updated = settings
        updated[keyPath: keyPath] = value
        settings = updated
      }
    )
  }

  private var dateMode: Binding<DateStampMode> {
    Binding(
      get: { settings.dateStamp.mode },
      set: { mode in
        var updated = settings
        updated.dateStamp = DateStampConfiguration(
          mode: mode,
          format: settings.dateStamp.format,
          localeIdentifier: settings.dateStamp.localeIdentifier
        )
        settings = updated
      }
    )
  }

  private var dateFormat: Binding<DateStampFormat> {
    Binding(
      get: { settings.dateStamp.format },
      set: { format in
        var updated = settings
        updated.dateStamp = DateStampConfiguration(
          mode: settings.dateStamp.mode,
          format: format,
          localeIdentifier: settings.dateStamp.localeIdentifier
        )
        settings = updated
      }
    )
  }

  private var version: String {
    let short =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "\(short) (\(build))"
  }

  private var selectedFilmName: String {
    FilmRecipeCatalog.recipe(for: settings.selectedFilm)?.displayName ?? "1998"
  }

  private var photoQualityDescription: String {
    switch settings.photoQuality {
    case .spaceSaving: "Smaller files"
    case .balanced: "A considered middle ground"
    case .maximum: "Largest, cleanest files"
    }
  }
}
