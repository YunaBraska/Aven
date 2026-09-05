import AppKit
import Foundation

private struct CodexDesktopSupport {
  let installed: Bool
}

private final class CodexDesktopSupportCache: @unchecked Sendable {
  private let lock = NSLock()
  private var checkedAt: Date?
  private var support = CodexDesktopSupport(installed: false)

  func value(load: () -> CodexDesktopSupport) -> CodexDesktopSupport {
    lock.lock()
    defer { lock.unlock() }
    if let checkedAt, Date().timeIntervalSince(checkedAt) < 300 {
      return support
    }
    support = load()
    checkedAt = Date()
    return support
  }
}

enum CodexChatDestination: Equatable {
  case chat(URL)
  case transcript(URL)

  var menuTitle: String {
    "Open Chat"
  }
}

enum CodexChatOpenResult: Equatable {
  case desktop
  case terminal
  case transcript
  case unavailable
}

struct ChatOpenGate {
  private(set) var isOpening = false
  private var lastFinishedAt = Date.distantPast

  mutating func begin(at date: Date = Date(), cooldown: TimeInterval = 2) -> Bool {
    guard !isOpening, date.timeIntervalSince(lastFinishedAt) >= cooldown else { return false }
    isOpening = true
    return true
  }

  mutating func finish(at date: Date = Date()) {
    isOpening = false
    lastFinishedAt = date
  }
}

enum CodexChatLauncher {
  private static let desktopSupportCache = CodexDesktopSupportCache()
  private static let terminalApplicationScript = """
    on run argv
      set codexPath to item 1 of argv
      set configOption to item 2 of argv
      set configValue to item 3 of argv
      set resumeCommand to item 4 of argv
      set threadID to item 5 of argv
      set directoryOption to item 6 of argv
      set workspacePath to item 7 of argv
      tell application "Terminal"
        activate
        do script quoted form of codexPath & " " & quoted form of configOption & " " & quoted form of configValue & " " & quoted form of resumeCommand & " " & quoted form of threadID & " " & quoted form of directoryOption & " " & quoted form of workspacePath
      end tell
    end run
    """

