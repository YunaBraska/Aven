import Darwin
import Foundation

struct CodexMaintenanceCommandResult: Equatable {
  let status: Int32
  let output: String
  let error: String
  let timedOut: Bool
}

struct CodexMaintenanceReport: Equatable {
  enum Change: Equatable {
    case none
    case installed
    case upgraded
  }

  let executableURL: URL?
  let change: Change
  let warnings: [String]
  let checked: Bool
}

enum CodexMaintenance {
  typealias Runner = (
    _ executable: URL, _ arguments: [String], _ environment: [String: String],
    _ timeout: TimeInterval
  ) -> CodexMaintenanceCommandResult
  typealias TrustEvaluator = (_ executable: URL) -> Bool

  static let brewDefaultsKey = "voiceAssistant.homebrewExecutablePath"
  static let lastCheckDefaultsKey = "voiceAssistant.codexMaintenance.lastCheck"
  static let lastMetadataUpdateDefaultsKey = "voiceAssistant.codexMaintenance.lastMetadataUpdate"
  static let lastVersionDefaultsKey = "voiceAssistant.codexMaintenance.lastVersion"
  static let warningsDefaultsKey = "voiceAssistant.codexMaintenance.warnings"

  private static let checkInterval: TimeInterval = 604_800
  private static let metadataInterval: TimeInterval = 604_800

  static func displayVersion(defaults: UserDefaults = .standard) -> String {
    guard var value = defaults.string(forKey: lastVersionDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return "Codex —" }
    if value.lowercased().hasPrefix("codex-cli ") {
      value.removeFirst("codex-cli ".count)
    }
    return "Codex \(value)"
  }

