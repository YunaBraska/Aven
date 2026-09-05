import Foundation

@main
enum CodexClientTests {
  static func main() {
    startsAndResumesConversationThroughPublicClient()
    scopesCapabilitiesToOneCodexTask()
    boundsUntrustedCodexOutput()
    steersRunningConversationThroughPublicClient()
    clearsContextWithoutDeletingWorkspaceData()
    clearingAnActiveContextCannotRestoreItsThreadID()
    clearContextWinsTheThreadPersistenceRace()
    cancellationBeforeLaunchNeverStartsCodex()
    failedLaunchDoesNotActivateAProposedProjectContext()
    cancellationAfterLaunchReturnsCancelled()
    clearedContextRemainsOwnedForDeletion()
    discoversPreRegistryWorkspaceTasksForDeletion()
    discoversOnlyVerifiedLegacyWorkspaceTasks()
    deletesOnlyStoredAssistantThreads()
    rejectsEmptyPromptBeforeLaunchingCodex()
    rejectsMissingExecutable()
    discoversCodexWithoutAPackageManagerPath()
    migratesAnOldBlockedCandidateToWarningOnly()
    requiresForwardingConsentAtTheProcessBoundary()
    classifiesOperationalFailures()
    persistsOnlyCurrentForwardingConsent()
    expiresTransientWarnings()
    print("Codex client tests passed")
  }

