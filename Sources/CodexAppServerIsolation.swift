import Darwin
import Foundation

enum CodexAppServerIsolation {
  private static let commonConfiguration = [
    "notify=[]",
    "model_provider=\"openai\"",
    "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"",
    "otel.exporter=\"none\"",
    "otel.trace_exporter=\"none\"",
    "otel.metrics_exporter=\"none\"",
    "otel.log_user_prompt=false",
    "analytics.enabled=false",
  ]

  static func configuration(
    executableURL: URL,
    environment: [String: String],
    workspaceURL: URL,
    timeout: TimeInterval = 3
  ) -> [String]? {
    let probeArguments = ["login", "status"]
      + commonConfiguration.flatMap { ["--config", $0] }
    guard let status = run(
      executableURL: executableURL,
      arguments: probeArguments,
      environment: environment,
      workspaceURL: workspaceURL,
      timeout: timeout
    ) else { return nil }
    return configuration(loginStatus: status)
  }

  static func configuration(loginStatus: String) -> [String]? {
    let normalized = loginStatus.lowercased()
    let endpoint: String
    if normalized.contains("api key") {
      endpoint = "https://api.openai.com/v1"
    } else if normalized.contains("chatgpt") {
      endpoint = "https://chatgpt.com/backend-api/codex"
    } else {
      return nil
    }
    return commonConfiguration + ["openai_base_url=\"\(endpoint)\""]
  }

  private static func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    workspaceURL: URL,
    timeout: TimeInterval
  ) -> String? {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workspaceURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
      _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
    } catch {
      return nil
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var output = Data()
    var error = Data()
    for (handle, target) in [
      (stdout.fileHandleForReading, true),
      (stderr.fileHandleForReading, false),
    ] {
      group.enter()
      DispatchQueue.global(qos: .utility).async {
        let value = readBounded(handle, limit: 8_192)
        lock.lock()
        if target { output = value } else { error = value }
        lock.unlock()
        group.leave()
      }
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      _ = Darwin.kill(-process.processIdentifier, SIGTERM)
      _ = Darwin.kill(process.processIdentifier, SIGTERM)
      Thread.sleep(forTimeInterval: 0.1)
      if process.isRunning {
        _ = Darwin.kill(-process.processIdentifier, SIGKILL)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      group.wait(timeout: .now() + 1) == .success
    else { return nil }
    lock.lock()
    let text = String(decoding: output + error, as: UTF8.self)
    lock.unlock()
    return text
  }

  private static func readBounded(_ handle: FileHandle, limit: Int) -> Data {
    var retained = Data()
    while true {
      let chunk = handle.readData(ofLength: 4_096)
      if chunk.isEmpty { return retained }
      if retained.count < limit {
        retained.append(chunk.prefix(limit - retained.count))
      }
    }
  }
}
