import Darwin
import Foundation

struct CodexResetCredit: Codable, Equatable {
  let id: String
  let status: String?
  let grantedAt: Date?
  let expiresAt: Date?
  let title: String?
}

struct CodexAccountMetricsSnapshot: Codable, Equatable {
  let weeklyRemainingPercent: Double?
  let weeklyResetAt: Date?
  let resetCreditsAvailableCount: Int?
  let resetCredits: [CodexResetCredit]
  let observedAt: Date?

  static let empty = CodexAccountMetricsSnapshot(
    weeklyRemainingPercent: nil,
    weeklyResetAt: nil,
    resetCreditsAvailableCount: nil,
    resetCredits: [],
    observedAt: nil
  )

  func warnings(now: Date = Date(), expiringWithin: TimeInterval = 5 * 86_400) -> [String] {
    let expiring = resetCredits.filter { credit in
      guard let expiresAt = credit.expiresAt,
        expiresAt >= now,
        expiresAt <= now.addingTimeInterval(expiringWithin)
      else { return false }
      let status = credit.status?.lowercased()
      return status != "used" && status != "consumed" && status != "expired"
    }
    guard !expiring.isEmpty else { return [] }
    let label = expiring.count == 1 ? "reset credit expires" : "reset credits expire"
    return ["\(expiring.count) \(label) within 5 days."]
  }
}

/// Reads account rate-limit information through Codex's local app-server.
///
/// Calls are deliberately asynchronous and cached for fifteen minutes so menu rendering never
/// performs network or process work.
final class CodexAccountMetrics: @unchecked Sendable {
  typealias Completion = @Sendable (CodexAccountMetricsSnapshot) -> Void
  typealias AppServerRunner = (
    _ executableURL: URL, _ arguments: [String], _ input: Data,
    _ environment: [String: String], _ workspaceURL: URL, _ timeout: TimeInterval
  ) -> Data?

  static let cacheInterval: TimeInterval = 15 * 60
  static let failedAttemptCacheInterval: TimeInterval = 60
  private static let maximumOutputBytes = 131_072

  private let executableURL: URL?
  private let environment: [String: String]
  private let workspaceURL: URL
  private let runner: AppServerRunner
  private let queue = DispatchQueue(label: "aven.account-metrics", qos: .utility)
  private let lock = NSLock()
  private var cached = CodexAccountMetricsSnapshot.empty
  private var refreshInProgress = false
  private var lastFailedAttemptAt: Date?
  private var pendingCompletions: [Completion] = []

  init(
    executableURL: URL? = CodexExecutableLocator.locate(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    workspaceURL: URL = AssistantPaths.workspaceURL,
    runner: @escaping AppServerRunner = runAppServer
  ) {
    self.executableURL = executableURL
    self.environment = Self.reducedEnvironment(environment, executableURL: executableURL)
    self.workspaceURL = workspaceURL
    self.runner = runner
  }

  var snapshot: CodexAccountMetricsSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return cached
  }

  /// Refreshes only when the cached result is older than fifteen minutes.
  /// Completion is delivered on the main queue.
  func refreshIfNeeded(now: Date = Date(), completion: @escaping Completion = { _ in }) {
    scheduleRefresh(now: now, honoringCache: true, completion: completion)
  }

  /// Forces a refresh. Intended for explicit user refresh actions, never menu rendering.
  func refresh(now: Date = Date(), completion: @escaping Completion = { _ in }) {
    scheduleRefresh(now: now, honoringCache: false, completion: completion)
  }

