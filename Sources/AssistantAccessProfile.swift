import Foundation

enum AssistantAccessProfile: String, CaseIterable, Identifiable {
  case fullAccess = "full-access"
  case askForApproval = "ask-for-approval"
  case approveForMe = "approve-for-me"
  case custom = "custom"

  static let defaultsKey = "voiceAssistant.accessProfile"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .fullAccess:
      "Full Access"
    case .askForApproval:
      "Ask for Approval"
    case .approveForMe:
      "Approve for Me"
    case .custom:
      "Custom / config.toml"
    }
  }

  static func load(defaults: UserDefaults = .standard) -> AssistantAccessProfile {
    guard let rawValue = defaults.string(forKey: defaultsKey), let profile = Self(rawValue: rawValue)
    else { return .fullAccess }
    return profile
  }

  func save(defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.defaultsKey)
  }

  func selection(using capabilities: CodexExecCapabilities) -> CodexAccessProfileSelection {
    switch self {
    case .custom:
      return .arguments([])
    case .fullAccess:
      guard capabilities.supportsFullAccess else {
        return .unavailable("This Codex installation cannot provide Full Access from codex exec.")
      }
      return .arguments([
        "--ignore-user-config",
        "--config", "sandbox_mode=\"danger-full-access\"",
        "--config", "approval_policy=\"never\"",
      ])
    case .askForApproval:
      guard capabilities.supportsAskForApproval else {
        return .unavailable(
          "Ask for Approval requires Codex config overrides and isolated user configuration."
        )
      }
      return .arguments([
        "--ignore-user-config",
        "--config", "sandbox_mode=\"workspace-write\"",
        "--config", "approval_policy=\"on-request\"",
      ])
    case .approveForMe:
      guard capabilities.supportsApproveForMe else {
        return .unavailable(
          "Approve for Me requires Codex config overrides and isolated user configuration."
        )
      }
      return .arguments([
        "--ignore-user-config",
        "--config", "sandbox_mode=\"workspace-write\"",
        "--config", "approval_policy=\"on-request\"",
        "--config", "approvals_reviewer=\"auto_review\"",
      ])
    }
  }
}

enum CodexAccessProfileSelection: Equatable {
  case arguments([String])
  case unavailable(String)
}

struct CodexExecCapabilities: Equatable {
  let config: Bool
  let ignoreUserConfig: Bool
  let askForApproval: Bool

  init(helpText: String) {
    let normalized = helpText.lowercased()
    config = Self.containsOption("--config", in: normalized)
    ignoreUserConfig = Self.containsOption("--ignore-user-config", in: normalized)
    askForApproval = Self.containsOption("--ask-for-approval", in: normalized)
  }

  var supportsFullAccess: Bool {
    ignoreUserConfig && config
  }

  var supportsAskForApproval: Bool {
    ignoreUserConfig && config && askForApproval
  }

  var supportsApproveForMe: Bool {
    ignoreUserConfig && config
  }

  private static func containsOption(_ option: String, in helpText: String) -> Bool {
    helpText.split(whereSeparator: \.isNewline).contains { $0.contains(option) }
  }
}
