import Foundation

@main
enum CodexContextMaintenanceTests {
  static func main() {
    doesNotLaunchBelowTheIdleOrContextThreshold()
    compactsWithTheExpectedAppServerProtocol()
    preservesJSONRPCFailures()
    preservesTimeouts()
    exposesNonblockingStateWithoutCancellingCompaction()
    explicitCancellationUsesTheSingleRunningProcess()
    cancellationBeforeCompactionNeverStartsTheLoginProbe()
    cancellationDuringLoginProbeNeverStartsTheAppServer()
    print("Codex context maintenance tests passed")
  }

  private static func doesNotLaunchBelowTheIdleOrContextThreshold() {
    withFakeCodex(mode: "success") { executable, marker in
      let maintenance = CodexContextMaintenance(
        executableURL: executable,
        workspaceURL: marker.deletingLastPathComponent()
      )
      let result = maintenance.compactIfNeeded(
        threadID: "thread-1",
        contextTokens: 74,
        contextWindow: 100,
        idleDuration: 601,
        idleGeneration: 2,
        lastCompactedIdleGeneration: nil
      )
      expect(result == .notNeeded, "context below 75 percent must not start Codex")
      expect(!FileManager.default.fileExists(atPath: marker.path), "below threshold must not launch the executable")
      expect(!CodexContextCompactionPolicy.shouldCompact(
        threadID: "thread-1", contextTokens: 75, contextWindow: 100, idleDuration: 599,
        idleGeneration: 2, lastCompactedIdleGeneration: nil
      ), "less than ten idle minutes must not compact")
      expect(!CodexContextCompactionPolicy.shouldCompact(
        threadID: "thread-1", contextTokens: 75, contextWindow: 100, idleDuration: 600,
        idleGeneration: 2, lastCompactedIdleGeneration: 2
      ), "one idle generation may compact only once")
    }
  }

  private static func compactsWithTheExpectedAppServerProtocol() {
    withFakeCodex(mode: "success") { executable, marker in
      let result = CodexContextMaintenance(
        executableURL: executable,
        environment: [
          "HOME": marker.deletingLastPathComponent().path,
          "VOICE_ASSISTANT_CONTROL_TOKEN": "must-not-reach-compaction",
        ],
        workspaceURL: marker.deletingLastPathComponent()
      ).compact(threadID: "thread-1")
      expect(result == .compacted, "completed context-compaction item should succeed: \(result)")
      let requests = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
      expect(requests.contains("\"method\":\"initialize\""), "must initialize app server")
      expect(requests.contains("\"experimentalApi\":true"), "experimental fields require capability negotiation")
      expect(requests.contains("\"method\":\"initialized\""), "must acknowledge initialization")
      expect(requests.contains("\"method\":\"thread/resume\""), "must resume the stored task")
      expect(requests.contains("\"excludeTurns\":true"), "resume must not return the full large thread")
      expect(requests.contains("\"method\":\"thread/compact/start\""), "must request context compaction")
      let arguments = (try? String(
        contentsOf: marker.appendingPathExtension("args"), encoding: .utf8
      )) ?? ""
      let inheritedToken = ((try? String(
        contentsOf: marker.appendingPathExtension("control-token"), encoding: .utf8
      )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      for feature in [
        "plugins", "remote_plugin", "workspace_dependencies", "apps", "browser_use",
        "in_app_browser", "computer_use", "image_generation", "multi_agent", "hooks",
      ] {
        expect(arguments.contains("--disable \(feature)"), "compaction must disable \(feature)")
      }
      for setting in [
        "notify=[]", "model_provider=\"openai\"",
        "openai_base_url=\"https://chatgpt.com/backend-api/codex\"",
        "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"", "otel.exporter=\"none\"",
        "otel.trace_exporter=\"none\"", "otel.metrics_exporter=\"none\"",
        "otel.log_user_prompt=false", "analytics.enabled=false",
      ] {
        expect(arguments.contains("--config \(setting)"), "compaction must isolate \(setting)")
      }
      expect(inheritedToken.isEmpty, "compaction must not inherit the app-control token")
    }
  }

  private static func preservesJSONRPCFailures() {
    withFakeCodex(mode: "error") { executable, marker in
      let result = CodexContextMaintenance(
        executableURL: executable,
        workspaceURL: marker.deletingLastPathComponent()
      ).compact(threadID: "thread-1")
      guard case .failed(let message) = result else {
        fatalError("JSON-RPC errors must be exposed as failures")
      }
      expect(message.contains("resume rejected"), "JSON-RPC error message should be preserved")
    }
  }

  private static func preservesTimeouts() {
    withFakeCodex(mode: "timeout") { executable, marker in
      let result = CodexContextMaintenance(
        executableURL: executable,
        workspaceURL: marker.deletingLastPathComponent()
      ).compact(threadID: "thread-1", timeout: 0.1)
      expect(result == .timedOut, "a silent app server must time out")
    }
  }

  private static func exposesNonblockingStateWithoutCancellingCompaction() {
    withFakeCodex(mode: "delayed-success") { executable, marker in
      let maintenance = CodexContextMaintenance(
        executableURL: executable,
        workspaceURL: marker.deletingLastPathComponent()
      )
      let finished = DispatchSemaphore(value: 0)
      let resultLock = NSLock()
      var result: CodexContextCompactionResult?
      DispatchQueue.global().async {
        let value = maintenance.compact(threadID: "thread-1", timeout: 2)
        resultLock.lock()
        result = value
        resultLock.unlock()
        finished.signal()
      }
      let deadline = Date().addingTimeInterval(1)
      while maintenance.snapshot.activity != .compacting, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.005)
      }
      let running = maintenance.snapshot
      expect(running.activity == .compacting, "caller must be able to observe active compaction without blocking")
      expect(running.lastResult == nil, "an active compaction must not expose a stale result")
      expect(finished.wait(timeout: .now() + 3) == .success, "observing activity must not cancel compaction")
      resultLock.lock()
      let finalResult = result
      resultLock.unlock()
      expect(finalResult == .compacted, "compaction must finish after nonblocking state reads")
      expect(
        maintenance.snapshot == CodexContextCompactionSnapshot(activity: .idle, lastResult: .compacted),
        "completion must atomically expose idle state and its result"
      )
    }
  }

