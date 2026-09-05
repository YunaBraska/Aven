import AVFoundation
import AppKit
import ServiceManagement

private enum DictationMode {
  case request
  case steering(previousState: AssistantState)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private static let spokenThinkingKey = "voiceAssistant.spokenThinkingStatus"
  private static let fnPermissionMessage = "Allow Input Monitoring for the assistant shortcut"
  private let assistantControlToken = UUID().uuidString

  private let startupError: String?
  private let startupWarning: String?
  private let speechController = SpeechController()
  private let speechOutput = SpeechOutput()
  private lazy var codexClient = makeCodexClient()
  private lazy var accountMetrics = CodexAccountMetrics(
    executableURL: CodexExecutableLocator.locate(),
    workspaceURL: AssistantPaths.workspaceURL
  )
  private let shortcutStore = AssistantShortcutStore()
  private lazy var hotKey = GlobalHotKey(preset: shortcutStore.selectedPreset)
  private let screenCapture = ScreenCaptureController()
  private let meetingRecorder = MeetingRecorder()
  private let permissionController = PermissionController()
  private let performanceTracker = PipelinePerformanceTracker()
  private var meetingStartGate = MeetingStartGate()
  private let inputJournal: ConversationInputJournal
  private let inputQueue: ConversationInputQueue
  private let maintenanceQueue = DispatchQueue(label: "aven.maintenance", qos: .utility)
  private var statusItem: NSStatusItem!
  private var statusIconAnimator: StatusIconAnimator!
  private var statusMenuItem: NSMenuItem!
  private var backgroundStatusMenuItem: NSMenuItem!
  private var listenMenuItem: NSMenuItem!
  private var repeatMenuItem: NSMenuItem!
  private var pauseMenuItem: NSMenuItem!
  private var stopMenuItem: NSMenuItem!
  private var meetingMenuItem: NSMenuItem!
  private var menuTextInputView: MenuTextInputView!
  private var contextMetricItem: NSMenuItem!
  private var agentsMetricItem: NSMenuItem!
  private var workersMetricItem: NSMenuItem!
  private var diffMetricItem: NSMenuItem!
  private var memoryMetricItem: NSMenuItem!
  private var databaseMetricItem: NSMenuItem!
  private var recipesMetricItem: NSMenuItem!
  private var vaultMetricItem: NSMenuItem!
  private var weeklyUsageItem: NSMenuItem!
  private var resetCreditsItem: NSMenuItem!
  private var codexVersionItem: NSMenuItem!
  private var openChatMenuItem: NSMenuItem!
  private var resultMenuItem: NSMenuItem!
  private var sourcesMenuItem: NSMenuItem!
  private var warningsMenuItem: NSMenuItem!
  private var warningDetailItems: [NSMenuItem] = []
  private var warningExpirationWorkItem: DispatchWorkItem?
  private var statusSeparatorItem: NSMenuItem!
  private var spokenThinkingMenuItem: NSMenuItem!
  private var voiceSettingsMenuItem: NSMenuItem!
  private var timingMenuItems: [PipelineStage: NSMenuItem] = [:]
  private var launchAtLoginMenuItem: NSMenuItem!
  private var deleteDataMenuItem: NSMenuItem!
  private var permissionMenuItems: [AssistantCapability: NSMenuItem] = [:]
  private var permissionSubmenu: NSMenu?
  private var shortcutSubmenu: NSMenu?
  private var shortcutMenuItems: [AssistantShortcutPreset: NSMenuItem] = [:]
  private var accessMenuItems: [AssistantAccessProfile: NSMenuItem] = [:]
  private var accessSubmenu: NSMenu?
  private var accessCapabilities = CodexExecCapabilities(
    helpText: "--config <key=value>\n--ignore-user-config"
  )
  private var fileDropController: StatusFileDropController?
  private var steeringDeferredUntilTurnEnds = false
  private var activeInput: ConversationInput?
  private var inputJournalWarning: String?
  private var meetingWarning: String?
  private var lastAnswer = ""
  private var deferredSpeechAfterDictation: String?
  private var isRecording = false
  private var lastResultURL: URL?
  private var speaksThinkingStatus =
    UserDefaults.standard.object(forKey: AppDelegate.spokenThinkingKey) as? Bool ?? true
  private var requestGeneration = 0
  private var lastProgress: CodexProgress?
  private var pendingListenWorkItem: DispatchWorkItem?
  private var dictationMode = DictationMode.request
  private var stateBeforePause: AssistantState?
  private var metrics = AssistantMetricsSnapshot.empty
  private var accountSnapshot = CodexAccountMetricsSnapshot.empty
  private var metricsGeneration = 0
  private var metricsRefreshInProgress = false
  private var lastMetricsRefreshAt: Date?
  private var recipeMaintenanceTimer: Timer?
  private var codexMaintenanceWarnings: [String] = []
  private var accountWarnings: [String] = []
  private var accessWarning: String?
  private var codexMaintenanceInProgress = false
  private var pendingCodexExecutableURL: URL?
  private var pendingCodexActivationWorkItem: DispatchWorkItem?
  private var contextMaintenanceWarning: String?
  private var contextMaintenanceInProgress = false
  private var contextMaintenance: CodexContextMaintenance?
  private var contextCompactionWorkItem: DispatchWorkItem?
  private var contextIdleGeneration = 0
  private var lastCompactionAttemptedGeneration: Int?
  private var lastConversationFinishedAt: Date?
  private var workerCount = 0
  private var hasVisibleWarnings = false
  private var deleteConfirmationTimer: Timer?
  private var isDeletingData = false
  private var aboutPanelController: AboutPanelController?
  private var chatOpenGate = ChatOpenGate()
  private var state = AssistantState.idle {
    didSet { render() }
  }

  init(startupError: String? = nil, startupWarning: String? = nil) {
    self.startupError = startupError
    self.startupWarning = startupWarning
    let inputJournal = ConversationInputJournal()
    self.inputJournal = inputJournal
    inputQueue = ConversationInputQueue(initialInputs: inputJournal.pendingInputs)
    inputJournalWarning = inputJournal.recoveryWarning
    super.init()
    AvenIntentBridge.control = { [weak self] action in self?.performIntent(action) == true }
    AvenIntentBridge.send = { [weak self] message in self?.submitIntentMessage(message) == true }
  }

  private func performIntent(_ action: AvenIntentAction) -> Bool {
    switch action {
    case .listen:
      startListening()
    case .stop:
      cancelCurrentWork()
    case .pauseOrResume:
      toggleSpeechPause()
    case .repeatAnswer:
      repeatShortcut()
    case .openChat:
      openChat()
    case .clearContext:
      clearContext()
    case .showResult:
      showLastResult()
    case .openUsage:
      openUsage()
    case .progressOn:
      setSpokenProgress(true)
    case .progressOff:
      setSpokenProgress(false)
    case .startMeeting:
      if meetingRecorder.state == .idle, !meetingStartGate.isWaitingForPermission {
        startMeetingRecording()
      }
    case .stopMeeting:
      if meetingStartGate.isWaitingForPermission || meetingRecorder.state != .idle {
        stopMeetingRecording()
      }
    }
    return true
  }

  private func submitIntentMessage(_ message: String) -> Bool {
    guard requestAIForwardingConsentIfNeeded() else { return false }
    beginConversationActivity()
    return enqueueInput(message)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    configureStatusItem()
    configureSpeechOutput()
    configurePermissions()
    configureMeetingRecorder()
    configureHotKey()
    configureAssistantControl()
    configureRecipeMaintenance()
    refreshAccessCapabilities()
    if AIForwardingConsent.isEnabled() { codexClient.prewarmRouting() }
    refreshMetrics()
    if let startupError {
      state = .failed(startupError)
    } else if !codexClient.isExecutableAvailable {
      state = codexMaintenanceInProgress
        ? .working("Installing Codex…")
        : .failed(CodexClientError.executableMissing.localizedDescription)
    }
    render()
    refreshWarnings()
    if inputQueue.hasPendingInput, startupError == nil, codexClient.isExecutableAvailable,
      AIForwardingConsent.isEnabled()
    {
      beginConversationActivity()
      DispatchQueue.main.async { [weak self] in self?.drainConversationInput() }
    }
  }

