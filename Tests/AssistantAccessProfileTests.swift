import Foundation

@main
enum AssistantAccessProfileTests {
  static func main() {
    parsesCapabilitiesFromExecHelp()
    producesFullAccessArguments()
    producesAskForApprovalArguments()
    reportsAskForApprovalAsUnavailableWhenUnsupported()
    producesApproveForMeArguments()
    fallsBackToExplicitApproveForMeArguments()
    respectsCustomConfig()
    persistsTheSelectedProfile()
    print("Assistant access profile tests passed")
  }

  private static func parsesCapabilitiesFromExecHelp() {
    let capabilities = CodexExecCapabilities(helpText: completeHelp)
    expect(capabilities.supportsFullAccess, "full access capability should be detected from exec help")
    expect(capabilities.supportsAskForApproval, "ask capability should be detected from exec help")
  }

  private static func producesFullAccessArguments() {
    let selection = AssistantAccessProfile.fullAccess.selection(using: .init(helpText: completeHelp))
    expect(
      selection == .arguments([
        "--ignore-user-config", "--config", "sandbox_mode=\"danger-full-access\"",
        "--config", "approval_policy=\"never\"",
      ]),
      "full access should override config, sandbox, and approval deterministically"
    )
  }

  private static func producesAskForApprovalArguments() {
    let selection = AssistantAccessProfile.askForApproval.selection(using: .init(helpText: completeHelp))
    expect(
      selection == .arguments([
        "--ignore-user-config", "--config", "sandbox_mode=\"workspace-write\"",
        "--config", "approval_policy=\"on-request\"",
      ]),
      "ask profile should use workspace write with on-request approval"
    )
  }

  private static func reportsAskForApprovalAsUnavailableWhenUnsupported() {
    let selection = AssistantAccessProfile.askForApproval.selection(
      using: .init(helpText: "--config <key=value>")
    )
    guard case .unavailable(let reason) = selection else {
      fail("unsupported ask profile must not emit misleading arguments")
    }
    expect(reason.contains("config"), "unavailability should name the missing config capability")
  }

  private static func producesApproveForMeArguments() {
    let selection = AssistantAccessProfile.approveForMe.selection(using: .init(helpText: completeHelp))
    expect(
      selection == .arguments([
        "--ignore-user-config", "--config", "sandbox_mode=\"workspace-write\"",
        "--config", "approval_policy=\"on-request\"",
        "--config", "approvals_reviewer=\"auto_review\"",
      ]),
      "approve-for-me should request Codex auto review through portable config overrides"
    )
  }

  private static func fallsBackToExplicitApproveForMeArguments() {
    let help = completeHelp.replacingOccurrences(of: "--approve-for-me", with: "")
    let selection = AssistantAccessProfile.approveForMe.selection(using: .init(helpText: help))
    expect(
      selection == .arguments([
        "--ignore-user-config", "--config", "sandbox_mode=\"workspace-write\"",
        "--config", "approval_policy=\"on-request\"",
        "--config", "approvals_reviewer=\"auto_review\"",
      ]),
      "approve-for-me must not depend on the shorthand option"
    )
  }

  private static func respectsCustomConfig() {
    let selection = AssistantAccessProfile.custom.selection(using: .init(helpText: ""))
    expect(selection == .arguments([]), "custom profile must leave sandbox and approval to config.toml")
  }

  private static func persistsTheSelectedProfile() {
    let suiteName = "assistant-access-profile-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { fail("isolated defaults should exist") }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    expect(AssistantAccessProfile.load(defaults: defaults) == .fullAccess, "the legacy default is full access")
    AssistantAccessProfile.custom.save(defaults: defaults)
    expect(AssistantAccessProfile.load(defaults: defaults) == .custom, "saved profile should survive reload")
    defaults.set("unknown", forKey: AssistantAccessProfile.defaultsKey)
    expect(AssistantAccessProfile.load(defaults: defaults) == .fullAccess, "invalid stored values should fall back safely")
  }

  private static let completeHelp = """
    --ignore-user-config
    --config <key=value>
    --sandbox <SANDBOX_MODE>
      [possible values: read-only, workspace-write, danger-full-access]
    --ask-for-approval <APPROVAL_POLICY>
      [possible values: untrusted, on-failure, on-request, never]
    --approve-for-me
    """

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}
