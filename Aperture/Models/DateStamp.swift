import Foundation

enum DateStampMode: String, Codable, CaseIterable, Hashable, Sendable {
  case current
  case nostalgic1998
  case off
}

enum DateStampFormat: String, Codable, CaseIterable, Hashable, Sendable {
  case digitalDateTime
  case huji
  case localeAware
  case yearMonthDay
  case monthDayYear
  case dayMonthYear
}

struct DateStampConfiguration: Codable, Hashable, Sendable {
  let mode: DateStampMode
  let format: DateStampFormat
  /// Persisting the identifier makes a developed result reproducible if the
  /// device locale changes later.
  let localeIdentifier: String

  init(
    mode: DateStampMode,
    format: DateStampFormat = .localeAware,
    localeIdentifier: String = Locale.autoupdatingCurrent.identifier
  ) {
    self.mode = mode
    self.format = format
    self.localeIdentifier = localeIdentifier
  }

  static let off = DateStampConfiguration(
    mode: .off,
    format: .yearMonthDay,
    localeIdentifier: "en_US_POSIX"
  )
}

enum ApertureDateStampFormatter {
  static func string(
    for captureDate: Date,
    configuration: DateStampConfiguration,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String? {
    guard configuration.mode != .off else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: configuration.localeIdentifier)
    calendar.timeZone = timeZone

    let displayDate: Date
    switch configuration.mode {
    case .current:
      displayDate = captureDate
    case .nostalgic1998:
      var components = calendar.dateComponents(
        [.month, .day, .hour, .minute, .second], from: captureDate)
      components.year = 1998
      if components.month == 2, components.day == 29 {
        components.day = 28
      }
      if let date = calendar.date(from: components) {
        displayDate = date
      } else {
        // 1998 was not a leap year. Preserve a February capture's
        // nostalgic year without unexpectedly falling back to today.
        components.day = min(components.day ?? 1, 28)
        displayDate = calendar.date(from: components) ?? captureDate
      }
    case .off:
      return nil
    }

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: configuration.localeIdentifier)
    formatter.timeZone = timeZone

    switch configuration.format {
    case .digitalDateTime:
      formatter.dateFormat = "yyyy/MM/dd  HH:mm"
    case .huji:
      formatter.dateFormat = "M d ''yy"
    case .localeAware:
      formatter.dateStyle = .short
      formatter.timeStyle = .none
    case .yearMonthDay:
      formatter.dateFormat = "yyyy MM dd"
    case .monthDayYear:
      formatter.dateFormat = "MM dd yy"
    case .dayMonthYear:
      formatter.dateFormat = "dd MM yy"
    }

    return formatter.string(from: displayDate)
  }
}