  private func configureStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.toolTip = "Aven"
    statusIconAnimator = StatusIconAnimator(button: statusItem.button)
    let dropController = StatusFileDropController(button: statusItem.button)
    dropController.onFiles = { [weak self] files in self?.receiveDroppedFiles(files) }
    fileDropController = dropController
    let menu = buildMenu()
    menu.delegate = self
    statusItem.menu = menu
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    statusMenuItem = NSMenuItem(title: state.statusText, action: nil, keyEquivalent: "")
    statusMenuItem.isEnabled = false
    statusMenuItem.isHidden = !state.showsStatusInMenu
    menu.addItem(statusMenuItem)
    backgroundStatusMenuItem = NSMenuItem(title: "Compacting…", action: nil, keyEquivalent: "")
    backgroundStatusMenuItem.isEnabled = false
    backgroundStatusMenuItem.isHidden = true
    backgroundStatusMenuItem.image = NSImage(
      systemSymbolName: "arrow.down.right.and.arrow.up.left.circle",
      accessibilityDescription: "Background work"
    )
    menu.addItem(backgroundStatusMenuItem)
    warningsMenuItem = NSMenuItem(title: "Warnings", action: nil, keyEquivalent: "")
    warningsMenuItem.isEnabled = false
    warningsMenuItem.image = NSImage(
      systemSymbolName: "exclamationmark.triangle",
      accessibilityDescription: "Warnings"
    )
    warningsMenuItem.isHidden = true
    menu.addItem(warningsMenuItem)
    statusSeparatorItem = .separator()
    statusSeparatorItem.isHidden = true
    menu.addItem(statusSeparatorItem)

    listenMenuItem = NSMenuItem(
      title: "Listen (Fn)",
      action: #selector(performPrimaryAction),
      keyEquivalent: ""
    )
    listenMenuItem.target = self
    listenMenuItem.image = menuSymbol("mic", description: "Listen")
    menu.addItem(listenMenuItem)

    repeatMenuItem = NSMenuItem(
      title: "Repeat (Fn+R)",
      action: #selector(repeatLastAnswer),
      keyEquivalent: ""
    )
    repeatMenuItem.target = self
    repeatMenuItem.image = menuSymbol("arrow.counterclockwise", description: "Repeat answer")
    repeatMenuItem.isEnabled = false
    menu.addItem(repeatMenuItem)

    pauseMenuItem = NSMenuItem(
      title: "Pause (Fn+P)",
      action: #selector(toggleSpeechPause),
      keyEquivalent: ""
    )
    pauseMenuItem.target = self
    pauseMenuItem.image = menuSymbol("pause", description: "Pause speech")
    pauseMenuItem.isEnabled = false
    menu.addItem(pauseMenuItem)

    stopMenuItem = NSMenuItem(
      title: "Stop (Fn+Esc)",
      action: #selector(cancelCurrentWork),
      keyEquivalent: ""
    )
    stopMenuItem.target = self
    stopMenuItem.image = menuSymbol("stop.fill", description: "Stop")
    stopMenuItem.isEnabled = false
    menu.addItem(stopMenuItem)

    meetingMenuItem = NSMenuItem(
      title: "Record Meeting…",
      action: #selector(toggleMeetingRecording),
      keyEquivalent: ""
    )
    meetingMenuItem.target = self
    meetingMenuItem.image = menuSymbol("record.circle", description: "Record meeting")
    menu.addItem(meetingMenuItem)

    let textInputItem = NSMenuItem()
    menuTextInputView = MenuTextInputView(frame: .zero)
    menuTextInputView.onSubmit = { [weak self] message in
      self?.submitManualMessage(message) ?? false
    }
    textInputItem.view = menuTextInputView
    menu.addItem(textInputItem)

    menu.addItem(.separator())
    addMetrics(to: menu)

    let options = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
    options.image = menuSymbol("gearshape", description: "Options")
    let optionsMenu = NSMenu()
    voiceSettingsMenuItem = NSMenuItem(
      title: "Voice · \(SystemSpeechLanguage.menuLabel)",
      action: #selector(openSpeechSettings),
      keyEquivalent: ""
    )
    voiceSettingsMenuItem.target = self
    optionsMenu.addItem(voiceSettingsMenuItem)
    optionsMenu.addItem(.separator())
    spokenThinkingMenuItem = NSMenuItem(
      title: "Speak Progress",
      action: #selector(toggleSpokenThinkingStatus),
      keyEquivalent: ""
    )
    spokenThinkingMenuItem.target = self
    spokenThinkingMenuItem.state = speaksThinkingStatus ? .on : .off
    optionsMenu.addItem(spokenThinkingMenuItem)

    launchAtLoginMenuItem = NSMenuItem(
      title: "Launch at Login",
      action: #selector(toggleLaunchAtLogin),
      keyEquivalent: ""
    )
    launchAtLoginMenuItem.target = self
    launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    optionsMenu.addItem(launchAtLoginMenuItem)
    let shortcuts = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
    shortcuts.submenu = shortcutMenu()
    optionsMenu.addItem(shortcuts)
    optionsMenu.addItem(.separator())
    let clearContext = NSMenuItem(
      title: "Clear Context",
      action: #selector(clearContext),
      keyEquivalent: ""
    )
    clearContext.target = self
    optionsMenu.addItem(clearContext)
    optionsMenu.addItem(.separator())
    deleteDataMenuItem = NSMenuItem(
      title: "Delete Assistant Data…",
      action: #selector(deleteAllData),
      keyEquivalent: ""
    )
    deleteDataMenuItem.target = self
    optionsMenu.addItem(deleteDataMenuItem)
    options.submenu = optionsMenu
    menu.addItem(options)

    let access = NSMenuItem(title: "Access", action: nil, keyEquivalent: "")
    access.image = menuSymbol("lock.shield", description: "Access")
    access.submenu = accessMenu()
    menu.addItem(access)
    let permissions = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
    permissions.image = menuSymbol("checkmark.shield", description: "Permissions")
    permissions.submenu = permissionMenu()
    menu.addItem(permissions)
    menu.addItem(.separator())

    let about = NSMenuItem(title: "About Aven", action: #selector(showAbout), keyEquivalent: "")
    about.target = self
    about.image = menuSymbol("info.circle", description: "About Aven")
    menu.addItem(about)

    let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    return menu
  }

