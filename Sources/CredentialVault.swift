import CryptoKit
import Darwin
import Foundation
import Security

enum VaultSecretKind: String, Codable, CaseIterable {
  case password
  case token
  case totpSeed = "totp_seed"
  case browserSession = "browser_session"
}

struct VaultSource: Codable, Equatable {
  let path: String
  let key: String
  let format: String
}

struct VaultAccessScope: Codable, Equatable {
  let executable: String
  let executableSHA256: String
  let arguments: [String]
  let environment: String
  let operation: String
  let destination: String?

  enum CodingKeys: String, CodingKey {
    case executable
    case executableSHA256 = "executable_sha256"
    case arguments
    case environment
    case operation
    case destination
  }
}

struct VaultRecord: Codable, Equatable {
  let version: Int
  let id: String
  let service: String
  let account: String
  let kind: VaultSecretKind
  let purpose: String
  let origin: String?
  let source: VaultSource?
  let accessScope: VaultAccessScope?
  let createdAtMs: Int64
  var updatedAtMs: Int64
  var lastUsedAtMs: Int64?
  let expiresAtMs: Int64?
  var secret: Data

  var summary: VaultRecordSummary {
    VaultRecordSummary(
      id: id,
      service: service,
      account: account,
      kind: kind,
      purpose: purpose,
      origin: origin,
      source: source,
      accessScope: accessScope,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      lastUsedAtMs: lastUsedAtMs,
      expiresAtMs: expiresAtMs
    )
  }
}

struct VaultRecordSummary: Codable, Equatable {
  let id: String
  let service: String
  let account: String
  let kind: VaultSecretKind
  let purpose: String
  let origin: String?
  let source: VaultSource?
  let accessScope: VaultAccessScope?
  let createdAtMs: Int64
  let updatedAtMs: Int64
  let lastUsedAtMs: Int64?
  let expiresAtMs: Int64?

  enum CodingKeys: String, CodingKey {
    case id
    case service
    case account
    case kind
    case purpose
    case origin
    case source
    case accessScope = "access_scope"
    case createdAtMs = "created_at_ms"
    case updatedAtMs = "updated_at_ms"
    case lastUsedAtMs = "last_used_at_ms"
    case expiresAtMs = "expires_at_ms"
  }
}

private struct VaultMetadata: Codable {
  let version: Int
  let id: String
  let service: String
  let account: String
  let kind: VaultSecretKind
  let purpose: String
  let origin: String?
  let source: VaultSource?
  let accessScope: VaultAccessScope?
  let createdAtMs: Int64
  var updatedAtMs: Int64
  var lastUsedAtMs: Int64?
  let expiresAtMs: Int64?

  enum CodingKeys: String, CodingKey {
    case version
    case id
    case service
    case account
    case kind
    case purpose
    case origin
    case source
    case accessScope = "access_scope"
    case createdAtMs = "created_at_ms"
    case updatedAtMs = "updated_at_ms"
    case lastUsedAtMs = "last_used_at_ms"
    case expiresAtMs = "expires_at_ms"
  }

  var summary: VaultRecordSummary {
    VaultRecordSummary(
      id: id,
      service: service,
      account: account,
      kind: kind,
      purpose: purpose,
      origin: origin,
      source: source,
      accessScope: accessScope,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      lastUsedAtMs: lastUsedAtMs,
      expiresAtMs: expiresAtMs
    )
  }

  func replacingVersion(_ version: Int) -> VaultMetadata {
    VaultMetadata(
      version: version,
      id: id,
      service: service,
      account: account,
      kind: kind,
      purpose: purpose,
      origin: origin,
      source: source,
      accessScope: accessScope,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      lastUsedAtMs: lastUsedAtMs,
      expiresAtMs: expiresAtMs
    )
  }
}

private enum StoredCredential {
  private static let header = Data("AVEN-CREDENTIAL-V4\0".utf8)
  private static let digestSize = 32

