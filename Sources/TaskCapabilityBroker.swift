import CryptoKit
import Darwin
import Foundation
import Security

/// Issues process-bound, per-task capabilities for local privileged helper commands.
///
/// A capability is valid only for the Aven process session that issued it. Starting Aven again
/// invalidates every outstanding capability, while ending a task can revoke its token early.
enum TaskCapabilityBroker {
  enum Capability: String, Codable, CaseIterable, Hashable {
    case vault
    case calendar
    case selection
    case clipboard
  }

  static let service = "com.yunabraska.aven.task-capabilities"
  private static let sessionAccount = "active-session"
  private static let helperServiceSuffix = ".vault-helper"
  // An unused token has a bounded activation window. Once activated, process identity and ancestry
  // bind it to the exact task subtree for that task's full lifetime; task completion still revokes it.
  private static let defaultLifetime: TimeInterval = 24 * 60 * 60

  /// Starts a new application session and invalidates capabilities from every earlier session.
  @discardableResult
  static func beginSession(service: String = service) -> Bool {
    _ = deleteAll(service: service)
    guard let token = randomToken() else { return false }
    return write(Data(token.utf8), service: service, account: sessionAccount)
  }

  /// Removes the current session and every still-issued task capability.
  @discardableResult
  static func endSession(service: String = service) -> Bool {
    deleteAll(service: service)
  }

  /// Issues a capability token for one active task. The caller must revoke it when the task ends.
  static func issue(
    capabilities: Set<Capability>,
    lifetime: TimeInterval = defaultLifetime,
    service: String = service,
    now: Date = Date()
  ) -> String? {
    guard !capabilities.isEmpty, lifetime > 0, lifetime <= defaultLifetime, lifetime.isFinite,
      let session = currentSession(service: service),
      let issuerIdentity = processIdentity(Darwin.getpid())
    else { return nil }
    guard let token = randomToken() else { return nil }
    let grant = Grant(
      session: session,
      issuerPID: Darwin.getpid(),
      issuerIdentity: issuerIdentity,
      taskPID: nil,
      taskIdentity: nil,
      capabilities: capabilities.map(\.rawValue).sorted(),
      expiresAtMs: epochMilliseconds(now.addingTimeInterval(lifetime))
    )
    guard let data = try? JSONEncoder().encode(grant),
      write(data, service: service, account: token)
    else { return nil }
    return token
  }

  /// Revokes a task token immediately. It is safe to call for an already-expired token.
  @discardableResult
  static func revoke(_ token: String, service: String = service) -> Bool {
    guard validToken(token) else { return false }
    return delete(service: service, account: token)
  }

  /// Returns whether a token remains valid for an active Aven task and the requested capability.
  static func authorizes(
    _ token: String?,
    capability: Capability,
    service: String = service,
    now: Date = Date()
  ) -> Bool {
    guard let token, validToken(token), let session = currentSession(service: service) else {
      return false
    }
    for _ in 0..<3 {
      guard let data = value(service: service, account: token),
        var grant = try? JSONDecoder().decode(Grant.self, from: data),
        grant.session == session,
        grant.issuerIdentity == processIdentity(grant.issuerPID),
        grant.capabilities.contains(capability.rawValue)
      else { return false }

      if let taskPID = grant.taskPID, let taskIdentity = grant.taskIdentity {
        return taskIdentity == processIdentity(taskPID)
          && isProcess(Darwin.getpid(), descendantOf: taskPID)
      }

      guard grant.expiresAtMs >= epochMilliseconds(now),
        let taskPID = directChild(Darwin.getpid(), of: grant.issuerPID),
        let taskIdentity = processIdentity(taskPID)
      else { return false }
      grant.taskPID = taskPID
      grant.taskIdentity = taskIdentity
      guard let replacement = try? JSONEncoder().encode(grant) else { return false }
      if replaceIfMatching(data, with: replacement, service: service, account: token) {
        return true
      }
    }
    return false
  }

  /// Creates a single-use authorization for Aven's internal vault executor.
  static func issueVaultHelper(
    executable: URL,
    arguments: [String],
    service: String = service,
    now: Date = Date()
  ) -> String? {
    guard let session = currentSession(service: service) else { return nil }
    guard let token = randomToken() else { return nil }
    let grant = HelperGrant(
      session: session,
      issuerPID: Darwin.getpid(),
      digest: commandDigest(executable: executable, arguments: arguments),
      expiresAtMs: epochMilliseconds(now.addingTimeInterval(60))
    )
    guard let data = try? JSONEncoder().encode(grant),
      write(data, service: helperService(service), account: token)
    else { return nil }
    return token
  }

