import Foundation

@main
enum RecentSourcesTests {
  static func main() {
    extractsOnlyRecognizedSources()
    persistsProjectScopedBoundedSources()
    redactsQueriesFromExistingStorage()
    print("Recent sources tests passed")
  }

  private static func extractsOnlyRecognizedSources() {
    let events = """
      {"type":"item.completed","item":{"type":"file_change","changes":[{"path":"/tmp/work/../work/file.swift"}]}}
      {"type":"item.completed","item":{"type":"image_view","path":"/tmp/screen.png"}}
      {"type":"item.completed","item":{"type":"user_message","content":[{"type":"local_image","path":"/tmp/local.png"}]}}
      {"type":"item.completed","item":{"type":"web_search","action":{"type":"open_page","url":"https://Example.COM/a?utm_source=x&keep=y#part"}}}
      {"type":"item.completed","item":{"type":"agent_message","phase":"final","text":"See [guide](https://example.com/guide)."}}
      {"type":"item.completed","item":{"type":"agent_message","phase":"final","text":"See [planet](https://en.wikipedia.org/wiki/Mercury_(planet))."}}
      {"type":"item.completed","item":{"type":"agent_message","phase":"commentary","text":"[ignore](https://example.com/no)"}}
      {"type":"item.completed","item":{"type":"fileChange","changes":[{"path":"/tmp/camel.swift"}]}}
      {"type":"item.completed","item":{"type":"webSearch","action":{"type":"openPage","url":"https://example.com/camel"}}}
      {"type":"item.completed","item":{"type":"command_execution","command":"cat .env"}}
      """
    let extracted = RecentSourcesStore.extract(from: Data(events.utf8))
    expect(extracted.filter { $0.kind == .file }.count == 4, "recognized file events should support both naming styles")
    expect(extracted.filter { $0.kind == .web }.count == 4, "recognized web events should support both naming styles")
    expect(
      extracted.contains { $0.url.absoluteString == "https://en.wikipedia.org/wiki/Mercury_(planet)" },
      "balanced parentheses in Markdown URLs must remain intact"
    )
  }

  private static func persistsProjectScopedBoundedSources() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("recent-sources-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecentSourcesStore(workspaceURL: root)
    let baseline = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0..<20 {
      store.record([
        RecentSource(kind: .file, url: URL(fileURLWithPath: "/tmp/source-\(index)"), recordedAt: .distantPast),
        RecentSource(kind: .web, url: URL(string: "https://example.com/\(index)?utm_campaign=x")!, recordedAt: .distantPast),
      ], projectKey: "project-a", now: baseline.addingTimeInterval(TimeInterval(index)))
    }
    store.record([
      RecentSource(kind: .file, url: URL(fileURLWithPath: "/tmp/other"), recordedAt: .distantPast),
    ], projectKey: "project-b", now: baseline)
    let reopened = RecentSourcesStore(workspaceURL: root)
    let files = reopened.sources(for: "project-a", kind: .file)
    let web = reopened.sources(for: "project-a", kind: .web)
    let combined = reopened.sources(for: "project-a")
    expect(files.count == 16 && web.count == 16, "each project and kind must remain bounded to sixteen entries")
    expect(files.first?.url.path == "/tmp/source-19", "newest sources should come first")
    expect(web.first?.url.absoluteString == "https://example.com/19", "tracking fragments must be removed from web URLs")
    expect(
      reopened.sources(for: "project-a").allSatisfy { $0.url.query == nil },
      "persisted source links must not retain query credentials"
    )
    expect(combined.count == 32, "the flat source list should retain both bounded kinds")
    expect(
      combined.prefix(2).map(\.kind).contains(.file)
        && combined.prefix(2).map(\.kind).contains(.web),
      "the flat source list should merge kinds by recency"
    )
    expect(reopened.sources(for: "project-b", kind: .file).count == 1, "projects must remain isolated")
  }

  private static func redactsQueriesFromExistingStorage() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("recent-source-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let storage = root.appendingPathComponent("recent-sources.json")
    let source = RecentSource(
      kind: .web,
      url: URL(string: "https://example.com/callback?code=secret-value")!,
      recordedAt: Date()
    )
    try! JSONEncoder().encode(["general": [source]]).write(to: storage)

    let store = RecentSourcesStore(workspaceURL: root)
    expect(store.sources(for: "general").first?.url.query == nil, "loaded links must be redacted")
    let persisted = try! String(contentsOf: storage, encoding: .utf8)
    expect(!persisted.contains("secret-value"), "legacy query credentials must be removed from disk")
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}
