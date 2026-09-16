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
  /// Fills the whole screen with the live preview and floats the controls
  /// over it. The preview crops to the screen; capture framing is unchanged.
  var fullScreenViewfinderEnabled: Bool

  init(
    schemaVersion: Int = AppSettings.currentSchemaVersion,
    selectedFilm: FilmRecipeIdentifier = .nineteenNinetyEight,
    lightLeaksEnabled: Bool = true,
    dateStamp: DateStampConfiguration = .off,
    hapticsEnabled: Bool = true,
    autoSaveToPhotos: Bool = false,
    preserveOriginal: Bool = true,
    photoQuality: PhotoQualityPreference = .balanced,
    filmRollModeEnabled: Bool = false,
    fullScreenViewfinderEnabled: Bool = false
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
    self.fullScreenViewfinderEnabled = fullScreenViewfinderEnabled
  }

  /// Decoded by hand so a key added after the schema shipped cannot make an
  /// existing settings payload look corrupt and reset someone's preferences.
  /// Every key that shipped with schema 1 stays required.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    selectedFilm = try container.decode(FilmRecipeIdentifier.self, forKey: .selectedFilm)
    lightLeaksEnabled = try container.decode(Bool.self, forKey: .lightLeaksEnabled)
    dateStamp = try container.decode(DateStampConfiguration.self, forKey: .dateStamp)
    hapticsEnabled = try container.decode(Bool.self, forKey: .hapticsEnabled)
    autoSaveToPhotos = try container.decode(Bool.self, forKey: .autoSaveToPhotos)
    preserveOriginal = try container.decode(Bool.self, forKey: .preserveOriginal)
    photoQuality = try container.decode(PhotoQualityPreference.self, forKey: .photoQuality)
    filmRollModeEnabled = try container.decode(Bool.self, forKey: .filmRollModeEnabled)
    fullScreenViewfinderEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .fullScreenViewfinderEnabled) ?? false
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