  private func scheduleRefresh(
    now: Date, honoringCache: Bool, completion: @escaping Completion
  ) {
    lock.lock()
    let retained = cached
    let fresh = retained.observedAt.map { now.timeIntervalSince($0) < Self.cacheInterval } == true
    let recentlyFailed = lastFailedAttemptAt.map {
      now.timeIntervalSince($0) < Self.failedAttemptCacheInterval
    } == true
    if (honoringCache && fresh) || (honoringCache && recentlyFailed) {
      lock.unlock()
      DispatchQueue.main.async { completion(retained) }
      return
    }
    pendingCompletions.append(completion)
    guard !refreshInProgress else {
      lock.unlock()
      return
    }
    refreshInProgress = true
    lock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      let refreshed = self.fetch(now: now)
      self.lock.lock()
      self.refreshInProgress = false
      self.lastFailedAttemptAt = refreshed == nil ? now : nil
      let completions = self.pendingCompletions
      self.pendingCompletions.removeAll()
      let result = self.cached
      self.lock.unlock()
      DispatchQueue.main.async {
        completions.forEach { $0(result) }
      }
    }
  }

  static func parse(response data: Data, observedAt: Date = Date()) -> CodexAccountMetricsSnapshot? {
    for line in data.split(separator: 0x0A) {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        (object["id"] as? NSNumber)?.intValue == 2,
        let result = object["result"] as? [String: Any]
      else { continue }
      return parse(result: result, observedAt: observedAt)
    }
    return nil
  }

  private func fetch(now: Date) -> CodexAccountMetricsSnapshot? {
    guard let executableURL else { return nil }
    guard let configuration = CodexAppServerIsolation.configuration(
      executableURL: executableURL,
      environment: environment,
      workspaceURL: workspaceURL,
      timeout: 3
    ) else { return nil }
    let input = [
      #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"aven","version":"1"}}}"#,
      #"{"method":"initialized","params":{}}"#,
      #"{"id":2,"method":"account/rateLimits/read","params":{}}"#,
    ].joined(separator: "\n") + "\n"
    guard let output = runner(
      executableURL,
      ["app-server", "--stdio"]
        + CodexFeatureIsolation.disableArguments(
          executableURL: executableURL,
          environment: environment,
          workspaceURL: workspaceURL
        )
        + configuration.flatMap { ["--config", $0] },
      Data(input.utf8), environment, workspaceURL, 5
    ), let parsed = Self.parse(response: output, observedAt: now)
    else { return nil }
    lock.lock()
    cached = parsed
    lock.unlock()
    return parsed
  }

  private static func parse(result: [String: Any], observedAt: Date) -> CodexAccountMetricsSnapshot {
    let limits = allLimits(in: result)
    let weekly = limits.first { number($0["windowDurationMins"] ?? $0["window_minutes"]) == 10_080 }
    let used = weekly.flatMap { number($0["usedPercent"] ?? $0["used_percent"]) }
    let resetAt = weekly.flatMap { seconds in
      number(seconds["resetsAt"] ?? seconds["resets_at"]).map(Date.init(timeIntervalSince1970:))
    }
    let credits = (result["rateLimitResetCredits"] as? [String: Any])
      ?? (result["rate_limit_reset_credits"] as? [String: Any])
    let available = credits.flatMap { number($0["availableCount"] ?? $0["available_count"]) }
      .map { Int($0) }
    let details = (credits?["credits"] as? [[String: Any]] ?? []).compactMap(parseCredit)
    return CodexAccountMetricsSnapshot(
      weeklyRemainingPercent: used.map { min(max(100 - $0, 0), 100) },
      weeklyResetAt: resetAt,
      resetCreditsAvailableCount: available,
      resetCredits: details,
      observedAt: observedAt
    )
  }

  private static func parseCredit(_ value: [String: Any]) -> CodexResetCredit? {
    guard let id = value["id"] as? String, !id.isEmpty else { return nil }
    return CodexResetCredit(
      id: id,
      status: value["status"] as? String,
      grantedAt: date(value["grantedAt"] ?? value["granted_at"]),
      expiresAt: date(value["expiresAt"] ?? value["expires_at"]),
      title: value["title"] as? String
    )
  }

  private static func allLimits(in result: [String: Any]) -> [[String: Any]] {
    let direct = limitDictionaries(result["rateLimits"] ?? result["rate_limits"])
    let identified = limitDictionaries(result["rateLimitsByLimitId"] ?? result["rate_limits_by_limit_id"])
    return direct + identified
  }

  private static func limitDictionaries(_ value: Any?) -> [[String: Any]] {
    if let limits = value as? [[String: Any]] { return limits }
    guard let dictionary = value as? [String: Any] else { return [] }
    if number(dictionary["windowDurationMins"] ?? dictionary["window_minutes"]) != nil {
      return [dictionary]
    }
    return dictionary.values.flatMap(limitDictionaries)
  }

  private static func date(_ value: Any?) -> Date? {
    if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
    guard let string = value as? String else { return nil }
    return ISO8601DateFormatter().date(from: string)
  }

  private static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  private static func reducedEnvironment(
    _ source: [String: String], executableURL: URL?
  ) -> [String: String] {
    let allowed = Set(["CODEX_HOME", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "TMPDIR", "USER"])
    var reduced = source.filter { key, _ in allowed.contains(key) || key.hasPrefix("LC_") }
    reduced["HOME"] = source["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    let executableDirectory = executableURL?.deletingLastPathComponent().path ?? ""
    reduced["PATH"] = "\(executableDirectory):/usr/bin:/bin:/usr/sbin:/sbin"
    return AssistantPaths.normalizingCodexHome(in: reduced)
  }

  private static func runAppServer(
    executableURL: URL, arguments: [String], input: Data,
    environment: [String: String], workspaceURL: URL, timeout: TimeInterval
  ) -> Data? {
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workspaceURL
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let outputLock = NSLock()
    let initialized = DispatchSemaphore(value: 0)
    let response = DispatchSemaphore(value: 0)
    let readerFinished = DispatchSemaphore(value: 0)
    var output = Data()
    var initializationReceived = false
    var responseReceived = false
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        readerFinished.signal()
        initialized.signal()
        response.signal()
        return
      }
      var foundInitialization = false
      var foundResponse = false
      outputLock.lock()
      if output.count < maximumOutputBytes {
        output.append(chunk.prefix(maximumOutputBytes - output.count))
      }
      for line in output.split(separator: 0x0A) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
          continue
        }
        if !initializationReceived, (object["id"] as? NSNumber)?.intValue == 1 {
          initializationReceived = true
          foundInitialization = true
        }
        if !responseReceived, (object["id"] as? NSNumber)?.intValue == 2 {
          responseReceived = true
          foundResponse = true
        }
      }
      outputLock.unlock()
      if foundInitialization { initialized.signal() }
      if foundResponse { response.signal() }
    }
    do {
      try process.run()
      _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
      let lines = input.split(separator: 0x0A, omittingEmptySubsequences: true)
      guard let initialize = lines.first else { return nil }
      try stdin.fileHandleForWriting.write(contentsOf: initialize + Data([0x0A]))
      let deadline = DispatchTime.now() + timeout
      guard initialized.wait(timeout: deadline) == .success else {
        terminate(process, stdin: stdin, readerFinished: readerFinished)
        return nil
      }
      outputLock.lock()
      let ready = initializationReceived
      outputLock.unlock()
      guard ready else {
        terminate(process, stdin: stdin, readerFinished: readerFinished)
        return nil
      }
      let remainder = lines.dropFirst().joined(separator: Data([0x0A])) + Data([0x0A])
      try stdin.fileHandleForWriting.write(contentsOf: remainder)
      guard response.wait(timeout: deadline) == .success else {
        terminate(process, stdin: stdin, readerFinished: readerFinished)
        return nil
      }
    } catch {
      try? stdin.fileHandleForWriting.close()
      stdout.fileHandleForReading.readabilityHandler = nil
      return nil
    }
    outputLock.lock()
    let received = responseReceived
    outputLock.unlock()
    terminate(process, stdin: stdin, readerFinished: readerFinished)
    stdout.fileHandleForReading.readabilityHandler = nil
    guard received else { return nil }
    outputLock.lock()
    defer { outputLock.unlock() }
    return output
  }

  private static func terminate(
    _ process: Process, stdin: Pipe, readerFinished: DispatchSemaphore
  ) {
    try? stdin.fileHandleForWriting.close()
    let identifier = process.processIdentifier
    if process.isRunning {
      _ = Darwin.kill(-identifier, SIGTERM)
      _ = Darwin.kill(identifier, SIGTERM)
    }
    if readerFinished.wait(timeout: .now() + 1) == .timedOut {
      _ = Darwin.kill(-identifier, SIGKILL)
      _ = Darwin.kill(identifier, SIGKILL)
    }
    process.waitUntilExit()
  }
}