  static func maintain(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    rootURL _: URL = AssistantPaths.rootURL,
    now: Date = Date(),
    runner: Runner = run,
    trustEvaluator: TrustEvaluator = CodexExecutableLocator.hasTrustedCodexSignature
  ) -> CodexMaintenanceReport {
    let current = CodexExecutableLocator.locate(defaults: defaults, environment: environment)
    let lastCheck = defaults.object(forKey: lastCheckDefaultsKey) as? Date
    if current != nil, let lastCheck, now.timeIntervalSince(lastCheck) < checkInterval {
      let probeEnvironment = probeEnvironment(environment)
      if let current, let currentVersion = version(current, environment: probeEnvironment, runner: runner) {
        defaults.set(currentVersion, forKey: lastVersionDefaultsKey)
      }
      var warnings = (defaults.stringArray(forKey: warningsDefaultsKey) ?? []).filter {
        !$0.hasPrefix("Codex sign-in is required")
      }
      if let current {
        warnings.append(contentsOf: loginWarnings(
          for: current, environment: probeEnvironment, runner: runner
        ))
      }
      return report(
        defaults: defaults,
        executableURL: current,
        change: .none,
        warnings: warnings,
        checked: false
      )
    }
    defaults.set(now, forKey: lastCheckDefaultsKey)

    guard let brew = locateBrew(defaults: defaults, environment: environment, runner: runner) else {
      let diagnosticsEnvironment = probeEnvironment(environment)
      if let current, let currentVersion = version(
        current, environment: diagnosticsEnvironment, runner: runner
      ) {
        defaults.set(currentVersion, forKey: lastVersionDefaultsKey)
      }
      let warning = current == nil
        ? "Codex is missing and Homebrew was not found. Install Homebrew or Codex manually."
        : nil
      return report(
        defaults: defaults,
        executableURL: current,
        change: .none,
        warnings: warning.map { [$0] } ?? diagnosticWarnings(
          for: current!, environment: diagnosticsEnvironment, runner: runner,
          trustEvaluator: trustEvaluator
        ),
        checked: true
      )
    }

    let brewEnvironment = packageEnvironment(environment, brew: brew)
    var warnings: [String] = []
    var caskExecutables = installedCaskExecutables(
      brew: brew, environment: brewEnvironment, runner: runner
    )
    if let lastMetadataUpdate = defaults.object(forKey: lastMetadataUpdateDefaultsKey) as? Date {
      if now.timeIntervalSince(lastMetadataUpdate) >= metadataInterval {
        let update = runner(brew, ["update", "--quiet"], brewEnvironment, 300)
        if update.status == 0, !update.timedOut {
          defaults.set(now, forKey: lastMetadataUpdateDefaultsKey)
        } else if current != nil {
          warnings.append("Codex update check could not refresh Homebrew metadata; current Codex remains usable.")
        }
      }
    } else {
      let update = runner(brew, ["update", "--quiet"], brewEnvironment, 300)
      if update.status == 0, !update.timedOut {
        defaults.set(now, forKey: lastMetadataUpdateDefaultsKey)
      } else if current != nil {
        warnings.append("Codex update check could not refresh Homebrew metadata; current Codex remains usable.")
      }
    }
    var change = CodexMaintenanceReport.Change.none

    if caskExecutables.isEmpty {
      let installation = runner(
        brew, ["install", "--cask", "codex"], brewEnvironment, 600
      )
      guard installation.status == 0, !installation.timedOut else {
        let retainedWarnings = current.map {
          diagnosticWarnings(
            for: $0, environment: probeEnvironment(environment), runner: runner,
            trustEvaluator: trustEvaluator
          )
        } ?? []
        return report(
          defaults: defaults,
          executableURL: current,
          change: .none,
          warnings: retainedWarnings + [
            "The latest Codex could not be installed through Homebrew: \(failureDetail(installation))"
          ],
          checked: true
        )
      }
      change = .installed
      caskExecutables = installedCaskExecutables(
        brew: brew, environment: brewEnvironment, runner: runner
      )
    } else {
      let outdated = runner(
        brew, ["outdated", "--cask", "codex"], brewEnvironment, 120
      )
      let codexIsOutdated = !outdated.timedOut
        && outdated.output.split(whereSeparator: \.isWhitespace).contains("codex")
      if codexIsOutdated {
        let upgrade = runner(
          brew, ["upgrade", "--cask", "codex"], brewEnvironment, 600
        )
        if upgrade.status == 0, !upgrade.timedOut {
          change = .upgraded
        } else {
          warnings.append("Codex could not be updated through Homebrew: \(failureDetail(upgrade))")
        }
        caskExecutables = installedCaskExecutables(
          brew: brew, environment: brewEnvironment, runner: runner
        )
      } else if outdated.status != 0 || outdated.timedOut {
        warnings.append("Codex update availability could not be checked; current Codex remains usable.")
      }
    }

    let candidate = caskExecutables.first ?? current.flatMap(CodexExecutableLocator.validated)
    guard let candidate else {
      return report(
        defaults: defaults,
        executableURL: current,
        change: .none,
        warnings: ["Homebrew did not expose an executable Codex after maintenance."],
        checked: true
      )
    }

    let probeWarnings = diagnosticWarnings(
      for: candidate, environment: probeEnvironment(environment), runner: runner,
      trustEvaluator: trustEvaluator
    )
    defaults.set(candidate.path, forKey: CodexExecutableLocator.defaultsKey)
    defaults.removeObject(forKey: CodexExecutableLocator.blockedDefaultsKey)
    if let version = version(
      candidate, environment: probeEnvironment(environment), runner: runner
    ) {
      defaults.set(version, forKey: lastVersionDefaultsKey)
    }
    warnings.append(contentsOf: probeWarnings)
    return report(
      defaults: defaults,
      executableURL: candidate,
      change: change,
      warnings: Array(Set(warnings)).sorted(),
      checked: true
    )
  }

  private static func report(
    defaults: UserDefaults,
    executableURL: URL?,
    change: CodexMaintenanceReport.Change,
    warnings: [String],
    checked: Bool
  ) -> CodexMaintenanceReport {
    let uniqueWarnings = Array(Set(warnings)).sorted()
    if uniqueWarnings.isEmpty {
      defaults.removeObject(forKey: warningsDefaultsKey)
    } else {
      defaults.set(uniqueWarnings, forKey: warningsDefaultsKey)
    }
    return CodexMaintenanceReport(
      executableURL: executableURL,
      change: change,
      warnings: uniqueWarnings,
      checked: checked
    )
  }