  private func addMetrics(to menu: NSMenu) {
    openChatMenuItem = NSMenuItem(
      title: "Open Chat",
      action: #selector(openChat),
      keyEquivalent: ""
    )
    openChatMenuItem.target = self
    openChatMenuItem.image = menuSymbol("bubble.left.and.bubble.right", description: "Open chat")
    openChatMenuItem.isEnabled = codexClient.threadID != nil
    menu.addItem(openChatMenuItem)
    resultMenuItem = NSMenuItem(
      title: "Show Result",
      action: #selector(showLastResult),
      keyEquivalent: ""
    )
    resultMenuItem.target = self
    resultMenuItem.image = menuSymbol("doc", description: "Show result")
    resultMenuItem.isEnabled = false
    menu.addItem(resultMenuItem)
    sourcesMenuItem = NSMenuItem(title: "Sources (0)", action: nil, keyEquivalent: "")
    sourcesMenuItem.image = menuSymbol("link", description: "Recent sources")
    sourcesMenuItem.submenu = NSMenu()
    menu.addItem(sourcesMenuItem)
    menu.addItem(.separator())

    contextMetricItem = metricItem(title: metrics.contextLabel, action: #selector(showContext))
    workersMetricItem = NSMenuItem(title: "Workers 0", action: nil, keyEquivalent: "")
    workersMetricItem.isEnabled = false
    agentsMetricItem = metricItem(title: metrics.agentsLabel, action: #selector(showAgents))
    diffMetricItem = NSMenuItem(title: CodexDiffSummary.empty.menuLabel, action: nil, keyEquivalent: "")
    diffMetricItem.isEnabled = false
    memoryMetricItem = metricItem(title: metrics.memoryLabel, action: #selector(showMemory))
    databaseMetricItem = metricItem(title: metrics.databaseLabel, action: #selector(showDatabase))
    recipesMetricItem = metricItem(title: metrics.recipesLabel, action: #selector(showRecipes))
    vaultMetricItem = metricItem(title: metrics.vaultLabel, action: #selector(showVault))
    [contextMetricItem, workersMetricItem, diffMetricItem]
      .forEach(menu.addItem)
    weeklyUsageItem = NSMenuItem(
      title: metrics.weeklyUsageLabel,
      action: #selector(openUsage),
      keyEquivalent: ""
    )
    weeklyUsageItem.target = self
    menu.addItem(weeklyUsageItem)
    resetCreditsItem = NSMenuItem(title: "Resets —", action: nil, keyEquivalent: "")
    resetCreditsItem.isEnabled = false
    menu.addItem(resetCreditsItem)

    let more = NSMenuItem(title: "More…", action: nil, keyEquivalent: "")
    more.image = menuSymbol("ellipsis.circle", description: "More information")
    let moreMenu = NSMenu()
    let timing = NSMenuItem(title: "Timing · Last", action: nil, keyEquivalent: "")
    timing.isEnabled = false
    moreMenu.addItem(timing)
    for stage in PipelineStage.allCases {
      let item = NSMenuItem(
        title: performanceTracker.snapshot.label(for: stage),
        action: nil,
        keyEquivalent: ""
      )
      item.isEnabled = false
      item.toolTip = stage == .speech
        ? "Duration of the last spoken playback."
        : "Duration of the last completed stage."
      timingMenuItems[stage] = item
      moreMenu.addItem(item)
    }
    moreMenu.addItem(.separator())
    [agentsMetricItem, memoryMetricItem, databaseMetricItem, recipesMetricItem, vaultMetricItem]
      .forEach(moreMenu.addItem)
    moreMenu.addItem(.separator())
    codexVersionItem = NSMenuItem(
      title: CodexMaintenance.displayVersion(),
      action: nil,
      keyEquivalent: ""
    )
    codexVersionItem.isEnabled = false
    moreMenu.addItem(codexVersionItem)
    more.submenu = moreMenu
    menu.addItem(more)
    menu.addItem(.separator())
  }

  private func metricItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func shortcutMenu() -> NSMenu {
    let menu = NSMenu()
    shortcutSubmenu = menu
    rebuildShortcutMenu()
    return menu
  }

  private func rebuildShortcutMenu() {
    guard let menu = shortcutSubmenu else { return }
    menu.removeAllItems()
    shortcutMenuItems.removeAll()
    let current = NSMenuItem(
      title: "Talk Key · \(shortcutStore.selectedPreset.displayName)",
      action: nil,
      keyEquivalent: ""
    )
    current.isEnabled = false
    menu.addItem(current)
    menu.addItem(.separator())
    for preset in AssistantShortcutPreset.suggestedPresets {
      let item = NSMenuItem(
        title: preset.displayName,
        action: #selector(selectShortcut(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = preset.rawValue
      item.state = shortcutStore.selectedPreset == preset ? .on : .off
      shortcutMenuItems[preset] = item
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let record = NSMenuItem(
      title: "Record Talk Key…",
      action: #selector(recordShortcut),
      keyEquivalent: ""
    )
    record.target = self
    menu.addItem(record)
  }

  @objc private func recordShortcut() {
    hotKey.unregister()
    guard let preset = ShortcutRecorder.recordTalkKey() else {
      if permissionController.snapshot(.inputMonitoring).enabled { _ = hotKey.register() }
      return
    }
    applyShortcut(preset)
  }

  private func accessMenu() -> NSMenu {
    let menu = NSMenu()
    accessSubmenu = menu
    rebuildAccessMenu()
    return menu
  }

  private func rebuildAccessMenu() {
    guard let menu = accessSubmenu else { return }
    menu.removeAllItems()
    accessMenuItems.removeAll()
    let selected = AssistantAccessProfile.load()
    for profile in AssistantAccessProfile.allCases {
      guard case .arguments = profile.selection(using: accessCapabilities) else { continue }
      let item = NSMenuItem(
        title: profile.label,
        action: #selector(selectAccessProfile(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = profile.rawValue
      item.state = selected == profile ? .on : .off
      accessMenuItems[profile] = item
      menu.addItem(item)
    }
  }

  @objc private func selectShortcut(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let preset = AssistantShortcutPreset(rawValue: raw)
    else { return }
    applyShortcut(preset)
  }

  private func applyShortcut(_ preset: AssistantShortcutPreset) {
    _ = shortcutStore.select(preset)
    shortcutMenuItems.forEach { $0.value.state = $0.key == preset ? .on : .off }
    updateShortcutLabels()
    DispatchQueue.main.async { [weak self] in self?.rebuildShortcutMenu() }
    guard permissionController.snapshot(.inputMonitoring).enabled else {
      hotKey.configure(preset)
      return
    }
    if !hotKey.use(preset) { state = .failed(Self.fnPermissionMessage) }
  }

  @objc private func selectAccessProfile(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let profile = AssistantAccessProfile(rawValue: raw)
    else { return }
    applyAccessProfile(profile)
  }

  private func applyAccessProfile(_ profile: AssistantAccessProfile) {
    guard case .arguments = profile.selection(using: accessCapabilities) else { return }
    profile.save()
    accessWarning = nil
    refreshWarnings()
    accessMenuItems.forEach { $0.value.state = $0.key == profile ? .on : .off }
    if codexClient.isRunning {
      pendingCodexExecutableURL = CodexExecutableLocator.locate()
      activatePendingCodexClientWhenIdle()
    } else {
      activateCodexClient(executableURL: CodexExecutableLocator.locate())
    }
  }

  private func updateShortcutLabels() {
    let hold = shortcutStore.selectedPreset.displayName
    listenMenuItem?.title = state == .listening ? "Stop (\(hold))" : "Listen (\(hold))"
    repeatMenuItem?.title = "Repeat (\(hold)+R)"
    pauseMenuItem?.title = "Pause (\(hold)+P)"
    stopMenuItem?.title = "Stop (\(hold)+Esc)"
  }

  @objc private func toggleMeetingRecording() {
    if meetingStartGate.isWaitingForPermission {
      stopMeetingRecording()
      return
    }
    switch meetingRecorder.state {
    case .idle:
      startMeetingRecording()
    case .recording:
      stopMeetingRecording()
    case .starting:
      stopMeetingRecording()
    case .stopping:
      return
    }
  }

  private func startMeetingRecording() {
    let alert = NSAlert()
    alert.messageText = "Record this meeting?"
    alert.informativeText = "Aven stores an on-device transcript without raw audio. Start only after informing everyone in the meeting."
    alert.addButton(withTitle: "Start Recording")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let permissionGeneration = meetingStartGate.begin() else { return }
    meetingWarning = nil
    meetingMenuItem.isEnabled = true
    meetingMenuItem.title = "Starting Meeting…"
    meetingMenuItem.image = menuSymbol("xmark.circle", description: "Cancel meeting start")
    permissionController.prepareForMeeting { [weak self] permissionResult in
      guard let self else { return }
      guard self.meetingStartGate.accept(permissionGeneration) else { return }
      switch permissionResult {
      case .failure(let error):
        self.meetingWarning = error.localizedDescription
        self.updateMeetingMenu()
        self.refreshWarnings()
      case .success:
        self.meetingRecorder.start { [weak self] result in
          guard let self else { return }
          switch result {
          case .success(let transcriptURL):
            self.meetingWarning = nil
            self.lastResultURL = transcriptURL
            self.resultMenuItem.isEnabled = true
          case .failure(let error):
            self.meetingWarning = error.localizedDescription
          }
          self.updateMeetingMenu()
          self.refreshWarnings()
          self.render()
        }
      }
    }
  }

  private func stopMeetingRecording() {
    if meetingStartGate.isWaitingForPermission {
      meetingStartGate.cancel()
      updateMeetingMenu()
      render()
      return
    }
    meetingMenuItem.isEnabled = false
    meetingMenuItem.title = "Stopping Meeting…"
    meetingMenuItem.image = menuSymbol("hourglass", description: "Stopping meeting recording")
    meetingRecorder.stop { [weak self] transcriptURL in
      guard let self else { return }
      if let transcriptURL {
        self.lastResultURL = transcriptURL
        self.resultMenuItem.isEnabled = true
      }
      self.updateMeetingMenu()
      self.render()
    }
  }

  private func updateMeetingMenu() {
    if meetingStartGate.isWaitingForPermission {
      meetingMenuItem?.title = "Cancel Meeting Start"
      meetingMenuItem?.image = menuSymbol("xmark.circle", description: "Cancel meeting start")
      meetingMenuItem?.isEnabled = true
      return
    }
    switch meetingRecorder.state {
    case .idle:
      meetingMenuItem?.title = "Record Meeting…"
      meetingMenuItem?.image = menuSymbol("record.circle", description: "Record meeting")
      meetingMenuItem?.isEnabled = true
    case .starting:
      meetingMenuItem?.title = "Cancel Meeting Start"
      meetingMenuItem?.image = menuSymbol("xmark.circle", description: "Cancel meeting start")
      meetingMenuItem?.isEnabled = true
    case .recording:
      meetingMenuItem?.title = "Stop Meeting Recording"
      meetingMenuItem?.image = menuSymbol("stop.circle.fill", description: "Stop meeting recording")
      meetingMenuItem?.isEnabled = true
    case .stopping:
      meetingMenuItem?.title = "Stopping Meeting…"
      meetingMenuItem?.image = menuSymbol("hourglass", description: "Stopping meeting recording")
      meetingMenuItem?.isEnabled = false
    }
  }

  private func menuSymbol(_ name: String, description: String) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
      .withSymbolConfiguration(configuration)
    image?.isTemplate = true
    return image
  }

  @objc private func showAbout() {
    let controller = aboutPanelController ?? AboutPanelController()
    aboutPanelController = controller
    controller.present()
  }

  private func permissionMenu() -> NSMenu {
    let menu = NSMenu()
    permissionSubmenu = menu
    rebuildPermissionMenu()
    return menu
  }

  private func rebuildPermissionMenu() {
    guard let menu = permissionSubmenu else { return }
    menu.removeAllItems()
    permissionMenuItems.removeAll()
    for (groupIndex, group) in AssistantCapabilityGroup.allCases.enumerated() {
      if groupIndex > 0 { menu.addItem(.separator()) }
      for capability in group.capabilities {
        let snapshot = permissionController.snapshot(capability)
        let item = NSMenuItem(
          title: snapshot.menuTitle,
          action: #selector(togglePermission(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = capability.rawValue
        item.state = snapshot.isUsable ? .on : .off
        permissionMenuItems[capability] = item
        menu.addItem(item)
      }
    }
    menu.addItem(.separator())
    let privacy = NSMenuItem(
      title: "Data Privacy…",
      action: #selector(showDataPrivacy),
      keyEquivalent: ""
    )
    privacy.target = self
    menu.addItem(privacy)
  }

  private func configurePermissions() {
    permissionController.onChange = { [weak self] in
      self?.refreshPermissionMenu()
    }
    refreshPermissionMenu()
  }

  private func configureMeetingRecorder() {
    meetingRecorder.onUnexpectedStop = { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.meetingWarning = error.localizedDescription
        self.updateMeetingMenu()
        self.refreshWarnings()
        self.render()
      }
    }
    meetingRecorder.onTranscriptionWarning = { [weak self] error in
      DispatchQueue.main.async {
        self?.meetingWarning = error.localizedDescription
        self?.refreshWarnings()
      }
    }
  }

  private func refreshPermissionMenu() {
    for capability in AssistantCapability.allCases {
      let snapshot = permissionController.snapshot(capability)
      permissionMenuItems[capability]?.title = snapshot.menuTitle
      permissionMenuItems[capability]?.state = snapshot.isUsable ? .on : .off
    }
  }

  @objc private func showDataPrivacy() {
    let alert = NSAlert()
    alert.messageText = "Data sent through Codex"
    alert.informativeText = "Only while Send to OpenAI is on, a request may include its transcript, conversation context, selected capture, relevant files, calendar results, and results returned by credential-backed tools. Turn the permission off to stop active work and prevent further sending. Credentials themselves remain in the app-scoped Keychain and are never placed in prompts."
    alert.runModal()
  }

  @objc private func togglePermission(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let capability = AssistantCapability(rawValue: raw)
    else { return }
    let snapshot = permissionController.snapshot(capability)
    if capability == .aiForwarding, !snapshot.enabled {
      _ = requestAIForwardingConsentIfNeeded()
      return
    }
    if snapshot.enabled && snapshot.authorization != .available {
      permissionController.requestOrOpenSettings(capability)
    } else {
      permissionController.toggle(capability)
    }
    if capability == .inputMonitoring {
      if permissionController.snapshot(.inputMonitoring).enabled {
        _ = hotKey.use(shortcutStore.selectedPreset)
      } else {
        hotKey.unregister()
      }
    }
    if capability == .microphone || capability == .speechRecognition,
      !permissionController.isUsable(capability)
    {
      speechController.cancel()
      isRecording = false
      if state == .listening { state = .idle }
    }
    if [.microphone, .speechRecognition, .screenCapture].contains(capability),
      !permissionController.isUsable(capability),
      meetingStartGate.isWaitingForPermission || meetingRecorder.state != .idle
    {
      stopMeetingRecording()
    }
    if capability == .aiForwarding, !permissionController.isUsable(.aiForwarding) {
      cancelActiveWork(preservingPendingInputs: true)
    }
    refreshPermissionMenu()
  }

  private func requestAIForwardingConsentIfNeeded() -> Bool {
    guard !permissionController.snapshot(.aiForwarding).enabled else { return true }
    let alert = NSAlert()
    alert.messageText = "Send requests to OpenAI?"
    alert.informativeText = "Voice transcripts, selected screen captures, conversation context, relevant files, calendar results, and results from credential-backed tools may be sent to OpenAI through Codex. You can turn this off at any time."
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    permissionController.acceptAIForwarding()
    codexClient.prewarmRouting()
    refreshPermissionMenu()
    return true
  }

  private func configureSpeechOutput() {
    speechOutput.onStart = { [weak self] in
      guard let self else { return }
      self.performanceTracker.begin(.speech)
      self.state = .speaking
      self.refreshTimingMenu()
    }
    speechOutput.onFinish = { [weak self] in
      guard let self, self.state == .speaking else { return }
      self.performanceTracker.finish(.speech)
      self.refreshTimingMenu()
      self.state = .idle
      self.drainConversationInput()
    }
  }

  private func configureHotKey() {
    hotKey.onPress = { [weak self] in self?.scheduleListening() }
    hotKey.onRelease = { [weak self] in
      self?.pendingListenWorkItem?.cancel()
      self?.pendingListenWorkItem = nil
      self?.stopListening()
    }
    hotKey.onChord = { [weak self] action in self?.handleChord(action) }
    hotKey.onAvailabilityChange = { [weak self] available in
      guard let self else { return }
      if available {
        if self.state == .failed(Self.fnPermissionMessage) { self.state = .idle }
      } else {
        self.state = .failed(Self.fnPermissionMessage)
      }
    }
    guard permissionController.snapshot(.inputMonitoring).enabled else { return }
    if !hotKey.register() {
      state = .failed(Self.fnPermissionMessage)
    }
  }

  private func configureAssistantControl() {
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(receiveAssistantControl(_:)),
      name: AssistantControlCommand.notification,
      object: nil
    )
  }

  private func configureRecipeMaintenance() {
    performDataMaintenance()
    if codexClient.isExecutableAvailable {
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        self?.performCodexMaintenance()
      }
    } else {
      performCodexMaintenance()
    }
    recipeMaintenanceTimer = Timer.scheduledTimer(
      timeInterval: 86_400,
      target: self,
      selector: #selector(performMaintenance),
      userInfo: nil,
      repeats: true
    )
  }

  @objc private func performMaintenance() {
    performDataMaintenance()
    performCodexMaintenance()
  }

  private func performDataMaintenance() {
    maintenanceQueue.async { [weak self] in
      let report = RecipeMaintenance.maintain()
      let memoryMaintained = MemoryMaintenance.maintain()
      guard report.expired > 0 || report.deleted > 0 || memoryMaintained else { return }
      DispatchQueue.main.async { self?.refreshMetrics() }
    }
  }

  private func performCodexMaintenance() {
    guard !codexMaintenanceInProgress, !contextMaintenanceInProgress,
      !codexClient.isRunning, state.allowsCodexMaintenance
    else { return }
    codexMaintenanceInProgress = true
    render()
    maintenanceQueue.async { [weak self] in
      let report = CodexMaintenance.maintain()
      DispatchQueue.main.async {
        guard let self else { return }
        self.codexMaintenanceInProgress = false
        self.render()
        self.codexMaintenanceWarnings = report.warnings
        self.codexVersionItem?.title = CodexMaintenance.displayVersion()
        if report.checked {
          if self.codexClient.isRunning {
            self.pendingCodexExecutableURL = report.executableURL
          } else {
            self.activateCodexClient(executableURL: report.executableURL)
          }
        }
        if self.codexClient.isExecutableAvailable {
          if self.state == .working("Installing Codex…")
            || self.state == .working("Updating Codex…")
            || self.state == .failed(CodexClientError.executableMissing.localizedDescription)
          {
            self.state = .idle
          }
        } else if self.startupError == nil {
          self.state = .failed(
            report.warnings.first ?? CodexClientError.executableMissing.localizedDescription
          )
        }
        self.refreshWarnings()
      }
    }
  }

  private func makeCodexClient(
    executableURL: URL? = CodexExecutableLocator.locate()
  ) -> CodexClient {
    let profile = AssistantAccessProfile.load()
    let accessArguments: [String]
    switch profile.selection(using: accessCapabilities) {
    case .arguments(let arguments):
      accessArguments = arguments
    case .unavailable:
      if case .arguments(let arguments) = AssistantAccessProfile.fullAccess.selection(
        using: accessCapabilities
      ) {
        accessArguments = arguments
      } else {
        accessArguments = []
      }
    }
    return CodexClient(
      executableURL: executableURL,
      assistantControlToken: assistantControlToken,
      forwardingAllowed: { AIForwardingConsent.isEnabled() },
      automaticRouting: true,
      accessArguments: accessArguments,
      isolatesExtensions: profile != .custom,
      taskCapabilityProvider: { TaskCapabilityBroker.issue(capabilities: $0) }
    )
  }

  private func refreshAccessCapabilities() {
    guard let executableURL = CodexExecutableLocator.locate() else { return }
    maintenanceQueue.async { [weak self] in
      let result = CodexMaintenance.run(
        executable: executableURL,
        arguments: ["exec", "resume", "--help"],
        environment: ProcessInfo.processInfo.environment,
        timeout: 10
      )
      guard result.status == 0, !result.timedOut else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.accessCapabilities = CodexExecCapabilities(helpText: result.output + result.error)
        let selected = AssistantAccessProfile.load()
        if case .unavailable(let reason) = selected.selection(using: self.accessCapabilities) {
          AssistantAccessProfile.fullAccess.save()
          self.accessWarning = "Access profile changed to Full Access because the previous option is unavailable: \(reason)"
        } else {
          self.accessWarning = nil
        }
        self.rebuildAccessMenu()
        if self.codexClient.isRunning {
          self.pendingCodexExecutableURL = executableURL
          self.activatePendingCodexClientWhenIdle()
        } else {
          self.activateCodexClient(executableURL: executableURL)
        }
        self.refreshWarnings()
      }
    }
  }

  private func activateCodexClient(executableURL: URL?) {
    pendingCodexActivationWorkItem?.cancel()
    pendingCodexActivationWorkItem = nil
    codexClient = makeCodexClient(executableURL: executableURL)
    accountMetrics = CodexAccountMetrics(
      executableURL: executableURL,
      workspaceURL: AssistantPaths.workspaceURL
    )
    pendingCodexExecutableURL = nil
    if AIForwardingConsent.isEnabled() { codexClient.prewarmRouting() }
    openChatMenuItem?.isEnabled = codexClient.threadID != nil
  }

  private func activatePendingCodexClientWhenIdle() {
    guard let executableURL = pendingCodexExecutableURL else { return }
    guard !codexClient.isRunning else {
      pendingCodexActivationWorkItem?.cancel()
      let item = DispatchWorkItem { [weak self] in
        self?.activatePendingCodexClientWhenIdle()
      }
      pendingCodexActivationWorkItem = item
      DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
      return
    }
    activateCodexClient(executableURL: executableURL)
  }

  func applicationWillTerminate(_ notification: Notification) {
    meetingRecorder.stopImmediately()
    recipeMaintenanceTimer?.invalidate()
    deleteConfirmationTimer?.invalidate()
    pendingCodexActivationWorkItem?.cancel()
    contextCompactionWorkItem?.cancel()
    contextMaintenance?.cancel()
    DistributedNotificationCenter.default().removeObserver(self)
  }

  @objc private func performPrimaryAction() {
    if codexClient.isRunning {
      if state == .listening {
        stopListening()
      } else {
        startListening()
      }
    } else if state == .listening {
      stopListening()
    } else if state == .thinking || state.isWorking {
      cancelCurrentWork()
    } else if state == .speaking || state == .paused {
      speechOutput.stop()
      state = .idle
    } else {
      startListening()
    }
  }

  private func startListening() {
    guard !isDeletingData else { return }
    guard !codexMaintenanceInProgress || codexClient.isExecutableAvailable else {
      state = .working("Installing Codex…")
      return
    }
    permissionController.prepareForConversation()
    let isSteering = codexClient.isRunning
    if !isSteering && (state == .speaking || state == .paused) {
      speechOutput.stop()
    }
    guard !isRecording else { return }
    beginConversationActivity()
    if isSteering {
      dictationMode = .steering(previousState: state)
      speechOutput.stopStatus()
    } else {
      dictationMode = .request
    }
    state = .listening
    isRecording = true
    meetingRecorder.setQuestionCaptureActive(true)
    speechController.start(onPartialTranscript: { _ in }) { [weak self] result in
      guard let self else { return }
      self.meetingRecorder.setQuestionCaptureActive(false)
      self.isRecording = false
      self.performanceTracker.finish(.transcription)
      self.refreshTimingMenu()
      switch result {
      case .success(let transcript):
        self.submit(transcript)
      case .failure(let error):
        if error.isSilent {
          self.restoreAfterEmptyDictation()
        } else {
          if case .microphoneDenied = error {
            self.permissionController.requestOrOpenSettings(.microphone)
          }
          if case .recognitionDenied = error {
            self.permissionController.requestOrOpenSettings(.speechRecognition)
          }
          self.fail(error.localizedDescription)
        }
      }
    }
  }

  private func scheduleListening() {
    pendingListenWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.pendingListenWorkItem = nil
      self?.startListening()
    }
    pendingListenWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
  }

  private func stopListening() {
    guard isRecording else { return }
    performanceTracker.begin(.transcription)
    state = .transcribing
    speechController.stop()
  }

  private func submit(_ transcript: String) {
    let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      restoreAfterEmptyDictation()
      return
    }
    guard requestAIForwardingConsentIfNeeded() else {
      state = .idle
      return
    }
    if case .steering(let previousState) = dictationMode { state = previousState }
    dictationMode = .request
    speakDeferredAfterDictationIfNeeded()
    _ = enqueueInput(normalized)
  }

  @discardableResult
  private func submitManualMessage(_ message: String) -> Bool {
    guard requestAIForwardingConsentIfNeeded() else { return false }
    beginConversationActivity()
    return enqueueInput(message)
  }

  @discardableResult
  private func enqueueInput(_ text: String, attachments: [URL] = []) -> Bool {
    do {
      let input = try inputJournal.enqueue(text: text, attachments: attachments)
      inputJournalWarning = nil
      handleInputAction(inputQueue.submit(input, during: conversationPhase()))
      return true
    } catch {
      inputJournalWarning = error.localizedDescription
      refreshWarnings()
      fail(error.localizedDescription)
      return false
    }
  }

  private func startTurn(_ input: ConversationInput) {
    if contextMaintenanceInProgress {
      _ = inputQueue.requeueStarted(input)
      return
    }
    activeInput = input
    state = .routing
    steeringDeferredUntilTurnEnds = false
    performanceTracker.begin(.routing)
    refreshTimingMenu()
    lastProgress = nil
    requestGeneration += 1
    let currentGeneration = requestGeneration
    let prompt = prompt(for: input)
    let shouldCapture = ScreenContextPolicy.shouldCapture(for: input.text)
    guard shouldCapture else {
      askCodex(prompt, imageURL: nil, generation: currentGeneration)
      return
    }
    guard permissionController.isUsable(.screenCapture) else {
      permissionController.requestOrOpenSettings(.screenCapture)
      if permissionController.isUsable(.screenCapture) {
        screenCapture.captureActiveDisplay { [weak self] result in
          self?.handleScreenCapture(result, transcript: prompt, generation: currentGeneration)
        }
      } else {
        retainActiveInputForRetry()
        fail("Allow Screen Recording, then try again.")
      }
      return
    }
    screenCapture.captureActiveDisplay { [weak self] result in
      self?.handleScreenCapture(result, transcript: prompt, generation: currentGeneration)
    }
  }

  private func conversationPhase() -> ConversationInputQueue.Phase {
    ConversationInputQueue.phase(
      state: state,
      codexRunning: codexClient.isRunning,
      canSteer: codexClient.canSteer && !steeringDeferredUntilTurnEnds,
      contextMaintenanceInProgress: contextMaintenanceInProgress
    )
  }

  private func handleInputAction(_ action: ConversationInputQueue.Action) {
    switch action {
    case .none:
      return
    case .queued:
      return
    case .startTurn(let input):
      startTurn(input)
    case .steer(let input):
      codexClient.steer(prompt(for: input)) {
        [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          _ = self.inputQueue.acceptSteering()
          self.acknowledge(input)
          self.drainConversationInput()
        case .failure:
          _ = self.inputQueue.requeueRejectedSteering()
          self.steeringDeferredUntilTurnEnds = true
          self.refreshWarnings()
        }
      }
    }
  }

  private func drainConversationInput() {
    guard inputQueue.hasPendingInput, !inputQueue.hasSubmittedSteering else { return }
    let phase = conversationPhase()
    let action = inputQueue.nextAction(during: phase)
    handleInputAction(action)
  }

  private func receiveDroppedFiles(_ files: [URL]) {
    let attachments = DroppedFileSelection.normalized(files)
    guard !attachments.isEmpty else { return }
    beginConversationActivity()
    let message = "Use the newly attached file or files as additional context. If no task is active, briefly ask what help is wanted."
    _ = enqueueInput(message, attachments: attachments)
  }

  private func prompt(for input: ConversationInput) -> String {
    input.text + DroppedFileSelection.promptSuffix(for: input.attachments)
  }

  private func handleScreenCapture(
    _ result: Result<URL, ScreenCaptureError>,
    transcript: String,
    generation: Int
  ) {
    guard requestGeneration == generation else {
      if case .success(let imageURL) = result { screenCapture.remove(imageURL) }
      return
    }
    switch result {
    case .success(let imageURL):
      askCodex(transcript, imageURL: imageURL, generation: generation)
    case .failure(let error):
      retainActiveInputForRetry()
      fail(error.localizedDescription)
    }
  }

  private func restoreAfterEmptyDictation() {
    if case .steering(let previousState) = dictationMode {
      state = previousState
    } else {
      state = .idle
    }
    dictationMode = .request
    speakDeferredAfterDictationIfNeeded()
  }

  private func speakDeferredAfterDictationIfNeeded() {
    guard let text = deferredSpeechAfterDictation else { return }
    deferredSpeechAfterDictation = nil
    speechOutput.stopStatus()
    speechOutput.speak(text)
  }

  private func askCodex(
    _ transcript: String,
    imageURL: URL?,
    generation: Int
  ) {
    codexClient.ask(
      transcript,
      imageURL: imageURL,
      capabilitySummary: codexCapabilitySummary(),
      taskCapabilities: taskCapabilitiesForCurrentTurn(),
      searchEnabled: permissionController.isUsable(.webSearch),
      progress: { [weak self] progress in self?.handle(progress: progress) }
    ) { [weak self] result in
      if let imageURL { self?.screenCapture.remove(imageURL) }
      guard let self, self.requestGeneration == generation else { return }
      self.steeringDeferredUntilTurnEnds = false
      self.performanceTracker.finish(.routing)
      self.performanceTracker.finish(.response)
      self.refreshTimingMenu()
      self.workerCount = 0
      self.workersMetricItem?.title = "Workers 0"
      self.activatePendingCodexClientWhenIdle()
      self.refreshWarnings()
      switch result {
      case .success(let answer):
        if let activeInput = self.activeInput {
          self.acknowledge(activeInput)
          self.activeInput = nil
        }
        self.lastAnswer = answer
        self.diffMetricItem?.title = self.codexClient.lastDiff.menuLabel
        self.repeatMenuItem.isEnabled = true
        self.refreshMetrics(forceLocal: true)
        self.finishConversationActivity()
        if self.isRecording {
          self.deferredSpeechAfterDictation = answer
        } else {
          self.speechOutput.speak(answer)
        }
      case .failure(let error):
        self.retainActiveInputForRetry()
        if error == .emptyPrompt {
          self.state = .idle
        } else {
          self.fail(error.localizedDescription)
        }
      }
    }
  }

  private func codexCapabilitySummary() -> String {
    let base = permissionController.codexSummary()
    guard meetingRecorder.isRecording, let transcriptURL = meetingRecorder.transcriptURL else {
      return base
    }
    return "\(base) An active consented meeting transcript is available at \(transcriptURL.path). Read a bounded current snapshot only when the user's request concerns this meeting."
  }

  private func taskCapabilitiesForCurrentTurn() -> Set<TaskCapabilityBroker.Capability> {
    var capabilities: Set<TaskCapabilityBroker.Capability> = [.vault]
    if permissionController.snapshot(.calendar).enabled { capabilities.insert(.calendar) }
    if permissionController.snapshot(.accessibility).enabled { capabilities.insert(.selection) }
    if permissionController.snapshot(.clipboard).enabled { capabilities.insert(.clipboard) }
    return capabilities
  }

  private func acknowledge(_ input: ConversationInput) {
    do {
      try inputJournal.acknowledge(input)
      inputJournalWarning = nil
    } catch {
      inputJournalWarning = error.localizedDescription
      refreshWarnings()
    }
  }

  private func retainActiveInputForRetry() {
    guard let activeInput else { return }
    _ = inputQueue.requeueStarted(activeInput)
    self.activeInput = nil
  }

  @objc private func toggleSpokenThinkingStatus() {
    setSpokenProgress(!speaksThinkingStatus)
  }

  private func setSpokenProgress(_ enabled: Bool) {
    speaksThinkingStatus = enabled
    UserDefaults.standard.set(speaksThinkingStatus, forKey: Self.spokenThinkingKey)
    spokenThinkingMenuItem.state = speaksThinkingStatus ? .on : .off
    if !speaksThinkingStatus {
      speechOutput.stopStatus()
    }
  }

  private func fail(_ message: String) {
    if isRecording {
      deferredSpeechAfterDictation = message
      return
    }
    state = .failed(message)
    speechOutput.speak(message)
  }

  @objc private func repeatLastAnswer() {
    repeatShortcut()
  }

  private func repeatShortcut() {
    if isRecording {
      speechController.cancel()
      isRecording = false
      restoreAfterEmptyDictation()
    }
    guard !codexClient.isRunning, !lastAnswer.isEmpty else { return }
    if state == .speaking || state == .paused {
      speechOutput.stop()
      state = .idle
    }
    speechOutput.speak(lastAnswer)
  }

  private func handleChord(_ action: FunctionChordAction) {
    pendingListenWorkItem?.cancel()
    pendingListenWorkItem = nil
    if isRecording {
      speechController.cancel()
      isRecording = false
      restoreAfterEmptyDictation()
    }
    switch action {
    case .repeatAnswer:
      repeatShortcut()
    case .pauseResume:
      toggleSpeechPause()
    case .stop:
      cancelCurrentWork()
    case .cancelDictation:
      break
    }
  }

  @objc private func receiveAssistantControl(_ notification: Notification) {
    guard let raw = notification.object as? String,
      notification.userInfo?["token"] as? String == assistantControlToken,
      let action = AssistantControlAction(rawValue: raw)
    else { return }
    let value = notification.userInfo?["value"] as? String
    switch action {
    case .progressOn:
      setSpokenProgress(true)
    case .progressOff:
      setSpokenProgress(false)
    case .speechPause:
      if state == .speaking { toggleSpeechPause() }
    case .speechResume:
      if state == .paused { toggleSpeechPause() }
    case .speechStop:
      speechOutput.stop()
      if state == .speaking || state == .paused { state = .idle }
    case .workStop:
      cancelCurrentWork()
    case .answerRepeat:
      repeatLastAnswer()
    case .contextClear:
      clearContext()
    case .chatOpen:
      openChat()
    case .usageOpen:
      openUsage()
    case .reveal:
      revealControlTarget(value)
    case .resultSet:
      setLastResult(value)
    case .resultShow:
      showLastResult()
    case .launchAtLoginOn:
      setLaunchAtLogin(true)
    case .launchAtLoginOff:
      setLaunchAtLogin(false)
    case .capabilityOn:
      setCapability(value, enabled: true)
    case .capabilityOff:
      setCapability(value, enabled: false)
    case .shortcutSelect:
      if let value, let preset = AssistantShortcutPreset(rawValue: value) {
        applyShortcut(preset)
      }
    case .accessSelect:
      if let value, let profile = AssistantAccessProfile(rawValue: value) {
        applyAccessProfile(profile)
      }
    case .diagramOpen:
      openDiagram(value)
    case .meetingStart:
      if meetingRecorder.state == .idle, !meetingStartGate.isWaitingForPermission {
        startMeetingRecording()
      }
    case .meetingStop:
      if meetingStartGate.isWaitingForPermission || meetingRecorder.state != .idle {
        stopMeetingRecording()
      }
    }
  }

  @objc private func toggleSpeechPause() {
    guard let isPaused = speechOutput.togglePause() else { return }
    if isPaused {
      stateBeforePause = state
      state = .paused
    } else {
      state = stateBeforePause ?? .speaking
      stateBeforePause = nil
    }
  }

  @objc private func cancelCurrentWork() {
    cancelActiveWork(preservingPendingInputs: false)
  }

  private func cancelActiveWork(preservingPendingInputs: Bool) {
    pendingListenWorkItem?.cancel()
    pendingListenWorkItem = nil
    stateBeforePause = nil
    requestGeneration += 1
    speechController.cancel()
    meetingRecorder.setQuestionCaptureActive(false)
    isRecording = false
    deferredSpeechAfterDictation = nil
    dictationMode = .request
    speechOutput.stop()
    codexClient.cancel()
    if preservingPendingInputs {
      _ = inputQueue.preserveForRetry(activeInput: activeInput)
      activeInput = nil
    } else {
      _ = inputQueue.clear()
      activeInput = nil
      do {
        try inputJournal.clear()
        inputJournalWarning = nil
      } catch {
        inputJournalWarning = error.localizedDescription
      }
    }
    steeringDeferredUntilTurnEnds = false
    performanceTracker.cancelAll()
    activatePendingCodexClientWhenIdle()
    cancelContextCompaction(invalidateIdleGeneration: true)
    state = .idle
  }

  @objc private func clearContext() {
    cancelActiveWork(preservingPendingInputs: true)
    codexClient.clearContext()
    lastAnswer = ""
    repeatMenuItem.isEnabled = false
    refreshMetrics()
    speechOutput.speak(SystemSpeechLanguage.contextCleared)
  }

  @objc private func showContext() {
    reveal(metrics.contextURL ?? AssistantPaths.workspaceURL)
  }

  @objc private func showAgents() {
    reveal(metrics.sessionsURL)
  }

  @objc private func showMemory() {
    reveal(AssistantPaths.workspaceURL.appendingPathComponent("memory", isDirectory: true))
  }

  @objc private func showDatabase() {
    reveal(AssistantPaths.workspaceURL.appendingPathComponent("database/assistant.sqlite3"))
  }

  @objc private func showRecipes() {
    reveal(AssistantPaths.workspaceURL.appendingPathComponent("recipes", isDirectory: true))
  }

  @objc private func showVault() {
    reveal(CredentialVault.defaultRootURL)
  }

  @objc private func openUsage() {
    guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func openChat() {
    guard chatOpenGate.begin() else { return }
    let transcriptURL = metrics.contextURL
      ?? AssistantMetricsLoader.load(
        threadID: codexClient.threadID,
        includeWeeklyFallback: false
      ).contextURL
    CodexChatLauncher.openInApp(
      threadID: codexClient.threadID,
      transcriptURL: transcriptURL,
      executableURL: CodexExecutableLocator.locate()
    ) { [weak self] result in
      self?.chatOpenGate.finish()
      if result == .unavailable {
        self?.fail("No assistant conversation is available yet.")
      }
    }
  }

  private func beginConversationActivity() {
    if !contextMaintenanceInProgress { contextIdleGeneration += 1 }
    lastConversationFinishedAt = nil
    contextCompactionWorkItem?.cancel()
    contextCompactionWorkItem = nil
    contextMaintenanceWarning = nil
  }

  private func finishConversationActivity() {
    lastConversationFinishedAt = Date()
    scheduleContextCompaction(
      generation: contextIdleGeneration,
      after: CodexContextCompactionPolicy.minimumIdle
    )
  }

  private func scheduleContextCompaction(generation: Int, after delay: TimeInterval) {
    contextCompactionWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.performContextCompaction(generation: generation)
    }
    contextCompactionWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func performContextCompaction(generation: Int) {
    guard generation == contextIdleGeneration,
      lastCompactionAttemptedGeneration != generation,
      let finishedAt = lastConversationFinishedAt
    else { return }
    guard !codexMaintenanceInProgress, !contextMaintenanceInProgress,
      !codexClient.isRunning, state.allowsCodexMaintenance
    else {
      scheduleContextCompaction(generation: generation, after: 60)
      return
    }
    let threadID = codexClient.threadID
    let snapshot = metrics
    let idleDuration = Date().timeIntervalSince(finishedAt)
    guard CodexContextCompactionPolicy.shouldCompact(
      threadID: threadID,
      contextTokens: snapshot.contextTokens,
      contextWindow: snapshot.contextWindow,
      idleDuration: idleDuration,
      idleGeneration: generation,
      lastCompactedIdleGeneration: lastCompactionAttemptedGeneration
    ) else { return }
    guard let executableURL = CodexExecutableLocator.locate() else {
      contextMaintenanceWarning = "Context compaction could not start because Codex is unavailable."
      refreshWarnings()
      return
    }

    lastCompactionAttemptedGeneration = generation
    contextMaintenanceInProgress = true
    state = .compacting
    performanceTracker.begin(.compaction)
    refreshTimingMenu()
    let maintenance = CodexContextMaintenance(
      executableURL: executableURL,
      forwardingAllowed: { AIForwardingConsent.isEnabled() }
    )
    contextMaintenance = maintenance
    maintenanceQueue.async { [weak self] in
      let result = maintenance.compactIfNeeded(
        threadID: threadID,
        contextTokens: snapshot.contextTokens,
        contextWindow: snapshot.contextWindow,
        idleDuration: idleDuration,
        idleGeneration: generation,
        lastCompactedIdleGeneration: nil,
        timeout: 120
      )
      DispatchQueue.main.async {
        guard let self else { return }
        self.contextMaintenanceInProgress = false
        self.render()
        self.performanceTracker.finish(.compaction)
        self.refreshTimingMenu()
        if self.contextMaintenance === maintenance { self.contextMaintenance = nil }
        switch result {
        case .compacted, .notNeeded, .cancelled:
          self.contextMaintenanceWarning = nil
        case .timedOut:
          self.contextMaintenanceWarning = "Codex context compaction timed out; the conversation remains usable."
        case .failed(let message):
          self.contextMaintenanceWarning = message
        }
        self.refreshMetrics(forceLocal: true)
        self.refreshWarnings()
        if self.state == .compacting {
          self.state = .idle
        }
        self.drainConversationInput()
      }
    }
  }

  private func cancelContextCompaction(invalidateIdleGeneration: Bool) {
    contextCompactionWorkItem?.cancel()
    contextCompactionWorkItem = nil
    contextMaintenance?.cancel()
    if invalidateIdleGeneration {
      contextIdleGeneration += 1
      lastConversationFinishedAt = nil
    }
  }

  @objc private func openSpeechSettings() {
    for url in SystemSpeechLanguage.settingsURLs where NSWorkspace.shared.open(url) { return }
  }

  private func refreshTimingMenu() {
    let snapshot = performanceTracker.snapshot
    for stage in PipelineStage.allCases {
      timingMenuItems[stage]?.title = snapshot.label(for: stage)
    }
  }

  @objc private func showLastResult() {
    guard let lastResultURL else { return }
    reveal(lastResultURL)
  }

  private func rebuildSourcesMenu() {
    let menu = NSMenu()
    let values = codexClient.sources()
    sourcesMenuItem?.title = "Sources (\(values.count))"
    if values.isEmpty {
      let empty = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      for value in values {
        let title = value.kind == .file
          ? value.url.lastPathComponent
          : (value.url.host ?? value.url.absoluteString)
        let item = NSMenuItem(title: title, action: #selector(openRecentSource(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value.url
        item.toolTip = value.url.isFileURL ? value.url.path : value.url.absoluteString
        let symbol = value.kind == .file ? "doc" : "link"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        menu.addItem(item)
      }
    }
    sourcesMenuItem?.submenu = menu
  }

  @objc private func openRecentSource(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    if url.isFileURL {
      reveal(url)
    } else {
      NSWorkspace.shared.open(url)
    }
  }

  private func setLastResult(_ path: String?) {
    guard let path, path.hasPrefix("/") else { return }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    lastResultURL = url
    resultMenuItem?.title = "Show Result: \(url.lastPathComponent)"
    resultMenuItem?.toolTip = url.path
    resultMenuItem?.isEnabled = true
  }

  private func openDiagram(_ path: String?) {
    guard let path else { return }
    let request: DiagramEditorRequest
    do {
      request = try DiagramEditor.request(path: path)
    } catch {
      fail(error.localizedDescription)
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Open in diagrams.net?"
    alert.informativeText = "\(request.fileURL.lastPathComponent) will be loaded into the third-party browser editor."
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard NSWorkspace.shared.open(request.editorURL) else {
      fail("The diagram could not be opened in the browser.")
      return
    }
    setLastResult(request.fileURL.path)
  }

  private func revealControlTarget(_ target: String?) {
    switch target {
    case "context": showContext()
    case "agents": showAgents()
    case "memory": showMemory()
    case "database": showDatabase()
    case "recipes": showRecipes()
    case "vault": showVault()
    default: break
    }
  }

  private func reveal(_ url: URL) {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      NSWorkspace.shared.open(url)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  @objc private func toggleLaunchAtLogin() {
    setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
  }

  private func setLaunchAtLogin(_ enabled: Bool) {
    guard (SMAppService.mainApp.status == .enabled) != enabled else { return }
    do {
      if !enabled {
        try SMAppService.mainApp.unregister()
        launchAtLoginMenuItem.state = .off
      } else {
        try SMAppService.mainApp.register()
        launchAtLoginMenuItem.state = .on
      }
    } catch {
      fail("Launch at Login could not be changed.")
    }
  }

  private func setCapability(_ rawValue: String?, enabled: Bool) {
    guard let rawValue, let capability = AssistantCapability(rawValue: rawValue) else { return }
    let snapshot = permissionController.snapshot(capability)
    guard snapshot.enabled != enabled else { return }
    let item = permissionMenuItems[capability] ?? NSMenuItem()
    item.representedObject = capability.rawValue
    togglePermission(item)
  }

  @objc private func deleteAllData() {
    if deleteDataMenuItem.title == "Confirm Delete Assistant Data" {
      meetingRecorder.stopImmediately()
      cancelCurrentWork()
      recipeMaintenanceTimer?.invalidate()
      isDeletingData = true
      state = .working("Deleting…")
      let domain = Bundle.main.bundleIdentifier ?? "com.yunabraska.aven"
      let client = codexClient
      maintenanceQueue.async { [weak self] in
        guard let self else { return }
        guard client.cancelAndWait() else {
          DispatchQueue.main.async {
            self.isDeletingData = false
            self.resetDeleteConfirmation()
            self.fail("Assistant data could not be deleted while Codex is still running.")
          }
          return
        }
        let tasksDeleted = client.deleteStoredThreads()
        do {
          try AssistantDataController().eraseAll(domain: domain)
          DispatchQueue.main.async {
            if !tasksDeleted {
              let alert = NSAlert()
              alert.messageText = "Local assistant data was deleted"
              alert.informativeText = "Some Codex task history could not be removed because Codex was unavailable."
              alert.runModal()
            }
            NSApp.terminate(nil)
          }
        } catch {
          DispatchQueue.main.async {
            self.isDeletingData = false
            self.resetDeleteConfirmation()
            self.fail("Assistant data could not be deleted.")
          }
        }
      }
      return
    }
    deleteDataMenuItem.title = "Confirm Delete Assistant Data"
    deleteConfirmationTimer?.invalidate()
    deleteConfirmationTimer = Timer.scheduledTimer(
      timeInterval: 10,
      target: self,
      selector: #selector(resetDeleteConfirmation),
      userInfo: nil,
      repeats: false
    )
  }

  @objc private func resetDeleteConfirmation() {
    deleteConfirmationTimer?.invalidate()
    deleteConfirmationTimer = nil
    deleteDataMenuItem?.title = "Delete Assistant Data…"
  }

  @objc private func quit() {
    cancelActiveWork(preservingPendingInputs: true)
    NSApp.terminate(nil)
  }

  private func render() {
    guard statusItem != nil else { return }
    statusIconAnimator?.update(
      state: state,
      hasWarning: hasVisibleWarnings,
      isMeetingRecording: meetingRecorder.isRecording
    )
    statusMenuItem?.title = state.statusText
    statusMenuItem?.isHidden = !state.showsStatusInMenu
    if contextMaintenanceInProgress {
      backgroundStatusMenuItem?.title = "Compacting…"
      backgroundStatusMenuItem?.isHidden = state == .compacting
    } else if codexMaintenanceInProgress {
      backgroundStatusMenuItem?.title = "Updating Codex…"
      backgroundStatusMenuItem?.isHidden = false
    } else {
      backgroundStatusMenuItem?.isHidden = true
    }
    refreshStatusHeaderVisibility()
    let hold = shortcutStore.selectedPreset.displayName
    listenMenuItem?.title = switch state {
    case .listening: codexClient.isRunning ? "Steering…" : "Stop (\(hold))"
    case .routing, .thinking, .working: "Steer (\(hold))"
    case .compacting: "Listen (\(hold))"
    case .transcribing: "Transcribing…"
    case .speaking: "Stop"
    case .paused: "Stop"
    case .idle, .failed: "Listen (\(hold))"
    }
    listenMenuItem?.image = menuSymbol(
      state == .listening ? "stop.circle" : "mic",
      description: state == .listening ? "Stop listening" : "Listen"
    )
    repeatMenuItem?.title = "Repeat (\(hold)+R)"
    pauseMenuItem?.title = state == .paused ? "Resume (\(hold)+P)" : "Pause (\(hold)+P)"
    pauseMenuItem?.image = menuSymbol(
      state == .paused ? "play" : "pause",
      description: state == .paused ? "Resume speech" : "Pause speech"
    )
    stopMenuItem?.title = "Stop (\(hold)+Esc)"
    pauseMenuItem?.isEnabled = state == .speaking || state == .paused
    stopMenuItem?.isEnabled =
      state == .listening || state == .transcribing || state == .routing || state == .thinking
      || state.isWorking || state == .compacting || state == .speaking || state == .paused
  }

  private func handle(progress: CodexProgress) {
    switch state {
    case .routing, .thinking, .working:
      break
    case .idle, .listening, .transcribing, .compacting, .speaking, .paused, .failed:
      return
    }
    guard progress != lastProgress else { return }
    lastProgress = progress
    switch progress {
    case .routing:
      state = .routing
    case .thinking:
      performanceTracker.finish(.routing)
      performanceTracker.begin(.response)
      refreshTimingMenu()
      state = .thinking
    case .workers(let count):
      workerCount = count
      workersMetricItem?.title = "Workers \(count)"
      return
    case .searching, .working, .update:
      state = .working(progress.statusText)
    }
    if speaksThinkingStatus, progress.shouldSpeak {
      speechOutput.speakStatus(SystemSpeechLanguage.spokenProgress(progress))
    }
    if codexClient.canSteer { drainConversationInput() }
  }

  func menuWillOpen(_ menu: NSMenu) {
    voiceSettingsMenuItem?.title = "Voice · \(SystemSpeechLanguage.menuLabel)"
    updateMeetingMenu()
    refreshPermissionMenu()
    rebuildSourcesMenu()
    refreshMetrics()
    refreshWarnings()
  }

  private func refreshWarnings() {
    warningExpirationWorkItem?.cancel()
    warningExpirationWorkItem = nil
    let warnings = Array(Set(
      codexClient.warnings + codexMaintenanceWarnings
        + [startupWarning, contextMaintenanceWarning].compactMap { $0 }
        + [accessWarning, inputJournalWarning, meetingWarning].compactMap { $0 } + accountWarnings
    )).sorted()
    hasVisibleWarnings = !warnings.isEmpty
    let parentMenu = warningsMenuItem?.menu
    warningDetailItems.forEach { parentMenu?.removeItem($0) }
    warningDetailItems.removeAll(keepingCapacity: true)
    warningsMenuItem?.isHidden = warnings.isEmpty
    warningsMenuItem?.title = warnings.count == 1 ? "Warning" : "Warnings · \(warnings.count)"
    statusIconAnimator?.update(
      state: state,
      hasWarning: hasVisibleWarnings,
      isMeetingRecording: meetingRecorder.isRecording
    )
    refreshStatusHeaderVisibility()
    if let expiration = codexClient.nextWarningExpiration {
      let item = DispatchWorkItem { [weak self] in self?.refreshWarnings() }
      warningExpirationWorkItem = item
      DispatchQueue.main.asyncAfter(
        deadline: .now() + max(expiration.timeIntervalSinceNow + 0.05, 0.05),
        execute: item
      )
    }
    guard !warnings.isEmpty, let parentMenu, let warningsMenuItem else { return }
    var insertionIndex = parentMenu.index(of: warningsMenuItem) + 1
    for warning in warnings {
      let compact = warning.count > 88 ? String(warning.prefix(85)) + "…" : warning
      let item = NSMenuItem(title: compact, action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.indentationLevel = 1
      item.toolTip = warning
      item.image = NSImage(
        systemSymbolName: "exclamationmark.triangle",
        accessibilityDescription: "Warning"
      )
      parentMenu.insertItem(item, at: insertionIndex)
      warningDetailItems.append(item)
      insertionIndex += 1
    }
  }

  private func refreshStatusHeaderVisibility() {
    let statusVisible = !(statusMenuItem?.isHidden ?? true)
    let backgroundVisible = !(backgroundStatusMenuItem?.isHidden ?? true)
    let warningsVisible = !(warningsMenuItem?.isHidden ?? true)
    statusSeparatorItem?.isHidden = !statusVisible && !backgroundVisible && !warningsVisible
  }

  private func refreshMetrics(forceLocal: Bool = false) {
    let threadID = codexClient.threadID
    accountMetrics.refreshIfNeeded { [weak self] snapshot in
      DispatchQueue.main.async {
        guard let self else { return }
        self.accountSnapshot = snapshot
        if let remaining = snapshot.weeklyRemainingPercent {
          self.weeklyUsageItem?.title = AssistantMetricsSnapshot.weeklyUsageLabel(
            remainingPercent: remaining,
            resetAt: snapshot.weeklyResetAt
          )
        }
        self.resetCreditsItem?.title = snapshot.resetCreditsAvailableCount
          .map { "Resets \($0)" } ?? "Resets —"
        self.accountWarnings = snapshot.warnings()
        self.refreshWarnings()
      }
    }
    let now = Date()
    guard !metricsRefreshInProgress,
      forceLocal || (lastMetricsRefreshAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true)
    else { return }
    metricsRefreshInProgress = true
    metricsGeneration += 1
    let generation = metricsGeneration
    let includeWeeklyFallback = accountSnapshot.weeklyRemainingPercent == nil
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let snapshot = AssistantMetricsLoader.load(
        threadID: threadID,
        includeWeeklyFallback: includeWeeklyFallback
      )
      DispatchQueue.main.async {
        guard let self else { return }
        self.metricsRefreshInProgress = false
        guard self.metricsGeneration == generation else { return }
        self.lastMetricsRefreshAt = Date()
        self.metrics = snapshot
        self.contextMetricItem?.title = snapshot.contextLabel
        self.agentsMetricItem?.title = snapshot.agentsLabel
        self.memoryMetricItem?.title = snapshot.memoryLabel
        self.databaseMetricItem?.title = snapshot.databaseLabel
        self.recipesMetricItem?.title = snapshot.recipesLabel
        self.vaultMetricItem?.title = snapshot.vaultLabel
        if let remaining = self.accountSnapshot.weeklyRemainingPercent {
          self.weeklyUsageItem?.title = AssistantMetricsSnapshot.weeklyUsageLabel(
            remainingPercent: remaining,
            resetAt: self.accountSnapshot.weeklyResetAt
          )
        } else {
          self.weeklyUsageItem?.title = snapshot.weeklyUsageLabel
        }
        self.codexVersionItem?.title = CodexMaintenance.displayVersion()
        self.openChatMenuItem?.title = "Open Chat"
        self.openChatMenuItem?.isEnabled = !(self.codexClient.threadID?.isEmpty ?? true)
      }
    }
  }
}
