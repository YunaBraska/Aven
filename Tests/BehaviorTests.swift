import Darwin
import Foundation

@MainActor
@main
enum BehaviorTests {
  static func main() {
    parsesCompletedCodexResponse()
    ignoresMalformedAndNonMessageEvents()
    cleansTextForSpeech()
    recoversSpeechOutputAfterDefaultRouteChange()
    reportsAssistantStates()
    permitsCodexMaintenanceOnlyWhileInactive()
    keepsActiveStatesVisible()
    tracksFunctionKeyEdgesOnlyOnce()
    acceptsOnlyThePhysicalFunctionKey()
    recognizesOnlyMnemonicFnShortcuts()
    parsesLanguageNeutralAssistantControls()
    parsesAndBoundsOnDemandContext()
    authorizesPrivilegedCommandsOnlyForActiveTasks()
    groupsEveryPermissionExactlyOnce()
    suppressesNoSpeechErrors()
    capturesOnlyExplicitScreenReferences()
    resolvesTheSystemSpeechLanguage()
    formatsPipelineTiming()
    resolvesCustomCodexHome()
    reportsSafeCodexProgress()
    loadsCachedAssistantMetrics()
    boundsSessionMetricsReads()
    fallsBackFromIncompatiblePaginatedChats()
    opensTerminalWhenDesktopChatCannotBeOpened()
    preventsDuplicateChatWindows()
    validatesDiagramEditorRequests()
    expiresAndDeletesTaskRecipes()
    preservesUnsafeOrMalformedTaskRecipes()
    runsMemoryMaintenanceFromTheAppBoundary()
    selectsTrustedEndpointsFromTheLoginMode()
    discoversAndSelectsModelsSemantically()
    backsOffAfterSlowRouting()
    preservesActiveContextDuringRoutingCooldown()
    boundsRouterProcessOutput()
    fallsBackToTheLiveCodexDefaultWhenPlanningFails()
    returnsQuicklyWhenTheModelServerExits()
    animatesOnlyActiveStates()
    composesNativeStatusVisuals()
    print("Behavior tests passed")
  }

  private static func backsOffAfterSlowRouting() {
    var policy = RoutingFallbackPolicy()
    expect(policy.shouldAttemptSemanticRoute(), "routing should begin with semantic selection")
    policy.record(duration: 0.1, succeeded: false)
    expect(policy.shouldAttemptSemanticRoute(), "a quick failure should retry normally")
    policy.record(duration: RoutingFallbackPolicy.slowThreshold, succeeded: false)
    for _ in 0..<RoutingFallbackPolicy.fallbackTurnsAfterSlowRoute {
      expect(
        !policy.shouldAttemptSemanticRoute(),
        "slow route failures should temporarily use the live Codex default"
      )
    }
    expect(policy.shouldAttemptSemanticRoute(), "semantic routing must be probed again")
    policy.record(duration: 0.2, succeeded: true)
    expect(policy.shouldAttemptSemanticRoute(), "a fast successful route must close the circuit")
    policy.record(duration: RoutingFallbackPolicy.slowThreshold, succeeded: true)
    expect(
      !policy.shouldAttemptSemanticRoute(),
      "even a successful but slow route should protect following response latency"
    )
  }

