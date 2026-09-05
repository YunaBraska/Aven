import Foundation

struct CodexEventSummary: Equatable {
  let threadID: String?
  let messages: [String]
  let completed: Bool
  let diff: CodexDiffSummary
}

struct CodexDiffSummary: Equatable {
  let added: Int
  let removed: Int

  static let empty = CodexDiffSummary(added: 0, removed: 0)

  var menuLabel: String { "Diff +\(added) −\(removed)" }
}

struct CodexProgressStream {
  private var pendingAgentMessage: String?
  private var activeWorkers = Set<String>()

  mutating func consume(_ line: Data) -> [CodexProgress] {
    guard
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let type = object["type"] as? String
    else {
      return []
    }
    if type == "turn.started" { return [.thinking] }
    if type == "turn.completed" {
      pendingAgentMessage = nil
      return []
    }
    guard type == "item.started" || type == "item.completed",
      let item = object["item"] as? [String: Any],
      let itemType = item["type"] as? String
    else {
      return []
    }

    if itemType == "collab_tool_call" || itemType == "collabToolCall" {
      guard let identifier = item["id"] as? String else { return [] }
      if type == "item.started" {
        activeWorkers.insert(identifier)
      } else {
        activeWorkers.remove(identifier)
      }
      return [.workers(activeWorkers.count)]
    }

    if itemType == "agent_message" || itemType == "AgentMessage" {
      guard let text = item["text"] as? String,
        let update = CodexEventParser.progressText(text)
      else {
        return []
      }
      if item["phase"] as? String == "commentary" { return [.update(update)] }
      var progress: [CodexProgress] = []
      if let previous = pendingAgentMessage { progress.append(.update(previous)) }
      pendingAgentMessage = update
      return progress
    }

    var progress = flushPendingMessage()
    guard type == "item.started" else { return progress }
    switch itemType {
    case "web_search", "webSearch": progress.append(.searching)
    case "command_execution", "commandExecution", "mcp_tool_call", "mcpToolCall",
      "file_change", "fileChange":
      progress.append(.working)
    default: break
    }
    return progress
  }

  private mutating func flushPendingMessage() -> [CodexProgress] {
    guard let message = pendingAgentMessage else { return [] }
    pendingAgentMessage = nil
    return [.update(message)]
  }
}

enum CodexEventParser {
  fileprivate static func progressText(_ text: String) -> String? {
    let normalized = text
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "`", with: "")
      .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(360))
  }

  static func parse(_ data: Data) -> CodexEventSummary {
    guard let output = String(data: data, encoding: .utf8) else {
      return CodexEventSummary(
        threadID: nil,
        messages: [],
        completed: false,
        diff: .empty
      )
    }

    var threadID: String?
    var messages: [String] = []
    var completed = false
    var added = 0
    var removed = 0

    for line in output.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = object["type"] as? String
      else {
        continue
      }

      switch type {
      case "thread.started":
        threadID = object["thread_id"] as? String
      case "item.completed":
        guard let item = object["item"] as? [String: Any] else { continue }
        if let itemType = item["type"] as? String,
          itemType == "file_change" || itemType == "fileChange"
        {
          let counts = diffCounts(item)
          added += counts.added
          removed += counts.removed
          continue
        }
        guard let itemType = item["type"] as? String,
          itemType == "agent_message" || itemType == "agentMessage" || itemType == "AgentMessage",
          item["phase"] as? String != "commentary",
          let text = item["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          continue
        }
        messages.append(text)
      case "turn.completed":
        completed = true
      default:
        continue
      }
    }

    return CodexEventSummary(
      threadID: threadID,
      messages: messages,
      completed: completed,
      diff: CodexDiffSummary(added: added, removed: removed)
    )
  }

  private static func diffCounts(_ item: [String: Any]) -> CodexDiffSummary {
    let values = (item["changes"] as? [[String: Any]])?.compactMap { $0["diff"] as? String }
      ?? [item["diff"] as? String].compactMap { $0 }
    return values.reduce(.empty) { total, diff in
      let lines = diff.split(whereSeparator: \.isNewline)
      let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
      let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
      return CodexDiffSummary(added: total.added + added, removed: total.removed + removed)
    }
  }
}
