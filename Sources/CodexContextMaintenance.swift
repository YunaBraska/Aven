import Darwin
import Foundation

enum CodexContextCompactionPolicy {
  static let minimumIdle: TimeInterval = 600
  static let minimumUsage = 0.75

  static func shouldCompact(
    threadID: String?,
    contextTokens: Int?,
    contextWindow: Int?,
    idleDuration: TimeInterval,
    idleGeneration: Int,
    lastCompactedIdleGeneration: Int?
  ) -> Bool {
    guard idleGeneration >= 0,
      lastCompactedIdleGeneration != idleGeneration,
      let threadID, !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let contextTokens, contextTokens > 0,
      let contextWindow, contextWindow > 0,
      contextTokens <= contextWindow,
      idleDuration >= minimumIdle
    else { return false }
    return Double(contextTokens) / Double(contextWindow) >= minimumUsage
  }
}

enum CodexContextCompactionResult: Equatable {
  case notNeeded
  case compacted
  case failed(String)
  case timedOut
  case cancelled
}

enum CodexContextCompactionActivity: Equatable {
  case idle
  case compacting
}

struct CodexContextCompactionSnapshot: Equatable {
  let activity: CodexContextCompactionActivity
  let lastResult: CodexContextCompactionResult?
}

final class CodexContextMaintenance: @unchecked Sendable {
  private static let maximumLineBytes = 131_072

  private let executableURL: URL
  private let environment: [String: String]
  private let workspaceURL: URL
  private let forwardingAllowed: @Sendable () -> Bool
  private let lock = NSLock()
  private var process: Process?
  private var operationInProgress = false
  private var cancellationRequested = false
  private var latestResult: CodexContextCompactionResult?