  private static func locateBrew(
    defaults: UserDefaults,
    environment: [String: String],
    runner: Runner
  ) -> URL? {
    let configured = [
      defaults.string(forKey: brewDefaultsKey),
      environment["VOICE_ASSISTANT_HOMEBREW_EXECUTABLE"],
    ]
    for path in configured.compactMap({ $0 }) {
      if let executable = CodexExecutableLocator.validated(URL(fileURLWithPath: path)) {
        defaults.set(executable.path, forKey: brewDefaultsKey)
        return executable
      }
    }
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
        .appendingPathComponent("brew")
      if let executable = CodexExecutableLocator.validated(candidate) {
        defaults.set(executable.path, forKey: brewDefaultsKey)
        return executable
      }
    }
    let pathHelper = URL(fileURLWithPath: "/usr/libexec/path_helper")
    guard let helper = CodexExecutableLocator.validated(pathHelper) else { return nil }
    let result = runner(helper, ["-s"], probeEnvironment(environment), 10)
    guard result.status == 0, !result.timedOut,
      let discoveredPath = pathValue(from: result.output)
    else { return nil }
    for directory in discoveredPath.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
        .appendingPathComponent("brew")
      if let executable = CodexExecutableLocator.validated(candidate) {
        defaults.set(executable.path, forKey: brewDefaultsKey)
        return executable
      }
    }
    return nil
  }

  private static func installedCaskExecutables(
    brew: URL,
    environment: [String: String],
    runner: Runner
  ) -> [URL] {
    let result = runner(brew, ["list", "--cask", "codex"], environment, 60)
    guard result.status == 0, !result.timedOut else { return [] }
    return result.output.split(whereSeparator: \.isNewline).compactMap { line in
      let url = URL(fileURLWithPath: String(line)).standardizedFileURL
      guard url.lastPathComponent == "codex" else { return nil }
      return CodexExecutableLocator.validated(url)
    }
  }

  private static func capabilityWarnings(
    for executable: URL,
    environment: [String: String],
    runner: Runner
  ) -> [String] {
    let exec = runner(executable, ["exec", "--help"], environment, 20)
    let execHelp = exec.output + exec.error
    let coreFlags = [
      "--json", "--ignore-user-config", "--skip-git-repo-check", "--sandbox", "--config",
      "--disable", "--model", "--image", "--cd",
    ]
    guard exec.status == 0, !exec.timedOut,
      coreFlags.allSatisfy(execHelp.contains)
    else {
      return ["Codex cannot run assistant tasks with the required non-interactive interface."]
    }

    var warnings: [String] = []
    let resume = runner(executable, ["exec", "resume", "--help"], environment, 20)
    let resumeHelp = resume.output + resume.error
    let resumeFlags = [
      "--json", "--ignore-user-config", "--skip-git-repo-check", "--config", "--disable",
      "--model", "--image",
    ]
    if resume.status != 0 || resume.timedOut || !resumeFlags.allSatisfy(resumeHelp.contains) {
      warnings.append("Codex conversation resume is unavailable; new conversations still work.")
    }
    let queue = runner(executable, ["queue", "--help"], environment, 20)
    let queueHelp = queue.output + queue.error
    if queue.status != 0 || queue.timedOut || !queueHelp.contains("--thread")
      || !queueHelp.contains("--message")
    {
      warnings.append("Codex steering is unavailable; active work can still finish.")
    }
    let global = runner(executable, ["--help"], environment, 20)
    if global.status != 0 || global.timedOut
      || !(global.output + global.error).contains("--search")
    {
      warnings.append("Codex web search is unavailable; other assistant work can continue.")
    }
    let deletion = runner(executable, ["delete", "--help"], environment, 20)
    if deletion.status != 0 || deletion.timedOut
      || !(deletion.output + deletion.error).contains("--force")
    {
      warnings.append("Stored Codex task cleanup is unavailable; conversations remain usable.")
    }
    warnings.append(contentsOf: loginWarnings(
      for: executable, environment: environment, runner: runner
    ))
    return warnings
  }

  private static func loginWarnings(
    for executable: URL,
    environment: [String: String],
    runner: Runner
  ) -> [String] {
    let login = runner(executable, ["login", "status"], environment, 20)
    let loginText = (login.output + login.error).lowercased()
    if login.status != 0,
      loginText.contains("not logged") || loginText.contains("login")
    {
      return ["Codex sign-in is required. Run codex login once in Terminal."]
    }
    return []
  }

  private static func diagnosticWarnings(
    for executable: URL,
    environment: [String: String],
    runner: Runner,
    trustEvaluator: TrustEvaluator
  ) -> [String] {
    var warnings = capabilityWarnings(for: executable, environment: environment, runner: runner)
    if !trustEvaluator(executable) {
      warnings.append("Codex signature is not verified. The configured executable remains usable.")
    }
    return warnings
  }

  private static func version(
    _ executable: URL,
    environment: [String: String],
    runner: Runner
  ) -> String? {
    let result = runner(executable, ["--version"], environment, 20)
    guard result.status == 0, !result.timedOut else { return nil }
    let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : String(value.prefix(120))
  }

  private static func pathValue(from output: String) -> String? {
    guard let start = output.range(of: "PATH=\"")?.upperBound,
      let end = output[start...].firstIndex(of: "\"")
    else { return nil }
    return String(output[start..<end])
  }

  private static func packageEnvironment(
    _ source: [String: String],
    brew: URL
  ) -> [String: String] {
    var value = probeEnvironment(source)
    value["PATH"] = "\(brew.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
    value["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    value["HOMEBREW_NO_ANALYTICS"] = "1"
    value["HOMEBREW_NO_ENV_HINTS"] = "1"
    return value
  }

  private static func probeEnvironment(_ source: [String: String]) -> [String: String] {
    let allowed = ["HOME", "LANG", "LC_ALL", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER"]
    return Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
      source[key].map { (key, $0) }
    })
  }

  private static func failureDetail(_ result: CodexMaintenanceCommandResult) -> String {
    if result.timedOut { return "the command timed out" }
    let value = (result.error.isEmpty ? result.output : result.error)
      .split(whereSeparator: \.isNewline)
      .suffix(2)
      .joined(separator: " ")
    if value.isEmpty { return "Homebrew exited with status \(result.status)" }
    return String(value.prefix(240))
  }

  static func run(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    timeout: TimeInterval
  ) -> CodexMaintenanceCommandResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
      _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
    } catch {
      return CodexMaintenanceCommandResult(
        status: 126, output: "", error: "the command could not start", timedOut: false
      )
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var output = Data()
    var errors = Data()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      let value = readBounded(stdout.fileHandleForReading, limit: 65_536)
      lock.withMaintenanceLock { output = value }
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      let value = readBounded(stderr.fileHandleForReading, limit: 65_536)
      lock.withMaintenanceLock { errors = value }
      group.leave()
    }

    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      timedOut = true
      _ = Darwin.kill(-process.processIdentifier, SIGTERM)
      process.terminate()
      Thread.sleep(forTimeInterval: 0.2)
      if process.isRunning {
        _ = Darwin.kill(-process.processIdentifier, SIGKILL)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }
    process.waitUntilExit()
    guard group.wait(timeout: .now() + 2) == .success else {
      return CodexMaintenanceCommandResult(
        status: process.terminationStatus,
        output: "",
        error: "command output could not be collected safely",
        timedOut: true
      )
    }
    return lock.withMaintenanceLock {
      CodexMaintenanceCommandResult(
        status: process.terminationStatus,
        output: String(decoding: output, as: UTF8.self),
        error: String(decoding: errors, as: UTF8.self),
        timedOut: timedOut
      )
    }
  }

  private static func readBounded(_ handle: FileHandle, limit: Int) -> Data {
    var retained = Data()
    while true {
      let chunk = handle.readData(ofLength: 16_384)
      if chunk.isEmpty { return retained }
      if retained.count < limit {
        retained.append(chunk.prefix(limit - retained.count))
      }
    }
  }
}

private extension NSLock {
  func withMaintenanceLock<T>(_ operation: () -> T) -> T {
    lock()
    defer { unlock() }
    return operation()
  }
}
