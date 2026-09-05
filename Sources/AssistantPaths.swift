import Foundation

enum AssistantPaths {
  static var rootURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Aven", isDirectory: true)
  }

  static var legacyApplicationSupportURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Voice Assistant", isDirectory: true)
  }

  static var workspaceURL: URL {
    rootURL.appendingPathComponent("Assistant", isDirectory: true)
  }

  static var vaultURL: URL {
    rootURL.appendingPathComponent("Credential Vault", isDirectory: true)
  }

  static var pendingInputsURL: URL {
    rootURL.appendingPathComponent("Pending Inputs.json", isDirectory: false)
  }

  static var instanceLockURL: URL {
    rootURL.appendingPathComponent("Aven.lock", isDirectory: false)
  }

  static var sessionsURL: URL {
    codexHomeURL().appendingPathComponent("sessions", isDirectory: true)
  }

  static func codexHomeURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let configured = normalizedCodexHomePath(environment["CODEX_HOME"]) {
      return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true)
  }

  static func normalizingCodexHome(in environment: [String: String]) -> [String: String] {
    var normalized = environment
    if let path = normalizedCodexHomePath(environment["CODEX_HOME"]) {
      normalized["CODEX_HOME"] = path
    } else {
      normalized.removeValue(forKey: "CODEX_HOME")
    }
    return normalized
  }

  private static func normalizedCodexHomePath(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty, value.hasPrefix("/")
    else { return nil }
    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
  }

  static var legacyWorkspaceURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("VoiceAssistant", isDirectory: true)
  }

  static func isVerifiedLegacyWorkspace(_ url: URL) -> Bool {
    let standardized = url.standardizedFileURL
    guard let rootValues = try? standardized.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    ), rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return false }
    let readme = standardized.appendingPathComponent("README.md")
    let policy = standardized.appendingPathComponent("decisions/0001-assistant-boundaries.md")
    guard let readmeText = verifiedTextFile(readme, maximum: 8_192),
      let policyText = verifiedTextFile(policy, maximum: 65_536)
    else { return false }
    return readmeText.hasPrefix("# Voice Assistant\n\nEigener Arbeitsbereich des Menüleisten-Assistenten.")
      && policyText.contains("# 0001 – Begrenzte Berechtigungen des Sprachassistenten")
      && policyText.contains("Der Assistent erhält Schreibzugriff")
  }

  private static func verifiedTextFile(_ url: URL, maximum: Int) -> String? {
    guard let values = try? url.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    ), values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= maximum,
      let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }
}

enum AssistantStorageMigrationResult: Equatable {
  case unchanged
  case migrated
  case removedEmptyLegacyDirectory
  case conflict
}

enum AssistantStorageMigrationError: LocalizedError {
  case unsafePath(String)

  var errorDescription: String? {
    switch self {
    case .unsafePath(let path): "Aven storage uses an unsafe path: \(path)"
    }
  }
}

enum AssistantStorageMigration {
  static func prepare(
    legacyURL: URL = AssistantPaths.legacyApplicationSupportURL,
    currentURL: URL = AssistantPaths.rootURL,
    fileManager: FileManager = .default
  ) throws -> AssistantStorageMigrationResult {
    let legacy = legacyURL.standardizedFileURL
    let current = currentURL.standardizedFileURL
    guard legacy != current, legacy.deletingLastPathComponent() == current.deletingLastPathComponent()
    else { return .unchanged }
    guard fileManager.fileExists(atPath: legacy.path) else { return .unchanged }
    guard isSafeDirectory(legacy) else {
      throw AssistantStorageMigrationError.unsafePath(legacy.path)
    }
    if fileManager.fileExists(atPath: current.path) {
      guard isSafeDirectory(current) else {
        throw AssistantStorageMigrationError.unsafePath(current.path)
      }
      let legacyContents = try fileManager.contentsOfDirectory(atPath: legacy.path)
      guard legacyContents.isEmpty else { return .conflict }
      try fileManager.removeItem(at: legacy)
      return .removedEmptyLegacyDirectory
    }
    try fileManager.moveItem(at: legacy, to: current)
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: current.path
    )
    return .migrated
  }

  private static func isSafeDirectory(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }
}