  private static func scopesCapabilitiesToOneCodexTask() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-capability-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let tokenLog = root.appendingPathComponent("token")
    let suiteName = "aven-capability-\(UUID().uuidString)"
    guard let defaults = consentedDefaults(suiteName: suiteName) else { exit(1) }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      printenv VOICE_ASSISTANT_TASK_CAPABILITY > "\(tokenLog.path)"
      /bin/cat >/dev/null
      printf '%s\n' '{"type":"thread.started","thread_id":"thread-capability"}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let revoked = LockedStrings()
    let requestedCapabilities = LockedCapabilitySets()
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: root,
      defaults: defaults,
      isolatesExtensions: false,
      taskCapabilityProvider: {
        requestedCapabilities.append($0)
        return "task-token"
      },
      taskCapabilityRevoker: { revoked.append($0) }
    )
    let result = awaitResult {
      client.ask("work", taskCapabilities: [.clipboard], completion: $0)
    }
    guard case .success = result else { fail("a scoped task should complete") }
    let received = try! String(contentsOf: tokenLog, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    expect(received == "task-token", "the task process must receive its capability")
    expect(
      requestedCapabilities.values == [Set([.clipboard])],
      "each turn must request only the capabilities selected at its app boundary"
    )
    expect(revoked.values == ["task-token"], "the capability must be revoked after the task")
  }

  private static func boundsUntrustedCodexOutput() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-output-limit-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let suiteName = "aven-output-limit-\(UUID().uuidString)"
    guard let defaults = consentedDefaults(suiteName: suiteName) else { exit(1) }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      /bin/cat >/dev/null
      /usr/bin/yes x | /usr/bin/head -c \(CodexClient.maximumOutputBytes + 8_192)
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: root,
      defaults: defaults,
      isolatesExtensions: false,
      taskCapabilityProvider: { _ in nil }
    )
    expect(
      awaitResult { client.ask("work", completion: $0) } == .failure(.outputLimitExceeded),
      "oversized Codex output must terminate safely instead of growing without bounds"
    )
  }

  private static func steersRunningConversationThroughPublicClient() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-steer-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let queueLog = root.appendingPathComponent("fake-codex.queue")
    let workspace = root.appendingPathComponent("workspace")
    let suiteName = "aven-steer-\(UUID().uuidString)"
    guard let defaults = consentedDefaults(suiteName: suiteName) else { exit(1) }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      if [ "$1" = "features" ] && [ "$2" = "list" ]; then
        exit 0
      fi
      if [ "$1" = "queue" ]; then
        printf '%s\n' "$*" > "$0.queue"
        exit 0
      fi
      cat >/dev/null
      printf '%s\n' '{"type":"thread.started","thread_id":"thread-steer"}'
      printf '%s\n' '{"type":"turn.started"}'
      sleep 5
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"steered"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let client = CodexClient(
      executableURL: executable,
      workspaceURL: workspace,
      defaults: defaults,
      isolatesExtensions: false
    )
    let askSemaphore = DispatchSemaphore(value: 0)
    var askResult: Result<String, CodexClientError>?
    client.ask("start working") {
      askResult = $0
      askSemaphore.signal()
    }
    let deadline = Date(timeIntervalSinceNow: 3)
    while !client.canSteer && Date() < deadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    expect(client.canSteer, "running conversation should become steerable")
    let steerResult = awaitVoidResult {
      client.steer("use the new constraint", completion: $0)
    }
    guard case .success = steerResult else { fail("steering should be accepted") }
    while askSemaphore.wait(timeout: .now() + 0.05) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard case .success(let answer) = askResult else { fail("steered request should finish") }
    expect(answer == "steered", "steered request should return its response")
    let recorded = try! String(contentsOf: queueLog, encoding: .utf8)
    expect(
      recorded.contains("queue --thread thread-steer --message use the new constraint"),
      "steering must target the active Codex thread"
    )
    expect(!recorded.contains("--model"), "steering must not wait for a second route-planning call")
  }

  private static func expiresTransientWarnings() {
    let now = Date(timeIntervalSince1970: 1_000)
    var warnings = ExpiringWarnings()
    warnings.remember("temporary", until: now.addingTimeInterval(10))
    expect(warnings.active(at: now) == ["temporary"], "fresh warnings should remain visible")
    expect(
      warnings.nextExpiration(at: now) == now.addingTimeInterval(10),
      "the UI should receive the next warning expiry"
    )
    expect(
      warnings.active(at: now.addingTimeInterval(11)).isEmpty,
      "transient warnings should expire instead of living forever"
    )
    expect(
      warnings.nextExpiration(at: now.addingTimeInterval(11)) == nil,
      "expired warnings need no refresh timer"
    )
  }

  private static func startsAndResumesConversationThroughPublicClient() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-tests-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let argumentsLog = root.appendingPathComponent("fake-codex.args")
    let inputLog = root.appendingPathComponent("fake-codex.input")
    let workspace = root.appendingPathComponent("workspace")
    let image = root.appendingPathComponent("screen.png")
    let suiteName = "aven-tests-\(UUID().uuidString)"
    guard let defaults = consentedDefaults(suiteName: suiteName) else { exit(1) }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }

    try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try! Data("image".utf8).write(to: image)
    let script = """
      #!/bin/sh
      if [ "$1" = "features" ] && [ "$2" = "list" ]; then
        for feature in plugins remote_plugin workspace_dependencies apps browser_use in_app_browser computer_use image_generation multi_agent hooks; do
          printf '%s stable false\n' "$feature"
        done
        exit 0
      fi
      cat >> "$0.input"
      printf '\n---request---\n' >> "$0.input"
      printf '%s\n' "$*" >> "$0.args"
      printf '%s\\n' '{"type":"thread.started","thread_id":"thread-fixed"}'
      printf '%s\\n' '{"type":"turn.started"}'
      printf '%s\\n' '{"type":"item.started","item":{"type":"web_search"}}'
      case "$*" in
        *resume*--ignore-user-config*) printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"resumed"}}' ;;
        *--ignore-user-config*sandbox_mode*danger-full-access*) printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"started"}}' ;;
        *) exit 9 ;;
      esac
      printf '%s\\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )

    let client = CodexClient(
      executableURL: executable,
      workspaceURL: workspace,
      defaults: defaults
    )
    let fastRoute = ModelRoute(
      model: "gpt-5.6-luna",
      reasoningEffort: "low",
      initialProgress: nil
    )
    let deepRoute = ModelRoute(
      model: "gpt-5.6-sol",
      reasoningEffort: "high",
      initialProgress: .thinking
    )
    var progressUpdates: [CodexProgress] = []
    let first = awaitResult {
      client.ask(
        "erste frage",
        route: fastRoute,
        searchEnabled: true,
        progress: { progressUpdates.append($0) },
        completion: $0
      )
    }
    guard case .success(let firstAnswer) = first else {
      fail("first request should succeed")
    }
    expect(firstAnswer == "started", "first request should start a thread")
    expect(progressUpdates.contains(.thinking), "live thinking status should be emitted")
    expect(progressUpdates.contains(.searching), "live search status should be emitted")

    let second = awaitResult {
      client.ask("zweite frage", imageURL: image, route: deepRoute, completion: $0)
    }
    guard case .success(let secondAnswer) = second else {
      fail("second request should succeed")
    }
    expect(secondAnswer == "resumed", "second request should resume the thread")
    let recordedArguments = try! String(contentsOf: argumentsLog, encoding: .utf8)
    let recordedInput = try! String(contentsOf: inputLog, encoding: .utf8)
    expect(
      recordedArguments.contains("--image \(image.path)"),
      "explicit screenshot should be attached to the request"
    )
    expect(
      recordedArguments.contains("sandbox_mode=\"danger-full-access\""),
      "resumed conversations should retain unrestricted local file access"
    )
    expect(!recordedArguments.contains("--add-dir"), "file access should not use a path allowlist")
    expect(recordedArguments.contains("--search"), "enabled web research should reach Codex")
    expect(!recordedArguments.contains("Credential Vault"), "Codex must not read vault storage")
    expect(
      recordedArguments.contains("--disable plugins --disable remote_plugin"),
      "remote plugins should stay disabled for predictable voice response time"
    )
    expect(
      recordedArguments.contains("--disable computer_use --disable image_generation"),
      "unneeded high-authority features should stay disabled"
    )
    expect(
      recordedArguments.contains("--model gpt-5.6-luna"),
      "initial request should use the selected fast model"
    )
    expect(
      recordedArguments.contains("--model gpt-5.6-sol"),
      "resumed request should allow switching to the deep model"
    )
    expect(
      recordedInput.contains("macOS system speech language: \"")
        && recordedInput.contains("erste frage")
        && recordedInput.contains("zweite frage"),
      "every request should carry the current system speech language"
    )
    expect(
      !recordedInput.contains("You are responding as a personal assistant"),
      "resumed requests must not duplicate the durable workspace instruction prompt"
    )
    expect(
      recordedInput.components(separatedBy: "Current Aven turn context:").count - 1 == 2,
      "each request should carry only one compact dynamic turn context"
    )
  }

  private static func rejectsMissingExecutable() {
    let client = CodexClient(
      executableURL: URL(fileURLWithPath: "/definitely/missing/codex")
    )
    let result = awaitResult { client.ask("frage", completion: $0) }
    expect(result == .failure(.executableMissing), "missing executable should fail explicitly")
  }

  private static func failedLaunchDoesNotActivateAProposedProjectContext() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-launch-context-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let suiteName = "aven-launch-context-\(UUID().uuidString)"
    guard let defaults = consentedDefaults(suiteName: suiteName) else { exit(1) }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try! FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    let generalThread = UUID().uuidString
    let initialStore = ProjectContextStore(defaults: defaults)
    initialStore.remember(threadID: generalThread, for: initialStore.select("general"))

    let client = CodexClient(
      executableURL: executable,
      workspaceURL: root,
      defaults: defaults,
      isolatesExtensions: false,
      taskCapabilityProvider: { _ in nil },
      beforeLaunch: { try? FileManager.default.removeItem(at: executable) }
    )
    let route = ModelRoute(
      model: "available-model",
      reasoningEffort: "low",
      initialProgress: nil,
      contextKey: "new:never-started"
    )
    let result = awaitResult { client.ask("work", route: route, completion: $0) }
    guard case .failure(.launchFailed) = result else {
      fail("removing the executable immediately before launch should fail at the process boundary")
    }

    let reloaded = ProjectContextStore(defaults: defaults)
    expect(reloaded.threadID() == generalThread, "a failed launch must retain the prior context")
    expect(
      reloaded.hint().availableKeys == [ProjectContextStore.generalKey],
      "a failed launch must not persist the proposed empty project context"
    )
  }

  private static func migratesAnOldBlockedCandidateToWarningOnly() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-blocked-codex-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("codex")
    let suiteName = "aven-blocked-codex-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { exit(1) }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try! FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: executable.path
    )
    defaults.set(executable.path, forKey: CodexExecutableLocator.blockedDefaultsKey)

    let located = CodexExecutableLocator.locate(
      defaults: defaults,
      environment: ["PATH": root.path]
    )

    expect(located == executable.standardizedFileURL, "an old block marker must not disable the executable")
    expect(
      defaults.string(forKey: CodexExecutableLocator.blockedDefaultsKey) == nil,
      "the obsolete block marker should be removed during discovery"
    )
  }

  private static func clearsContextWithoutDeletingWorkspaceData() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-clear-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let workspace = root.appendingPathComponent("workspace")
    let memory = workspace.appendingPathComponent("memory.md")
    let suiteName = "aven-clear-\(UUID().uuidString)"
    guard let defaults = consentedDefaults(suiteName: suiteName) else { exit(1) }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try! Data("durable".utf8).write(to: memory)
    let script = """
      #!/bin/sh
      cat >/dev/null
      printf '%s\\n' '{"type":"thread.started","thread_id":"thread-clear"}'
      printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'
      printf '%s\\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let client = CodexClient(
      executableURL: executable,
      workspaceURL: workspace,
      defaults: defaults
    )
    let result = awaitResult { client.ask("remember this", completion: $0) }
    guard case .success = result else { fail("context setup should succeed") }
    expect(client.threadID == "thread-clear", "the active context should be stored")

    client.clearContext()

    expect(client.threadID == nil, "clear context should remove only the active thread link")
    expect(FileManager.default.fileExists(atPath: memory.path), "durable memory must remain")
  }

  private static func clearingAnActiveContextCannotRestoreItsThreadID() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-active-clear-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let workspace = root.appendingPathComponent("workspace")
    let suiteName = "aven-active-clear-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      cat >/dev/null
      printf '%s\\n' '{"type":"thread.started","thread_id":"thread-active"}'
      sleep 2
      printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"late"}}'
      printf '%s\\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: workspace,
      defaults: defaults,
      isolatesExtensions: false
    )
    let completed = DispatchSemaphore(value: 0)
    client.ask("start") { _ in completed.signal() }
    let deadline = Date(timeIntervalSinceNow: 1)
    while client.threadID == nil, Date() < deadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    expect(client.threadID == "thread-active", "active thread should be observed before clearing")

    client.clearContext()
    expect(client.cancelAndWait(), "active process should terminate before deletion")
    while completed.wait(timeout: .now() + 0.05) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    expect(client.threadID == nil, "buffered events must not restore a cleared thread")
  }

  private static func clearContextWinsTheThreadPersistenceRace() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-clear-race-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let suiteName = "aven-clear-race-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      cat >/dev/null
      printf '%s\n' '{"type":"thread.started","thread_id":"thread-race"}'
      sleep 2
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"late"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    let persistenceGate = BlockingOnce()
    let reachedPersistence = DispatchSemaphore(value: 0)
    let releasePersistence = DispatchSemaphore(value: 0)
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: root,
      defaults: defaults,
      isolatesExtensions: false,
      beforeThreadPersistence: {
        persistenceGate.runOnce {
          reachedPersistence.signal()
          _ = releasePersistence.wait(timeout: .now() + 5)
        }
      }
    )
    let route = ModelRoute(
      model: "available-model",
      reasoningEffort: "low",
      initialProgress: nil,
      contextKey: "new:discarded"
    )
    let completed = DispatchSemaphore(value: 0)
    client.ask("start", route: route) { _ in completed.signal() }
    expect(
      reachedPersistence.wait(timeout: .now() + 3) == .success,
      "the test task should reach thread persistence"
    )

    client.clearContext()
    releasePersistence.signal()
    while completed.wait(timeout: .now() + 0.05) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    let reloaded = ProjectContextStore(defaults: defaults)
    expect(reloaded.threadID() == nil, "clear context must win against an in-flight thread event")
    expect(
      reloaded.hint().availableKeys == [ProjectContextStore.generalKey],
      "a discarded thread event must not recreate its proposed context"
    )
  }

  private static func deletesOnlyStoredAssistantThreads() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-delete-threads-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let log = root.appendingPathComponent("fake-codex.deleted")
    let suiteName = "aven-delete-threads-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      printf '%s\\n' "$*" >> "$0.deleted"
      exit 0
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let identifier = "11111111-1111-4111-8111-111111111111"
    defaults.set(identifier, forKey: "voiceAssistant.codexThreadID.v2")
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: root,
      sessionsURL: root.appendingPathComponent("sessions"),
      defaults: defaults
    )

    expect(client.deleteStoredThreads(), "stored assistant task deletion should succeed")
    let recorded = try! String(contentsOf: log, encoding: .utf8)
    expect(recorded.contains("delete --force \(identifier)"), "only the stored task ID should be deleted")
    expect(
      defaults.string(forKey: "voiceAssistant.codexThreadID.v2") == nil,
      "deleted task links should be cleared"
    )
  }

  private static func discoversPreRegistryWorkspaceTasksForDeletion() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-discover-threads-\(UUID().uuidString)")
    let workspace = root.appendingPathComponent("workspace")
    let sessions = root.appendingPathComponent("sessions")
    let executable = root.appendingPathComponent("fake-codex")
    let deletionLog = root.appendingPathComponent("fake-codex.deleted")
    let suiteName = "aven-discover-threads-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    let identifier = "33333333-3333-4333-8333-333333333333"
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let metadata = """
      {"type":"session_meta","payload":{"id":"\(identifier)","cwd":"\(workspace.path)"}}
      """
    try! Data(metadata.utf8).write(to: sessions.appendingPathComponent("rollout.jsonl"))
    let script = """
      #!/bin/sh
      printf '%s\n' "$*" >> "$0.deleted"
      exit 0
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: workspace,
      sessionsURL: sessions,
      defaults: defaults
    )

    expect(client.threadID == nil, "the simulated older task must not have a stored scalar link")
    expect(client.deleteStoredThreads(), "workspace-owned pre-registry tasks should be deleted")
    let recorded = try! String(contentsOf: deletionLog, encoding: .utf8)
    expect(recorded.contains("delete --force \(identifier)"), "workspace discovery should recover the task")
  }

  private static func discoversOnlyVerifiedLegacyWorkspaceTasks() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-legacy-threads-\(UUID().uuidString)")
    let workspace = root.appendingPathComponent("current")
    let legacy = root.appendingPathComponent("VoiceAssistant")
    let sessions = root.appendingPathComponent("sessions")
    let executable = root.appendingPathComponent("fake-codex")
    let deletionLog = root.appendingPathComponent("fake-codex.deleted")
    let suiteName = "aven-legacy-threads-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    let identifier = "44444444-4444-4444-8444-444444444444"
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    for directory in [workspace, legacy, sessions] {
      try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let metadata = """
      {"type":"session_meta","payload":{"id":"\(identifier)","cwd":"\(legacy.path)"}}
      """
    try! Data(metadata.utf8).write(to: sessions.appendingPathComponent("legacy.jsonl"))
    let script = """
      #!/bin/sh
      printf '%s\n' "$*" >> "$0.deleted"
      exit 0
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    func client() -> CodexClient {
      CodexClient(
        executableURL: executable,
        workspaceURL: workspace,
        sessionsURL: sessions,
        legacyWorkspaceURL: legacy,
        defaults: defaults
      )
    }
    expect(client().deleteStoredThreads(), "unverified legacy paths should be ignored safely")
    expect(!FileManager.default.fileExists(atPath: deletionLog.path), "generic legacy paths are not owned")

    let decisions = legacy.appendingPathComponent("decisions")
    try! FileManager.default.createDirectory(at: decisions, withIntermediateDirectories: true)
    try! Data("# Voice Assistant\n\nEigener Arbeitsbereich des Menüleisten-Assistenten.\n".utf8)
      .write(to: legacy.appendingPathComponent("README.md"))
    try! Data("# 0001 – Begrenzte Berechtigungen des Sprachassistenten\nDer Assistent erhält Schreibzugriff\n".utf8)
      .write(to: decisions.appendingPathComponent("0001-assistant-boundaries.md"))
    expect(client().deleteStoredThreads(), "verified historical assistant tasks should be deleted")
    let recorded = try! String(contentsOf: deletionLog, encoding: .utf8)
    expect(recorded.contains("delete --force \(identifier)"), "verified legacy ownership should migrate")
  }

  private static func cancellationBeforeLaunchNeverStartsCodex() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-cancel-reservation-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let launchLog = root.appendingPathComponent("fake-codex.launched")
    let suiteName = "aven-cancel-reservation-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      printf 'launched\n' > "$0.launched"
      cat >/dev/null
      exit 0
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: root,
      sessionsURL: root.appendingPathComponent("sessions"),
      defaults: defaults,
      beforeLaunch: {
        entered.signal()
        release.wait()
      }
    )
    let completed = DispatchSemaphore(value: 0)
    var result: Result<String, CodexClientError>?
    client.ask(
      "do not launch",
      route: ModelRoute(
        model: "model-test",
        reasoningEffort: "low",
        initialProgress: nil,
        contextKey: "new:cancelled-context"
      )
    ) {
      result = $0
      completed.signal()
    }
    expect(entered.wait(timeout: .now() + 2) == .success, "request should reach its launch boundary")
    client.cancel()
    release.signal()
    while completed.wait(timeout: .now() + 0.05) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    expect(
      result == .failure(.cancelled),
      "a cancelled reservation must fail before launch"
    )
    expect(!FileManager.default.fileExists(atPath: launchLog.path), "cancelled work must not launch Codex")
    expect(
      !client.projectContextHint.availableKeys.contains("cancelled-context"),
      "cancelled work must not create or activate its proposed project context"
    )
    expect(client.cancelAndWait(), "the cancelled reservation should be fully released")
  }

  private static func cancellationAfterLaunchReturnsCancelled() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-active-cancel-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let suiteName = "aven-active-cancel-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      cat >/dev/null
      printf '%s\n' '{"type":"thread.started","thread_id":"thread-cancel"}'
      exec sleep 30
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: root,
      defaults: defaults,
      isolatesExtensions: false
    )
    let finished = DispatchSemaphore(value: 0)
    var result: Result<String, CodexClientError>?
    client.ask("long work") {
      result = $0
      finished.signal()
    }
    let deadline = Date(timeIntervalSinceNow: 2)
    while client.threadID == nil, Date() < deadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    expect(client.threadID == "thread-cancel", "the process should be running before cancellation")

    client.cancel()
    while finished.wait(timeout: .now() + 0.05) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    expect(result == .failure(.cancelled), "a terminated active request should report cancellation")
  }

  private static func clearedContextRemainsOwnedForDeletion() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-cleared-owned-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let deletionLog = root.appendingPathComponent("fake-codex.deleted")
    let suiteName = "aven-cleared-owned-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    let identifier = "22222222-2222-4222-8222-222222222222"
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      if [ "$1" = "delete" ]; then
        printf '%s\n' "$*" >> "$0.deleted"
        exit 0
      fi
      cat >/dev/null
      printf '%s\n' '{"type":"thread.started","thread_id":"\(identifier)"}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexClient(
      executableURL: executable,
      workspaceURL: root,
      defaults: defaults
    )

    guard case .success = awaitResult({ client.ask("remember", completion: $0) }) else {
      fail("assistant task should complete")
    }
    client.clearContext()
    expect(client.threadID == nil, "clear context should detach the current task")
    expect(client.deleteStoredThreads(), "detached assistant tasks should still be deletable")
    let recorded = try! String(contentsOf: deletionLog, encoding: .utf8)
    expect(recorded.contains("delete --force \(identifier)"), "deletion should include the cleared task")
  }

  private static func rejectsEmptyPromptBeforeLaunchingCodex() {
    let client = CodexClient(
      executableURL: URL(fileURLWithPath: "/definitely/missing/codex")
    )
    let result = awaitResult { client.ask("  \n ", completion: $0) }
    expect(result == .failure(.emptyPrompt), "empty transcripts must never launch Codex")
  }

  private static func discoversCodexWithoutAPackageManagerPath() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-locator-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("codex")
    let suiteName = "aven-locator-\(UUID().uuidString)"
    let defaults = consentedDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let located = CodexExecutableLocator.locate(
      defaults: defaults,
      environment: ["PATH": root.path]
    )

    expect(located == executable.standardizedFileURL, "Codex should be discovered from PATH")
    expect(
      CodexExecutableLocator.signatureWarning(for: executable) != nil,
      "an unverified executable should warn without being blocked"
    )
  }

  private static func requiresForwardingConsentAtTheProcessBoundary() {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    let client = CodexClient(executableURL: executable, forwardingAllowed: { false })

    let result = awaitResult { client.ask("private request", completion: $0) }

    expect(result == .failure(.forwardingDisabled), "Codex must not start without forwarding consent")
  }

  private static func classifiesOperationalFailures() {
    let cases: [(String, CodexClientError)] = [
      ("401 unauthorized; login required", .loginRequired),
      ("session expired; failed to resume", .sessionExpired),
      ("network connection timed out", .networkUnavailable),
      ("429 rate limit reached", .rateLimited),
      ("model unavailable", .modelUnavailable),
      (
        "upgrade required; unsupported version",
        .featureUnavailable("upgrade required; unsupported version")
      ),
      ("permission denied", .accessDenied),
    ]
    for (message, expected) in cases {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aven-error-\(UUID().uuidString)")
      let executable = root.appendingPathComponent("fake-codex")
      let suiteName = "aven-error-\(UUID().uuidString)"
      let defaults = consentedDefaults(suiteName: suiteName)!
      defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
      }
      try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let script = "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '\(message)' >&2\nexit 1\n"
      try! Data(script.utf8).write(to: executable)
      try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
      let client = CodexClient(executableURL: executable, workspaceURL: root, defaults: defaults)

      let result = awaitResult { client.ask("test", completion: $0) }

      expect(result == .failure(expected), "operational error should be classified: \(message)")
    }
  }

  private static func persistsOnlyCurrentForwardingConsent() {
    let suiteName = "aven-consent-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    expect(!AIForwardingConsent.isEnabled(defaults: defaults), "forwarding starts disabled")

    AIForwardingConsent.accept(defaults: defaults, at: Date(timeIntervalSince1970: 1))
    expect(AIForwardingConsent.isEnabled(defaults: defaults), "current disclosure can be accepted")

    AIForwardingConsent.revoke(defaults: defaults)
    expect(!AIForwardingConsent.isEnabled(defaults: defaults), "revocation should take effect immediately")
  }

  private static func awaitResult(
    _ operation: (@escaping (Result<String, CodexClientError>) -> Void) -> Void
  ) -> Result<String, CodexClientError> {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<String, CodexClientError>?
    operation {
      result = $0
      semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return result!
  }

  private static func consentedDefaults(suiteName: String) -> UserDefaults? {
    guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
    AIForwardingConsent.accept(defaults: defaults)
    return defaults
  }

  private static func awaitVoidResult(
    _ operation: (@escaping (Result<Void, CodexClientError>) -> Void) -> Void
  ) -> Result<Void, CodexClientError> {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Void, CodexClientError>?
    operation {
      result = $0
      semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return result!
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}

private final class LockedStrings: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
}

private final class LockedCapabilitySets: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Set<TaskCapabilityBroker.Capability>] = []

  var values: [Set<TaskCapabilityBroker.Capability>] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ value: Set<TaskCapabilityBroker.Capability>) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
}

private final class BlockingOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var hasRun = false

  func runOnce(_ operation: () -> Void) {
    lock.lock()
    guard !hasRun else {
      lock.unlock()
      return
    }
    hasRun = true
    lock.unlock()
    operation()
  }
}