  /// Consumes the helper authorization exactly once before the helper replaces itself with the target.
  static func consumeVaultHelper(
    _ token: String?,
    executable: URL,
    arguments: [String],
    service: String = service,
    now: Date = Date()
  ) -> Bool {
    guard let token, validToken(token), let session = currentSession(service: service),
      let data = value(service: helperService(service), account: token),
      let grant = try? JSONDecoder().decode(HelperGrant.self, from: data),
      grant.session == session,
      isProcess(Darwin.getpid(), descendantOf: grant.issuerPID),
      grant.expiresAtMs >= epochMilliseconds(now),
      grant.digest == commandDigest(executable: executable, arguments: arguments)
    else { return false }
    return deleteIfMatching(data, service: helperService(service), account: token)
  }

  private static func currentSession(service: String) -> String? {
    guard let data = value(service: service, account: sessionAccount),
      let session = String(data: data, encoding: .utf8), validToken(session)
    else { return nil }
    return session
  }

  private static func helperService(_ service: String) -> String { service + helperServiceSuffix }

  private static func commandDigest(executable: URL, arguments: [String]) -> String {
    let values = [executable.standardizedFileURL.path] + arguments
    let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func randomToken() -> String? {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      return nil
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func validToken(_ token: String) -> Bool {
    token.range(of: "^[0-9a-f]{32,64}$", options: .regularExpression) != nil
  }

  private static func epochMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
  }

  static func isProcess(_ processID: pid_t, descendantOf ancestorID: pid_t) -> Bool {
    guard processID > 0, ancestorID > 0 else { return false }
    var current = processID
    for _ in 0..<64 {
      if current == ancestorID { return true }
      guard let parent = parentProcessID(current), parent > 1, parent != current else {
        return false
      }
      current = parent
    }
    return false
  }

  private static func directChild(_ processID: pid_t, of ancestorID: pid_t) -> pid_t? {
    guard processID > 0, ancestorID > 0 else { return nil }
    if processID == ancestorID { return processID }
    var current = processID
    for _ in 0..<64 {
      guard let parent = parentProcessID(current), parent > 1, parent != current else { return nil }
      if parent == ancestorID { return current }
      current = parent
    }
    return nil
  }

  private static func processIdentity(_ processID: pid_t) -> String? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard processID > 0,
      proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size
    else { return nil }
    return "\(processID):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
  }

  private static func parentProcessID(_ processID: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
  }

  private static func write(_ data: Data, service: String, account: String) -> Bool {
    _ = delete(service: service, account: account)
    let status = SecItemAdd(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecValueData as String: data,
      ] as CFDictionary,
      nil
    )
    return status == errSecSuccess
  }

  private static func value(service: String, account: String) -> Data? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
      ] as CFDictionary,
      &result
    )
    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  @discardableResult
  private static func delete(service: String, account: String) -> Bool {
    let status = SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ] as CFDictionary
    )
    return status == errSecSuccess || status == errSecItemNotFound
  }

  private static func deleteIfMatching(_ data: Data, service: String, account: String) -> Bool {
    let status = SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: data,
      ] as CFDictionary
    )
    return status == errSecSuccess
  }

  private static func replaceIfMatching(
    _ expected: Data,
    with replacement: Data,
    service: String,
    account: String
  ) -> Bool {
    let status = SecItemUpdate(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: expected,
      ] as CFDictionary,
      [kSecValueData as String: replacement] as CFDictionary
    )
    return status == errSecSuccess
  }

  @discardableResult
  private static func deleteAll(service: String) -> Bool {
    let taskStatus = SecItemDelete(
      [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        as CFDictionary
    )
    let helperStatus = SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: helperService(service),
      ] as CFDictionary
    )
    return [taskStatus, helperStatus].allSatisfy { $0 == errSecSuccess || $0 == errSecItemNotFound }
  }

  private struct Grant: Codable {
    let session: String
    let issuerPID: pid_t
    let issuerIdentity: String
    var taskPID: pid_t?
    var taskIdentity: String?
    let capabilities: [String]
    let expiresAtMs: Int64
  }

  private struct HelperGrant: Codable {
    let session: String
    let issuerPID: pid_t
    let digest: String
    let expiresAtMs: Int64
  }
}