  private static func desktopSupport() -> CodexDesktopSupport {
    desktopSupportCache.value {
      guard let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.openai.codex"
      ) else {
        return CodexDesktopSupport(installed: false)
      }
      return CodexDesktopSupport(installed: FileManager.default.fileExists(atPath: applicationURL.path))
    }
  }

  static func destination(threadID: String?, transcriptURL: URL?) -> CodexChatDestination? {
    guard let threadID, !threadID.isEmpty else { return nil }
    let support = desktopSupport()
    return destination(
      threadID: threadID,
      transcriptURL: transcriptURL,
      transcriptIsPaginated: transcriptURL.map { transcriptIsPaginated(at: $0) } ?? false,
      desktopInstalled: support.installed
    )
  }

  static func destination(
    threadID: String,
    transcriptURL: URL?,
    transcriptIsPaginated: Bool,
    desktopInstalled: Bool = true
  ) -> CodexChatDestination? {
    guard desktopInstalled else { return transcriptURL.map(CodexChatDestination.transcript) }
    if transcriptIsPaginated, let transcriptURL {
      return .transcript(transcriptURL)
    }
    guard let url = desktopURL(threadID: threadID) else { return nil }
    return .chat(url)
  }

  /// Opens an existing Codex conversation without exposing the assistant process environment.
  ///
  /// The desktop deep link is preferred. When it is unavailable or rejected, this launches a
  /// visible Terminal window that resumes a UUID-backed thread in the assistant workspace. A
  /// local transcript remains the final fallback.
  static func open(
    threadID: String?,
    transcriptURL: URL?,
    workspaceURL: URL = AssistantPaths.workspaceURL,
    desktopInstalled: Bool? = nil,
    urlOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) },
    executableLocator: () -> URL? = locateCodex,
    terminalLauncher: (URL, String, URL) -> Bool = launchTerminal
  ) -> CodexChatOpenResult {
    guard let threadID, !threadID.isEmpty else { return .unavailable }
    let paginated = transcriptURL.map { transcriptIsPaginated(at: $0) } ?? false
    let hasDesktop = desktopInstalled ?? desktopSupport().installed

    if hasDesktop, !paginated, let desktopURL = desktopURL(threadID: threadID), urlOpener(desktopURL) {
      return .desktop
    }

    if let validatedThreadID = validatedThreadID(threadID),
      let executableURL = executableLocator(),
      isExecutable(executableURL),
      terminalLauncher(executableURL, validatedThreadID, workspaceURL)
    {
      return .terminal
    }

    if let transcriptURL, urlOpener(transcriptURL) {
      return .transcript
    }
    return .unavailable
  }

  @MainActor
  static func openInApp(
    threadID: String?,
    transcriptURL: URL?,
    workspaceURL: URL = AssistantPaths.workspaceURL,
    executableURL: URL?,
    completion: @escaping (CodexChatOpenResult) -> Void
  ) {
    guard let threadID, !threadID.isEmpty else {
      completion(.unavailable)
      return
    }
    let paginated = transcriptURL.map { transcriptIsPaginated(at: $0) } ?? false
    if desktopSupport().installed, !paginated, let url = desktopURL(threadID: threadID),
      NSWorkspace.shared.open(url)
    {
      completion(.desktop)
      return
    }
    guard let validatedThreadID = validatedThreadID(threadID),
      let executableURL, isExecutable(executableURL)
    else {
      completion(openTranscript(transcriptURL))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let opened = launchTerminal(
        executableURL: executableURL,
        threadID: validatedThreadID,
        workspaceURL: workspaceURL
      )
      DispatchQueue.main.async {
        completion(opened ? .terminal : openTranscript(transcriptURL))
      }
    }
  }

  static func transcriptIsPaginated(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 262_144)) ?? Data()
    let line = data.prefix { $0 != 0x0A }
    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    else { return false }
    if object["ordinal"] != nil { return true }
    guard
      object["type"] as? String == "session_meta",
      let payload = object["payload"] as? [String: Any]
    else { return false }
    return payload["history_mode"] as? String == "paginated"
  }

  static func validatedThreadID(_ value: String) -> String? {
    guard let identifier = UUID(uuidString: value), identifier.uuidString.caseInsensitiveCompare(value) == .orderedSame
    else { return nil }
    return identifier.uuidString.lowercased()
  }

  static func terminalCodexArguments(threadID: String, workspaceURL: URL) -> [String]? {
    guard let threadID = validatedThreadID(threadID) else { return nil }
    return [
      "-c", "check_for_update_on_startup=false", "resume", threadID, "--cd", workspaceURL.path,
    ]
  }

  private static func desktopURL(threadID: String) -> URL? {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    guard let encoded = threadID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: "codex://threads/\(encoded)")
  }

  private static func locateCodex() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    let configured = environment["VOICE_ASSISTANT_CODEX_EXECUTABLE"].map(URL.init(fileURLWithPath:))
    let candidates = [configured].compactMap { $0 }
      + (environment["PATH"] ?? "").split(separator: ":").map {
        URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex")
      }
    return candidates.lazy.map { $0.resolvingSymlinksInPath().standardizedFileURL }.first(where: isExecutable)
  }

  private static func isExecutable(_ url: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    return resolved.path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: resolved.path)
  }

  private static func launchTerminal(executableURL: URL, threadID: String, workspaceURL: URL) -> Bool {
    guard let codexArguments = terminalCodexArguments(threadID: threadID, workspaceURL: workspaceURL)
    else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", terminalApplicationScript, executableURL.path] + codexArguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  @MainActor
  private static func openTranscript(_ transcriptURL: URL?) -> CodexChatOpenResult {
    guard let transcriptURL, NSWorkspace.shared.open(transcriptURL) else { return .unavailable }
    return .transcript
  }

}
