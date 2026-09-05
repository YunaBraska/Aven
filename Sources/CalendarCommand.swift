import EventKit
import Foundation

enum CalendarCommand {
  static func handles(_ arguments: [String]) -> Bool {
    arguments.first == "calendar"
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      let output = try execute(Array(arguments.dropFirst()))
      FileHandle.standardOutput.write(output)
      FileHandle.standardOutput.write(Data([0x0A]))
      return 0
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      FileHandle.standardError.write(Data("calendar: \(message)\n".utf8))
      return 1
    }
  }

  private static func execute(_ arguments: [String]) throws -> Data {
    guard arguments.first == "list" else { throw CalendarCommandError.usage }
    guard TaskCapabilityBroker.authorizes(
      ProcessInfo.processInfo.environment["VOICE_ASSISTANT_TASK_CAPABILITY"],
      capability: .calendar
    ) else {
      throw CalendarCommandError.taskUnavailable
    }
    let options = try CalendarOptions(Array(arguments.dropFirst()))
    guard UserDefaults.standard.bool(forKey: "voiceAssistant.capability.calendar.enabled") else {
      throw CalendarCommandError.disabled
    }
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
      throw CalendarCommandError.notAuthorized
    }
    let from = try date(options.required("from"))
    let to = try date(options.required("to"))
    guard from < to, to.timeIntervalSince(from) <= 366 * 24 * 60 * 60 else {
      throw CalendarCommandError.invalidRange
    }
    let limit = try options.integer("limit") ?? 50
    guard (1...200).contains(limit) else { throw CalendarCommandError.invalidLimit }
    let query = options.value("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
    try options.rejectUnused()

    let store = EKEventStore()
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
    let events = store.events(matching: predicate)
      .filter { event in
        guard let query, !query.isEmpty else { return true }
        return [event.title, event.location, event.calendar.title]
          .compactMap { $0 }
          .contains { $0.localizedCaseInsensitiveContains(query) }
      }
      .prefix(limit)
      .map(CalendarEvent.init)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(events)
  }

  private static func date(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else { throw CalendarCommandError.invalidDate }
    return date
  }

  private struct CalendarEvent: Encodable {
    let title: String
    let start: String
    let end: String
    let allDay: Bool
    let calendar: String
    let location: String?
    let url: String?

    init(_ event: EKEvent) {
      title = event.title ?? ""
      start = ISO8601DateFormatter().string(from: event.startDate)
      end = ISO8601DateFormatter().string(from: event.endDate)
      allDay = event.isAllDay
      calendar = event.calendar.title
      location = event.location
      url = event.url?.absoluteString
    }

    enum CodingKeys: String, CodingKey {
      case title
      case start
      case end
      case allDay = "all_day"
      case calendar
      case location
      case url
    }
  }

  private final class CalendarOptions {
    private var values: [String: String] = [:]
    private var consumed: Set<String> = []

    init(_ arguments: [String]) throws {
      guard arguments.count.isMultiple(of: 2) else { throw CalendarCommandError.usage }
      var index = 0
      while index < arguments.count {
        let option = arguments[index]
        guard option.hasPrefix("--"), option.count > 2 else { throw CalendarCommandError.usage }
        let name = String(option.dropFirst(2))
        guard values[name] == nil else { throw CalendarCommandError.duplicateOption(name) }
        values[name] = arguments[index + 1]
        index += 2
      }
    }

    func required(_ name: String) throws -> String {
      guard let result = value(name) else { throw CalendarCommandError.missingOption(name) }
      return result
    }

    func value(_ name: String) -> String? {
      consumed.insert(name)
      return values[name]
    }

    func integer(_ name: String) throws -> Int? {
      guard let text = value(name) else { return nil }
      guard let value = Int(text) else { throw CalendarCommandError.invalidLimit }
      return value
    }

    func rejectUnused() throws {
      let extra = Set(values.keys).subtracting(consumed).sorted()
      if let name = extra.first { throw CalendarCommandError.unknownOption(name) }
    }
  }
}

enum CalendarCommandError: LocalizedError, Equatable {
  case usage
  case taskUnavailable
  case disabled
  case notAuthorized
  case invalidDate
  case invalidRange
  case invalidLimit
  case missingOption(String)
  case duplicateOption(String)
  case unknownOption(String)

  var errorDescription: String? {
    switch self {
    case .usage: "usage: Aven calendar list --from ISO8601 --to ISO8601 [--query TEXT] [--limit 1...200]"
    case .taskUnavailable: "Calendar access is available only during an active Aven task."
    case .disabled: "Calendar capability is disabled in the Aven menu."
    case .notAuthorized: "Calendar access is not authorized for Aven."
    case .invalidDate: "Calendar dates must use ISO 8601."
    case .invalidRange: "Calendar range must be positive and at most 366 days."
    case .invalidLimit: "Calendar limit must be between 1 and 200."
    case .missingOption(let name): "Missing --\(name)."
    case .duplicateOption(let name): "Duplicate --\(name)."
    case .unknownOption(let name): "Unknown --\(name)."
    }
  }
}