  case legacy(Data)
  case bound(digest: Data, secret: Data)

  init(data: Data) throws {
    guard data.starts(with: Self.header) else {
      self = .legacy(data)
      return
    }
    let digestStart = Self.header.count
    let secretStart = digestStart + Self.digestSize
    guard data.count >= secretStart else { throw CredentialVaultError.corrupted }
    self = .bound(
      digest: data.subdata(in: digestStart..<secretStart),
      secret: data.subdata(in: secretStart..<data.count)
    )
  }

  static func bind(secret: Data, to metadata: VaultMetadata) throws -> Data {
    var result = header
    result.append(contentsOf: SHA256.hash(data: try canonicalData(metadata)))
    result.append(secret)
    return result
  }

  func verifiedSecret(for metadata: VaultMetadata) throws -> Data {
    guard case .bound(let expected, let secret) = self else {
      throw CredentialVaultError.corrupted
    }
    let actual = Data(SHA256.hash(data: try Self.canonicalData(metadata)))
    guard Self.constantTimeEqual(actual, expected) else { throw CredentialVaultError.corrupted }
    return secret
  }

  private static func canonicalData(_ metadata: VaultMetadata) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(metadata)
  }

  private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { difference, pair in
      difference | (pair.0 ^ pair.1)
    } == 0
  }
}

enum CredentialVaultError: LocalizedError, Equatable {
  case invalidInput(String)
  case unavailable(String)
  case storage(String)
  case notFound
  case expired
  case corrupted

  var errorDescription: String? {
    switch self {
    case .invalidInput(let message): message
    case .unavailable(let message): "Credential vault is unavailable: \(message)"
    case .storage(let message): "Credential storage failed: \(message)"
    case .notFound: "Credential not found."
    case .expired: "Credential expired and was removed."
    case .corrupted: "Credential metadata is damaged or was modified."
    }
  }
}

struct CredentialSecretStore {
  let put: (_ id: String, _ secret: Data) throws -> Void
  let get: (_ id: String) throws -> Data
  let remove: (_ id: String) throws -> Void
  let removeAll: () throws -> Void
  let verify: () throws -> Void

  static var keychain: CredentialSecretStore {
    CredentialSecretStore(
      put: KeychainCredentialStore.put,
      get: KeychainCredentialStore.get,
      remove: KeychainCredentialStore.remove,
      removeAll: KeychainCredentialStore.removeAll,
      verify: KeychainCredentialStore.verify
    )
  }
}

private enum KeychainCredentialStore {
  static let service = "com.yunabraska.aven.credentials.v1"

  static func put(id: String, secret: Data) throws {
    let query = exactQuery(id: id, dataProtection: true)
    let update = [kSecValueData as String: secret]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecSuccess {
      try? delete(exactQuery(id: id, dataProtection: false), allowMissingEntitlement: false)
      return
    }
    if status == errSecMissingEntitlement {
      try putLegacy(id: id, secret: secret)
      return
    }
    guard status == errSecItemNotFound else { throw mapped(status) }

    var attributes = query
    attributes[kSecValueData as String] = secret
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let addStatus = SecItemAdd(attributes as CFDictionary, nil)
    if addStatus == errSecMissingEntitlement {
      try putLegacy(id: id, secret: secret)
      return
    }
    guard addStatus == errSecSuccess else { throw mapped(addStatus) }
    try? delete(exactQuery(id: id, dataProtection: false), allowMissingEntitlement: false)
  }

  static func get(id: String) throws -> Data {
    let protected = copy(id: id, dataProtection: true)
    if protected.status == errSecSuccess, let data = protected.data { return data }
    if protected.status == errSecMissingEntitlement || protected.status == errSecItemNotFound {
      let legacy = copy(id: id, dataProtection: false)
      guard legacy.status == errSecSuccess, let data = legacy.data else {
        throw mapped(legacy.status)
      }
      if protected.status == errSecItemNotFound { try? put(id: id, secret: data) }
      return data
    }
    throw mapped(protected.status)
  }

