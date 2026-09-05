import Foundation
import Security

enum CodexExecutableLocator {
  static let defaultsKey = "voiceAssistant.codexExecutablePath"
  static let blockedDefaultsKey = "voiceAssistant.codexExecutableBlockedPath"

  static func locate(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    defaults.removeObject(forKey: blockedDefaultsKey)
    if let installed = defaults.string(forKey: defaultsKey),
      let executable = validated(URL(fileURLWithPath: installed))
    {
      return executable
    }
    if let configured = environment["VOICE_ASSISTANT_CODEX_EXECUTABLE"],
      let executable = validated(URL(fileURLWithPath: configured))
    {
      return executable
    }

    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
        .appendingPathComponent("codex")
      if let executable = validated(candidate) {
        return executable
      }
    }

    return nil
  }

  static func signatureWarning(for url: URL) -> String? {
    hasTrustedCodexSignature(url.resolvingSymlinksInPath().standardizedFileURL)
      ? nil
      : "Codex signature is not verified. The configured executable remains usable."
  }

  static func validated(_ url: URL) -> URL? {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: resolved.path),
      let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
      let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
      let owner = attributes[.ownerAccountID] as? NSNumber,
      owner.uint32Value == 0 || owner.uint32Value == getuid(),
      let permissions = attributes[.posixPermissions] as? NSNumber,
      permissions.intValue & 0o022 == 0
    else { return nil }
    return resolved
  }

  static func hasTrustedCodexSignature(_ url: URL) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
      let code
    else { return false }
    var requirement: SecRequirement?
    let expression =
      #"anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2""#
    guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
  }
}
