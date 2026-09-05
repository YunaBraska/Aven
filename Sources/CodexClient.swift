import Darwin
import Foundation

private final class ConsentDefaults: @unchecked Sendable {
  let value: UserDefaults

  init(_ value: UserDefaults) {
    self.value = value
  }
}

private final class ProcessTermination: @unchecked Sendable {
  weak var process: Process?
  let identifier: pid_t

  init(_ process: Process) {
    self.process = process
    self.identifier = process.processIdentifier
  }
}

private final class ProcessPipeDrains: @unchecked Sendable {
  let group = DispatchGroup()
  private let lock = NSLock()
  private var values: [Data]

  init(count: Int) {
    values = Array(repeating: Data(), count: count)
  }

  func store(_ data: Data, at index: Int) {
    lock.withLock { values[index] = data }
  }

  func data(at index: Int) -> Data {
    lock.withLock { values[index] }
  }
}

struct ExpiringWarnings {
  private var expirationByMessage: [String: Date] = [:]

  mutating func remember(_ message: String, until expiration: Date) {
    expirationByMessage[message] = expiration
  }

  mutating func active(at date: Date = Date()) -> [String] {
    expirationByMessage = expirationByMessage.filter { $0.value > date }
    return expirationByMessage.keys.sorted()
  }

  mutating func nextExpiration(at date: Date = Date()) -> Date? {
    _ = active(at: date)
    return expirationByMessage.values.min()
  }
}

enum CodexClientError: LocalizedError, Equatable {
  case alreadyRunning
  case emptyPrompt
  case forwardingDisabled
  case executableMissing
  case loginRequired
  case sessionExpired
  case networkUnavailable
  case rateLimited
  case modelUnavailable
  case featureUnavailable(String)
  case accessDenied
  case cancelled
  case launchFailed(String)
  case requestFailed(String)
  case outputLimitExceeded
  case responseMissing
  case steeringUnavailable
  case steeringFailed(String)

  var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      "The previous request is still running."
    case .emptyPrompt:
      "No speech detected."
    case .forwardingDisabled:
      "OpenAI access is off. Enable Send to OpenAI in Permissions."
    case .executableMissing:
      "Codex was not found. Install Codex or set VOICE_ASSISTANT_CODEX_EXECUTABLE."
    case .loginRequired:
      "Codex login is required. Run codex login, then try again."
    case .sessionExpired:
      "The Codex session expired. Clear Context, then try again."
    case .networkUnavailable:
      "Codex cannot reach OpenAI. Check the network connection and try again."
    case .rateLimited:
      "The Codex usage limit was reached. Check Usage and try again later."
    case .modelUnavailable:
      "The selected Codex model became unavailable. The model list will refresh next time."
    case .featureUnavailable(let feature):
      "A required Codex function is unavailable: \(feature)"
    case .accessDenied:
      "Codex does not have access to a required file or service."
    case .cancelled:
      "The request was stopped."
    case .launchFailed(let message):
      "Codex could not start: \(message)"
    case .requestFailed(let message):
      "Codex could not answer: \(message)"
    case .outputLimitExceeded:
      "Codex returned more data than Aven can safely process."
    case .responseMissing:
      "Codex returned no readable answer."
    case .steeringUnavailable:
      "The current Codex task is not ready for steering."
    case .steeringFailed(let message):
      "Codex could not accept the update: \(message)"
    }
  }
}

final class CodexClient: @unchecked Sendable {
  static let maximumOutputBytes = 16 * 1_024 * 1_024
  static let maximumErrorBytes = 512 * 1_024
  private static let threadKey = ProjectContextStore.legacyThreadKey
  private static let priorThreadKeys = [
    "voiceAssistant.codexThreadID",
    "voiceAssistant.codexThreadID.v1",
    "voiceAssistant.codexThreadID.v2",
  ]
  private static let ownedThreadIDsKey = "voiceAssistant.ownedCodexThreadIDs.v1"
  private static func turnContext(languageIdentifier: String, capabilitySummary: String) -> String {
    """
    Current Aven turn context:
    - macOS system speech language: "\(languageIdentifier)"
    - app capability boundary: \(capabilitySummary)
    Follow the workspace assistant instructions. The user's request follows:
    """
  }