  static func remove(id: String) throws {
    try delete(exactQuery(id: id, dataProtection: true), allowMissingEntitlement: true)
    try delete(exactQuery(id: id, dataProtection: false), allowMissingEntitlement: false)
  }

  static func removeAll() throws {
    try delete(baseQuery(dataProtection: true), allowMissingEntitlement: true)
    try delete(baseQuery(dataProtection: false), allowMissingEntitlement: false)
  }

  static func verify() throws {
    var query = baseQuery(dataProtection: true)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecMissingEntitlement {
      var legacy = baseQuery(dataProtection: false)
      legacy[kSecReturnData as String] = true
      legacy[kSecMatchLimit as String] = kSecMatchLimitOne
      let legacyStatus = SecItemCopyMatching(legacy as CFDictionary, &result)
      guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
        throw mapped(legacyStatus)
      }
      return
    }
    guard status == errSecSuccess || status == errSecItemNotFound else { throw mapped(status) }
  }

  private static func putLegacy(id: String, secret: Data) throws {
    let query = exactQuery(id: id, dataProtection: false)
    let update = [kSecValueData as String: secret]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw mapped(status) }
    var attributes = query
    attributes[kSecValueData as String] = secret
    let addStatus = SecItemAdd(attributes as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw mapped(addStatus) }
  }

  private static func copy(id: String, dataProtection: Bool) -> (data: Data?, status: OSStatus) {
    var query = exactQuery(id: id, dataProtection: dataProtection)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return (nil, status) }
    guard let data = result as? Data else { return (nil, errSecDecode) }
    return (data, errSecSuccess)
  }

  private static func delete(_ query: [String: Any], allowMissingEntitlement: Bool) throws {
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound { return }
    if allowMissingEntitlement && status == errSecMissingEntitlement { return }
    throw mapped(status)
  }

  private static func exactQuery(id: String, dataProtection: Bool) -> [String: Any] {
    var query = baseQuery(dataProtection: dataProtection)
    query[kSecAttrAccount as String] = id
    return query
  }

  private static func baseQuery(dataProtection: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if dataProtection {
      query[kSecAttrSynchronizable as String] = kCFBooleanFalse
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }

  private static func mapped(_ status: OSStatus) -> CredentialVaultError {
    switch status {
    case errSecItemNotFound:
      return .notFound
    case errSecInteractionNotAllowed, errSecAuthFailed:
      return .unavailable("unlock this Mac to use credentials")
    case errSecMissingEntitlement:
      return .unavailable("this app signature cannot access its private Keychain storage")
    default:
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
      return .storage("Keychain: \(message)")
    }
  }
}

struct CredentialVault {
  static let browserSessionDefaultTTL: TimeInterval = 12 * 60 * 60
  static let browserSessionMaximumTTL: TimeInterval = 7 * 24 * 60 * 60

  let rootURL: URL
  private let secretStore: CredentialSecretStore

  init(
    rootURL: URL = CredentialVault.defaultRootURL,
    secretStore: CredentialSecretStore = .keychain
  ) {
    self.rootURL = rootURL
    self.secretStore = secretStore
  }

  static var defaultRootURL: URL { AssistantPaths.vaultURL }

  func verifyAccess() throws {
    try secretStore.verify()
  }

