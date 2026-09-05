import AppKit

@MainActor
enum ShortcutRecorder {
  static func recordTalkKey() -> AssistantShortcutPreset? {
    let alert = NSAlert()
    alert.messageText = "Record Talk Key"
    alert.informativeText = "Hold one modifier key. Press Cancel to keep the current shortcut."
    alert.addButton(withTitle: "Cancel")

    var recorded: AssistantShortcutPreset?
    var globalMonitor: Any?
    var localMonitor: Any?
    let receive: (NSEvent) -> Void = { event in
      guard let preset = AssistantShortcutPreset.recorded(
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags
      ) else { return }
      recorded = preset
      NSApp.abortModal()
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: receive)
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
      receive(event)
      return event
    }
    defer {
      if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
      if let localMonitor { NSEvent.removeMonitor(localMonitor) }
      alert.window.orderOut(nil)
    }
    _ = alert.runModal()
    return recorded
  }
}
