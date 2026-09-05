import Foundation

@main
enum CredentialVaultTests {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 3, arguments[0] == "authorize-selection" {
      exit(
        TaskCapabilityBroker.authorizes(
          arguments[2], capability: .selection, service: arguments[1]) ? 0 : 1
      )
    }
    storesSecretsOutsideReadableMetadata()
    refreshesAChangedEnvironmentSource()
    expiresBrowserSessionsAndRejectsLongTTLs()
    rejectsMalformedMetadataAndSymbolicLinkSources()
    rejectsTamperedAndReplayedMetadata()
    migratesOnlyLegacyMetadataWithoutAuthorityFields()
    failsClosedWhenIntegrityStorageIsLocked()
    erasesOnlyTheAssistantCredentialCollection()
    erasesAssistantDataAndDefaultsTogether()
    listsEnvironmentNamesWithoutValues()
    generatesAStandardTOTPCode()
    bindsCredentialsToAnExactReviewedCommand()
    keepsCapabilitiesValidForTheirExactTaskLifetime()
    bindsCapabilityToOneSpawnedTaskSubtree()
    print("Credential vault tests passed")
  }

  private static func storesSecretsOutsideReadableMetadata() {
    withVault { vault, secrets in
      let secret = Data("ultra-secret-value".utf8)
      let first = try! vault.store(
        service: "jira.example.com",
        account: "user@example.com",
        kind: .token,
        purpose: "Jira API",
        origin: "https://jira.example.com",
        source: nil,
        secret: secret,
        ttl: nil
      )
      let replacement = try! vault.store(
        service: "jira.example.com",
        account: "user@example.com",
        kind: .token,
        purpose: "Jira API",
        origin: "https://jira.example.com",
        source: nil,
        secret: Data("replacement-secret".utf8),
        ttl: nil
      )
      expect(first.id == replacement.id, "the same identity should replace one record")
      expect(try! vault.list().count == 1, "replacement must not duplicate metadata")
      let resolved = try! vault.resolve(id: first.id)
      expect(resolved.secret == Data("replacement-secret".utf8), "vault should decrypt the record")

      let metadata = try! Data(
        contentsOf: vault.rootURL.appendingPathComponent(first.id + ".json"))
      expect(
        !String(decoding: metadata, as: UTF8.self).contains("replacement-secret"),
        "metadata must never contain secret values"
      )
      expect(secrets.values[first.id] != nil, "secret store owns the protected credential data")
      let attributes = try! FileManager.default.attributesOfItem(
        atPath: vault.rootURL.appendingPathComponent(first.id + ".json").path
      )
      let mode = attributes[.posixPermissions] as! NSNumber
      expect(mode.intValue == 0o600, "record files should be private")
    }
  }

  private static func refreshesAChangedEnvironmentSource() {
    withVault { vault, _ in
      let source = vault.rootURL.deletingLastPathComponent().appendingPathComponent("source.env")
      try! Data("JIRA_TOKEN=first-value\n".utf8).write(to: source)
      let summary = try! vault.store(
        service: "jira",
        account: "automation",
        kind: .token,
        purpose: "Jira download",
        origin: nil,
        source: VaultSource(path: source.path, key: "JIRA_TOKEN", format: "env"),
        secret: CredentialVault.envValue(named: "JIRA_TOKEN", from: source),
        ttl: nil
      )
      try! Data("JIRA_TOKEN=second-value\n".utf8).write(to: source)
      expect(try! vault.refresh() == 1, "changed source should refresh one record")
      expect(
        try! vault.resolve(id: summary.id).secret == Data("second-value".utf8),
        "refreshed secret should be current"
      )
    }
  }

  private static func expiresBrowserSessionsAndRejectsLongTTLs() {
    withVault { vault, _ in
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let summary = try! vault.store(
        service: "example.com",
        account: "browser",
        kind: .browserSession,
        purpose: "Temporary session",
        origin: "https://example.com",
        source: nil,
        secret: Data("session".utf8),
        ttl: 60,
        now: now
      )
      expect(try! vault.prune(now: now.addingTimeInterval(59)) == 0, "live session should remain")
      expect(
        try! vault.prune(now: now.addingTimeInterval(60)) == 1, "expired session should be removed")
      expectThrows("removed session should be absent") { _ = try vault.resolve(id: summary.id) }
      expectThrows("session TTL must be bounded") {
        _ = try vault.store(
          service: "example.com",
          account: "browser",
          kind: .browserSession,
          purpose: "Temporary session",
          origin: nil,
          source: nil,
          secret: Data("session".utf8),
          ttl: CredentialVault.browserSessionMaximumTTL + 1,
          now: now
        )
      }
      expectThrows("secrets too short for reliable output redaction must be rejected") {
        _ = try vault.store(
          service: "example.com",
          account: "short",
          kind: .token,
          purpose: "Invalid short secret",
          origin: nil,
          source: nil,
          secret: Data("abc".utf8),
          ttl: nil,
          now: now
        )
      }
    }
  }

  private static func rejectsMalformedMetadataAndSymbolicLinkSources() {
    withVault { vault, _ in
      let summary = try! vault.store(
        service: "service",
        account: "account",
        kind: .password,
        purpose: "test",
        origin: nil,
        source: nil,
        secret: Data("password".utf8),
        ttl: nil
      )
      let recordURL = vault.rootURL.appendingPathComponent(summary.id + ".json")
      try! Data("not-json".utf8).write(to: recordURL)
      expectThrows("malformed metadata should be rejected") {
        _ = try vault.resolve(id: summary.id)
      }

      let source = vault.rootURL.deletingLastPathComponent().appendingPathComponent("real.env")
      let link = vault.rootURL.deletingLastPathComponent().appendingPathComponent("linked.env")
      try! Data("TOKEN=value\n".utf8).write(to: source)
      try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
      expectThrows("credential sources must not be symlinks") {
        _ = try CredentialVault.envValue(named: "TOKEN", from: link)
      }
    }
  }

  private static func rejectsTamperedAndReplayedMetadata() {
    withVault { vault, _ in
      let initialTime = Date(timeIntervalSince1970: 1_700_000_000)
      let executable = vault.rootURL.deletingLastPathComponent().appendingPathComponent("reader")
      try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
      try! FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
      let sourceURL = vault.rootURL.deletingLastPathComponent().appendingPathComponent("source.env")
      try! Data("TOKEN=original-secret\n".utf8).write(to: sourceURL)
      let scope = try! CredentialVault.accessScope(
        executable: executable,
        arguments: ["read"],
        environment: "TOKEN",
        operation: "read records",
        destination: "https://safe.example"
      )
      let summary = try! vault.store(
        service: "safe.example",
        account: "reader",
        kind: .token,
        purpose: "read records",
        origin: "https://safe.example",
        source: VaultSource(path: sourceURL.path, key: "TOKEN", format: "env"),
        accessScope: scope,
        secret: Data("original-secret".utf8),
        ttl: nil,
        now: initialTime
      )
      let recordURL = vault.rootURL.appendingPathComponent(summary.id + ".json")
      let original = try! Data(contentsOf: recordURL)
      var object = try! JSONSerialization.jsonObject(with: original) as! [String: Any]
      var accessScope = object["access_scope"] as! [String: Any]
      accessScope["destination"] = "https://attacker.example"
      object["access_scope"] = accessScope
      try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
        to: recordURL)
      expectThrows("a changed destination must invalidate metadata") {
        _ = try vault.resolve(id: summary.id)
      }

      _ = try! vault.store(
        service: "safe.example",
        account: "reader",
        kind: .token,
        purpose: "read records",
        origin: "https://safe.example",
        source: VaultSource(path: sourceURL.path, key: "TOKEN", format: "env"),
        accessScope: scope,
        secret: Data("replacement-secret".utf8),
        ttl: nil,
        now: initialTime.addingTimeInterval(1)
      )
      try! original.write(to: recordURL)
      expectThrows(
        "replaying previously valid metadata must fail against the current Keychain binding"
      ) {
        _ = try vault.resolve(id: summary.id)
      }
    }
  }

  private static func migratesOnlyLegacyMetadataWithoutAuthorityFields() {
    withVault { vault, secrets in
      let summary = try! vault.store(
        service: "legacy.example",
        account: "reader",
        kind: .token,
        purpose: "legacy token",
        origin: nil,
        source: nil,
        secret: Data("legacy-secret".utf8),
        ttl: nil
      )
      let recordURL = vault.rootURL.appendingPathComponent(summary.id + ".json")
      var object =
        try! JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
      object["version"] = 3
      try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
        to: recordURL)
      secrets.values[summary.id] = Data("legacy-secret".utf8)

      expect(
        try! vault.list().single?.id == summary.id, "authority-free legacy metadata should migrate")
      expect(
        try! vault.resolve(id: summary.id).version == 4, "legacy migration should bind metadata")

      var migrated =
        try! JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
      migrated["version"] = 3
      migrated["source"] = ["path": "/tmp/attacker.env", "key": "TOKEN", "format": "env"]
      try! JSONSerialization.data(withJSONObject: migrated, options: [.sortedKeys]).write(
        to: recordURL)
      secrets.values[summary.id] = Data("legacy-secret".utf8)
      expectThrows("legacy source authority must require explicit re-import") {
        _ = try vault.resolve(id: summary.id)
      }
    }
  }

  private static func failsClosedWhenIntegrityStorageIsLocked() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-locked-\(UUID().uuidString)")
    let box = MemorySecretStore()
    let writable = box.store()
    let vault = CredentialVault(rootURL: root, secretStore: writable)
    defer { try? FileManager.default.removeItem(at: root) }
    let summary = try! vault.store(
      service: "jira",
      account: "locked",
      kind: .token,
      purpose: "Locked test",
      origin: nil,
      source: nil,
      secret: Data("secret".utf8),
      ttl: nil
    )
    let expiryBase = Date(timeIntervalSince1970: 1_700_000_000)
    let expiring = try! vault.store(
      service: "example",
      account: "session",
      kind: .browserSession,
      purpose: "Locked expiry test",
      origin: nil,
      source: nil,
      secret: Data("session".utf8),
      ttl: 60,
      now: expiryBase
    )
    box.isLocked = true
    expectThrows("metadata listing must not expose unverified authority while Keychain is locked") {
      _ = try vault.list(now: expiryBase.addingTimeInterval(61))
    }
    expect(
      FileManager.default.fileExists(
        atPath: vault.rootURL.appendingPathComponent(expiring.id + ".json").path
      ),
      "failed locked cleanup must retain metadata for a later retry"
    )
    expectThrows("secret resolution must fail closed while locked") {
      _ = try vault.resolve(id: summary.id)
    }
  }

  private static func erasesOnlyTheAssistantCredentialCollection() {
    withVault { vault, secrets in
      _ = try! vault.store(
        service: "service",
        account: "account",
        kind: .password,
        purpose: "erase test",
        origin: nil,
        source: nil,
        secret: Data("password".utf8),
        ttl: nil
      )
      secrets.unrelated = Data("keep".utf8)
      try! vault.eraseAll()
      expect(secrets.values.isEmpty, "assistant secrets should be erased")
      expect(secrets.unrelated == Data("keep".utf8), "unrelated secrets must stay untouched")
      expect(
        !FileManager.default.fileExists(atPath: vault.rootURL.path), "metadata should be erased")
    }
  }

  private static func erasesAssistantDataAndDefaultsTogether() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-data-\(UUID().uuidString)")
    let domain = "aven-data-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data("memory".utf8).write(to: root.appendingPathComponent("memory.db"))
    defaults.set("thread", forKey: "context")
    var credentialsErased = false
    let controller = AssistantDataController(
      rootURL: root,
      eraseCredentials: { credentialsErased = true }
    )

    try! controller.eraseAll(defaults: defaults, domain: domain)

    expect(credentialsErased, "credential deletion must be part of assistant data deletion")
    expect(!FileManager.default.fileExists(atPath: root.path), "assistant files must be removed")
    expect(defaults.string(forKey: "context") == nil, "assistant defaults must be removed")

    let rootWithLegacy = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-data-legacy-\(UUID().uuidString)")
    let appRoot = rootWithLegacy.appendingPathComponent("Application Support")
    let legacy = rootWithLegacy.appendingPathComponent("VoiceAssistant")
    let decisions = legacy.appendingPathComponent("decisions")
    try! FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: decisions, withIntermediateDirectories: true)
    try! Data("# Voice Assistant\n\nEigener Arbeitsbereich des Menüleisten-Assistenten.\n".utf8)
      .write(to: legacy.appendingPathComponent("README.md"))
    try! Data(
      "# 0001 – Begrenzte Berechtigungen des Sprachassistenten\nDer Assistent erhält Schreibzugriff\n"
        .utf8
    )
    .write(to: decisions.appendingPathComponent("0001-assistant-boundaries.md"))
    try! AssistantDataController(
      rootURL: appRoot,
      legacyWorkspaceURL: legacy,
      eraseCredentials: {}
    ).eraseAll(defaults: defaults, domain: domain)
    expect(
      !FileManager.default.fileExists(atPath: legacy.path),
      "verified legacy app data should be removed")
    try? FileManager.default.removeItem(at: rootWithLegacy)

    let blockedRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-data-blocked-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: blockedRoot) }
    let blocked = AssistantDataController(
      rootURL: blockedRoot,
      eraseCredentials: { throw CredentialVaultError.unavailable("locked") }
    )
    expectThrows("file deletion must stop when credential deletion fails") {
      try blocked.eraseAll(defaults: defaults, domain: domain)
    }
    expect(
      FileManager.default.fileExists(atPath: blockedRoot.path),
      "assistant files must remain recoverable when Keychain cleanup is blocked"
    )
  }

  private static func listsEnvironmentNamesWithoutValues() {
    withVault { vault, _ in
      let source = vault.rootURL.deletingLastPathComponent().appendingPathComponent("keys.env")
      try! Data("# ignored\nTOKEN=secret\nexport USER_NAME='Yuna'\ninvalid-name=x\n".utf8)
        .write(to: source)
      let keys = try! CredentialVault.envKeys(from: source)
      expect(keys == ["TOKEN", "USER_NAME"], "only valid environment names should be listed")
    }
  }

  private static func generatesAStandardTOTPCode() {
    let seed = Data("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ".utf8)
    let code = try! TOTP.currentCode(seed: seed, date: Date(timeIntervalSince1970: 59))
    expect(code == "287082", "TOTP should match the RFC 6238 SHA-1 vector at 59 seconds")
  }

  private static func bindsCredentialsToAnExactReviewedCommand() {
    withVault { vault, _ in
      let executable = vault.rootURL.deletingLastPathComponent().appendingPathComponent("jira-read")
      try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
      try! FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
      let scope = try! CredentialVault.accessScope(
        executable: executable,
        arguments: ["issues", "--project", "OPS"],
        environment: "JIRA_TOKEN",
        operation: "read Jira issues",
        destination: "https://jira.example.com"
      )
      let summary = try! vault.store(
        service: "jira.example.com",
        account: "reader",
        kind: .token,
        purpose: "Jira issue reads",
        origin: "https://jira.example.com",
        source: nil,
        accessScope: scope,
        secret: Data("secret-token".utf8),
        ttl: nil
      )
      let record = try! vault.resolve(id: summary.id)
      expect(
        try! CredentialVault.validateAccess(
          record.accessScope,
          executable: executable,
          arguments: ["issues", "--project", "OPS"],
          environment: "JIRA_TOKEN"
        ).path == executable.path,
        "an exact reviewed command should retain standing consent"
      )
      expectThrows("different arguments must not inherit credential consent") {
        _ = try CredentialVault.validateAccess(
          record.accessScope,
          executable: executable,
          arguments: ["delete", "OPS-1"],
          environment: "JIRA_TOKEN"
        )
      }
      try! Data("#!/bin/sh\nprintf stolen\n".utf8).write(to: executable)
      expectThrows("modified executables must lose credential consent") {
        _ = try CredentialVault.validateAccess(
          record.accessScope,
          executable: executable,
          arguments: ["issues", "--project", "OPS"],
          environment: "JIRA_TOKEN"
        )
      }
    }
  }

  private static func keepsCapabilitiesValidForTheirExactTaskLifetime() {
    let service = "com.yunabraska.aven.tests.task-lifetime.\(UUID().uuidString)"
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    defer { _ = TaskCapabilityBroker.endSession(service: service) }
    expect(
      TaskCapabilityBroker.beginSession(service: service), "the capability session should start")
    expect(
      Set(TaskCapabilityBroker.Capability.allCases) == [.vault, .calendar, .selection, .clipboard],
      "the per-task broker should own every privileged local data capability"
    )
    guard
      let token = TaskCapabilityBroker.issue(
        capabilities: [.selection, .clipboard], lifetime: 60, service: service, now: base
      )
    else { fail("the active task should receive a scoped token") }
    expect(
      TaskCapabilityBroker.authorizes(
        token, capability: .selection, service: service, now: base.addingTimeInterval(59)
      ),
      "first use should bind the token to this task subtree"
    )
    expect(
      TaskCapabilityBroker.authorizes(
        token, capability: .clipboard, service: service, now: base.addingTimeInterval(3_600)
      ),
      "a bound token should remain valid for the full live task instead of expiring after 15 minutes"
    )
    expect(
      !TaskCapabilityBroker.authorizes(token, capability: .vault, service: service, now: base),
      "a bound task token must not gain an unissued capability"
    )
    expect(
      TaskCapabilityBroker.revoke(token, service: service),
      "task completion should revoke the token")
    expect(
      !TaskCapabilityBroker.authorizes(token, capability: .selection, service: service, now: base),
      "revocation must not reopen through lifetime binding"
    )

    guard
      let unused = TaskCapabilityBroker.issue(
        capabilities: [.selection], lifetime: 60, service: service, now: base
      )
    else { fail("the test should receive an unused token") }
    expect(
      !TaskCapabilityBroker.authorizes(
        unused, capability: .selection, service: service, now: base.addingTimeInterval(61)
      ),
      "an unused token must still lose its bounded activation window"
    )
  }

  private static func bindsCapabilityToOneSpawnedTaskSubtree() {
    let service = "com.yunabraska.aven.tests.task-subtree.\(UUID().uuidString)"
    defer { _ = TaskCapabilityBroker.endSession(service: service) }
    expect(
      TaskCapabilityBroker.beginSession(service: service), "the subtree test session should start")
    guard
      let token = TaskCapabilityBroker.issue(
        capabilities: [.selection], lifetime: 60, service: service)
    else { fail("the spawned task should receive a selection token") }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    task.arguments = ["authorize-selection", service, token]
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try! task.run()
    task.waitUntilExit()
    expect(task.terminationStatus == 0, "the first spawned task should bind and use its token")
    expect(
      !TaskCapabilityBroker.authorizes(token, capability: .selection, service: service),
      "the issuing process must not reuse a token after it was bound to a different task subtree"
    )
  }

  private static func withVault(_ operation: (CredentialVault, MemorySecretStore) -> Void) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-vault-\(UUID().uuidString)")
    let vaultRoot = root.appendingPathComponent("vault")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = MemorySecretStore()
    operation(CredentialVault(rootURL: vaultRoot, secretStore: secrets.store()), secrets)
  }

  private final class MemorySecretStore {
    var values: [String: Data] = [:]
    var unrelated: Data?
    var isLocked = false

    func store() -> CredentialSecretStore {
      CredentialSecretStore(
        put: { [weak self] id, value in
          guard let self else { throw CredentialVaultError.unavailable("store disappeared") }
          try self.requireUnlocked()
          self.values[id] = value
        },
        get: { [weak self] id in
          guard let self else { throw CredentialVaultError.unavailable("store disappeared") }
          try self.requireUnlocked()
          guard let value = self.values[id] else { throw CredentialVaultError.notFound }
          return value
        },
        remove: { [weak self] id in
          guard let self else { throw CredentialVaultError.unavailable("store disappeared") }
          try self.requireUnlocked()
          self.values.removeValue(forKey: id)
        },
        removeAll: { [weak self] in
          guard let self else { throw CredentialVaultError.unavailable("store disappeared") }
          try self.requireUnlocked()
          self.values.removeAll()
        },
        verify: { [weak self] in
          guard let self else { throw CredentialVaultError.unavailable("store disappeared") }
          try self.requireUnlocked()
        }
      )
    }

    private func requireUnlocked() throws {
      if isLocked { throw CredentialVaultError.unavailable("locked") }
    }
  }

  private static func expectThrows(_ message: String, _ operation: () throws -> Void) {
    do {
      try operation()
      fail(message)
    } catch {}
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}

extension Array {
  fileprivate var single: Element? { count == 1 ? first : nil }
}