  func store(
    service: String,
    account: String,
    kind: VaultSecretKind,
    purpose: String,
    origin: String?,
    source: VaultSource?,
    accessScope: VaultAccessScope? = nil,
    secret: Data,
    ttl: TimeInterval?,
    now: Date = Date()
  ) throws -> VaultRecordSummary {
    let normalizedService = try normalized(service, field: "service", maximum: 256)
    let normalizedAccount = try normalized(account, field: "account", maximum: 256)
    let normalizedPurpose = try normalized(purpose, field: "purpose", maximum: 512)
    try validate(secret: secret, kind: kind)
    let normalizedOrigin = try validateOrigin(origin)
    let expiresAtMs = try expiration(kind: kind, ttl: ttl, now: now)
    let id = Self.recordID(service: normalizedService, account: normalizedAccount, kind: kind)
    let nowMs = Self.milliseconds(now)

    return try withLock {
      let existing: VaultMetadata?
      do {
        existing = try existingMetadata(id: id)
      } catch CredentialVaultError.corrupted {
        // An explicit import supplies a new secret and complete metadata, so it may repair this ID.
        existing = nil
      }
      let metadata = VaultMetadata(
        version: 4,
        id: id,
        service: normalizedService,
        account: normalizedAccount,
        kind: kind,
        purpose: normalizedPurpose,
        origin: normalizedOrigin,
        source: source,
        accessScope: accessScope,
        createdAtMs: existing?.createdAtMs ?? nowMs,
        updatedAtMs: nowMs,
        lastUsedAtMs: existing?.lastUsedAtMs,
        expiresAtMs: expiresAtMs
      )
      try replaceSecretAndMetadata(metadata: metadata, secret: secret)
      return metadata.summary
    }
  }

  func list(now: Date = Date()) throws -> [VaultRecordSummary] {
    try withLock {
      let nowMs = Self.milliseconds(now)
      var active: [VaultRecordSummary] = []
      for url in try recordURLs() {
        let metadata = try readMetadata(url: url)
        if let expiresAtMs = metadata.expiresAtMs, expiresAtMs <= nowMs {
          do {
            try secretStore.remove(metadata.id)
            try FileManager.default.removeItem(at: url)
          } catch {
            continue
          }
        } else {
          active.append(metadata.summary)
        }
      }
      return active.sorted {
        ($0.service.localizedCaseInsensitiveCompare($1.service) == .orderedAscending)
          || ($0.service.caseInsensitiveCompare($1.service) == .orderedSame
            && $0.account.localizedCaseInsensitiveCompare($1.account) == .orderedAscending)
      }
    }
  }

  func resolve(id: String, now: Date = Date()) throws -> VaultRecord {
    try withLock {
      var metadata = try readMetadata(id: try validateID(id))
      if let expiresAtMs = metadata.expiresAtMs, expiresAtMs <= Self.milliseconds(now) {
        try removeRecord(id: metadata.id)
        throw CredentialVaultError.expired
      }
      var secret = try verifiedSecret(for: metadata)
      if let source = metadata.source, let refreshed = try secretFromSourceIfPresent(source),
        refreshed != secret
      {
        try validate(secret: refreshed, kind: metadata.kind)
        metadata.updatedAtMs = Self.milliseconds(now)
        try replaceSecretAndMetadata(metadata: metadata, secret: refreshed)
        secret = refreshed
      }
      return VaultRecord(
        version: metadata.version,
        id: metadata.id,
        service: metadata.service,
        account: metadata.account,
        kind: metadata.kind,
        purpose: metadata.purpose,
        origin: metadata.origin,
        source: metadata.source,
        accessScope: metadata.accessScope,
        createdAtMs: metadata.createdAtMs,
        updatedAtMs: metadata.updatedAtMs,
        lastUsedAtMs: metadata.lastUsedAtMs,
        expiresAtMs: metadata.expiresAtMs,
        secret: secret
      )
    }
  }

  func markUsed(ids: [String], now: Date = Date()) throws {
    try withLock {
      for id in Set(ids) {
        var metadata = try readMetadata(id: try validateID(id))
        metadata.lastUsedAtMs = Self.milliseconds(now)
        let secret = try verifiedSecret(for: metadata)
        try replaceSecretAndMetadata(metadata: metadata, secret: secret)
      }
    }
  }