  private let executableURL: URL?
  private let executableWarning: String?
  private let workspaceURL: URL
  private let assistantExecutableURL: URL
  private let assistantControlToken: String?
  private let sessionsURL: URL
  private let legacyWorkspaceURL: URL
  private let defaults: UserDefaults
  private let contextStore: ProjectContextStore
  private let recentSources: RecentSourcesStore
  private let forwardingAllowed: @Sendable () -> Bool
  private let automaticRouting: Bool
  private let accessArguments: [String]
  private let isolatesExtensions: Bool
  private let taskCapabilityProvider: @Sendable (Set<TaskCapabilityBroker.Capability>) -> String?
  private let taskCapabilityRevoker: @Sendable (String) -> Void
  private let beforeThreadPersistence: @Sendable () -> Void
  private lazy var modelRouter: ModelRouter? = executableURL.map {
    ModelRouter(
      executableURL: $0,
      environment: environment(),
      workspaceURL: workspaceURL,
      forwardingAllowed: forwardingAllowed,
      contextHint: { [contextStore] in contextStore.hint() }
    )
  }
  private let beforeLaunch: @Sendable () -> Void
  private let queue = DispatchQueue(label: "aven.codex", qos: .userInitiated)
  private let steeringQueue = DispatchQueue(label: "aven.codex-steering", qos: .userInitiated)
  private let lock = NSLock()
  private var process: Process?
  private var steeringProcess: Process?
  private var reserved = false
  private var activeThreadID: String?
  private var discardActiveThread = false
  private var cancellationGeneration = 0
  private var runtimeWarnings = ExpiringWarnings()
  private var latestDiff = CodexDiffSummary.empty

  init(
    executableURL: URL? = CodexExecutableLocator.locate(),
    workspaceURL: URL = AssistantPaths.workspaceURL,
    assistantExecutableURL: URL = Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
    assistantControlToken: String? = nil,
    sessionsURL: URL = AssistantPaths.sessionsURL,
    legacyWorkspaceURL: URL = AssistantPaths.legacyWorkspaceURL,
    defaults: UserDefaults = .standard,
    forwardingAllowed: (@Sendable () -> Bool)? = nil,
    automaticRouting: Bool = false,
    accessArguments: [String] = [
      "--ignore-user-config", "--config", "sandbox_mode=\"danger-full-access\"",
      "--config", "approval_policy=\"never\"",
    ],
    isolatesExtensions: Bool = true,
    taskCapabilityProvider: @escaping @Sendable (Set<TaskCapabilityBroker.Capability>) -> String? = {
      _ in nil
    },
    taskCapabilityRevoker: @escaping @Sendable (String) -> Void = {
      _ = TaskCapabilityBroker.revoke($0)
    },
    beforeThreadPersistence: @escaping @Sendable () -> Void = {},
    beforeLaunch: @escaping @Sendable () -> Void = {}
  ) {
    self.executableURL = executableURL
    self.executableWarning = executableURL.flatMap(CodexExecutableLocator.signatureWarning(for:))
    self.workspaceURL = workspaceURL
    self.assistantExecutableURL = assistantExecutableURL
    self.assistantControlToken = assistantControlToken
    self.sessionsURL = sessionsURL
    self.legacyWorkspaceURL = legacyWorkspaceURL
    self.defaults = defaults
    self.contextStore = ProjectContextStore(defaults: defaults)
    self.recentSources = RecentSourcesStore(workspaceURL: workspaceURL)
    let consentDefaults = ConsentDefaults(defaults)
    self.forwardingAllowed = forwardingAllowed
      ?? { AIForwardingConsent.isEnabled(defaults: consentDefaults.value) }
    self.automaticRouting = automaticRouting
    self.accessArguments = accessArguments
    self.isolatesExtensions = isolatesExtensions
    self.taskCapabilityProvider = taskCapabilityProvider
    self.taskCapabilityRevoker = taskCapabilityRevoker
    self.beforeThreadPersistence = beforeThreadPersistence
    self.beforeLaunch = beforeLaunch
  }

  var isRunning: Bool {
    lock.withLock { reserved }
  }

  var isExecutableAvailable: Bool {
    guard let executableURL else { return false }
    return FileManager.default.isExecutableFile(atPath: executableURL.path)
  }

  var canSteer: Bool {
    lock.withLock { reserved && activeThreadID != nil }
  }

  var warnings: [String] {
    var values: [String] = []
    if let executableWarning { values.append(executableWarning) }
    values.append(contentsOf: lock.withLock { runtimeWarnings.active() })
    return Array(Set(values)).sorted()
  }

