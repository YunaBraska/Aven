import Darwin
import Foundation

/// Builds optional Codex feature arguments from the executable's live feature catalog.
///
/// Unknown or removed features are omitted. A failed probe therefore disables only isolation
/// refinements; it never prevents an ordinary Codex request from starting.
enum CodexFeatureIsolation {
  static let optionalFeatures = [
    "plugins", "remote_plugin", "workspace_dependencies", "apps", "browser_use",
    "in_app_browser", "computer_use", "image_generation", "multi_agent", "hooks",
  ]

  private static let cacheDuration: TimeInterval = 6 * 60 * 60
  private static let failedProbeCacheDuration: TimeInterval = 1
  private static let maximumOutputBytes = 256 * 1_024
  private static let cache = FeatureCache()

  static func disableArguments(
    executableURL: URL,
    environment: [String: String],
    workspaceURL: URL,
    desired: [String] = optionalFeatures
  ) -> [String] {
    let available = cache.features(
      key: cacheKey(executableURL),
      maxAge: cacheDuration,
      failureMaxAge: failedProbeCacheDuration
    ) {
      discover(
        executableURL: executableURL,
        environment: environment,
        workspaceURL: workspaceURL
      )
    }
    return disableArguments(desired: desired, available: available ?? [])
  }

  static func disableArguments(desired: [String], featureList: String) -> [String] {
    disableArguments(desired: desired, available: featureNames(in: featureList))
  }

  static func featureNames(in output: String) -> Set<String> {
    Set(output.split(whereSeparator: \.isNewline).compactMap { line in
      guard let first = line.split(whereSeparator: \.isWhitespace).first else { return nil }
      let name = String(first)
      guard name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_-]*$"#, options: .regularExpression)
        != nil
      else { return nil }
      return name
    })
  }

  static func invalidate(executableURL: URL? = nil) {
    cache.invalidate(key: executableURL.map(cacheKey))
  }

  private static func disableArguments(desired: [String], available: Set<String>) -> [String] {
    desired.filter(available.contains).flatMap { ["--disable", $0] }
  }

  private static func cacheKey(_ executableURL: URL) -> String {
    let url = executableURL.standardizedFileURL
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    let size = values?.fileSize ?? 0
    return "\(url.path)|\(modified)|\(size)"
  }

  private static func discover(
    executableURL: URL,
    environment: [String: String],
    workspaceURL: URL
  ) -> Set<String>? {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executableURL
    process.arguments = ["features", "list"]
    process.environment = environment
    process.currentDirectoryURL = workspaceURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors

    let group = DispatchGroup()
    let lock = NSLock()
    var retained = Data()
    var overflow = false
    for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
      group.enter()
      DispatchQueue.global(qos: .utility).async {
        while true {
          let chunk = handle.readData(ofLength: 8_192)
          if chunk.isEmpty { break }
          lock.lock()
          if retained.count < maximumOutputBytes {
            retained.append(chunk.prefix(maximumOutputBytes - retained.count))
          } else {
            overflow = true
          }
          lock.unlock()
        }
        group.leave()
      }
    }

    do {
      try process.run()
      _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
    } catch {
      return nil
    }
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      _ = Darwin.kill(-process.processIdentifier, SIGTERM)
      _ = Darwin.kill(process.processIdentifier, SIGTERM)
    }
    if group.wait(timeout: .now() + 1) == .timedOut {
      _ = Darwin.kill(-process.processIdentifier, SIGKILL)
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
      _ = group.wait(timeout: .now() + 1)
    }
    process.waitUntilExit()
    lock.lock()
    let data = retained
    let exceededLimit = overflow
    lock.unlock()
    guard process.terminationStatus == 0, !exceededLimit else { return nil }
    let names = featureNames(in: String(decoding: data, as: UTF8.self))
    return names.isEmpty ? nil : names
  }
}

private final class FeatureCache: @unchecked Sendable {
  private struct Entry {
    let loadedAt: Date
    let value: Set<String>?
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var loads: [String: DispatchGroup] = [:]

  func features(
    key: String,
    maxAge: TimeInterval,
    failureMaxAge: TimeInterval,
    loader: () -> Set<String>?
  ) -> Set<String>? {
    while true {
      lock.lock()
      if let entry = entries[key] {
        let age = Date().timeIntervalSince(entry.loadedAt)
        let entryMaxAge = entry.value == nil ? failureMaxAge : maxAge
        if age < entryMaxAge {
          lock.unlock()
          return entry.value
        }
      }
      if let load = loads[key] {
        lock.unlock()
        load.wait()
        continue
      }
      let load = DispatchGroup()
      load.enter()
      loads[key] = load
      lock.unlock()

      let loaded = loader()

      lock.lock()
      entries[key] = Entry(loadedAt: Date(), value: loaded)
      loads.removeValue(forKey: key)
      load.leave()
      lock.unlock()
      return loaded
    }
  }

  func invalidate(key: String?) {
    lock.lock()
    if let key {
      entries.removeValue(forKey: key)
    } else {
      entries.removeAll()
    }
    lock.unlock()
  }
}
