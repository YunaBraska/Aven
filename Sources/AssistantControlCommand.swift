import Foundation

enum AssistantControlAction: String {
  case progressOn = "progress-on"
  case progressOff = "progress-off"
  case speechPause = "speech-pause"
  case speechResume = "speech-resume"
  case speechStop = "speech-stop"
  case workStop = "work-stop"
  case answerRepeat = "answer-repeat"
  case contextClear = "context-clear"
  case chatOpen = "chat-open"
  case usageOpen = "usage-open"
  case reveal = "reveal"
  case resultSet = "result-set"
  case resultShow = "result-show"
  case launchAtLoginOn = "launch-at-login-on"
  case launchAtLoginOff = "launch-at-login-off"
  case capabilityOn = "capability-on"
  case capabilityOff = "capability-off"
  case shortcutSelect = "shortcut-select"
  case accessSelect = "access-select"
  case diagramOpen = "diagram-open"
  case meetingStart = "meeting-start"
  case meetingStop = "meeting-stop"
}

struct AssistantControlRequest: Equatable {
  let action: AssistantControlAction
  let value: String?
}

enum AssistantControlCommand {
  static let notification = Notification.Name("com.yunabraska.aven.control")

  static func handles(_ arguments: [String]) -> Bool {
    arguments.first == "assistant-control"
  }

  static func run(arguments: [String]) -> Int32 {
    if arguments == ["assistant-control", "--help"] {
      FileHandle.standardOutput.write(Data(usage.utf8))
      return 0
    }
    if arguments == ["assistant-control", "shortcut", "status"] {
      FileHandle.standardOutput.write(
        Data("\(AssistantShortcutStore().selectedPreset.rawValue)\n".utf8)
      )
      return 0
    }
    if arguments == ["assistant-control", "access", "status"] {
      FileHandle.standardOutput.write(Data("\(AssistantAccessProfile.load().rawValue)\n".utf8))
      return 0
    }
    guard let request = request(arguments: arguments) else {
      FileHandle.standardError.write(
        Data(usage.utf8)
      )
      return 2
    }
    guard let token = ProcessInfo.processInfo.environment["VOICE_ASSISTANT_CONTROL_TOKEN"],
      !token.isEmpty
    else {
      FileHandle.standardError.write(Data("assistant control is unavailable\n".utf8))
      return 3
    }
    DistributedNotificationCenter.default().postNotificationName(
      notification,
      object: request.action.rawValue,
      userInfo: ["token": token, "value": request.value ?? ""],
      deliverImmediately: true
    )
    return 0
  }

  static func request(arguments: [String]) -> AssistantControlRequest? {
    let values = Array(arguments.dropFirst())
    let fixed: [[String]: AssistantControlAction] = [
      ["progress", "on"]: .progressOn,
      ["progress", "off"]: .progressOff,
      ["speech", "pause"]: .speechPause,
      ["speech", "resume"]: .speechResume,
      ["speech", "stop"]: .speechStop,
      ["work", "stop"]: .workStop,
      ["answer", "repeat"]: .answerRepeat,
      ["context", "clear"]: .contextClear,
      ["chat", "open"]: .chatOpen,
      ["usage", "open"]: .usageOpen,
      ["result", "show"]: .resultShow,
      ["launch-at-login", "on"]: .launchAtLoginOn,
      ["launch-at-login", "off"]: .launchAtLoginOff,
      ["meeting", "start"]: .meetingStart,
      ["meeting", "stop"]: .meetingStop,
    ]
    if let action = fixed[values] { return AssistantControlRequest(action: action, value: nil) }
    if values.count == 2, values[0] == "reveal" {
      return AssistantControlRequest(action: .reveal, value: values[1])
    }
    if values.count == 2, values[0] == "shortcut" {
      guard AssistantShortcutPreset(rawValue: values[1]) != nil else { return nil }
      return AssistantControlRequest(action: .shortcutSelect, value: values[1])
    }
    if values.count == 2, values[0] == "access" {
      guard AssistantAccessProfile(rawValue: values[1]) != nil else { return nil }
      return AssistantControlRequest(action: .accessSelect, value: values[1])
    }
    if values.count == 3, values[0] == "result", values[1] == "set" {
      return AssistantControlRequest(action: .resultSet, value: values[2])
    }
    if values.count == 3, values[0] == "capability" {
      if values[2] == "on" {
        return AssistantControlRequest(action: .capabilityOn, value: values[1])
      }
      if values[2] == "off" {
        return AssistantControlRequest(action: .capabilityOff, value: values[1])
      }
    }
    if values.count == 3, values[0] == "diagram", values[1] == "open" {
      return AssistantControlRequest(action: .diagramOpen, value: values[2])
    }
    return nil
  }

  private static let usage = """
    usage: Aven assistant-control progress <on|off>
           Aven assistant-control speech <pause|resume|stop>
           Aven assistant-control work stop
           Aven assistant-control answer repeat
           Aven assistant-control context clear
           Aven assistant-control chat open
           Aven assistant-control usage open
           Aven assistant-control meeting <start|stop>
           Aven assistant-control reveal <context|agents|memory|database|recipes|vault>
           Aven assistant-control result set <absolute-path>
           Aven assistant-control result show
           Aven assistant-control launch-at-login <on|off>
           Aven assistant-control capability <name> <on|off>
           Aven assistant-control shortcut <physical-modifier>
           Aven assistant-control shortcut status
           Aven assistant-control access <full-access|ask-for-approval|approve-for-me|custom>
           Aven assistant-control access status
           Aven assistant-control diagram open <absolute-drawio-path>
    """
}
