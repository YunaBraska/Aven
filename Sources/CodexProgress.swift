import Foundation

enum CodexProgress: Equatable {
  case routing
  case thinking
  case searching
  case working
  case workers(Int)
  case update(String)

  var statusText: String {
    switch self {
    case .routing: "Selecting…"
    case .thinking: "Thinking…"
    case .searching: "Searching…"
    case .working: "Working…"
    case .workers(let count): "Workers \(count)"
    case .update(let text): text
    }
  }

  var shouldSpeak: Bool {
    if case .update = self { return true }
    return false
  }
}
