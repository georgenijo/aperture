import Foundation

enum SettingsStoreError: Error, Equatable, LocalizedError, Sendable {
  case corruptData(String)
  case encodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .corruptData(let details):
      return "Aperture settings could not be read: \(details)"
    case .encodeFailed(let details):
      return "Aperture settings could not be saved: \(details)"
    }
  }
}

/// UserDefaults is thread-safe, and the lock keeps each read/modify/write API
/// call logically atomic for callers using the store from multiple executors.
final class SettingsStore: @unchecked Sendable {
  static let defaultKey = "aperture.settings.v1"

  private let defaults: UserDefaults
  private let key: String
  private let lock = NSLock()

  init(defaults: UserDefaults = .standard, key: String = SettingsStore.defaultKey) {
    self.defaults = defaults
    self.key = key
  }

  func load() throws -> AppSettings {
    lock.lock()
    defer { lock.unlock() }

    guard let object = defaults.object(forKey: key) else { return .defaults }
    guard let data = object as? Data else {
      throw SettingsStoreError.corruptData("The stored value is not a settings payload.")
    }
    do {
      let settings = try ApertureJSON.makeDecoder().decode(AppSettings.self, from: data)
      guard settings.schemaVersion == AppSettings.currentSchemaVersion else {
        throw SettingsStoreError.corruptData(
          "Unsupported settings schema \(settings.schemaVersion)."
        )
      }
      return settings
    } catch let error as SettingsStoreError {
      throw error
    } catch {
      throw SettingsStoreError.corruptData(error.localizedDescription)
    }
  }

  func save(_ settings: AppSettings) throws {
    guard settings.schemaVersion == AppSettings.currentSchemaVersion else {
      throw SettingsStoreError.encodeFailed(
        "Unsupported settings schema \(settings.schemaVersion)."
      )
    }
    let data: Data
    do {
      data = try ApertureJSON.makeEncoder().encode(settings)
    } catch {
      throw SettingsStoreError.encodeFailed(error.localizedDescription)
    }

    lock.lock()
    defaults.set(data, forKey: key)
    lock.unlock()
  }

  func reset() {
    lock.lock()
    defaults.removeObject(forKey: key)
    lock.unlock()
  }
}

enum ApertureJSON {
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }
}
