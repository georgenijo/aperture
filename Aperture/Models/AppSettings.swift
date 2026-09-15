import Foundation

struct AppSettings: Codable, Hashable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  var selectedFilm: FilmRecipeIdentifier
  var lightLeaksEnabled: Bool
  var dateStamp: DateStampConfiguration
  var hapticsEnabled: Bool
  var autoSaveToPhotos: Bool
  var preserveOriginal: Bool
  var photoQuality: PhotoQualityPreference
  var filmRollModeEnabled: Bool

  init(
    schemaVersion: Int = AppSettings.currentSchemaVersion,
    selectedFilm: FilmRecipeIdentifier = .nineteenNinetyEight,
    lightLeaksEnabled: Bool = true,
    dateStamp: DateStampConfiguration = .off,
    hapticsEnabled: Bool = true,
    autoSaveToPhotos: Bool = false,
    preserveOriginal: Bool = true,
    photoQuality: PhotoQualityPreference = .balanced,
    filmRollModeEnabled: Bool = false
  ) {
    self.schemaVersion = schemaVersion
    self.selectedFilm = selectedFilm
    self.lightLeaksEnabled = lightLeaksEnabled
    self.dateStamp = dateStamp
    self.hapticsEnabled = hapticsEnabled
    self.autoSaveToPhotos = autoSaveToPhotos
    self.preserveOriginal = preserveOriginal
    self.photoQuality = photoQuality
    self.filmRollModeEnabled = filmRollModeEnabled
  }

  static let defaults = AppSettings()
}

enum PhotoQualityPreference: String, Codable, CaseIterable, Hashable, Sendable {
  case spaceSaving
  case balanced
  case maximum

  /// Resolved at capture time so changing Settings cannot alter existing media.
  var compressionQuality: Double {
    switch self {
    case .spaceSaving: 0.72
    case .balanced: 0.88
    case .maximum: 0.97
    }
  }
}