  var nextWarningExpiration: Date? {
    lock.withLock { runtimeWarnings.nextExpiration() }
  }

  var threadID: String? {
    contextStore.threadID()
  }

  var projectContextHint: ProjectContextHint { contextStore.hint() }

  func sources(_ kind: RecentSource.Kind) -> [RecentSource] {
    recentSources.sources(for: contextStore.hint().activeKey, kind: kind)
  }

  func sources() -> [RecentSource] {
    recentSources.sources(for: contextStore.hint().activeKey)
  }

  var lastRoute: ModelRoute? {
    modelRouter?.lastRoute
  }

  var lastDiff: CodexDiffSummary { lock.withLock { latestDiff } }

  func prewarmRouting() {
    modelRouter?.prewarmCatalog()
  }

  func ask(
    _ prompt: String,
    imageURL: URL? = nil,
    route: ModelRoute? = nil,
    capabilitySummary: String = "No optional app capabilities are available.",
    taskCapabilities: Set<TaskCapabilityBroker.Capability> = [.vault],
    searchEnabled: Bool = false,
    progress: @escaping (CodexProgress) -> Void = { _ in },
    completion: @escaping (Result<String, CodexClientError>) -> Void
  ) {
    let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      completion(.failure(.emptyPrompt))
      return
    }
    guard let executableURL,
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      completion(.failure(.executableMissing))
      return
    }
    guard forwardingAllowed() else {
      completion(.failure(.forwardingDisabled))
      return
    }
    guard let requestGeneration = lock.withLock({ () -> Int? in
        guard !reserved else { return nil }
        reserved = true
        discardActiveThread = false
        return cancellationGeneration
      })
    else {
      completion(.failure(.alreadyRunning))
      return
    }

    queue.async { [weak self] in
      guard let self else { return }
      self.modelRouter?.prepareForRequest()
      let mayRoute = self.lock.withLock { () -> Bool in
        guard requestGeneration == self.cancellationGeneration, self.reserved else {
          self.reserved = false
          return false
        }
        return true
      }
      guard mayRoute else {
        DispatchQueue.main.async { completion(.failure(.cancelled)) }
        return
      }
      if self.automaticRouting, route == nil {
        DispatchQueue.main.async { progress(.routing) }
      }
      let selectedRoute = route ?? (self.automaticRouting
        ? self.modelRouter?.route(prompt: normalized, threadID: self.threadID) : nil)
      let result = self.run(
        prompt: normalized,
        imageURL: imageURL,
        route: selectedRoute,
        capabilitySummary: capabilitySummary,
        taskCapabilities: taskCapabilities,
        searchEnabled: searchEnabled,
        requestGeneration: requestGeneration,
        progress: progress
      )
      DispatchQueue.main.async { completion(result) }
    }
  }

  func cancel() {
    lock.withLock {
      cancellationGeneration += 1
      terminateGracefully(process)
      terminateGracefully(steeringProcess)
    }
    modelRouter?.cancel()
  }

  func cancelAndWait(timeout: TimeInterval = 5) -> Bool {
    cancel()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let snapshot = lock.withLock { (reserved, process, steeringProcess) }
      guard !snapshot.0 && snapshot.2 == nil else {
        if let current = snapshot.1, current.isRunning { current.terminate() }
        if let steering = snapshot.2, steering.isRunning { steering.terminate() }
        Thread.sleep(forTimeInterval: 0.05)
        continue
      }
      return true
    }
    lock.withLock {
      forceTerminate(process)
      forceTerminate(steeringProcess)
    }
    return lock.withLock { !reserved && steeringProcess == nil }
  }

  func steer(
    _ message: String,
    completion: @escaping (Result<Void, CodexClientError>) -> Void
  ) {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      completion(.failure(.emptyPrompt))
      return
    }
    guard forwardingAllowed() else {
      completion(.failure(.forwardingDisabled))
      return
    }
    guard let executableURL,
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      completion(.failure(.executableMissing))
      return
    }
    guard let threadID = lock.withLock({ reserved ? activeThreadID : nil }) else {
      completion(.failure(.steeringUnavailable))
      return
    }
    let steeringGeneration = lock.withLock { cancellationGeneration }
    steeringQueue.async { [weak self] in
      guard let self else { return }
      let process = Process()
      let output = Pipe()
      let errors = Pipe()
      process.executableURL = executableURL
      let arguments = ["queue", "--thread", threadID, "--message", normalized]
      guard self.forwardingAllowed() else {
        DispatchQueue.main.async { completion(.failure(.forwardingDisabled)) }
        return
      }
      process.arguments = arguments
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = errors
      process.environment = self.environment()
      self.lock.lock()
      guard steeringGeneration == self.cancellationGeneration, self.forwardingAllowed() else {
        self.lock.unlock()
        DispatchQueue.main.async { completion(.failure(.cancelled)) }
        return
      }
      self.steeringProcess = process
      do {
        try process.run()
        _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
      } catch {
        self.steeringProcess = nil
        self.lock.unlock()
        DispatchQueue.main.async { completion(.failure(.steeringFailed(error.localizedDescription))) }
        return
      }
      self.lock.unlock()
      let drains = self.drainPipes(
        [output.fileHandleForReading, errors.fileHandleForReading],
        process: process
      )
      process.waitUntilExit()
      drains.group.wait()
      self.lock.withLock {
        if self.steeringProcess === process { self.steeringProcess = nil }
      }
      guard steeringGeneration == self.lock.withLock({ self.cancellationGeneration }) else {
        DispatchQueue.main.async { completion(.failure(.cancelled)) }
        return
      }
      let result: Result<Void, CodexClientError>
      if process.terminationStatus == 0 {
        result = .success(())
      } else {
        let data = drains.data(at: 1)
        let error = self.classifiedError(data, steering: true)
        if error == .modelUnavailable { self.modelRouter?.invalidateCatalog() }
        self.rememberWarning(error)
        result = .failure(error)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func clearContext() {
    lock.withLock {
      discardActiveThread = true
      cancellationGeneration += 1
      terminateGracefully(process)
      terminateGracefully(steeringProcess)
    }
    modelRouter?.cancel()
    contextStore.clearActive()
  }

  func deleteStoredThreads() -> Bool {
    lock.withLock {
      discardActiveThread = true
      cancellationGeneration += 1
      terminateGracefully(process)
      terminateGracefully(steeringProcess)
    }
    modelRouter?.cancel()
    guard cancelAndWait(), let executableURL else { return false }
    let keys = Self.priorThreadKeys + [Self.threadKey]
    let stored = keys.compactMap { defaults.string(forKey: $0) }
      + contextStore.allThreadIDs()
      + (defaults.stringArray(forKey: Self.ownedThreadIDsKey) ?? [])
    let identifiers = Set(stored.filter { UUID(uuidString: $0) != nil })
      .union(discoverOwnedWorkspaceThreads())
    for identifier in identifiers {
      let deletion = Process()
      let errors = Pipe()
      deletion.executableURL = executableURL
      deletion.arguments = ["delete", "--force", identifier]
      deletion.standardInput = FileHandle.nullDevice
      deletion.standardOutput = FileHandle.nullDevice
      deletion.standardError = errors
      deletion.environment = environment()
      do {
        try deletion.run()
        let drains = drainPipes([errors.fileHandleForReading], process: deletion)
        deletion.waitUntilExit()
        drains.group.wait()
        if deletion.terminationStatus != 0 {
          let message = String(
            decoding: drains.data(at: 0),
            as: UTF8.self
          ).lowercased()
          guard message.contains("not found") || message.contains("no session") else {
            return false
          }
        }
      } catch {
        return false
      }
    }
    keys.forEach(defaults.removeObject(forKey:))
    defaults.removeObject(forKey: ProjectContextStore.defaultsKey)
    defaults.removeObject(forKey: Self.ownedThreadIDsKey)
    return true
  }

  private func run(
    prompt: String,
    imageURL: URL?,
    route: ModelRoute?,
    capabilitySummary: String,
    taskCapabilities: Set<TaskCapabilityBroker.Capability>,
    searchEnabled: Bool,
    requestGeneration: Int,
    progress: @escaping (CodexProgress) -> Void
  ) -> Result<String, CodexClientError> {
    guard forwardingAllowed() else { return .failure(.forwardingDisabled) }
    guard let executableURL else { return .failure(.executableMissing) }
    beforeLaunch()
    lock.lock()
    guard requestGeneration == cancellationGeneration, reserved else {
      reserved = false
      lock.unlock()
      return .failure(.cancelled)
    }
    let contextSelection = contextStore.preview(route?.contextKey)
    let contextKey = contextSelection.key
    let currentThreadID = contextSelection.threadID
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let taskCapabilityToken = taskCapabilityProvider(taskCapabilities)
    defer {
      if let taskCapabilityToken { taskCapabilityRevoker(taskCapabilityToken) }
    }
    process.executableURL = executableURL
    process.arguments = arguments(
      threadID: currentThreadID,
      imageURL: imageURL,
      route: route,
      searchEnabled: searchEnabled
    )
    process.currentDirectoryURL = workspaceURL
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    process.environment = environment(taskCapabilityToken: taskCapabilityToken)
    self.process = process
    self.activeThreadID = currentThreadID
    do {
      try process.run()
      _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
    } catch {
      self.process = nil
      self.activeThreadID = nil
      self.reserved = false
      lock.unlock()
      return .failure(.launchFailed(error.localizedDescription))
    }
    if currentThreadID != nil { contextStore.activateExisting(contextKey) }
    lock.unlock()
    defer {
      lock.withLock {
        self.process = nil
        self.activeThreadID = nil
        self.reserved = false
      }
    }
    if let currentThreadID { rememberOwnedThread(currentThreadID) }

    let request = Self.turnContext(
      languageIdentifier: SystemSpeechLanguage.currentIdentifier,
      capabilitySummary: capabilitySummary
    )
      + "\n" + prompt
    do {
      try input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
      try input.fileHandleForWriting.close()
    } catch {
      process.terminate()
      return .failure(.requestFailed("The request could not be sent."))
    }

    let collected = collect(
      output: output,
      errors: errors,
      process: process,
      contextKey: contextKey,
      progress: progress
    )
    guard !collected.exceededLimit else {
      return .failure(.outputLimitExceeded)
    }
    recentSources.record(events: collected.output, projectKey: contextKey)
    guard lock.withLock({ requestGeneration == cancellationGeneration }) else {
      return .failure(.cancelled)
    }
    let summary = CodexEventParser.parse(collected.output)
    lock.withLock { latestDiff = summary.diff }
    guard process.terminationStatus == 0, summary.completed else {
      let error = classifiedError(collected.errors, steering: false)
      if error == .modelUnavailable { modelRouter?.invalidateCatalog() }
      rememberWarning(error)
      return .failure(error)
    }
    if let threadID = summary.threadID, !threadID.isEmpty {
      persistObservedThread(threadID, contextKey: contextKey, markActive: false)
    }
    guard let response = summary.messages.last else {
      return .failure(.responseMissing)
    }
    return .success(response)
  }

  private func arguments(
    threadID: String?,
    imageURL: URL?,
    route: ModelRoute?,
    searchEnabled: Bool
  ) -> [String] {
    if let threadID, !threadID.isEmpty {
      var values = searchEnabled ? ["--search", "exec", "resume"] : ["exec", "resume"]
      values.append(contentsOf: extensionIsolationArguments())
      values.append(contentsOf: accessArguments)
      values.append(contentsOf: [
        "--json", "--skip-git-repo-check",
        "--config", "model_reasoning_summary=\"concise\"",
      ])
      appendRoute(route, to: &values)
      if let imageURL { values.append(contentsOf: ["--image", imageURL.path]) }
      values.append(contentsOf: [threadID, "-"])
      return values
    }
    var values = searchEnabled ? ["--search", "exec"] : ["exec"]
    values.append(contentsOf: extensionIsolationArguments())
    values.append(contentsOf: accessArguments)
    values.append(contentsOf: [
      "--json", "--config", "model_reasoning_summary=\"concise\"",
    ])
    appendRoute(route, to: &values)
    values.append(contentsOf: ["--cd", workspaceURL.path, "--skip-git-repo-check", "-"])
    if let imageURL {
      values.insert(contentsOf: ["--image", imageURL.path], at: values.count - 1)
    }
    return values
  }

  private func appendRoute(_ route: ModelRoute?, to values: inout [String]) {
    guard let route else { return }
    values.append(contentsOf: [
      "--model", route.model,
      "--config", "model_reasoning_effort=\"\(route.reasoningEffort)\"",
    ])
  }

  private func extensionIsolationArguments() -> [String] {
    guard isolatesExtensions else { return [] }
    return CodexFeatureIsolation.disableArguments(
      executableURL: executableURL ?? assistantExecutableURL,
      environment: environment(),
      workspaceURL: workspaceURL
    )
  }

  private func environment(taskCapabilityToken: String? = nil) -> [String: String] {
    var value = AssistantPaths.normalizingCodexHome(in: ProcessInfo.processInfo.environment)
    if let executableURL {
      let directory = executableURL.deletingLastPathComponent().path
      let inherited = value["PATH"] ?? ""
      value["PATH"] = inherited.isEmpty ? directory : "\(directory):\(inherited)"
    }
    value["VOICE_ASSISTANT_HOME"] = workspaceURL.path
    value["VOICE_ASSISTANT_EXECUTABLE"] = assistantExecutableURL.path
    if let assistantControlToken { value["VOICE_ASSISTANT_CONTROL_TOKEN"] = assistantControlToken }
    if let taskCapabilityToken {
      value["VOICE_ASSISTANT_TASK_CAPABILITY"] = taskCapabilityToken
    } else {
      value.removeValue(forKey: "VOICE_ASSISTANT_TASK_CAPABILITY")
    }
    return value
  }

  private func collect(
    output: Pipe,
    errors: Pipe,
    process: Process,
    contextKey: String,
    progress: @escaping (CodexProgress) -> Void
  ) -> (output: Data, errors: Data, exceededLimit: Bool) {
    let group = DispatchGroup()
    let dataLock = NSLock()
    var outputData = Data()
    var errorData = Data()
    var exceededLimit = false

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      var pending = Data()
      var progressStream = CodexProgressStream()
      while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        let shouldStop = dataLock.withLock { () -> Bool in
          guard outputData.count < Self.maximumOutputBytes else {
            exceededLimit = true
            return true
          }
          let remaining = Self.maximumOutputBytes - outputData.count
          outputData.append(chunk.prefix(remaining))
          if chunk.count > remaining { exceededLimit = true }
          return exceededLimit
        }
        if shouldStop {
          self.terminateGracefully(process)
          break
        }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
          let line = pending.subdata(in: pending.startIndex..<newline)
          pending.removeSubrange(pending.startIndex...newline)
          if let threadID = CodexEventParser.parse(line).threadID {
            self.persistObservedThread(threadID, contextKey: contextKey, markActive: true)
          }
          for update in progressStream.consume(line) {
            DispatchQueue.main.async { progress(update) }
          }
        }
      }
      if !pending.isEmpty {
        for update in progressStream.consume(pending) {
          DispatchQueue.main.async { progress(update) }
        }
      }
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      let data = Self.readBounded(
        errors.fileHandleForReading,
        maximumBytes: Self.maximumErrorBytes,
        onExceeded: { self.terminateGracefully(process) }
      )
      dataLock.withLock {
        errorData = data.data
        exceededLimit = exceededLimit || data.exceededLimit
      }
      if data.exceededLimit { self.terminateGracefully(process) }
      group.leave()
    }

    process.waitUntilExit()
    group.wait()
    return dataLock.withLock { (outputData, errorData, exceededLimit) }
  }

  private func persistObservedThread(
    _ threadID: String,
    contextKey: String,
    markActive: Bool
  ) {
    rememberOwnedThread(threadID)
    beforeThreadPersistence()
    lock.withLock {
      if markActive { activeThreadID = threadID }
      guard !discardActiveThread else { return }
      contextStore.remember(threadID: threadID, for: contextKey)
      contextStore.activateExisting(contextKey)
    }
  }

  private func drainPipes(_ handles: [FileHandle], process: Process) -> ProcessPipeDrains {
    let drains = ProcessPipeDrains(count: handles.count)
    for (index, handle) in handles.enumerated() {
      drains.group.enter()
      DispatchQueue.global(qos: .utility).async {
        let result = Self.readBounded(
          handle,
          maximumBytes: Self.maximumErrorBytes,
          onExceeded: { self.terminateGracefully(process) }
        )
        drains.store(result.data, at: index)
        drains.group.leave()
      }
    }
    return drains
  }

  private static func readBounded(
    _ handle: FileHandle,
    maximumBytes: Int,
    onExceeded: () -> Void = {}
  ) -> (data: Data, exceededLimit: Bool) {
    var retained = Data()
    var exceededLimit = false
    while true {
      let chunk = handle.readData(ofLength: 8_192)
      guard !chunk.isEmpty else { break }
      if retained.count < maximumBytes {
        retained.append(chunk.prefix(maximumBytes - retained.count))
      }
      if retained.count >= maximumBytes, !exceededLimit {
        exceededLimit = true
        onExceeded()
      }
    }
    return (retained, exceededLimit)
  }

  private func rememberOwnedThread(_ identifier: String) {
    guard UUID(uuidString: identifier) != nil else { return }
    var identifiers = Set(defaults.stringArray(forKey: Self.ownedThreadIDsKey) ?? [])
    guard identifiers.insert(identifier).inserted else { return }
    defaults.set(identifiers.sorted(), forKey: Self.ownedThreadIDsKey)
  }

  private func discoverOwnedWorkspaceThreads() -> Set<String> {
    var ownedPaths = Set([workspaceURL.standardizedFileURL.path])
    if AssistantPaths.isVerifiedLegacyWorkspace(legacyWorkspaceURL) {
      ownedPaths.insert(legacyWorkspaceURL.standardizedFileURL.path)
      if legacyWorkspaceURL.standardizedFileURL == AssistantPaths.legacyWorkspaceURL.standardizedFileURL {
        ownedPaths.insert(AssistantPaths.historicalLegacyWorkspaceURL.standardizedFileURL.path)
      }
    }
    guard let enumerator = FileManager.default.enumerator(
      at: sessionsURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    var identifiers = Set<String>()
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
      let data = (try? handle.read(upToCount: 65_536)) ?? Data()
      try? handle.close()
      let firstLine = data.prefix { $0 != 0x0A }
      guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
        object["type"] as? String == "session_meta",
        let payload = object["payload"] as? [String: Any],
        let identifier = (payload["id"] as? String) ?? (payload["session_id"] as? String),
        UUID(uuidString: identifier) != nil,
        let cwd = payload["cwd"] as? String,
        ownedPaths.contains(URL(fileURLWithPath: cwd).standardizedFileURL.path)
      else { continue }
      identifiers.insert(identifier)
    }
    return identifiers
  }

  private func sanitizedError(_ data: Data) -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      return "Unknown error."
    }
    let lines =
      text
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.contains("WARN codex_skills::interface") }
    let value = lines.suffix(2).joined(separator: " ")
    return value.isEmpty ? "Unknown error." : String(value.prefix(280))
  }

  private func classifiedError(_ data: Data, steering: Bool) -> CodexClientError {
    let detail = sanitizedError(data)
    let value = detail.lowercased()
    if value.contains("not logged in") || value.contains("login required")
      || value.contains("unauthorized") || value.contains("authentication") || value.contains("401")
    {
      return .loginRequired
    }
    if value.contains("session")
      && (value.contains("expired") || value.contains("not found") || value.contains("failed to resume"))
    {
      return .sessionExpired
    }
    if value.contains("rate limit") || value.contains("usage limit") || value.contains("429") {
      return .rateLimited
    }
    if value.contains("model") && (value.contains("not found") || value.contains("unavailable")) {
      return .modelUnavailable
    }
    if value.contains("upgrade") && (value.contains("required") || value.contains("unsupported")) {
      return .featureUnavailable(detail)
    }
    if value.contains("unrecognized subcommand") || value.contains("unknown command")
      || value.contains("unexpected argument") || value.contains("unknown option")
    {
      return .featureUnavailable(detail)
    }
    if value.contains("permission denied") || value.contains("operation not permitted") {
      return .accessDenied
    }
    if value.contains("network") || value.contains("connection") || value.contains("dns")
      || value.contains("offline") || value.contains("timed out")
    {
      return .networkUnavailable
    }
    return steering ? .steeringFailed(detail) : .requestFailed(detail)
  }

  private func rememberWarning(_ error: CodexClientError) {
    guard case .featureUnavailable(let detail) = error else { return }
    lock.withLock {
      runtimeWarnings.remember(
        "Codex function unavailable: \(detail)",
        until: Date().addingTimeInterval(600)
      )
    }
  }

  private func terminateGracefully(_ process: Process?) {
    guard let process, process.isRunning else { return }
    let termination = ProcessTermination(process)
    process.terminate()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
      guard termination.process?.isRunning == true else { return }
      _ = Darwin.kill(-termination.identifier, SIGKILL)
      _ = Darwin.kill(termination.identifier, SIGKILL)
    }
  }

  private func forceTerminate(_ process: Process?) {
    guard let process, process.isRunning else { return }
    let identifier = process.processIdentifier
    _ = Darwin.kill(-identifier, SIGKILL)
    _ = Darwin.kill(identifier, SIGKILL)
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ operation: () -> T) -> T {
    lock()
    defer { unlock() }
    return operation()
  }
}