  func refresh(now: Date = Date()) throws -> Int {
    try withLock {
      _ = try pruneLocked(now: now)
      var changed = 0
      for url in try recordURLs() {
        var metadata = try readMetadata(url: url)
        guard let source = metadata.source,
          let refreshed = try secretFromSourceIfPresent(source)
        else { continue }
        let secret = try verifiedSecret(for: metadata)
        guard refreshed != secret else { continue }
        try validate(secret: refreshed, kind: metadata.kind)
        metadata.updatedAtMs = Self.milliseconds(now)
        try replaceSecretAndMetadata(metadata: metadata, secret: refreshed)
        changed += 1
      }
      return changed
    }
  }

  func remove(id: String) throws {
    try withLock { try removeRecord(id: try validateID(id)) }
  }

  func prune(now: Date = Date()) throws -> Int {
    try withLock { try pruneLocked(now: now) }
  }

  func eraseAll() throws {
    try withLock {
      try secretStore.removeAll()
      let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CredentialVaultError.storage("metadata path is unsafe")
      }
      try FileManager.default.removeItem(at: rootURL)
    }
  }

  static func envValue(named key: String, from fileURL: URL) throws -> Data {
    let validKey = key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression)
    guard validKey != nil else {
      throw CredentialVaultError.invalidInput("Invalid environment key.")
    }
    let values = try readSourceFile(fileURL, maximum: 1_048_576)
    guard let text = String(data: values, encoding: .utf8) else {
      throw CredentialVaultError.invalidInput("Environment file is not UTF-8.")
    }
    var found: String?
    for rawLine in text.split(whereSeparator: \.isNewline) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("export ") { line = line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
      guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
      let candidate = line[..<equals].trimmingCharacters(in: .whitespaces)
      guard candidate == key else { continue }
      var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
        let first = value.first,
        let last = value.last,
        (first == "\"" && last == "\"") || (first == "'" && last == "'")
      {
        value.removeFirst()
        value.removeLast()
      }
      found = value
    }
    guard let found, !found.isEmpty else {
      throw CredentialVaultError.invalidInput("Environment key is missing or empty.")
    }
    return Data(found.utf8)
  }

  static func envKeys(from fileURL: URL) throws -> [String] {
    let values = try readSourceFile(fileURL, maximum: 1_048_576)
    guard let text = String(data: values, encoding: .utf8) else {
      throw CredentialVaultError.invalidInput("Environment file is not UTF-8.")
    }
    var keys = Set<String>()
    for rawLine in text.split(whereSeparator: \.isNewline) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("export ") { line = line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
      guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<equals].trimmingCharacters(in: .whitespaces))
      if key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil {
        keys.insert(key)
      }
    }
    return keys.sorted()
  }

  static func fileValue(from fileURL: URL, maximum: Int = 8_388_608) throws -> Data {
    try readSourceFile(fileURL, maximum: maximum)
  }

  static func accessScope(
    executable: URL,
    arguments: [String],
    environment: String,
    operation: String,
    destination: String?
  ) throws -> VaultAccessScope {
    guard environment.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    else { throw CredentialVaultError.invalidInput("Invalid credential environment name.") }
    let normalizedOperation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedOperation.isEmpty, normalizedOperation.count <= 256 else {
      throw CredentialVaultError.invalidInput("Invalid credential operation.")
    }
    guard arguments.count <= 64,
      arguments.allSatisfy({ $0.count <= 4_096 && !$0.contains("\0") })
    else { throw CredentialVaultError.invalidInput("Credential command arguments are invalid.") }
    if let destination {
      guard destination.count <= 2_048, let url = URL(string: destination),
        let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil
      else {
        throw CredentialVaultError.invalidInput(
          "Credential destination must be an HTTP or HTTPS URL.")
      }
    }
    let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
    let blocked = [
      "bash", "curl", "dash", "env", "fish", "nc", "node", "osascript", "perl", "python",
      "python3", "ruby", "sh", "ssh", "wget", "zsh",
    ]
    let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard resolved.path.hasPrefix("/"), values.isRegularFile == true, values.isSymbolicLink != true,
      FileManager.default.isExecutableFile(atPath: resolved.path),
      !blocked.contains(resolved.lastPathComponent.lowercased())
    else {
      throw CredentialVaultError.invalidInput(
        "Use a reviewed dedicated executable for credential access.")
    }
    return VaultAccessScope(
      executable: resolved.path,
      executableSHA256: try executableDigest(resolved),
      arguments: arguments,
      environment: environment,
      operation: normalizedOperation,
      destination: destination
    )
  }

  static func validateAccess(
    _ scope: VaultAccessScope?,
    executable: URL,
    arguments: [String],
    environment: String
  ) throws -> URL {
    guard let scope else {
      throw CredentialVaultError.invalidInput(
        "Credential has no executable scope; import it again with the reviewed command."
      )
    }
    let current = try accessScope(
      executable: executable,
      arguments: arguments,
      environment: environment,
      operation: scope.operation,
      destination: scope.destination
    )
    guard current == scope else {
      throw CredentialVaultError.invalidInput(
        "Credential scope does not match this executable, environment, or argument list."
      )
    }
    return URL(fileURLWithPath: current.executable)
  }

  private func replaceSecretAndMetadata(metadata: VaultMetadata, secret: Data) throws {
    let previousValue = try? secretStore.get(metadata.id)
    try secretStore.put(metadata.id, try StoredCredential.bind(secret: secret, to: metadata))
    do {
      try writeMetadata(metadata)
    } catch {
      if let previousValue {
        try? secretStore.put(metadata.id, previousValue)
      } else {
        try? secretStore.remove(metadata.id)
      }
      throw error
    }
  }

  private func pruneLocked(now: Date) throws -> Int {
    let nowMs = Self.milliseconds(now)
    var removed = 0
    for url in try recordURLs() {
      let metadata = try readMetadata(url: url)
      guard let expiresAtMs = metadata.expiresAtMs, expiresAtMs <= nowMs else { continue }
      try secretStore.remove(metadata.id)
      try FileManager.default.removeItem(at: url)
      removed += 1
    }
    return removed
  }

  private func expiration(kind: VaultSecretKind, ttl: TimeInterval?, now: Date) throws -> Int64? {
    if kind == .browserSession {
      let value = ttl ?? Self.browserSessionDefaultTTL
      guard value >= 60, value <= Self.browserSessionMaximumTTL else {
        throw CredentialVaultError.invalidInput(
          "Browser session TTL must be between 1 minute and 7 days.")
      }
      return Self.milliseconds(now.addingTimeInterval(value))
    }
    guard let ttl else { return nil }
    guard ttl >= 60, ttl <= 365 * 24 * 60 * 60 else {
      throw CredentialVaultError.invalidInput("Credential TTL must be between 1 minute and 1 year.")
    }
    return Self.milliseconds(now.addingTimeInterval(ttl))
  }

  private func withLock<T>(_ operation: () throws -> T) throws -> T {
    try prepareStorage()
    let lockURL = rootURL.appendingPathComponent(".lock")
    let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
    guard descriptor >= 0 else { throw CredentialVaultError.storage("lock file is unavailable") }
    defer { Darwin.close(descriptor) }
    guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
      throw CredentialVaultError.storage("lock could not be acquired")
    }
    defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
    return try operation()
  }

  private func prepareStorage() throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: rootURL.path) {
      let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CredentialVaultError.storage("metadata path is not a private directory")
      }
    } else {
      try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
    try manager.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: rootURL.path
    )
  }

  private func recordURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
  }

  private func existingMetadata(id: String) throws -> VaultMetadata? {
    let url = recordURL(id: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try readMetadata(url: url)
  }

  private func readMetadata(id: String) throws -> VaultMetadata {
    try readMetadata(url: recordURL(id: id))
  }

  private func readMetadata(url: URL) throws -> VaultMetadata {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CredentialVaultError.notFound
    }
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= 65_536
    else {
      throw CredentialVaultError.corrupted
    }
    do {
      let metadata = try JSONDecoder().decode(VaultMetadata.self, from: Data(contentsOf: url))
      guard (2...4).contains(metadata.version),
        metadata.id == url.deletingPathExtension().lastPathComponent,
        metadata.id
          == Self.recordID(
            service: metadata.service,
            account: metadata.account,
            kind: metadata.kind
          )
      else { throw CredentialVaultError.corrupted }
      let stored = try StoredCredential(data: secretStore.get(metadata.id))
      if metadata.version == 4 {
        _ = try stored.verifiedSecret(for: metadata)
        return metadata
      }
      guard metadata.source == nil, metadata.accessScope == nil, metadata.expiresAtMs == nil,
        case .legacy(let secret) = stored
      else {
        // Security-bearing legacy metadata cannot be trusted enough to authenticate itself.
        throw CredentialVaultError.corrupted
      }
      let migrated = metadata.replacingVersion(4)
      try secretStore.put(metadata.id, try StoredCredential.bind(secret: secret, to: migrated))
      do {
        try writeMetadata(migrated)
      } catch {
        try? secretStore.put(metadata.id, secret)
        throw error
      }
      return migrated
    } catch let error as CredentialVaultError {
      throw error
    } catch {
      throw CredentialVaultError.corrupted
    }
  }

  private func writeMetadata(_ metadata: VaultMetadata) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let destination = recordURL(id: metadata.id)
    try encoder.encode(metadata).write(to: destination, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: destination.path
    )
  }

  private func removeRecord(id: String) throws {
    let url = recordURL(id: id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CredentialVaultError.notFound
    }
    try secretStore.remove(id)
    try FileManager.default.removeItem(at: url)
  }

  private func secretFromSourceIfPresent(_ source: VaultSource) throws -> Data? {
    guard source.format == "env" else { return nil }
    let url = URL(fileURLWithPath: source.path)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Self.envValue(named: source.key, from: url)
  }

  private func verifiedSecret(for metadata: VaultMetadata) throws -> Data {
    try StoredCredential(data: secretStore.get(metadata.id)).verifiedSecret(for: metadata)
  }

  private func recordURL(id: String) -> URL {
    rootURL.appendingPathComponent(id).appendingPathExtension("json")
  }

  private func validateID(_ id: String) throws -> String {
    guard id.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
      throw CredentialVaultError.invalidInput("Invalid credential ID.")
    }
    return id
  }

  private func normalized(_ value: String, field: String, maximum: Int) throws -> String {
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty, result.count <= maximum, !result.contains("\0") else {
      throw CredentialVaultError.invalidInput("Invalid \(field).")
    }
    return result
  }

  private func validateOrigin(_ value: String?) throws -> String? {
    guard let value, !value.isEmpty else { return nil }
    guard value.count <= 2_048, let url = URL(string: value),
      let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
      url.host != nil
    else {
      throw CredentialVaultError.invalidInput("Origin must be an HTTP or HTTPS URL.")
    }
    return value
  }

  private func validate(secret: Data, kind: VaultSecretKind) throws {
    let maximum = kind == .browserSession ? 8_388_608 : 65_536
    guard secret.count >= 4, secret.count <= maximum else {
      throw CredentialVaultError.invalidInput(
        "Secret must contain at least 4 bytes and stay within its size limit.")
    }
  }

  private static func recordID(service: String, account: String, kind: VaultSecretKind) -> String {
    let value = "\(service.lowercased())\0\(account.lowercased())\0\(kind.rawValue)"
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func executableDigest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
  }

  private static func readSourceFile(_ url: URL, maximum: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= maximum
    else {
      throw CredentialVaultError.invalidInput("Source must be a bounded regular file, not a link.")
    }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
  }
}