  private static func explicitCancellationUsesTheSingleRunningProcess() {
    withFakeCodex(mode: "timeout") { executable, marker in
      let maintenance = CodexContextMaintenance(
        executableURL: executable,
        workspaceURL: marker.deletingLastPathComponent()
      )
      let finished = DispatchSemaphore(value: 0)
      let resultLock = NSLock()
      var result: CodexContextCompactionResult?
      DispatchQueue.global().async {
        let value = maintenance.compact(threadID: "thread-1", timeout: 3)
        resultLock.lock()
        result = value
        resultLock.unlock()
        finished.signal()
      }
      let deadline = Date().addingTimeInterval(1)
      while maintenance.snapshot.activity != .compacting, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.005)
      }
      maintenance.cancel()
      expect(finished.wait(timeout: .now() + 2) == .success, "explicit cancellation must stop active compaction")
      resultLock.lock()
      let finalResult = result
      resultLock.unlock()
      expect(finalResult == .cancelled, "explicit cancellation must remain distinguishable from failure")
      expect(maintenance.snapshot.lastResult == .cancelled, "cancel result must be visible to the caller")
    }
  }

  private static func cancellationDuringLoginProbeNeverStartsTheAppServer() {
    withFakeCodex(mode: "cancel-login") { executable, marker in
      let maintenance = CodexContextMaintenance(
        executableURL: executable,
        workspaceURL: marker.deletingLastPathComponent()
      )
      let finished = DispatchSemaphore(value: 0)
      let resultLock = NSLock()
      var result: CodexContextCompactionResult?
      DispatchQueue.global().async {
        let value = maintenance.compact(threadID: "thread-1")
        resultLock.lock()
        result = value
        resultLock.unlock()
        finished.signal()
      }
      let probeMarker = marker.appendingPathExtension("login-probe")
      let deadline = Date().addingTimeInterval(1)
      while !FileManager.default.fileExists(atPath: probeMarker.path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      maintenance.cancel()
      expect(finished.wait(timeout: .now() + 4) == .success, "cancelled login probe must finish")
      resultLock.lock()
      let finalResult = result
      resultLock.unlock()
      expect(finalResult == .cancelled, "cancellation during login probing must remain sticky")
      expect(
        !FileManager.default.fileExists(atPath: marker.appendingPathExtension("args").path),
        "app-server must never launch after cancellation during login probing"
      )
    }
  }

  private static func cancellationBeforeCompactionNeverStartsTheLoginProbe() {
    withFakeCodex(mode: "success") { executable, marker in
      let maintenance = CodexContextMaintenance(
        executableURL: executable,
        workspaceURL: marker.deletingLastPathComponent()
      )
      maintenance.cancel()
      expect(
        maintenance.compact(threadID: "thread-1") == .cancelled,
        "cancellation before queued compaction starts must remain sticky"
      )
      expect(
        !FileManager.default.fileExists(atPath: marker.appendingPathExtension("args").path),
        "cancelled queued compaction must not launch Codex"
      )
    }
  }

  private static func withFakeCodex(
    mode: String,
    operation: (URL, URL) -> Void
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-context-tests-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("codex")
    let marker = root.appendingPathComponent("requests")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      marker='\(marker.path)'
      if [ "$1" = "features" ] && [ "$2" = "list" ]; then
        for feature in plugins remote_plugin workspace_dependencies apps browser_use in_app_browser computer_use image_generation multi_agent hooks; do
          printf '%s stable false\n' "$feature"
        done
        exit 0
      fi
      if [ "$1" = "login" ] && [ "$2" = "status" ]; then
        if [ '\(mode)' = cancel-login ]; then
          : > "$marker.login-probe"
          sleep 2
        fi
        printf '%s\\n' 'Logged in using ChatGPT'
        exit 0
      fi
      experimental_api=false
      : > "$marker"
      printf '%s\\n' "$*" > "$marker.args"
      printenv VOICE_ASSISTANT_CONTROL_TOKEN > "$marker.control-token" 2>/dev/null || :
      while IFS= read -r line; do
        printf '%s\\n' "$line" >> "$marker"
        case "$line" in
          *'"id":1'*)
            case "$line" in
              *'"experimentalApi":true'*) experimental_api=true ;;
            esac
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/resume"'*)
            if [ "$experimental_api" != true ]; then
              printf '%s\\n' '{"id":2,"error":{"message":"excludeTurns requires experimentalApi capability"}}'
            elif [ '\(mode)' = error ]; then
              printf '%s\\n' '{"id":2,"error":{"message":"resume rejected"}}'
            else
              printf '%s\\n' '{"id":2,"result":{}}'
            fi
            ;;
          *'"method":"thread/compact/start"'*)
            if [ '\(mode)' = success ]; then
              printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"context_compaction"}}}'
            elif [ '\(mode)' = delayed-success ]; then
              sleep 0.3
              printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"context_compaction"}}}'
            fi
            ;;
        esac
      done
      """
    try! script.write(to: executable, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    defer { try? FileManager.default.removeItem(at: root) }
    operation(executable, marker)
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
  }
}
