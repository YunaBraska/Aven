import Foundation

@main
enum CodexMaintenanceTests {
  static func main() {
    installsOnlyTheCodexCaskWhenCodexIsMissing()
    updatesOnlyAHomebrewManagedCodex()
    activatesAnUntrustedUpdateWithAWarning()
    activatesLatestEvenWhenARequiredCapabilityIsMissing()
    retainsTheInstalledCaskWhenAnUpgradeFails()
    checksForUpdatesWeekly()
    clearsAResolvedLoginWarningWithinTheWeeklyWindow()
    adoptsLatestHomebrewCodexWithoutDeletingAnExistingExecutable()
    formatsThePersistedVersionForTheMenu()
    discoversTheVersionWithoutHomebrewOnFirstCheck()
    reportsMissingHomebrewWithoutTryingAnotherInstaller()
    boundsCommandOutputWhileReading()
    reportsACollectorThatDoesNotFinish()
    print("Codex maintenance tests passed")
  }

  private static func installsOnlyTheCodexCaskWhenCodexIsMissing() {
    withFixture { fixture in
      var installed = false
      var invocations: [[String]] = []
      let report = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        runner: { executable, arguments, environment, _ in
          invocations.append(arguments)
          if arguments.first == "update" || arguments.first == "list"
            || arguments.first == "install" || arguments.first == "outdated"
            || arguments.first == "upgrade"
          {
            expect(executable == fixture.brew, "package changes must use the configured Homebrew executable")
          }
          expect(environment["VOICE_ASSISTANT_CONTROL_TOKEN"] == nil, "Homebrew must not inherit app secrets")
          if arguments == ["list", "--cask", "codex"] {
            return result(output: installed ? fixture.codex.path + "\n" : "", status: installed ? 0 : 1)
          }
          if arguments == ["install", "--cask", "codex"] {
            installed = true
            return result()
          }
          return compatibleResult(arguments)
        },
        trustEvaluator: { _ in true }
      )

      expect(report.change == .installed, "missing Codex should be installed through Homebrew")
      expect(report.executableURL == fixture.codex, "the installed Cask executable should be activated")
      expect(invocations.contains(["install", "--cask", "codex"]), "installation must name only the Codex Cask")
      expect(!invocations.contains(["upgrade"]), "maintenance must never run a broad Homebrew upgrade")
    }
  }

  private static func updatesOnlyAHomebrewManagedCodex() {
    withFixture(currentCodex: true) { fixture in
      var invocations: [[String]] = []
      let report = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        runner: { _, arguments, _, _ in
          invocations.append(arguments)
          if arguments == ["list", "--cask", "codex"] {
            return result(output: fixture.codex.path + "\n")
          }
          if arguments == ["outdated", "--cask", "codex"] {
            return result(output: "codex\n", status: 1)
          }
          return compatibleResult(arguments)
        },
        trustEvaluator: { _ in true }
      )

      expect(report.change == .upgraded, "an outdated managed Cask should be upgraded")
      expect(invocations.contains(["upgrade", "--cask", "codex"]), "upgrade must target only Codex")
    }
  }

  private static func activatesAnUntrustedUpdateWithAWarning() {
    withFixture(currentCodex: true) { fixture in
      var upgraded = false
      let report = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        runner: { _, arguments, _, _ in
          if arguments == ["list", "--cask", "codex"] {
            return result(output: fixture.codex.path + "\n")
          }
          if arguments == ["outdated", "--cask", "codex"] {
            return result(output: "codex\n", status: 1)
          }
          if arguments == ["upgrade", "--cask", "codex"] {
            upgraded = true
            return result()
          }
          return compatibleResult(arguments)
        },
        trustEvaluator: { _ in !upgraded }
      )

      expect(report.change == .upgraded, "an untrusted update should still be activated")
      expect(report.executableURL == fixture.codex, "the latest Cask executable should stay active")
      expect(report.warnings.contains(where: { $0.contains("signature is not verified") }), "signature failure must be visible")
    }
  }

  private static func adoptsLatestHomebrewCodexWithoutDeletingAnExistingExecutable() {
    withFixture(currentCodex: true) { fixture in
      var installed = false
      let report = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        runner: { _, arguments, _, _ in
          if arguments == ["list", "--cask", "codex"] {
            return result(output: installed ? fixture.codex.path + "\n" : "", status: installed ? 0 : 1)
          }
          if arguments == ["install", "--cask", "codex"] {
            installed = true
            return result()
          }
          return compatibleResult(arguments)
        },
        trustEvaluator: { _ in true }
      )

      expect(report.executableURL == fixture.codex, "the latest Homebrew Codex should become selected")
      expect(report.change == .installed, "Homebrew Codex should be installed when only another executable exists")
      expect(FileManager.default.fileExists(atPath: fixture.codex.path), "the prior executable must not be deleted")
    }
  }

  private static func formatsThePersistedVersionForTheMenu() {
    withFixture { fixture in
      expect(CodexMaintenance.displayVersion(defaults: fixture.defaults) == "Codex —", "missing versions need a quiet placeholder")
      fixture.defaults.set("codex-cli 1.2.3", forKey: CodexMaintenance.lastVersionDefaultsKey)
      expect(CodexMaintenance.displayVersion(defaults: fixture.defaults) == "Codex 1.2.3", "the menu should avoid repeating the CLI product name")
    }
  }

  private static func discoversTheVersionWithoutHomebrewOnFirstCheck() {
    withFixture(currentCodex: true, includeBrew: false) { fixture in
      let report = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path],
        rootURL: fixture.root,
        runner: { _, arguments, _, _ in compatibleResult(arguments) },
        trustEvaluator: { _ in true }
      )

      expect(report.executableURL == fixture.codex, "a manually installed Codex should remain active")
      expect(
        CodexMaintenance.displayVersion(defaults: fixture.defaults) == "Codex test",
        "the first maintenance pass must populate the menu version without Homebrew"
      )
    }
  }

  private static func activatesLatestEvenWhenARequiredCapabilityIsMissing() {
    withFixture(currentCodex: true) { fixture in
      let report = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        runner: { _, arguments, _, _ in
        if arguments == ["list", "--cask", "codex"] {
          return result(output: fixture.codex.path + "\n")
        }
        if arguments == ["outdated", "--cask", "codex"] {
          return result(output: "codex\n", status: 1)
        }
          if arguments == ["exec", "--help"] { return result(output: "--json") }
          return compatibleResult(arguments)
        },
        trustEvaluator: { _ in true }
      )
      expect(report.executableURL == fixture.codex, "the latest Cask executable should remain active")
      expect(
        report.warnings.contains(where: { $0.contains("cannot run assistant tasks") }),
        "a missing required capability must be visible without blocking Codex"
      )
    }
  }

  private static func checksForUpdatesWeekly() {
    withFixture(currentCodex: true) { fixture in
      var outdatedChecks = 0
      let runner: CodexMaintenance.Runner = { _, arguments, _, _ in
        if arguments == ["list", "--cask", "codex"] { return result(output: fixture.codex.path + "\n") }
        if arguments == ["outdated", "--cask", "codex"] {
          outdatedChecks += 1
          return result()
        }
        return compatibleResult(arguments)
      }
      let first = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        now: Date(timeIntervalSince1970: 1_000_000),
        runner: runner,
        trustEvaluator: { _ in true }
      )
      let early = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        now: Date(timeIntervalSince1970: 1_000_000 + 86_400),
        runner: runner,
        trustEvaluator: { _ in true }
      )
      let weekly = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        now: Date(timeIntervalSince1970: 1_000_000 + 604_801),
        runner: runner,
        trustEvaluator: { _ in true }
      )
      expect(first.checked, "the initial check must run")
      expect(!early.checked, "a daily idle interval must not check Homebrew")
      expect(weekly.checked, "the weekly interval must check Homebrew again")
      expect(outdatedChecks == 2, "only the initial and weekly checks may query updates")
    }
  }

  private static func retainsTheInstalledCaskWhenAnUpgradeFails() {
    withFixture(currentCodex: true) { fixture in
      let report = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        runner: { _, arguments, _, _ in
          if arguments == ["list", "--cask", "codex"] {
            return result(output: fixture.codex.path + "\n")
          }
          if arguments == ["outdated", "--cask", "codex"] {
            return result(output: "codex\n")
          }
          if arguments == ["upgrade", "--cask", "codex"] {
            return result(error: "upgrade failed", status: 1)
          }
          return compatibleResult(arguments)
        },
        trustEvaluator: { _ in true }
      )

      expect(report.change == .none, "a failed upgrade must not be reported as successful")
      expect(report.executableURL == fixture.codex, "the still-installed Cask should remain active")
      expect(
        report.warnings.contains(where: { $0.contains("could not be updated") }),
        "the failed upgrade should remain visible"
      )
    }
  }

  private static func clearsAResolvedLoginWarningWithinTheWeeklyWindow() {
    withFixture(currentCodex: true) { fixture in
      var signedIn = false
      var version = "codex-cli 1.0"
      let runner: CodexMaintenance.Runner = { _, arguments, _, _ in
        if arguments == ["list", "--cask", "codex"] {
          return result(output: fixture.codex.path + "\n")
        }
        if arguments == ["outdated", "--cask", "codex"] { return result() }
        if arguments == ["login", "status"], !signedIn {
          return result(error: "not logged in", status: 1)
        }
        if arguments == ["--version"] { return result(output: version + "\n") }
        return compatibleResult(arguments)
      }
      let started = Date(timeIntervalSince1970: 2_000_000)
      let first = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        now: started,
        runner: runner,
        trustEvaluator: { _ in true }
      )
      expect(first.warnings.contains(where: { $0.hasPrefix("Codex sign-in is required") }), "signed-out state must warn")

      signedIn = true
      version = "codex-cli 1.1"
      let recovered = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: fixture.environment,
        rootURL: fixture.root,
        now: started.addingTimeInterval(60),
        runner: runner,
        trustEvaluator: { _ in true }
      )

      expect(!recovered.checked, "Homebrew must not run again inside the weekly interval")
      expect(!recovered.warnings.contains(where: { $0.hasPrefix("Codex sign-in is required") }), "resolved login warnings must clear promptly")
      expect(CodexMaintenance.displayVersion(defaults: fixture.defaults) == "Codex 1.1", "local version diagnostics should refresh without Homebrew")
    }
  }

  private static func reportsMissingHomebrewWithoutTryingAnotherInstaller() {
    withFixture(includeBrew: false) { fixture in
      var packageMutation = false
      let report = CodexMaintenance.maintain(
        defaults: fixture.defaults,
        environment: ["PATH": "/usr/bin:/bin"],
        rootURL: fixture.root,
        runner: { _, arguments, _, _ in
          if arguments.contains("install") || arguments.contains("upgrade") {
            packageMutation = true
          }
          return result(status: 1)
        },
        trustEvaluator: { _ in true }
      )

      expect(report.executableURL == nil, "Codex should remain unavailable without a package manager")
      expect(!packageMutation, "maintenance must not use another installer when Homebrew is absent")
      expect(report.warnings.first?.contains("Homebrew was not found") == true, "the missing dependency should be actionable")
    }
  }

  private static func boundsCommandOutputWhileReading() {
    let report = CodexMaintenance.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c", "i=0; while [ $i -lt 10000 ]; do printf 0123456789; i=$((i + 1)); done",
      ],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: 10
    )

    expect(!report.timedOut, "bounded output collection should finish normally")
    expect(report.output.utf8.count == 65_536, "only bounded command output should be retained")
  }

  private static func reportsACollectorThatDoesNotFinish() {
    let report = CodexMaintenance.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "(sleep 3; printf late) & exit 0"],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: 10
    )

    expect(report.timedOut, "a lingering inherited pipe must fail explicitly")
    expect(
      report.error.contains("could not be collected safely"),
      "collector failure should explain why the result was rejected"
    )
  }

  private struct Fixture {
    let root: URL
    let brew: URL
    let codex: URL
    let defaults: UserDefaults
    let suiteName: String

    var environment: [String: String] {
      [
        "PATH": "/usr/bin:/bin",
        "HOME": root.path,
        "VOICE_ASSISTANT_CONTROL_TOKEN": "must-not-leak",
      ]
    }
  }

  private static func withFixture(
    currentCodex: Bool = false,
    includeBrew: Bool = true,
    operation: (Fixture) -> Void
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-maintenance-\(UUID().uuidString)")
    let brew = root.appendingPathComponent("brew")
    let codex = root.appendingPathComponent("codex")
    let suiteName = "aven-maintenance-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { exit(1) }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if includeBrew { makeExecutable(brew) }
    makeExecutable(codex)
    if includeBrew { defaults.set(brew.path, forKey: CodexMaintenance.brewDefaultsKey) }
    if currentCodex { defaults.set(codex.path, forKey: CodexExecutableLocator.defaultsKey) }
    operation(Fixture(root: root, brew: brew, codex: codex, defaults: defaults, suiteName: suiteName))
  }

  private static func makeExecutable(_ url: URL) {
    try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private static func compatibleResult(_ arguments: [String]) -> CodexMaintenanceCommandResult {
    switch arguments {
    case ["update", "--quiet"], ["upgrade", "--cask", "codex"]:
      result()
    case ["exec", "--help"]:
      result(output: "--json --ignore-user-config --skip-git-repo-check --sandbox --config --disable --model --image --cd")
    case ["exec", "resume", "--help"]:
      result(output: "--json --ignore-user-config --skip-git-repo-check --config --disable --model --image")
    case ["features", "list"]:
      result(output: "plugins remote_plugin workspace_dependencies apps browser_use in_app_browser computer_use image_generation multi_agent hooks")
    case ["queue", "--help"]:
      result(output: "--thread --message")
    case ["app-server", "--help"]:
      result(output: "app-server")
    case ["--help"]:
      result(output: "--search")
    case ["delete", "--help"]:
      result(output: "--force")
    case ["login", "status"]:
      result(output: "Logged in using ChatGPT")
    case ["--version"]:
      result(output: "codex-cli test\n")
    default:
      result()
    }
  }

  private static func result(
    output: String = "",
    error: String = "",
    status: Int32 = 0,
    timedOut: Bool = false
  ) -> CodexMaintenanceCommandResult {
    CodexMaintenanceCommandResult(
      status: status,
      output: output,
      error: error,
      timedOut: timedOut
    )
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
      exit(1)
    }
  }
}