  private static func preservesActiveContextDuringRoutingCooldown() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-router-cooldown-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    let plannerCalls = executable.appendingPathExtension("planner-calls")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      if [ "$1" = "login" ] && [ "$2" = "status" ]; then
        printf '%s\n' 'Logged in using ChatGPT'
        exit 0
      fi
      if [ "$1" = "features" ] && [ "$2" = "list" ]; then
        exit 0
      fi
      if [ "$1" = "app-server" ]; then
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'"id":2'*) printf '%s\n' '{"id":2,"result":{"data":[{"id":"live-default","model":"live-default","displayName":"Default","description":"General","hidden":false,"inputModalities":["text"],"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"quick"}],"defaultReasoningEffort":"low","isDefault":true,"multiAgentVersion":null}]}}' ;;
          esac
        done
        exit 0
      fi
      printf '%s\n' x >> "$0.planner-calls"
      /bin/sleep 2.7
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ROUTE\\tlive-default\\tlow\\tother-project"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let router = ModelRouter(
      executableURL: executable,
      environment: ["HOME": root.path],
      contextHint: {
        ProjectContextHint(activeKey: "active-project", availableKeys: ["general", "active-project"])
      }
    )

    let first = router.route(prompt: "move this", threadID: nil)
    let second = router.route(prompt: "keep going", threadID: nil)

    expect(first?.contextKey == "other-project", "the slow semantic route should still be accepted")
    expect(second?.model == "live-default", "cooldown should use the discovered live default")
    expect(second?.reasoningEffort == "low", "cooldown should use the default effort")
    expect(
      second?.contextKey == "active-project",
      "cooldown must preserve the active project context without keyword routing"
    )
    let calls = (try! String(contentsOf: plannerCalls, encoding: .utf8))
      .split(separator: "\n").count
    expect(calls == 1, "cooldown must not make another remote planner call")
  }

  private static func boundsRouterProcessOutput() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-router-output-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      if [ "$1" = "login" ] && [ "$2" = "status" ]; then
        printf '%s\n' 'Logged in using ChatGPT'
        exit 0
      fi
      if [ "$1" = "features" ] && [ "$2" = "list" ]; then
        exit 0
      fi
      if [ "$1" = "app-server" ]; then
        if [ "$ROUTER_OUTPUT_MODE" = app-server ]; then
          /bin/dd if=/dev/zero bs=1048577 count=1 2>/dev/null
          /bin/sleep 10
          exit 0
        fi
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'"id":2'*) printf '%s\n' '{"id":2,"result":{"data":[{"id":"live-default","model":"live-default","displayName":"Default","description":"General","hidden":false,"inputModalities":["text"],"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"quick"}],"defaultReasoningEffort":"low","isDefault":true,"multiAgentVersion":null}]}}' ;;
          esac
        done
        exit 0
      fi
      /bin/dd if=/dev/zero bs=1048577 count=1 2>/dev/null
      /bin/sleep 10
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    for mode in ["app-server", "helper"] {
      let router = ModelRouter(
        executableURL: executable,
        environment: ["HOME": root.path, "ROUTER_OUTPUT_MODE": mode]
      )
      let started = Date()
      let route = router.route(prompt: "route", threadID: nil)
      expect(route == nil, "oversized \(mode) output must be discarded")
      expect(
        Date().timeIntervalSince(started) < 2,
        "oversized \(mode) output must terminate the process instead of waiting for it"
      )
    }
  }

  private static func parsesCompletedCodexResponse() {
    let input = """
      {"type":"thread.started","thread_id":"thread-123"}
      {"type":"turn.started"}
      {"type":"item.completed","item":{"type":"agent_message","phase":"commentary","text":"Zwischenstand"}}
      {"type":"item.completed","item":{"type":"file_change","changes":[{"path":"/tmp/a","diff":"--- a\\n+++ b\\n-old\\n+new\\n+more"}]}}
      {"type":"item.completed","item":{"type":"agent_message","text":"Antwort"}}
      {"type":"turn.completed"}
      """
    let result = CodexEventParser.parse(Data(input.utf8))
    expect(result.threadID == "thread-123", "thread id should be parsed")
    expect(result.messages == ["Antwort"], "agent message should be parsed")
    expect(result.completed, "completion should be parsed")
    expect(result.diff == CodexDiffSummary(added: 2, removed: 1), "diff totals should be parsed")
  }

  private static func ignoresMalformedAndNonMessageEvents() {
    let input = """
      warning from stderr
      {"type":"item.completed","item":{"type":"command_execution","text":"secret"}}
      {"type":"item.completed","item":{"type":"agent_message","text":"  "}}
      """
    let result = CodexEventParser.parse(Data(input.utf8))
    expect(result.threadID == nil, "missing thread id should remain absent")
    expect(result.messages.isEmpty, "non-agent and empty messages should be ignored")
    expect(!result.completed, "missing completion should remain false")
  }

  private static func cleansTextForSpeech() {
    let input = "Noxius: **Siehe** [`Datei`](https://example.invalid)."
    expect(SpokenText.clean(input) == "Siehe Datei.", "markup should not be spoken")
  }

  private static func recoversSpeechOutputAfterDefaultRouteChange() {
    let outputRoute = TestSpeechOutputRouteObserver()
    var engines: [TestSpeechEngine] = []
    let output = SpeechOutput(
      engineFactory: {
        let engine = TestSpeechEngine()
        engines.append(engine)
        return engine
      },
      outputRouteObserver: outputRoute
    )
    var starts = 0
    var finishes = 0
    output.onStart = { starts += 1 }
    output.onFinish = { finishes += 1 }

    output.speak("first")
    output.speak("second")
    expect(engines.count == 1 && engines[0].spoken == ["first"], "first utterance should use a new engine")
    expect(output.togglePause() == true && engines[0].isPaused, "active speech should pause")

    outputRoute.change()
    expect(
      engines.count == 2 && engines[0].stopped && engines[1].spoken == ["first"]
        && engines[1].isPaused,
      "a default-output change should recreate the active utterance without losing pause state"
    )
    engines[0].finish()
    expect(
      engines.count == 2 && finishes == 0,
      "a late completion from the replaced output route must not advance the speech queue"
    )
    expect(output.togglePause() == false && !engines[1].isPaused, "replacement speech should resume")

    engines[1].finish()
    expect(engines.count == 3 && engines[2].spoken == ["second"], "queued speech should continue after recovery")
    engines[2].finish()
    expect(starts == 2 && finishes == 2 && !output.canPause, "speech callbacks should finish exactly once")
  }

  private static func reportsAssistantStates() {
    expect(AssistantState.listening.statusText == "Listening…", "listening status")
    expect(
      AssistantState.failed("Fehler").statusText == "Fehler",
      "failure should expose its useful message"
    )
  }

  private static func resolvesCustomCodexHome() {
    expect(
      AssistantPaths.codexHomeURL(environment: ["CODEX_HOME": "/tmp/custom-codex-home"]).path
        == "/tmp/custom-codex-home",
      "custom Codex homes must be shared by routing, compaction, metrics, and transcripts"
    )
    expect(
      AssistantPaths.codexHomeURL(environment: ["CODEX_HOME": "relative-home"]).path
        == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path,
      "relative Codex homes must not redirect storage"
    )
    expect(
      AssistantPaths.normalizingCodexHome(in: ["CODEX_HOME": "  /tmp/custom-codex-home  "])["CODEX_HOME"]
        == "/tmp/custom-codex-home",
      "subprocesses must receive one trimmed absolute Codex home"
    )
    expect(
      AssistantPaths.normalizingCodexHome(in: ["CODEX_HOME": "relative-home"])["CODEX_HOME"] == nil,
      "subprocesses must not receive a relative Codex home"
    )
  }

  private static func permitsCodexMaintenanceOnlyWhileInactive() {
    expect(AssistantState.idle.allowsCodexMaintenance, "idle should allow Codex maintenance")
    expect(
      AssistantState.failed("Unavailable").allowsCodexMaintenance,
      "a failed state should allow recovery maintenance"
    )
    let active: [AssistantState] = [
      .listening, .transcribing, .routing, .thinking, .working("Working…"), .compacting,
      .speaking, .paused,
    ]
    expect(
      active.allSatisfy { !$0.allowsCodexMaintenance },
      "listening, work, speech, and paused speech must block Codex maintenance"
    )
  }

  private static func keepsActiveStatesVisible() {
    let activeStates: [AssistantState] = [
      .listening, .transcribing, .routing, .thinking, .working("Working…"), .compacting,
      .speaking,
    ]
    expect(activeStates.allSatisfy { !$0.statusText.isEmpty }, "active states need visible text")
    expect(AssistantState.idle.statusText == "Aven", "idle accessibility label should use the app name")
    expect(!AssistantState.idle.showsStatusInMenu, "idle status should stay out of the menu")
    expect(
      activeStates.allSatisfy(\.showsStatusInMenu),
      "active status should remain visible in the menu"
    )
    expect(
      AssistantState.failed("Unavailable").showsStatusInMenu,
      "a real failure should remain visible in the menu"
    )
  }

  private static func tracksFunctionKeyEdgesOnlyOnce() {
    var tracker = FunctionKeyTracker()
    expect(tracker.update(isPressed: true) == .pressed, "Fn down should start listening")
    expect(tracker.update(isPressed: true) == nil, "repeated Fn flags should be ignored")
    expect(tracker.update(isPressed: false) == .released, "Fn up should stop listening")
    expect(tracker.update(isPressed: false) == nil, "repeated release should be ignored")
  }

  private static func acceptsOnlyThePhysicalFunctionKey() {
    expect(
      FunctionKeyEvent.isPhysicalFunctionKey(keyCode: 63),
      "physical Fn should be accepted"
    )
    expect(
      !FunctionKeyEvent.isPhysicalFunctionKey(keyCode: 125),
      "down arrow must never activate listening"
    )
  }

  private static func recognizesOnlyMnemonicFnShortcuts() {
    expect(
      FunctionKeyEvent.chordAction(keyCode: 15, functionIsPressed: true, isRepeat: false)
        == .repeatAnswer,
      "Fn+R should repeat the last answer"
    )
    expect(
      FunctionKeyEvent.chordAction(keyCode: 35, functionIsPressed: true, isRepeat: false)
        == .pauseResume,
      "Fn+P should pause or resume speech"
    )
    expect(
      FunctionKeyEvent.chordAction(keyCode: 53, functionIsPressed: true, isRepeat: false) == .stop,
      "Fn+Escape should stop all work"
    )
    expect(
      FunctionKeyEvent.chordAction(keyCode: 126, functionIsPressed: true, isRepeat: false)
        == .cancelDictation,
      "every other Fn chord should cancel dictation"
    )
    expect(
      FunctionKeyEvent.chordAction(keyCode: 15, functionIsPressed: false, isRepeat: false) == nil,
      "R without Fn must remain untouched"
    )
  }

  private static func parsesLanguageNeutralAssistantControls() {
    expect(
      AssistantControlCommand.request(arguments: ["assistant-control", "answer", "repeat"])
        == AssistantControlRequest(action: .answerRepeat, value: nil),
      "repeat should be exposed as an explicit control"
    )
    expect(
      AssistantControlCommand.request(
        arguments: ["assistant-control", "result", "set", "/tmp/output"]
      ) == AssistantControlRequest(action: .resultSet, value: "/tmp/output"),
      "result paths should be transported as data"
    )
    expect(
      AssistantControlCommand.request(
        arguments: ["assistant-control", "capability", "calendar", "on"]
      ) == AssistantControlRequest(action: .capabilityOn, value: "calendar"),
      "capabilities should be language-neutral operations"
    )
    expect(
      AssistantControlCommand.request(
        arguments: ["assistant-control", "diagram", "open", "/tmp/design.drawio"]
      ) == AssistantControlRequest(action: .diagramOpen, value: "/tmp/design.drawio"),
      "diagram paths should be transported as data"
    )
    expect(
      AssistantControlCommand.request(arguments: ["assistant-control", "shortcut", "right-option"])
        == AssistantControlRequest(action: .shortcutSelect, value: "right-option"),
      "shortcut selection should be a language-neutral operation"
    )
    expect(
      AssistantControlCommand.request(arguments: ["assistant-control", "access", "approve-for-me"])
        == AssistantControlRequest(action: .accessSelect, value: "approve-for-me"),
      "access selection should be a language-neutral operation"
    )
    expect(
      AssistantControlCommand.request(arguments: ["assistant-control", "meeting", "start"])
        == AssistantControlRequest(action: .meetingStart, value: nil),
      "meeting recording should expose a language-neutral start operation"
    )
    expect(
      AssistantControlCommand.request(arguments: ["assistant-control", "meeting", "stop"])
        == AssistantControlRequest(action: .meetingStop, value: nil),
      "meeting recording should expose a language-neutral stop operation"
    )
    expect(
      AssistantControlCommand.request(arguments: ["assistant-control", "shortcut", "caps-lock"])
        == nil,
      "unsupported shortcut keys must fail at the command boundary"
    )
    expect(
      AssistantControlCommand.request(arguments: ["assistant-control", "access", "unrestricted"])
        == nil,
      "unknown access profiles must fail at the command boundary"
    )
    expect(
      AssistantControlCommand.request(arguments: ["assistant-control", "mach", "das"]) == nil,
      "ordinary language must never be hard-coded as an app command"
    )
  }

  private static func parsesAndBoundsOnDemandContext() {
    expect(
      AssistantContextCommand.source(arguments: ["assistant-context", "selection"]) == .selection,
      "selection context should use the narrow broker operation"
    )
    expect(
      AssistantContextCommand.source(arguments: ["assistant-context", "clipboard"]) == .clipboard,
      "clipboard context should use the narrow broker operation"
    )
    expect(
      AssistantContextCommand.source(arguments: ["assistant-context", "watch"]) == nil,
      "the context broker must not expose continuous observation"
    )
    expect(
      AssistantContextCommand.bounded("äöü", maximumBytes: 5) == "äö",
      "bounded context must retain valid UTF-8"
    )
  }

  private static func authorizesPrivilegedCommandsOnlyForActiveTasks() {
    let service = "com.yunabraska.aven.tests.task-capabilities.\(UUID().uuidString)"
    defer { _ = TaskCapabilityBroker.endSession(service: service) }
    expect(TaskCapabilityBroker.beginSession(service: service), "a task capability session should start")
    expect(
      TaskCapabilityBroker.isProcess(Darwin.getpid(), descendantOf: Darwin.getpid()),
      "the issuing task must remain inside its own process boundary"
    )
    expect(
      !TaskCapabilityBroker.isProcess(Darwin.getpid(), descendantOf: 1),
      "an unrelated process root must not satisfy task ancestry"
    )
    let token = TaskCapabilityBroker.issue(
      capabilities: [.vault, .calendar],
      lifetime: 60,
      service: service
    )
    expect(token != nil, "an active session should issue a task capability")
    guard let token else { return }
    expect(
      TaskCapabilityBroker.authorizes(token, capability: .vault, service: service),
      "an active task should authorize its vault capability"
    )
    expect(
      TaskCapabilityBroker.authorizes(token, capability: .calendar, service: service),
      "an active task should authorize its calendar capability"
    )
    let calendarOnlyToken = TaskCapabilityBroker.issue(
      capabilities: [.calendar],
      lifetime: 60,
      service: service
    )
    expect(calendarOnlyToken != nil, "an active session should issue a scoped task capability")
    if let calendarOnlyToken {
      expect(
        !TaskCapabilityBroker.authorizes(calendarOnlyToken, capability: .vault, service: service),
        "a calendar capability must not authorize vault access"
      )
    }
    expect(TaskCapabilityBroker.revoke(token, service: service), "a finished task should revoke its token")
    expect(
      !TaskCapabilityBroker.authorizes(token, capability: .vault, service: service),
      "a revoked task token must not be replayed"
    )
    let staleToken = TaskCapabilityBroker.issue(
      capabilities: [.vault],
      lifetime: 60,
      service: service
    )
    expect(staleToken != nil, "an active session should issue a second task capability")
    guard let staleToken else { return }
    expect(TaskCapabilityBroker.beginSession(service: service), "an app restart should replace the session")
    expect(
      !TaskCapabilityBroker.authorizes(staleToken, capability: .vault, service: service),
      "a task token from an earlier app session must fail"
    )

    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let helperToken = TaskCapabilityBroker.issueVaultHelper(
      executable: executable,
      arguments: [],
      service: service
    )
    expect(helperToken != nil, "an active session should issue a helper authorization")
    guard let helperToken else { return }
    expect(
      TaskCapabilityBroker.consumeVaultHelper(
        helperToken,
        executable: executable,
        arguments: [],
        service: service
      ),
      "the helper authorization should permit its exact command once"
    )
    expect(
      !TaskCapabilityBroker.consumeVaultHelper(
        helperToken,
        executable: executable,
        arguments: [],
        service: service
      ),
      "a consumed helper authorization must not be replayed"
    )
  }

  private static func groupsEveryPermissionExactlyOnce() {
    let grouped = AssistantCapabilityGroup.allCases.flatMap(\.capabilities)
    expect(
      grouped.count == AssistantCapability.allCases.count && Set(grouped.map(\.rawValue)).count == grouped.count,
      "permission groups must contain every capability exactly once"
    )
  }

  private static func suppressesNoSpeechErrors() {
    expect(SpeechControllerError.noSpeech.isSilent, "no speech should be silent")
    expect(
      SpeechControllerError.recordingFailed("device").isSilent,
      "recording failures should not interrupt with spoken errors"
    )
    expect(!SpeechControllerError.microphoneDenied.isSilent, "missing permission should remain visible")
  }

  private static func capturesOnlyExplicitScreenReferences() {
    expect(
      ScreenContextPolicy.shouldCapture(for: "Was siehst du auf meinem Bildschirm?"),
      "explicit German screen questions should attach a screenshot"
    )
    expect(
      ScreenContextPolicy.shouldCapture(for: "Can you see this window?"),
      "explicit English screen questions should attach a screenshot"
    )
    expect(
      !ScreenContextPolicy.shouldCapture(for: "Was hältst du davon?"),
      "ambiguous questions must not capture the screen"
    )
  }

  private static func resolvesTheSystemSpeechLanguage() {
    expect(
      SystemSpeechLanguage.resolve(configured: "de", fallback: "en_GB") == "de",
      "configured speech language should win"
    )
    expect(
      SystemSpeechLanguage.resolve(configured: "  ", fallback: "en_GB") == "en_GB",
      "locale should be the fallback"
    )
    expect(
      SystemSpeechLanguage.voiceLabel(identifier: "com.apple.siri.natural.de-DE-C") == "Voice03",
      "system Siri voice identifiers should produce compact menu labels"
    )
  }

  private static func formatsPipelineTiming() {
    let snapshot = PipelineTimingSnapshot(durations: [.routing: 2.35, .transcription: 0.08])
    expect(snapshot.label(for: .routing) == "Route 2.4 s", "seconds should remain compact")
    expect(snapshot.label(for: .transcription) == "Transcribe 80 ms", "short stages use milliseconds")
    expect(snapshot.label(for: .speech) == "Speak —", "unseen stages remain explicit")
  }

  private static func reportsSafeCodexProgress() {
    let thinking = Data("{\"type\":\"turn.started\"}".utf8)
    let command = Data(
      "{\"type\":\"item.started\",\"item\":{\"type\":\"command_execution\"}}".utf8
    )
    let reasoning = Data(
      "{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\",\"text\":\"private\"}}".utf8
    )
    let commentary = Data(
      "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"phase\":\"commentary\",\"text\":\"I found the cause.\"}}".utf8
    )
    var stream = CodexProgressStream()
    expect(stream.consume(thinking) == [.thinking], "thinking progress")
    expect(stream.consume(reasoning).isEmpty, "private reasoning must stay hidden")
    expect(
      stream.consume(commentary) == [.update("I found the cause.")],
      "user-facing commentary should become spoken progress"
    )
    expect(!CodexProgress.thinking.shouldSpeak, "generic thinking must stay silent")
    expect(CodexProgress.update("Found it.").shouldSpeak, "concrete commentary should be spoken")

    let unmarkedCommentary = Data(
      "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"I will inspect the folder.\"}}".utf8
    )
    expect(stream.consume(unmarkedCommentary).isEmpty, "latest agent message may be final")
    expect(
      stream.consume(command) == [.update("I will inspect the folder."), .working],
      "an agent message becomes progress when more work follows"
    )
    let workerStarted = Data(
      "{\"type\":\"item.started\",\"item\":{\"id\":\"worker-1\",\"type\":\"collab_tool_call\"}}".utf8
    )
    let workerFinished = Data(
      "{\"type\":\"item.completed\",\"item\":{\"id\":\"worker-1\",\"type\":\"collab_tool_call\"}}".utf8
    )
    expect(stream.consume(workerStarted) == [.workers(1)], "worker start should update the count")
    expect(stream.consume(workerFinished) == [.workers(0)], "worker completion should update the count")
  }

  private static func loadsCachedAssistantMetrics() {
    expect(
      AssistantMetricsSnapshot.empty.weeklyUsageLabel == "Weekly —",
      "missing weekly usage should remain explicit"
    )
    expect(
      AssistantMetricsSnapshot.empty.agentsLabel == "Agents 0 KB",
      "empty agent storage should stay compact"
    )
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-metrics-\(UUID().uuidString)")
    let workspace = root.appendingPathComponent("workspace")
    let sessions = root.appendingPathComponent("sessions")
    let current = sessions.appendingPathComponent("current.jsonl")
    let child = sessions.appendingPathComponent("child.jsonl")
    let stale = sessions.appendingPathComponent("newly-touched-stale.jsonl")
    try! FileManager.default.createDirectory(
      at: workspace.appendingPathComponent("memory"),
      withIntermediateDirectories: true
    )
    try! FileManager.default.createDirectory(
      at: workspace.appendingPathComponent("database"),
      withIntermediateDirectories: true
    )
    try! FileManager.default.createDirectory(
      at: workspace.appendingPathComponent("vault"),
      withIntermediateDirectories: true
    )
    try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try! Data("memory".utf8).write(to: workspace.appendingPathComponent("memory/profile.md"))
    try! Data("database".utf8).write(
      to: workspace.appendingPathComponent("database/assistant.sqlite3")
    )
    try! Data("metadata".utf8).write(to: workspace.appendingPathComponent("vault/record.json"))
    let currentLines = """
      {"type":"session_meta","payload":{"id":"root"}}
      {"timestamp":"2026-09-04T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":12500},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":13.0,"window_minutes":10080,"resets_at":1788748010},"secondary":null}}}
      """
    let childLine = """
      {"type":"session_meta","payload":{"id":"child","parent_thread_id":"root"}}
      """
    try! Data(currentLines.utf8).write(to: current)
    try! Data(childLine.utf8).write(to: child)
    try! Data(
      """
      {"type":"session_meta","payload":{"id":"stale"}}
      {"timestamp":"2026-09-03T12:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":92.0,"window_minutes":10080,"resets_at":1788748010}}}}
      """.utf8
    ).write(to: stale)

    let snapshot = AssistantMetricsLoader.load(
      threadID: "root",
      workspaceURL: workspace,
      sessionsURL: sessions,
      vaultURL: workspace.appendingPathComponent("vault")
    )
    expect(snapshot.contextTokens == 12_500, "context token size should be loaded")
    expect(snapshot.contextWindow == 258_400, "context window should be loaded")
    expect(snapshot.weeklyRemainingPercent == 87, "remaining weekly Codex usage should be loaded")
    expect(
      snapshot.weeklyUsageLabel == "Weekly remaining 87% · 7 Sept",
      "weekly reset should show the remaining allowance explicitly"
    )
    expect(snapshot.subagentBytes > 0, "child agent session storage should be measured")
    expect(snapshot.memoryBytes > 0, "memory size should be loaded")
    expect(snapshot.databaseBytes > 0, "database size should be loaded")
    expect(snapshot.recipeBytes == 0, "missing recipe folder should report no storage")
    expect(snapshot.vaultBytes > 0, "vault size should be loaded")
    let withoutWeeklyFallback = AssistantMetricsLoader.load(
      threadID: "root",
      workspaceURL: workspace,
      sessionsURL: sessions,
      vaultURL: workspace.appendingPathComponent("vault"),
      includeWeeklyFallback: false
    )
    expect(
      withoutWeeklyFallback.weeklyRemainingPercent == nil,
      "current account metrics should let the session fallback stay unread"
    )
  }

  private static func boundsSessionMetricsReads() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-large-session-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = FileManager.default.createFile(atPath: url.path, contents: nil)
      ? try! FileHandle(forWritingTo: url) : nil
    guard let handle else {
      expect(false, "large session fixture should be writable")
      return
    }
    try! handle.write(contentsOf: Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"large\"}}\n".utf8))
    let filler = Data(repeating: 0x78, count: AssistantMetricsLoader.maximumSessionTailBytes + 1_024)
    try! handle.write(contentsOf: filler)
    try! handle.write(contentsOf: Data("\n{\"type\":\"tail\"}\n".utf8))
    try! handle.close()

    let tail = AssistantMetricsLoader.boundedTail(from: url)
    expect(tail?.count ?? 0 < AssistantMetricsLoader.maximumSessionTailBytes, "session reads must stay bounded")
    expect(String(decoding: tail ?? Data(), as: UTF8.self).contains("\"type\":\"tail\""), "the newest complete event must remain available")
  }

  private static func fallsBackFromIncompatiblePaginatedChats() {
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-paginated-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: transcript) }
    try! Data(
      "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-id\",\"history_mode\":\"paginated\"}}\n".utf8
    ).write(to: transcript)
    expect(
      CodexChatLauncher.transcriptIsPaginated(at: transcript),
      "paginated history mode should be detected from session metadata"
    )
    try! Data(
      "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-id\"}}\n".utf8
    ).write(to: transcript)
    expect(
      CodexChatLauncher.transcriptIsPaginated(at: transcript),
      "the current ordinal session shape should bypass the unsupported Desktop deep-link"
    )
    expect(
      CodexChatLauncher.destination(
        threadID: "thread-id",
        transcriptURL: transcript,
        transcriptIsPaginated: true,
        desktopInstalled: true
      ) == .transcript(transcript),
      "a paginated thread should fail closed to the transcript"
    )
    expect(
      CodexChatLauncher.destination(
        threadID: "thread-id",
        transcriptURL: transcript,
        transcriptIsPaginated: false,
        desktopInstalled: false
      ) == .transcript(transcript),
      "a missing desktop app should open the local transcript"
    )
    let compatible = CodexChatLauncher.destination(
      threadID: "thread-id",
      transcriptURL: transcript,
      transcriptIsPaginated: true,
      desktopInstalled: true
    )
    expect(compatible == .transcript(transcript), "paginated history must not use an unsafe deep-link")
    let legacy = CodexChatLauncher.destination(
      threadID: "thread-id",
      transcriptURL: transcript,
      transcriptIsPaginated: false,
      desktopInstalled: true
    )
    if case .chat(let url) = legacy {
      expect(url.absoluteString == "codex://threads/thread-id", "chat deep-link should remain stable")
    } else {
      expect(false, "a legacy chat with Codex Desktop should deep-link")
    }
    expect(
      CodexChatDestination.transcript(transcript).menuTitle == "Open Chat",
      "the menu action should keep a stable name when it falls back"
    )
  }

  private static func opensTerminalWhenDesktopChatCannotBeOpened() {
    let threadID = "01a060eb-47ae-7b21-a048-d2bbe7210ef6"
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-chat-\(UUID().uuidString).jsonl")
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let workspace = URL(fileURLWithPath: "/tmp/aven-workspace", isDirectory: true)
    var receivedTerminalArguments: (URL, String, URL)?
    var desktopWasAttempted = false
    try! Data(
      "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}\n".utf8
    ).write(to: transcript)
    defer { try? FileManager.default.removeItem(at: transcript) }

    let terminalResult = CodexChatLauncher.open(
      threadID: threadID,
      transcriptURL: transcript,
      workspaceURL: workspace,
      desktopInstalled: true,
      urlOpener: { _ in
        desktopWasAttempted = true
        return true
      },
      executableLocator: { executable },
      terminalLauncher: { receivedExecutable, receivedThreadID, receivedWorkspace in
        receivedTerminalArguments = (receivedExecutable, receivedThreadID, receivedWorkspace)
        return true
      }
    )
    expect(terminalResult == .terminal, "an ordinal assistant task should resume in Terminal")
    expect(!desktopWasAttempted, "known unsupported task storage must not open the broken Desktop deep-link")
    expect(receivedTerminalArguments?.0 == executable, "Terminal should receive the resolved Codex executable")
    expect(
      receivedTerminalArguments?.1 == threadID,
      "Terminal should receive the validated, canonical Codex thread UUID"
    )
    expect(receivedTerminalArguments?.2 == workspace, "Terminal should resume in the assistant workspace")
    expect(
      CodexChatLauncher.terminalCodexArguments(threadID: threadID, workspaceURL: workspace) == [
        "-c", "check_for_update_on_startup=false", "resume", threadID, "--cd", workspace.path,
      ],
      "Aven terminal chats should suppress only Codex's per-process startup update question"
    )

    var terminalWasCalled = false
    let invalidThreadResult = CodexChatLauncher.open(
      threadID: "not-a-thread-id; rm -rf /",
      transcriptURL: transcript,
      workspaceURL: workspace,
      desktopInstalled: false,
      urlOpener: { $0 == transcript },
      executableLocator: { executable },
      terminalLauncher: { _, _, _ in
        terminalWasCalled = true
        return true
      }
    )
    expect(!terminalWasCalled, "only UUID thread identifiers may reach the Terminal launcher")
    expect(invalidThreadResult == .transcript, "an invalid thread id should retain the transcript fallback")
    expect(
      CodexChatLauncher.validatedThreadID("01A060EB-47AE-7B21-A048-D2BBE7210EF6") == threadID,
      "valid UUID thread identifiers should be canonicalized"
    )
    expect(
      CodexChatLauncher.terminalCodexArguments(
        threadID: "not-a-thread-id; rm -rf /",
        workspaceURL: workspace
      ) == nil,
      "invalid thread identifiers must not produce terminal arguments"
    )
  }

  private static func validatesDiagramEditorRequests() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-diagram-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let valid = root.appendingPathComponent("überblick.drawio")
    try! Data(
      "<?xml version=\"1.0\"?><mxfile><diagram name=\"Übersicht\"><mxGraphModel><root/></mxGraphModel></diagram></mxfile>".utf8
    ).write(to: valid)
    let request = try! DiagramEditor.request(path: valid.path)
    expect(request.fileURL == valid, "valid diagram path should be preserved")
    expect(
      request.editorURL.absoluteString.hasPrefix("https://app.diagrams.net/?splash=0#create="),
      "diagram should use the documented browser create fragment"
    )
    expect(
      request.editorURL.absoluteString.contains("%C3%9Cbersicht"),
      "Unicode diagram labels should be encoded"
    )

    let malformed = root.appendingPathComponent("malformed.drawio")
    try! Data("<mxfile>".utf8).write(to: malformed)
    expectDiagramError(.invalidDiagram, path: malformed.path)
    let unrelated = root.appendingPathComponent("unrelated.xml")
    try! Data("<document/>".utf8).write(to: unrelated)
    expectDiagramError(.invalidDiagram, path: unrelated.path)
    let oversized = root.appendingPathComponent("oversized.drawio")
    try! Data(repeating: 0x20, count: 60_001).write(to: oversized)
    expectDiagramError(.tooLarge, path: oversized.path)
    let symlink = root.appendingPathComponent("linked.drawio")
    try! FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid)
    expectDiagramError(.unsafeFile, path: symlink.path)
  }

  private static func preventsDuplicateChatWindows() {
    let now = Date(timeIntervalSince1970: 1_000)
    var gate = ChatOpenGate()
    expect(gate.begin(at: now), "the first chat open should start")
    expect(!gate.begin(at: now), "a concurrent chat open must be ignored")
    gate.finish(at: now)
    expect(!gate.begin(at: now.addingTimeInterval(1)), "rapid duplicate opens must be ignored")
    expect(gate.begin(at: now.addingTimeInterval(3)), "chat should open again after the cooldown")
  }

  private static func expiresAndDeletesTaskRecipes() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-recipes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let active = root.appendingPathComponent("active")
    let expired = root.appendingPathComponent("expired")
    let fresh = active.appendingPathComponent("fresh")
    let old = active.appendingPathComponent("old")
    let ancient = expired.appendingPathComponent("ancient")
    [fresh, old, ancient].forEach {
      try! FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
    }
    writeRecipeMetadata(at: fresh, expiresAt: "2026-12-01T00:00:00Z")
    writeRecipeMetadata(at: old, expiresAt: "2026-08-01T00:00:00Z")
    try! Data("2026-07-01T00:00:00Z".utf8).write(
      to: ancient.appendingPathComponent(".expired-at")
    )

    let now = ISO8601DateFormatter().date(from: "2026-09-04T12:00:00Z")!
    let report = RecipeMaintenance.maintain(rootURL: root, now: now)

    expect(report == RecipeMaintenanceReport(expired: 1, deleted: 1, errors: 0), "recipe TTL")
    expect(FileManager.default.fileExists(atPath: fresh.path), "fresh recipe should remain active")
    expect(!FileManager.default.fileExists(atPath: old.path), "expired recipe should leave active")
    expect(!FileManager.default.fileExists(atPath: ancient.path), "old expired recipe is deleted")
    let expiredNames = try! FileManager.default.contentsOfDirectory(atPath: expired.path)
    expect(expiredNames == ["old"], "newly expired recipe should remain recoverable")
    let rootMode = try! FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
      as! NSNumber
    expect(rootMode.intValue == 0o700, "recipe storage should be private")
  }

  private static func preservesUnsafeOrMalformedTaskRecipes() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-recipes-\(UUID().uuidString)")
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-outside-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let active = root.appendingPathComponent("active")
    let malformed = active.appendingPathComponent("malformed")
    try! FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
    try! Data("not json".utf8).write(to: malformed.appendingPathComponent("recipe.json"))
    try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try! FileManager.default.createSymbolicLink(
      at: active.appendingPathComponent("outside-link"),
      withDestinationURL: outside
    )

    let now = ISO8601DateFormatter().date(from: "2026-09-04T12:00:00Z")!
    let report = RecipeMaintenance.maintain(rootURL: root, now: now)

    expect(report.expired == 0 && report.deleted == 0, "unsafe recipes must not be touched")
    expect(FileManager.default.fileExists(atPath: malformed.path), "malformed recipe is preserved")
    expect(FileManager.default.fileExists(atPath: outside.path), "symlink target is preserved")
  }

  private static func runsMemoryMaintenanceFromTheAppBoundary() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-memory-maintenance-\(UUID().uuidString)")
    let databaseDirectory = root.appendingPathComponent("database")
    let database = databaseDirectory.appendingPathComponent("assistant.sqlite3")
    let maintenance = databaseDirectory.appendingPathComponent("maintain.sql")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
    runSQLite(database: database, sql: "CREATE TABLE maintenance_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
    try! Data(
      "INSERT INTO maintenance_state(key,value) VALUES('last_maintenance',datetime('now'));".utf8
    ).write(to: maintenance)

    expect(
      MemoryMaintenance.maintain(workspaceURL: root, maintenanceURL: maintenance),
      "app maintenance should run bundled SQL"
    )
    let value = querySQLite(database: database, sql: "SELECT value FROM maintenance_state;")
    expect(!value.isEmpty, "memory maintenance should update persistent state")
  }

  private static func writeRecipeMetadata(at directory: URL, expiresAt: String) {
    let metadata = """
      {"name":"\(directory.lastPathComponent)","expires_at":"\(expiresAt)"}
      """
    try! Data(metadata.utf8).write(to: directory.appendingPathComponent("recipe.json"))
  }

  private static func discoversAndSelectsModelsSemantically() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-router-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      if [ "$1" = "login" ] && [ "$2" = "status" ]; then
        printf '%s\n' 'Logged in using ChatGPT'
        exit 0
      fi
      if [ "$1" = "features" ] && [ "$2" = "list" ]; then
        printf '%s\n' 'plugins stable false'
        printf '%s\n' 'remote_plugin stable false'
        printf '%s\n' 'workspace_dependencies stable false'
        printf '%s\n' 'apps stable false'
        printf '%s\n' 'browser_use stable false'
        printf '%s\n' 'in_app_browser stable false'
        printf '%s\n' 'computer_use stable false'
        printf '%s\n' 'image_generation stable false'
        printf '%s\n' 'multi_agent stable false'
        printf '%s\n' 'hooks stable false'
        exit 0
      fi
      if [ "$1" = "app-server" ]; then
        printf '%s\n' "$*" > "$0.appserver.args"
        printenv VOICE_ASSISTANT_CONTROL_TOKEN > "$0.appserver.control-token" 2>/dev/null || :
        initialized=false
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*)
              printf '%s\n' '{"id":1,"result":{}}'
              ;;
            *'"method":"initialized"'*) initialized=true ;;
            *'"id":2'*)
              if [ "$initialized" != true ]; then exit 22; fi
              printf '%s\n' '{"id":2,"result":{"data":[{"id":"model-default","model":"model-default","displayName":"Default","description":"General model","hidden":false,"inputModalities":["text","image"],"supportedReasoningEfforts":[{"reasoningEffort":"brief","description":"quick"},{"reasoningEffort":"careful","description":"careful"}],"defaultReasoningEffort":"brief","isDefault":true,"multiAgentVersion":null},{"id":"model-router","model":"model-router","displayName":"Router","description":"Text routing model","hidden":false,"inputModalities":["text"],"supportedReasoningEfforts":[{"reasoningEffort":"brief","description":"quick"}],"defaultReasoningEffort":"brief","isDefault":false,"multiAgentVersion":null},{"id":"model-capable","model":"model-capable","displayName":"Capable","description":"Difficult work","hidden":false,"inputModalities":["text","image"],"supportedReasoningEfforts":[{"reasoningEffort":"normal","description":"normal"},{"reasoningEffort":"ultra","description":"hardest"}],"defaultReasoningEffort":"normal","isDefault":false,"multiAgentVersion":"v2"}]}}'
              ;;
          esac
        done
        exit 9
      fi
      /bin/cat > "$0.input"
      printf '%s\n' "$*" > "$0.args"
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ROUTE\\tmodel-capable\\tultra\\tnew:aven"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let router = ModelRouter(
      executableURL: executable,
      environment: [
        "HOME": root.path,
        "VOICE_ASSISTANT_CONTROL_TOKEN": "must-not-reach-routing",
      ]
    )

    let route = router.route(prompt: "Mach das", threadID: "existing-context")
    expect(route?.model == "model-capable", "the semantic planner should choose a discovered model")
    expect(route?.reasoningEffort == "ultra", "the planner should choose a discovered effort")
    expect(route?.contextKey == "new:aven", "the planner should select a project context semantically")
    let arguments = try! String(contentsOf: executable.appendingPathExtension("args"), encoding: .utf8)
    let appServerArguments = try! String(
      contentsOf: executable.appendingPathExtension("appserver.args"), encoding: .utf8
    )
    let appServerToken = try! String(
      contentsOf: executable.appendingPathExtension("appserver.control-token"), encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let input = try! String(contentsOf: executable.appendingPathExtension("input"), encoding: .utf8)
    expect(arguments.contains("exec fork"), "ambiguous follow-ups should use conversation context")
    expect(arguments.contains("--model model-router"), "routing should use a live text-only model when available")
    expect(arguments.contains("existing-context"), "the context task should be forked for routing")
    expect(input.contains("Mach das"), "the actual request should reach semantic routing")
    for feature in [
      "plugins", "remote_plugin", "workspace_dependencies", "apps", "browser_use",
      "in_app_browser", "computer_use", "image_generation", "multi_agent", "hooks",
    ] {
      expect(
        appServerArguments.contains("--disable \(feature)"),
        "model discovery must disable \(feature)"
      )
    }
    for setting in [
      "notify=[]", "model_provider=\"openai\"",
      "openai_base_url=\"https://chatgpt.com/backend-api/codex\"",
      "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"", "otel.exporter=\"none\"",
      "otel.trace_exporter=\"none\"", "otel.metrics_exporter=\"none\"",
      "otel.log_user_prompt=false", "analytics.enabled=false",
    ] {
      expect(
        appServerArguments.contains("--config \(setting)"),
        "model discovery must isolate \(setting)"
      )
    }
    expect(appServerToken.isEmpty, "model discovery must not inherit the app-control token")
  }

  private static func selectsTrustedEndpointsFromTheLoginMode() {
    let chatGPT = CodexAppServerIsolation.configuration(loginStatus: "Logged in using ChatGPT")
    expect(
      chatGPT?.contains("openai_base_url=\"https://chatgpt.com/backend-api/codex\"") == true,
      "ChatGPT authentication must keep Codex on the ChatGPT Codex backend"
    )
    let apiKey = CodexAppServerIsolation.configuration(loginStatus: "Logged in using an API key")
    expect(
      apiKey?.contains("openai_base_url=\"https://api.openai.com/v1\"") == true,
      "API-key authentication must use the OpenAI API backend"
    )
    expect(
      CodexAppServerIsolation.configuration(loginStatus: "Logged in somehow else") == nil,
      "unknown authentication modes must fail closed"
    )
  }

  private static func fallsBackToTheLiveCodexDefaultWhenPlanningFails() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-router-fallback-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      if [ "$1" = "login" ] && [ "$2" = "status" ]; then
        printf '%s\n' 'Logged in using ChatGPT'
        exit 0
      fi
      if [ "$1" = "app-server" ]; then
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'"id":2'*) printf '%s\n' '{"id":2,"result":{"data":[{"id":"stale-default","model":"stale-default","displayName":"Default","description":"General","hidden":false,"inputModalities":["text"],"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"quick"}],"defaultReasoningEffort":"low","isDefault":true,"multiAgentVersion":null}]}}' ;;
          esac
        done
        exit 0
      fi
      cat >/dev/null
      exit 9
      """
    try! Data(script.utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let router = ModelRouter(executableURL: executable, environment: ["HOME": root.path])

    let route = router.route(prompt: "Mach das", threadID: nil)

    expect(route == nil, "failed planning must omit model arguments and use the live Codex default")
    expect(router.lastRoute == nil, "a failed planner must not expose a stale selected route")
  }

  private static func returnsQuicklyWhenTheModelServerExits() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-router-exit-\(UUID().uuidString)")
    let executable = root.appendingPathComponent("fake-codex")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let router = ModelRouter(executableURL: executable, environment: [:])

    let started = Date()
    let route = router.route(prompt: "Hello", threadID: nil)

    expect(route == nil, "an exited model server should leave routing to Codex")
    expect(
      Date().timeIntervalSince(started) < 1,
      "an exited model server should not consume the full response timeout"
    )
  }

  private static func animatesOnlyActiveStates() {
    expect(StatusAnimation.motion(for: .idle) == .none, "idle icon should remain still")
    expect(StatusAnimation.motion(for: .listening) == .breathe, "listening should breathe")
    expect(StatusAnimation.motion(for: .transcribing) == .speak, "transcription should move")
    expect(StatusAnimation.motion(for: .routing) == .consider, "routing should move gently")
    expect(StatusAnimation.motion(for: .thinking) == .consider, "thinking should move gently")
    expect(
      StatusAnimation.motion(for: .working("Searching…")) == .consider,
      "work should continue the thinking motion"
    )
    expect(StatusAnimation.motion(for: .speaking) == .speak, "speaking should move gently")
    let active: [AssistantState] = [
      .listening, .transcribing, .routing, .thinking, .working("Working…"), .compacting,
      .speaking,
    ]
    expect(
      active.allSatisfy { StatusAnimation.motion(for: $0).keyPath?.contains("opacity") == false },
      "active animation must not blink"
    )
    expect(
      StatusAnimation.symbol(for: .listening) != StatusAnimation.symbol(for: .speaking),
      "listening and speech output should have distinct symbols"
    )
    expect(
      !StatusAnimation.shouldAnimate(.breathe, reducedMotion: true),
      "Reduced Motion should disable status movement"
    )
    expect(
      StatusAnimation.shouldAnimate(.breathe, reducedMotion: false),
      "status movement should remain available otherwise"
    )
  }

  private static func composesNativeStatusVisuals() {
    let visual = StatusAnimation.visual(
      for: .idle,
      hasWarning: true,
      isMeetingRecording: true
    )
    expect(visual.symbol == "face.smiling", "idle should retain Aven's native base symbol")
    expect(visual.hasWarning, "warnings should be represented as a simultaneous badge")
    expect(visual.isMeetingRecording, "active meeting recording must remain visible beside warnings")
    expect(
      !visual.symbol.unicodeScalars.contains(where: { $0.properties.isEmoji }),
      "status visuals must use SF Symbol names rather than Unicode glyphs"
    )
  }

  private static func runSQLite(database: URL, sql: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    expect(process.terminationStatus == 0, "sqlite setup should succeed")
  }

  private static func querySQLite(database: URL, sql: String) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    expect(process.terminationStatus == 0, "sqlite query should succeed")
    return String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func expectDiagramError(_ expected: DiagramEditorError, path: String) {
    do {
      _ = try DiagramEditor.request(path: path)
      expect(false, "diagram validation should have failed with \(expected)")
    } catch let error as DiagramEditorError {
      expect(error == expected, "diagram validation returned \(error), expected \(expected)")
    } catch {
      expect(false, "diagram validation returned an unexpected error")
    }
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
      exit(1)
    }
  }
}

@MainActor
private final class TestSpeechEngine: SpeechEngine {
  var isPaused = false
  var onFinish: (() -> Void)?
  private(set) var spoken: [String] = []
  private(set) var stopped = false

  func speak(_ text: String) -> Bool {
    spoken.append(text)
    return true
  }

  func stop() { stopped = true }
  func pause() { isPaused = true }
  func resume() { isPaused = false }
  func finish() { onFinish?() }
}

@MainActor
private final class TestSpeechOutputRouteObserver: SpeechOutputRouteObserving {
  private var onRouteChange: (() -> Void)?

  func observe(_ onRouteChange: @escaping () -> Void) { self.onRouteChange = onRouteChange }
  func change() { onRouteChange?() }
}
