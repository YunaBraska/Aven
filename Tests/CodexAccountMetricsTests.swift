import Foundation

@main
enum CodexAccountMetricsTests {
  static func main() {
    parsesWeeklyUsageAndAuthoritativeResetCredits()
    parsesDictionaryRateLimitShapes()
    warnsOnlyForKnownSoonExpiringCredits()
    rejectsUnrelatedResponses()
    refreshesThroughInitializedAppServerAndUsesCache()
    print("Codex account metrics tests passed")
  }

  private static func parsesWeeklyUsageAndAuthoritativeResetCredits() {
    let observed = Date(timeIntervalSince1970: 1_700_000_000)
    let response = """
      {"id":2,"result":{"rateLimits":[{"windowDurationMins":60,"usedPercent":12,"resetsAt":1700000200},{"windowDurationMins":10080,"usedPercent":13,"resetsAt":1700604800}],"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"soon","status":"available","expiresAt":1700172800},{"id":"later","status":"available","expiresAt":1700604800}]}}}
      """
    guard let snapshot = CodexAccountMetrics.parse(response: Data(response.utf8), observedAt: observed) else {
      fail("rate-limit response should parse")
    }
    expect(snapshot.weeklyRemainingPercent == 87, "weekly remaining percent should be derived from used")
    expect(snapshot.weeklyResetAt == Date(timeIntervalSince1970: 1_700_604_800), "weekly reset must use weekly window")
    expect(snapshot.resetCreditsAvailableCount == 3, "availableCount is authoritative")
    expect(snapshot.resetCredits.count == 2, "credit details should be retained when provided")
  }

  private static func warnsOnlyForKnownSoonExpiringCredits() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = CodexAccountMetricsSnapshot(
      weeklyRemainingPercent: nil,
      weeklyResetAt: nil,
      resetCreditsAvailableCount: 9,
      resetCredits: [
        CodexResetCredit(id: "soon", status: "available", grantedAt: nil, expiresAt: now.addingTimeInterval(86_400), title: nil),
        CodexResetCredit(id: "used", status: "used", grantedAt: nil, expiresAt: now.addingTimeInterval(86_400), title: nil),
        CodexResetCredit(id: "late", status: "available", grantedAt: nil, expiresAt: now.addingTimeInterval(6 * 86_400), title: nil),
      ],
      observedAt: now
    )
    expect(snapshot.warnings(now: now) == ["1 reset credit expires within 5 days."], "only known usable credits expiring within five days should warn")
  }

  private static func parsesDictionaryRateLimitShapes() {
    let response = """
      {"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":60,"usedPercent":2},"secondary":{"windowDurationMins":10080,"usedPercent":44,"resetsAt":1700001000}},"rateLimitsByLimitId":{"weekly":{"windowDurationMins":10080,"usedPercent":40,"resetsAt":1700002000}}}}
      """
    guard let snapshot = CodexAccountMetrics.parse(response: Data(response.utf8)) else {
      fail("dictionary-shaped rate limits should parse")
    }
    expect(snapshot.weeklyRemainingPercent == 56, "primary/secondary dictionary limits should be considered")
    expect(snapshot.weeklyResetAt == Date(timeIntervalSince1970: 1_700_001_000), "the primary rate-limit response remains authoritative when present")
  }

  private static func rejectsUnrelatedResponses() {
    expect(CodexAccountMetrics.parse(response: Data(#"{"id":3,"result":{}}"#.utf8)) == nil, "unrelated JSON-RPC response must be ignored")
  }

  private static func refreshesThroughInitializedAppServerAndUsesCache() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("account-metrics-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("codex")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      if [ "$1" = "login" ]; then
        printf '%s\\n' 'Logged in with ChatGPT'
        exit 0
      fi
      if [ "$1" = "app-server" ]; then
        printf '%s\\n' app-server >> "$0.calls"
        initialized=false
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
            *'"method":"initialized"'*) initialized=true ;;
            *'"id":2'*'"method":"account/rateLimits/read"'*)
              [ "$initialized" = true ] || exit 21
              printf '%s\\n' '{"id":2,"result":{"rateLimits":[{"windowDurationMins":10080,"usedPercent":20}],"rateLimitResetCredits":{"availableCount":2}}}'
              exit 0 ;;
          esac
        done
      fi
      exit 22
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let metrics = CodexAccountMetrics(executableURL: executable, environment: ["HOME": root.path], workspaceURL: root)
    let pair = awaitSnapshots { completion in
      metrics.refreshIfNeeded(completion: completion)
      metrics.refreshIfNeeded(completion: completion)
    }
    let first = pair[0]
    let second = pair[1]
    expect(first.weeklyRemainingPercent == 80, "app-server response should update the snapshot")
    expect(second == first, "fresh metrics should be served from cache")
    let calls = try! String(contentsOf: executable.appendingPathExtension("calls"), encoding: .utf8)
    expect(calls.split(whereSeparator: \.isNewline).count == 1, "concurrent refreshes must share one app-server request")
  }

  private static func awaitSnapshot(
    _ operation: (@escaping CodexAccountMetrics.Completion) -> Void
  ) -> CodexAccountMetricsSnapshot {
    let semaphore = DispatchSemaphore(value: 0)
    let result = SnapshotBox()
    operation {
      result.set($0)
      semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.02) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return result.value
  }

  private static func awaitSnapshots(
    _ operation: (@escaping CodexAccountMetrics.Completion) -> Void
  ) -> [CodexAccountMetricsSnapshot] {
    let semaphore = DispatchSemaphore(value: 0)
    let result = SnapshotsBox(expected: 2, semaphore: semaphore)
    operation { result.append($0) }
    while semaphore.wait(timeout: .now() + 0.02) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return result.value
  }

  private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = CodexAccountMetricsSnapshot.empty

    var value: CodexAccountMetricsSnapshot {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }

    func set(_ value: CodexAccountMetricsSnapshot) {
      lock.lock()
      stored = value
      lock.unlock()
    }
  }

  private final class SnapshotsBox: @unchecked Sendable {
    private let expected: Int
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var stored: [CodexAccountMetricsSnapshot] = []

    init(expected: Int, semaphore: DispatchSemaphore) {
      self.expected = expected
      self.semaphore = semaphore
    }

    var value: [CodexAccountMetricsSnapshot] {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }

    func append(_ value: CodexAccountMetricsSnapshot) {
      lock.lock()
      stored.append(value)
      let completed = stored.count == expected
      lock.unlock()
      if completed { semaphore.signal() }
    }
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}
