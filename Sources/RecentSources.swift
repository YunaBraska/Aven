import Foundation

struct RecentSource: Codable, Equatable, Identifiable {
  enum Kind: String, Codable {
    case file
    case web
  }

  let kind: Kind
  let url: URL
  let recordedAt: Date

  var id: String { "\(kind.rawValue):\(url.absoluteString)" }
}

/// Persists a small, project-scoped list of files and web pages observed in Codex events.
/// It intentionally excludes commands and command output, which can contain sensitive material.
final class RecentSourcesStore: @unchecked Sendable {
  static let maximumItemsPerKind = 16
  private let storageURL: URL
  private let lock = NSLock()
  private var records: [String: [RecentSource]]

  init(workspaceURL: URL = AssistantPaths.workspaceURL) {
    storageURL = workspaceURL.appendingPathComponent("recent-sources.json")
    records = Self.load(storageURL: storageURL)
    if FileManager.default.fileExists(atPath: storageURL.path) {
      persist(records, to: storageURL)
    }
  }

  func sources(for projectKey: String, kind: RecentSource.Kind) -> [RecentSource] {
    lock.lock()
    defer { lock.unlock() }
    return (records[Self.projectKey(projectKey)] ?? []).filter { $0.kind == kind }
  }

  func sources(for projectKey: String) -> [RecentSource] {
    lock.lock()
    defer { lock.unlock() }
    return (records[Self.projectKey(projectKey)] ?? []).sorted { $0.recordedAt > $1.recordedAt }
  }

  func record(events data: Data, projectKey: String, now: Date = Date()) {
    let candidates = Self.extract(from: data)
    guard !candidates.isEmpty else { return }
    record(candidates, projectKey: projectKey, now: now)
  }

  func record(_ candidates: [RecentSource], projectKey: String, now: Date = Date()) {
    guard !candidates.isEmpty else { return }
    let key = Self.projectKey(projectKey)
    lock.lock()
    let existing = records[key] ?? []
    let normalized = candidates.compactMap { candidate in
      Self.canonicalURL(candidate.url, kind: candidate.kind).map {
        RecentSource(kind: candidate.kind, url: $0, recordedAt: now)
      }
    }
    guard !normalized.isEmpty else {
      lock.unlock()
      return
    }
    var merged = normalized + existing
    merged.sort { $0.recordedAt > $1.recordedAt }
    var seen = Set<String>()
    merged = merged.filter { seen.insert($0.id).inserted }
    let files = Array(merged.filter { $0.kind == .file }.prefix(Self.maximumItemsPerKind))
    let web = Array(merged.filter { $0.kind == .web }.prefix(Self.maximumItemsPerKind))
    records[key] = (files + web).sorted { $0.recordedAt > $1.recordedAt }
    let snapshot = records
    lock.unlock()
    persist(snapshot, to: storageURL)
  }

  static func extract(from data: Data) -> [RecentSource] {
    data.split(separator: 0x0A).flatMap { line in
      guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        return [RecentSource]()
      }
      return extract(event: event)
    }
  }

  private static func extract(event: [String: Any]) -> [RecentSource] {
    guard let item = event["item"] as? [String: Any],
      let type = (item["type"] as? String)?.lowercased()
    else { return [] }
    switch type {
    case "file_change", "filechange":
      return (item["changes"] as? [[String: Any]] ?? []).compactMap { change in
        fileSource(change["path"] as? String)
      }
    case "image_view", "imageview":
      return [fileSource(item["path"] as? String)].compactMap { $0 }
    case "user_message", "usermessage":
      return localImages(in: item)
    case "web_search", "websearch":
      return webAction(item["action"] as? [String: Any])
    case "agent_message", "agentmessage":
      guard item["phase"] as? String != "commentary", let text = item["text"] as? String else { return [] }
      return markdownLinks(in: text)
    default:
      return []
    }
  }

  private static func localImages(in item: [String: Any]) -> [RecentSource] {
    let content = item["content"] as? [[String: Any]] ?? []
    return content.compactMap { value in
      let type = (value["type"] as? String)?.lowercased()
      guard type == "local_image" || type == "localimage" else { return nil }
      return fileSource((value["path"] as? String) ?? (value["image_path"] as? String))
    }
  }

  private static func webAction(_ action: [String: Any]?) -> [RecentSource] {
    guard let action,
      let type = (action["type"] as? String)?.lowercased(),
      type == "open_page" || type == "openpage" || type == "find_in_page" || type == "findinpage",
      let url = action["url"] as? String,
      let source = webSource(url)
    else { return [] }
    return [source]
  }

  private static func markdownLinks(in text: String) -> [RecentSource] {
    var values: [RecentSource] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
      let marker = text.range(of: "](", range: searchStart..<text.endIndex)
    {
      var index = marker.upperBound
      let destinationStart = index
      var depth = 1
      var escaped = false
      while index < text.endIndex {
        let character = text[index]
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "(" {
          depth += 1
        } else if character == ")" {
          depth -= 1
          if depth == 0 { break }
        }
        index = text.index(after: index)
      }
      guard depth == 0 else { break }
      if let source = webSource(String(text[destinationStart..<index])) { values.append(source) }
      searchStart = text.index(after: index)
    }
    return values
  }

  private static func fileSource(_ path: String?) -> RecentSource? {
    guard let path, path.hasPrefix("/") else { return nil }
    return RecentSource(kind: .file, url: URL(fileURLWithPath: path), recordedAt: Date.distantPast)
  }

  private static func webSource(_ raw: String) -> RecentSource? {
    guard let url = URL(string: raw) else { return nil }
    return RecentSource(kind: .web, url: url, recordedAt: Date.distantPast)
  }

  private static func canonicalURL(_ url: URL, kind: RecentSource.Kind) -> URL? {
    switch kind {
    case .file:
      guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
      return url.standardizedFileURL
    case .web:
      guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let scheme = components.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        let host = components.host?.lowercased(), !host.isEmpty
      else { return nil }
      components.scheme = scheme
      components.host = host
      components.fragment = nil
      components.query = nil
      return components.url
    }
  }

  private static func projectKey(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "general" : trimmed
  }

  private static func load(storageURL: URL) -> [String: [RecentSource]] {
    guard let data = try? Data(contentsOf: storageURL),
      let decoded = try? JSONDecoder().decode([String: [RecentSource]].self, from: data)
    else { return [:] }
    return decoded.mapValues { items in
      var seen = Set<String>()
      let normalized = items.compactMap { item in
        canonicalURL(item.url, kind: item.kind).map {
          RecentSource(kind: item.kind, url: $0, recordedAt: item.recordedAt)
        }
      }.sorted { $0.recordedAt > $1.recordedAt }.filter { seen.insert($0.id).inserted }
      return Array(normalized.filter { $0.kind == .file }.prefix(maximumItemsPerKind))
        + Array(normalized.filter { $0.kind == .web }.prefix(maximumItemsPerKind))
    }
  }

  private func persist(_ snapshot: [String: [RecentSource]], to url: URL) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".recent-sources-\(UUID().uuidString)")
    do {
      try data.write(to: temporary, options: .atomic)
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url, options: .atomic) }
    }
  }
}
