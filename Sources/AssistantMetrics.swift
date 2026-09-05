import Foundation

struct AssistantMetricsSnapshot: Equatable {
  let contextTokens: Int?
  let contextWindow: Int?
  let weeklyRemainingPercent: Double?
  let weeklyResetAt: Date?
  let subagentBytes: Int64
  let memoryBytes: Int64
  let databaseBytes: Int64
  let recipeBytes: Int64
  let vaultBytes: Int64
  let contextURL: URL?
  let sessionsURL: URL

  static let empty = AssistantMetricsSnapshot(
    contextTokens: nil,
    contextWindow: nil,
    weeklyRemainingPercent: nil,
    weeklyResetAt: nil,
    subagentBytes: 0,
    memoryBytes: 0,
    databaseBytes: 0,
    recipeBytes: 0,
    vaultBytes: 0,
    contextURL: nil,
    sessionsURL: AssistantPaths.sessionsURL
  )

  var contextLabel: String {
    guard let contextTokens else { return "Context —" }
    if let contextWindow {
      return "Context \(Self.compact(contextTokens))/\(Self.compact(contextWindow))"
    }
    return "Context \(Self.compact(contextTokens))"
  }

  var agentsLabel: String { "Agents \(Self.bytes(subagentBytes))" }
  var memoryLabel: String { "Memory \(Self.bytes(memoryBytes))" }
  var databaseLabel: String { "DB \(Self.bytes(databaseBytes))" }
  var recipesLabel: String { "Recipes \(Self.bytes(recipeBytes))" }
  var vaultLabel: String { "Vault \(Self.bytes(vaultBytes))" }

  var weeklyUsageLabel: String {
    guard let weeklyRemainingPercent else { return "Weekly —" }
    return Self.weeklyUsageLabel(
      remainingPercent: weeklyRemainingPercent,
      resetAt: weeklyResetAt
    )
  }

  static func weeklyUsageLabel(remainingPercent: Double, resetAt: Date?) -> String {
    let percent = Int(min(max(remainingPercent, 0), 100).rounded())
    guard let resetAt else { return "Weekly remaining \(percent)%" }
    return "Weekly remaining \(percent)% · \(Self.shortDate(resetAt))"
  }

  private static func compact(_ value: Int) -> String {
    if value >= 1_000_000 {
      return String(format: "%.1fm", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fk", Double(value) / 1_000)
    }
    return String(value)
  }

  private static func bytes(_ value: Int64) -> String {
    guard value > 0 else { return "0 KB" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: value)
  }

  private static func shortDate(_ date: Date) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents(in: .current, from: date)
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]
    guard let day = components.day,
      let month = components.month,
      months.indices.contains(month - 1)
    else {
      return "—"
    }
    return "\(day) \(months[month - 1])"
  }
}

enum AssistantMetricsLoader {
  static let maximumSessionTailBytes = 2 * 1_024 * 1_024
  private static let maximumWeeklySessionCount = 12
  private static let sessionHeaders = SessionHeaderIndex()

  private struct WeeklyUsage {
    let usedPercent: Double
    let resetAt: Date?
    let observedAt: Date?
  }

  private struct Session {
    let id: String
    let parentID: String?
    let url: URL
    let modifiedAt: Date
  }

  private struct SessionHeader {
    let id: String
    let parentID: String?
  }

  private final class SessionHeaderIndex {
    private let lock = NSLock()
    private var values: [String: SessionHeader] = [:]

    func header(for url: URL, reader: (URL) -> SessionHeader?) -> SessionHeader? {
      let path = url.standardizedFileURL.path
      lock.lock()
      let cached = values[path]
      lock.unlock()
      if let cached { return cached }
      guard let loaded = reader(url) else { return nil }
      lock.lock()
      values[path] = loaded
      lock.unlock()
      return loaded
    }

    func retainOnly(_ paths: Set<String>) {
      lock.lock()
      values = values.filter { paths.contains($0.key) }
      lock.unlock()
    }
  }

  static func load(
    threadID: String?,
    workspaceURL: URL = AssistantPaths.workspaceURL,
    sessionsURL: URL = AssistantPaths.sessionsURL,
    vaultURL: URL = CredentialVault.defaultRootURL,
    includeWeeklyFallback: Bool = true
  ) -> AssistantMetricsSnapshot {
    let sessions = loadSessions(at: sessionsURL)
    let context = threadID.flatMap { id in sessions.first(where: { $0.id == id }) }
    let contextUsage = context.flatMap { loadContextUsage(from: $0.url) }
    let weeklyUsage = includeWeeklyFallback ? loadLatestWeeklyUsage(from: sessions) : nil
    return AssistantMetricsSnapshot(
      contextTokens: contextUsage?.tokens,
      contextWindow: contextUsage?.window,
      weeklyRemainingPercent: weeklyUsage.map { 100 - $0.usedPercent },
      weeklyResetAt: weeklyUsage?.resetAt,
      subagentBytes: threadID.map { descendantSize(of: $0, in: sessions) } ?? 0,
      memoryBytes: directorySize(workspaceURL.appendingPathComponent("memory")),
      databaseBytes: databaseSize(workspaceURL.appendingPathComponent("database/assistant.sqlite3")),
      recipeBytes: directorySize(workspaceURL.appendingPathComponent("recipes")),
      vaultBytes: directorySize(vaultURL),
      contextURL: context?.url,
      sessionsURL: sessionsURL
    )
  }

