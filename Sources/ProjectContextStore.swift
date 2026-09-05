import Foundation

struct ProjectContextHint: Equatable {
  let activeKey: String
  let availableKeys: [String]
}

struct ProjectContextSelection: Equatable {
  let key: String
  let threadID: String?
}

final class ProjectContextStore: @unchecked Sendable {
  private struct Record: Codable, Equatable {
    var threadID: String?
    var lastUsedAtMilliseconds: Int64
  }

  private struct State: Codable, Equatable {
    var activeKey: String
    var records: [String: Record]
  }

  static let defaultsKey = "voiceAssistant.projectContexts.v1"
  static let legacyThreadKey = "voiceAssistant.codexThreadID.v3"
  static let ttl: TimeInterval = 90 * 86_400
  static let generalKey = "general"

  private let defaults: UserDefaults
  private let lock = NSLock()
  private var state: State

  init(defaults: UserDefaults = .standard, now: Date = Date()) {
    self.defaults = defaults
    let decoded = defaults.data(forKey: Self.defaultsKey).flatMap {
      try? JSONDecoder().decode(State.self, from: $0)
    }
    let legacyThread = defaults.string(forKey: Self.legacyThreadKey)
    let milliseconds = Self.milliseconds(now)
    var loaded = decoded ?? State(activeKey: Self.generalKey, records: [:])
    if loaded.records[Self.generalKey] == nil {
      loaded.records[Self.generalKey] = Record(
        threadID: legacyThread,
        lastUsedAtMilliseconds: milliseconds
      )
    }
    loaded.records = loaded.records.filter { key, record in
      key == Self.generalKey
        || now.timeIntervalSince1970 - Double(record.lastUsedAtMilliseconds) / 1_000 < Self.ttl
    }
    if loaded.records[loaded.activeKey] == nil { loaded.activeKey = Self.generalKey }
    state = loaded
    persist(loaded)
    defaults.removeObject(forKey: Self.legacyThreadKey)
  }

  func hint() -> ProjectContextHint {
    lock.withProjectContextLock {
      ProjectContextHint(activeKey: state.activeKey, availableKeys: state.records.keys.sorted())
    }
  }

  func select(_ proposedKey: String?, now: Date = Date()) -> String {
    lock.withProjectContextLock {
      let key = resolved(proposedKey) ?? state.activeKey
      state.activeKey = key
      state.records[key, default: Record(
        threadID: nil,
        lastUsedAtMilliseconds: Self.milliseconds(now)
      )].lastUsedAtMilliseconds = Self.milliseconds(now)
      persist(state)
      return key
    }
  }

  func preview(_ proposedKey: String?) -> ProjectContextSelection {
    lock.withProjectContextLock {
      let key = resolved(proposedKey) ?? state.activeKey
      return ProjectContextSelection(key: key, threadID: state.records[key]?.threadID)
    }
  }

  func activateExisting(_ key: String, now: Date = Date()) {
    lock.withProjectContextLock {
      guard state.records[key] != nil else { return }
      state.activeKey = key
      state.records[key]?.lastUsedAtMilliseconds = Self.milliseconds(now)
      persist(state)
    }
  }

  func threadID(for key: String? = nil) -> String? {
    lock.withProjectContextLock { state.records[key ?? state.activeKey]?.threadID }
  }

  func remember(threadID: String, for key: String, now: Date = Date()) {
    guard !threadID.isEmpty, threadID.count <= 256,
      !threadID.contains("\n"), !threadID.contains("\r")
    else { return }
    lock.withProjectContextLock {
      state.records[key] = Record(
        threadID: threadID,
        lastUsedAtMilliseconds: Self.milliseconds(now)
      )
      persist(state)
    }
  }

  func clearActive(now: Date = Date()) {
    lock.withProjectContextLock {
      state.records[state.activeKey] = Record(
        threadID: nil,
        lastUsedAtMilliseconds: Self.milliseconds(now)
      )
      persist(state)
    }
  }

  func allThreadIDs() -> [String] {
    lock.withProjectContextLock {
      state.records.values.compactMap(\.threadID)
    }
  }

  private func resolved(_ proposedKey: String?) -> String? {
    guard let proposedKey else { return nil }
    let trimmed = proposedKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed == "current" { return state.activeKey }
    if trimmed == Self.generalKey { return Self.generalKey }
    if state.records[trimmed] != nil { return trimmed }
    guard trimmed.hasPrefix("new:") else { return nil }
    let candidate = String(trimmed.dropFirst(4))
    guard !candidate.contains(".."), !candidate.contains("/"), !candidate.contains("\\") else {
      return nil
    }
    let normalized = candidate.unicodeScalars.reduce(into: "") { value, scalar in
      if CharacterSet.alphanumerics.contains(scalar) {
        value.unicodeScalars.append(scalar)
      } else if scalar == "-" || scalar == "_" || scalar == " " {
        if !value.hasSuffix("-") { value.append("-") }
      }
    }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !normalized.isEmpty, normalized.count <= 64 else { return nil }
    return normalized
  }

  private func persist(_ value: State) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }
}

private extension NSLock {
  func withProjectContextLock<T>(_ operation: () -> T) -> T {
    lock()
    defer { unlock() }
    return operation()
  }
}