  var snapshot: CodexContextCompactionSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return CodexContextCompactionSnapshot(
      activity: operationInProgress ? .compacting : .idle,
      lastResult: latestResult
    )
  }

  init(
    executableURL: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    workspaceURL: URL = AssistantPaths.workspaceURL,
    forwardingAllowed: @escaping @Sendable () -> Bool = { true }
  ) {
    self.executableURL = executableURL
    self.environment = environment
    self.workspaceURL = workspaceURL
    self.forwardingAllowed = forwardingAllowed
  }

  func compact(threadID: String, timeout: TimeInterval = 30) -> CodexContextCompactionResult {
    guard !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failed("No active Codex task is available for context compaction.")
    }
    guard timeout > 0, forwardingAllowed() else { return .cancelled }
    lock.lock()
    guard !operationInProgress, !cancellationRequested else {
      if !operationInProgress { latestResult = .cancelled }
      lock.unlock()
      return .cancelled
    }
    operationInProgress = true
    latestResult = nil
    lock.unlock()
    guard let configuration = CodexAppServerIsolation.configuration(
      executableURL: executableURL,
      environment: reducedEnvironment(),
      workspaceURL: workspaceURL
    ) else {
      lock.lock()
      let cancelled = cancellationRequested || !forwardingAllowed()
      let result: CodexContextCompactionResult = cancelled
        ? .cancelled
        : .failed("Codex sign-in mode could not be identified for safe context compaction.")
      operationInProgress = false
      latestResult = result
      lock.unlock()
      return result
    }

    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    process.executableURL = executableURL
    process.arguments = ["app-server", "--stdio"]
      + CodexFeatureIsolation.disableArguments(
        executableURL: executableURL,
        environment: reducedEnvironment(),
        workspaceURL: workspaceURL
      )
      + configuration.flatMap { ["--config", $0] }
    process.currentDirectoryURL = workspaceURL
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    process.environment = reducedEnvironment()

    let completed = DispatchSemaphore(value: 0)
    let readerFinished = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var state = State()

    func finish(_ result: CodexContextCompactionResult) {
      stateLock.lock()
      guard state.result == nil else {
        stateLock.unlock()
        return
      }
      state.result = result
      stateLock.unlock()
      completed.signal()
    }

    func send(_ message: String) -> Bool {
      guard let data = (message + "\n").data(using: .utf8) else { return false }
      do {
        try stdin.fileHandleForWriting.write(contentsOf: data)
        return true
      } catch {
        finish(.failed("Codex context compaction could not send a request."))
        return false
      }
    }

    let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"aven","version":"1"},"capabilities":{"experimentalApi":true}}}"#
    let escapedThreadID = Self.escapedJSON(threadID)
    let resume = "{\"id\":2,\"method\":\"thread/resume\",\"params\":{\"threadId\":\"\(escapedThreadID)\",\"excludeTurns\":true}}"
    let compact = "{\"id\":3,\"method\":\"thread/compact/start\",\"params\":{\"threadId\":\"\(escapedThreadID)\"}}"

    do {
      lock.lock()
      guard !cancellationRequested, forwardingAllowed() else {
        operationInProgress = false
        latestResult = .cancelled
        lock.unlock()
        return .cancelled
      }
      self.process = process
      do {
        try process.run()
        _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
      } catch {
        let result = CodexContextCompactionResult.failed(
          "Codex context compaction could not start."
        )
        self.process = nil
        operationInProgress = false
        latestResult = result
        lock.unlock()
        return result
      }
      lock.unlock()

      stdout.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
          readerFinished.signal()
          stateLock.lock()
          let result = state.result
          stateLock.unlock()
          if result == nil { finish(.failed("Codex closed context compaction without a result.")) }
          return
        }

        stateLock.lock()
        state.buffer.append(chunk)
        if state.buffer.count > Self.maximumLineBytes {
          stateLock.unlock()
          finish(.failed("Codex returned an oversized context-compaction response."))
          return
        }
        let lines = state.buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
        let endsWithNewline = state.buffer.last == 0x0A
        state.buffer = endsWithNewline ? Data() : Data(lines.last ?? Data())
        let completeLines = endsWithNewline ? lines : lines.dropLast()
        stateLock.unlock()

        for line in completeLines where !line.isEmpty {
          guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
          if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown JSON-RPC error"
            finish(.failed("Codex context compaction failed: \(message)"))
            continue
          }
          if Self.isCompactionCompleted(object) {
            finish(.compacted)
            continue
          }
          guard let identifier = object["id"] as? Int else { continue }
          switch identifier {
          case 1:
            _ = send(#"{"method":"initialized","params":{}}"#)
            _ = send(resume)
          case 2:
            _ = send(compact)
          default:
            continue
          }
        }
      }

      guard send(initialize) else { return terminate(process, stdin: stdin, readerFinished: readerFinished) }
      if completed.wait(timeout: .now() + timeout) == .timedOut {
        finish(forwardingAllowed() ? .timedOut : .cancelled)
      }
      let result = stateLock.withContextLock { state.result ?? .failed("Codex context compaction ended unexpectedly.") }
      return terminate(process, stdin: stdin, readerFinished: readerFinished, result: result)
    }
  }

  func compactIfNeeded(
    threadID: String?,
    contextTokens: Int?,
    contextWindow: Int?,
    idleDuration: TimeInterval,
    idleGeneration: Int,
    lastCompactedIdleGeneration: Int?,
    timeout: TimeInterval = 30
  ) -> CodexContextCompactionResult {
    guard CodexContextCompactionPolicy.shouldCompact(
      threadID: threadID,
      contextTokens: contextTokens,
      contextWindow: contextWindow,
      idleDuration: idleDuration,
      idleGeneration: idleGeneration,
      lastCompactedIdleGeneration: lastCompactedIdleGeneration
    ), let threadID else { return .notNeeded }
    return compact(threadID: threadID, timeout: timeout)
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancellationRequested = true
    guard let process, process.isRunning else { return }
    let identifier = process.processIdentifier
    _ = Darwin.kill(-identifier, SIGTERM)
    _ = Darwin.kill(identifier, SIGTERM)
  }

  private func terminate(
    _ process: Process,
    stdin: Pipe,
    readerFinished: DispatchSemaphore,
    result: CodexContextCompactionResult = .failed("Codex context compaction ended unexpectedly.")
  ) -> CodexContextCompactionResult {
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
    lock.lock()
    if self.process === process { self.process = nil }
    operationInProgress = false
    let finalResult = cancellationRequested ? .cancelled : result
    latestResult = finalResult
    lock.unlock()
    return finalResult
  }

  private func reducedEnvironment() -> [String: String] {
    let allowed = Set(["CODEX_HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"])
    var selected = environment.filter { key, _ in
      allowed.contains(key) || key.hasPrefix("LC_")
    }
    selected["PATH"] = "\(executableURL.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
    selected["HOME"] = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    return AssistantPaths.normalizingCodexHome(in: selected)
  }

  private static func escapedJSON(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
    let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
  }

  private static func isCompactionCompleted(_ object: [String: Any]) -> Bool {
    guard let method = object["method"] as? String else { return false }
    if method == "thread/compacted" { return true }
    guard method == "item/completed",
      let params = object["params"] as? [String: Any],
      let item = params["item"] as? [String: Any]
    else { return false }
    let type = (item["type"] as? String ?? "").lowercased()
    return type == "context_compaction" || type == "contextcompaction"
  }

  private struct State {
    var buffer = Data()
    var result: CodexContextCompactionResult?
  }
}

private extension NSLock {
  func withContextLock<T>(_ operation: () -> T) -> T {
    lock()
    defer { unlock() }
    return operation()
  }
}
