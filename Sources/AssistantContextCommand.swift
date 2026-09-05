import AppKit
import ApplicationServices
import Foundation

enum AssistantContextSource: String {
  case selection
  case clipboard
}

enum AssistantContextCommand {
  static let maximumOutputBytes = 256 * 1_024

  static func handles(_ arguments: [String]) -> Bool {
    arguments.first == "assistant-context"
  }

  static func source(arguments: [String]) -> AssistantContextSource? {
    guard arguments.count == 2, arguments[0] == "assistant-context" else { return nil }
    return AssistantContextSource(rawValue: arguments[1])
  }

  static func run(arguments: [String]) -> Int32 {
    guard let source = source(arguments: arguments) else {
      writeError("usage: Aven assistant-context <selection|clipboard>\n")
      return 2
    }
    let requestedCapability: TaskCapabilityBroker.Capability = source == .selection
      ? .selection : .clipboard
    guard TaskCapabilityBroker.authorizes(
      ProcessInfo.processInfo.environment["VOICE_ASSISTANT_TASK_CAPABILITY"],
      capability: requestedCapability
    )
    else {
      writeError("assistant context is unavailable outside an active request\n")
      return 3
    }
    let capability: AssistantCapability = source == .selection ? .accessibility : .clipboard
    guard capability.isEnabled(in: .standard) else {
      writeError("\(capability.title) is disabled in Aven Permissions\n")
      return 4
    }

    let result: (value: String?, error: String?)
    switch source {
    case .selection:
      result = selectedText()
    case .clipboard:
      result = (NSPasteboard.general.string(forType: .string), nil)
    }
    if let error = result.error {
      writeError(error + "\n")
      return 5
    }
    let value = result.value
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      writeError(source == .selection ? "no readable text is selected\n" : "the clipboard contains no text\n")
      return 5
    }
    FileHandle.standardOutput.write(Data((bounded(value) + "\n").utf8))
    return 0
  }

  static func bounded(_ value: String, maximumBytes: Int = maximumOutputBytes) -> String {
    guard maximumBytes > 0 else { return "" }
    let data = Data(value.utf8)
    guard data.count > maximumBytes else { return value }
    var count = maximumBytes
    while count > 0 {
      if let result = String(data: data.prefix(count), encoding: .utf8) { return result }
      count -= 1
    }
    return ""
  }

  private static func selectedText() -> (value: String?, error: String?) {
    guard AXIsProcessTrusted() else {
      let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
      return (nil, "allow Accessibility for Aven, then try again")
    }
    let system = AXUIElementCreateSystemWide()
    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      system,
      kAXFocusedUIElementAttribute as CFString,
      &focusedValue
    ) == .success, let focusedValue else { return (nil, nil) }
    let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
    var selectedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      focused,
      kAXSelectedTextAttribute as CFString,
      &selectedValue
    ) == .success else { return (nil, nil) }
    return (selectedValue as? String, nil)
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
  }
}