  private static func loadSessions(at root: URL) -> [Session] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    var sessions: [Session] = []
    var currentPaths = Set<String>()
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      currentPaths.insert(url.standardizedFileURL.path)
      guard let header = sessionHeaders.header(for: url, reader: loadSessionHeader) else { continue }
      let modifiedAt =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      sessions.append(
        Session(
          id: header.id,
          parentID: header.parentID,
          url: url,
          modifiedAt: modifiedAt
        )
      )
    }
    sessionHeaders.retainOnly(currentPaths)
    return sessions
  }

  private static func loadSessionHeader(from url: URL) -> SessionHeader? {
    guard let metadata = firstJSONObject(in: url),
      metadata["type"] as? String == "session_meta",
      let payload = metadata["payload"] as? [String: Any],
      let id = (payload["id"] as? String) ?? (payload["session_id"] as? String)
    else {
      return nil
    }
    return SessionHeader(id: id, parentID: payload["parent_thread_id"] as? String)
  }

  private static func firstJSONObject(in url: URL) -> [String: Any]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 65_536)) ?? Data()
    let line = data.prefix { $0 != 0x0A }
    return try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
  }

  private static func loadContextUsage(from url: URL) -> (tokens: Int, window: Int?)? {
    guard let data = boundedTail(from: url),
      let text = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    var latest: (tokens: Int, window: Int?)?
    for line in text.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["type"] as? String == "event_msg",
        let payload = object["payload"] as? [String: Any],
        payload["type"] as? String == "token_count",
        let info = payload["info"] as? [String: Any],
        let usage = info["last_token_usage"] as? [String: Any],
        let tokens = usage["total_tokens"] as? Int
      else {
        continue
      }
      latest = (tokens, info["model_context_window"] as? Int)
    }
    return latest
  }

  private static func loadLatestWeeklyUsage(from sessions: [Session]) -> WeeklyUsage? {
    sessions.sorted { $0.modifiedAt > $1.modifiedAt }
      .prefix(maximumWeeklySessionCount)
      .compactMap { session -> (WeeklyUsage, Date)? in
      guard let usage = loadWeeklyUsage(from: session.url) else { return nil }
      return (usage, usage.observedAt ?? session.modifiedAt)
    }.max(by: { $0.1 < $1.1 })?.0
  }

  private static func loadWeeklyUsage(from url: URL) -> WeeklyUsage? {
    guard let data = boundedTail(from: url),
      let text = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    var latest: WeeklyUsage?
    for line in text.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["type"] as? String == "event_msg",
        let payload = object["payload"] as? [String: Any],
        payload["type"] as? String == "token_count",
        let rateLimits = payload["rate_limits"] as? [String: Any]
      else {
        continue
      }
      let limits = [rateLimits["primary"], rateLimits["secondary"]]
        .compactMap { $0 as? [String: Any] }
      guard let weekly = limits.first(where: { limit in
        number(limit["window_minutes"] ?? limit["windowDurationMins"]) == 10_080
      }), let usedPercent = number(weekly["used_percent"] ?? weekly["usedPercent"])
      else {
        continue
      }
      let resetSeconds = number(weekly["resets_at"] ?? weekly["resetsAt"])
      latest = WeeklyUsage(
        usedPercent: usedPercent,
        resetAt: resetSeconds.map(Date.init(timeIntervalSince1970:)),
        observedAt: (object["timestamp"] as? String).flatMap {
          ISO8601DateFormatter().date(from: $0)
        }
      )
    }
    return latest
  }

  private static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  private static func descendantSize(of rootID: String, in sessions: [Session]) -> Int64 {
    var known = Set([rootID])
    var changed = true
    while changed {
      changed = false
      for session in sessions {
        guard let parentID = session.parentID, known.contains(parentID), !known.contains(session.id)
        else {
          continue
        }
        known.insert(session.id)
        changed = true
      }
    }
    return sessions
      .filter { $0.id != rootID && known.contains($0.id) }
      .reduce(0) { total, session in total + fileSize(session.url) }
  }

  private static func databaseSize(_ databaseURL: URL) -> Int64 {
    [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
      .reduce(0) { total, path in total + fileSize(URL(fileURLWithPath: path)) }
  }

  private static func directorySize(_ directoryURL: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else {
      return 0
    }
    return enumerator.reduce(into: Int64(0)) { total, value in
      guard let url = value as? URL else { return }
      total += fileSize(url)
    }
  }

  private static func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true else { return 0 }
    return Int64(values?.fileSize ?? 0)
  }

  static func boundedTail(
    from url: URL,
    maximumBytes: Int = maximumSessionTailBytes
  ) -> Data? {
    guard maximumBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
    do {
      try handle.seek(toOffset: offset)
      let data = try handle.readToEnd() ?? Data()
      guard offset > 0, let newline = data.firstIndex(of: 0x0A) else { return data }
      return data.suffix(from: data.index(after: newline))
    } catch {
      return nil
    }
  }
}
