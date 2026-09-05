import Foundation

enum AssistantState: Equatable {
  case idle
  case listening
  case transcribing
  case routing
  case thinking
  case working(String)
  case compacting
  case speaking
  case paused
  case failed(String)

  var statusText: String {
    switch self {
    case .idle:
      "Aven"
    case .listening:
      "Listening…"
    case .transcribing:
      "Transcribing…"
    case .routing:
      "Selecting…"
    case .thinking:
      "Thinking…"
    case .working(let message):
      message
    case .compacting:
      "Compacting…"
    case .speaking:
      "Speaking…"
    case .paused:
      "Paused"
    case .failed(let message):
      message
    }
  }

  var isWorking: Bool {
    if case .working = self { return true }
    return false
  }

  var allowsCodexMaintenance: Bool {
    switch self {
    case .idle, .failed:
      true
    case .listening, .transcribing, .routing, .thinking, .working, .compacting, .speaking, .paused:
      false
    }
  }

  var showsStatusInMenu: Bool { self != .idle }
}
