import SwiftUI

struct SettingsView: View {
  @Binding var settings: AppSettings
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Film") {
          Picker("Selected Film", selection: setting(\.selectedFilm)) {
            ForEach(FilmRecipeCatalog.all) { film in
              Text(film.displayName).tag(film.id)
            }
          }
          Toggle("Light Leaks", isOn: setting(\.lightLeaksEnabled))
          Picker("Date Stamp", selection: dateMode) {
            Text("Off").tag(DateStampMode.off)
            Text("Current Date").tag(DateStampMode.current)
            Text("1998 Date").tag(DateStampMode.nostalgic1998)
          }
          if settings.dateStamp.mode != .off {
            Picker("Date Format", selection: dateFormat) {
              Text("Local").tag(DateStampFormat.localeAware)
              Text("Year Month Day").tag(DateStampFormat.yearMonthDay)
              Text("Month Day Year").tag(DateStampFormat.monthDayYear)
              Text("Day Month Year").tag(DateStampFormat.dayMonthYear)
            }
          }
        }

        Section("Capture") {
          Toggle("Haptics", isOn: setting(\.hapticsEnabled))
          Toggle("Preserve Original", isOn: setting(\.preserveOriginal))
          Picker("Photo Quality", selection: setting(\.photoQuality)) {
            Text("Space Saving").tag(PhotoQualityPreference.spaceSaving)
            Text("Balanced").tag(PhotoQualityPreference.balanced)
            Text("Maximum").tag(PhotoQualityPreference.maximum)
          }
        }

        Section("Photos") {
          Toggle("Auto-save Developed Media", isOn: setting(\.autoSaveToPhotos))
          Text(
            "Photos permission is requested only when you export or enable auto-save. Aperture remains usable without it."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        Section("Privacy") {
          Label("Processing stays on this iPhone", systemImage: "iphone.and.arrow.forward")
          Label("No accounts, analytics, ads, or uploads", systemImage: "hand.raised.fill")
          Text(
            "Deleting media from the Lab removes Aperture’s local copy and rebuildable cache. Copies previously exported to Photos are managed in Photos."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        Section("About") {
          LabeledContent("Version", value: version)
          Text(
            "Aperture is an original, private-by-design film camera made for simple shooting and surprising results."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
      .scrollContentBackground(.hidden)
      .background(ApertureStyle.ink)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .preferredColorScheme(.dark)
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
}
