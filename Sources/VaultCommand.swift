import CryptoKit
import Darwin
import Foundation

enum VaultCommand {
  typealias HelperAuthorization = (String?, URL, [String]) -> Bool
  private static let maximumOutputBytes = 8_388_608
  private static let helperCommand = "__voice_assistant_vault_exec"

  static func handles(_ arguments: [String]) -> Bool {
    arguments.first == "vault" || arguments.first == helperCommand
  }

  static func run(
    arguments: [String],
    authorizeHelper: HelperAuthorization = defaultHelperAuthorization
  ) -> Int32 {
    if arguments.first == helperCommand {
      return runIsolatedHelper(
        arguments: Array(arguments.dropFirst()),
        authorize: authorizeHelper
      )
    }
    do {
      let output = try execute(Array(arguments.dropFirst()))
      if !output.isEmpty {
        FileHandle.standardOutput.write(output)
        if output.last != 0x0A { FileHandle.standardOutput.write(Data([0x0A])) }
      }
      return 0
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "Credential command failed."
      FileHandle.standardError.write(Data("vault: \(message)\n".utf8))
      return 1
    }
  }

  private static func execute(_ arguments: [String]) throws -> Data {
    guard let command = arguments.first else { throw usage() }
    guard TaskCapabilityBroker.authorizes(
      ProcessInfo.processInfo.environment["VOICE_ASSISTANT_TASK_CAPABILITY"],
      capability: .vault
    ) else {
      throw CredentialVaultError.unavailable("vault access is available only during an active Aven task.")
    }
    let vault = CredentialVault()
    switch command {
    case "status":
      guard arguments.count == 1 else { throw usage() }
      try vault.verifyAccess()
      let records = try vault.list()
      return try json(["available": true, "records": records.count, "storage": "macOS Keychain"])
    case "list":
      guard arguments.count == 1 else { throw usage() }
      return try JSONEncoder.vault.encode(vault.list())
    case "env-keys":
      let options = try Options(Array(arguments.dropFirst()))
      let file = URL(fileURLWithPath: try options.required("file")).standardizedFileURL
      try options.rejectUnused()
      return try JSONEncoder.vault.encode(CredentialVault.envKeys(from: file))
    case "import-env":
      let options = try Options(Array(arguments.dropFirst()), repeatable: ["argument"])
      let kind = try secretKind(options.required("kind"))
      guard kind != .browserSession else {
        throw CredentialVaultError.invalidInput("Use import-file for browser sessions.")
      }
      let file = URL(fileURLWithPath: try options.required("file")).standardizedFileURL
      let key = try options.required("key")
      let origin = options.value("origin")
      let executable = URL(fileURLWithPath: try options.required("executable"))
      let accessScope = try CredentialVault.accessScope(
        executable: executable,
        arguments: options.values("argument"),
        environment: options.required("environment"),
        operation: options.required("operation"),
        destination: origin
      )
      let secret = try CredentialVault.envValue(named: key, from: file)
      let summary = try vault.store(
        service: options.required("service"),
        account: options.required("account"),
        kind: kind,
        purpose: options.required("purpose"),
        origin: origin,
        source: VaultSource(path: file.path, key: key, format: "env"),
        accessScope: accessScope,
        secret: secret,
        ttl: try options.duration("ttl-seconds")
      )
      try options.rejectUnused()
      return try JSONEncoder.vault.encode(summary)
    case "import-file":
      let options = try Options(Array(arguments.dropFirst()), repeatable: ["argument"])
      let kind = try secretKind(options.required("kind"))
      guard kind == .browserSession else {
        throw CredentialVaultError.invalidInput("import-file accepts browser_session only.")
      }
      let file = URL(fileURLWithPath: try options.required("file")).standardizedFileURL
      let origin = options.value("origin")
      let executable = URL(fileURLWithPath: try options.required("executable"))
      let accessScope = try CredentialVault.accessScope(
        executable: executable,
        arguments: options.values("argument"),
        environment: options.required("environment"),
        operation: options.required("operation"),
        destination: origin
      )
      let secret = try CredentialVault.fileValue(from: file)
      let summary = try vault.store(
        service: options.required("service"),
        account: options.required("account"),
        kind: kind,
        purpose: options.required("purpose"),
        origin: origin,
        source: nil,
        accessScope: accessScope,
        secret: secret,
        ttl: try options.duration("ttl-seconds")
      )
      try options.rejectUnused()
      return try JSONEncoder.vault.encode(summary)
    case "refresh":
      guard arguments.count == 1 else { throw usage() }
      return try json(["updated": vault.refresh()])
    case "prune":
      guard arguments.count == 1 else { throw usage() }
      return try json(["removed": vault.prune()])
    case "remove":
      guard arguments.count == 2 else { throw usage() }
      try vault.remove(id: arguments[1])
      return try json(["removed": arguments[1]])
    case "run":
      return try run(vault: vault, arguments: Array(arguments.dropFirst()))
    default:
      throw usage()
    }
  }

  private static func run(vault: CredentialVault, arguments: [String]) throws -> Data {
    guard let separator = arguments.firstIndex(of: "--"), separator < arguments.count - 1 else {
      throw usage()
    }
    let options = try Options(Array(arguments[..<separator]), repeatable: ["bind"])
    let bindings = try options.values("bind").map(parseBinding)
    let timeout = try options.duration("timeout-seconds") ?? 120
    guard timeout >= 1, timeout <= 900 else {
      throw CredentialVaultError.invalidInput("Run timeout must be between 1 and 900 seconds.")
    }
    try options.rejectUnused()
    guard !bindings.isEmpty else {
      throw CredentialVaultError.invalidInput("At least one credential binding is required.")
    }

    let command = Array(arguments[arguments.index(after: separator)...])
    guard command[0].hasPrefix("/") else {
      throw CredentialVaultError.invalidInput("The executable must use an absolute path.")
    }
    let requestedExecutable = URL(fileURLWithPath: command[0]).standardizedFileURL

    var environment = ProcessInfo.processInfo.environment
    var redactions: [Data] = []
    var usedIDs: [String] = []
    var temporaryFiles: [URL] = []
    var authorizedExecutable: URL?
    defer {
      for file in temporaryFiles {
        try? FileManager.default.removeItem(at: file)
      }
    }

    for binding in bindings {
      let record = try vault.resolve(id: binding.id)
      let executable = try CredentialVault.validateAccess(
        record.accessScope,
        executable: requestedExecutable,
        arguments: Array(command.dropFirst()),
        environment: binding.environment
      )
      guard executable.path == record.accessScope?.executable else {
        throw CredentialVaultError.invalidInput("Credential executable scope changed.")
      }
      if let authorizedExecutable, authorizedExecutable != executable {
        throw CredentialVaultError.invalidInput("All credential bindings must use one executable.")
      }
      authorizedExecutable = executable
      usedIDs.append(record.id)
      switch record.kind {
      case .browserSession:
        let file = try temporarySecretFile(record.secret, id: record.id, rootURL: vault.rootURL)
        temporaryFiles.append(file)
        environment[binding.environment] = file.path
        redactions.append(record.secret)
      case .totpSeed:
        let code = try TOTP.currentCode(seed: record.secret)
        environment[binding.environment] = code
        redactions.append(Data(code.utf8))
      case .password, .token:
        guard let value = String(data: record.secret, encoding: .utf8), !value.contains("\0") else {
          throw CredentialVaultError.invalidInput("Text credential is not valid UTF-8.")
        }
        environment[binding.environment] = value
        redactions.append(record.secret)
      }
    }

    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    guard let authorizedExecutable else {
      throw CredentialVaultError.invalidInput("Credential executable scope is missing.")
    }
    guard let helperToken = TaskCapabilityBroker.issueVaultHelper(
      executable: authorizedExecutable,
      arguments: Array(command.dropFirst())
    ) else {
      throw CredentialVaultError.unavailable("vault command isolation is unavailable for this task.")
    }
    process.arguments = [helperCommand, authorizedExecutable.path] + Array(command.dropFirst())
    process.environment = environment
    process.environment?["VOICE_ASSISTANT_VAULT_HELPER_TOKEN"] = helperToken
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw CredentialVaultError.storage("credential-bound command could not start")
    }

    let processGroupID = process.processIdentifier
    let collected = collect(
      process: process,
      processGroupID: processGroupID,
      stdout: stdout,
      stderr: stderr,
      timeout: timeout
    )
    try vault.markUsed(ids: usedIDs)
    let output = redact(collected.stdout, secrets: redactions)
    let errors = redact(collected.stderr, secrets: redactions)
    if !output.isEmpty { FileHandle.standardOutput.write(output) }
    if !errors.isEmpty { FileHandle.standardError.write(errors) }
    if collected.timedOut {
      throw CredentialVaultError.storage("credential-bound command timed out")
    }
    if process.terminationStatus != 0 {
      throw CredentialVaultError.storage(
        "credential-bound command exited with status \(process.terminationStatus)"
      )
    }
    return Data()
  }

  private static func collect(
    process: Process,
    processGroupID: pid_t,
    stdout: Pipe,
    stderr: Pipe,
    timeout: TimeInterval
  ) -> (stdout: Data, stderr: Data, timedOut: Bool) {
    let group = DispatchGroup()
    let lock = NSLock()
    var output = Data()
    var errors = Data()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      drain(stdout.fileHandleForReading) { chunk in
        lock.withVaultLock { appendBounded(chunk, to: &output) }
      }
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      drain(stderr.fileHandleForReading) { chunk in
        lock.withVaultLock { appendBounded(chunk, to: &errors) }
      }
      group.leave()
    }
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    let timeoutLock = NSLock()
    var timedOut = false
    let terminateProcessGroup = {
      timeoutLock.withVaultLock { timedOut = true }
      Darwin.kill(-processGroupID, SIGKILL)
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler(handler: terminateProcessGroup)
    timer.resume()
    process.waitUntilExit()
    Darwin.kill(-processGroupID, SIGKILL)
    if group.wait(timeout: .now() + 3) == .timedOut {
      timeoutLock.withVaultLock { timedOut = true }
    }
    timer.cancel()
    return lock.withVaultLock {
      (output, errors, timeoutLock.withVaultLock { timedOut })
    }
  }

  private static func drain(_ handle: FileHandle, consume: (Data) -> Void) {
    while true {
      let data = handle.readData(ofLength: 16_384)
      guard !data.isEmpty else { return }
      consume(data)
    }
  }

  private static func runIsolatedHelper(
    arguments: [String],
    authorize: HelperAuthorization
  ) -> Int32 {
    guard let executable = arguments.first, executable.hasPrefix("/") else { return 126 }
    let executableURL = URL(fileURLWithPath: executable).standardizedFileURL
    guard authorize(
      ProcessInfo.processInfo.environment["VOICE_ASSISTANT_VAULT_HELPER_TOKEN"],
      executableURL,
      Array(arguments.dropFirst())
    ) else {
      FileHandle.standardError.write(Data("vault helper: authorization is unavailable\n".utf8))
      return 126
    }
    Darwin.unsetenv("VOICE_ASSISTANT_VAULT_HELPER_TOKEN")
    Darwin.unsetenv("VOICE_ASSISTANT_TASK_CAPABILITY")
    let processID = Darwin.getpid()
    guard Darwin.getpgrp() == processID || Darwin.setsid() >= 0 else {
      FileHandle.standardError.write(Data("vault helper: process isolation failed\n".utf8))
      return 126
    }
    let allocated = arguments.map { strdup($0) }
    guard allocated.allSatisfy({ $0 != nil }) else {
      allocated.forEach { free($0) }
      return 126
    }
    defer { allocated.forEach { free($0) } }
    var pointers = allocated + [nil]
    if Darwin.execv(executableURL.path, &pointers) == -1 {
      FileHandle.standardError.write(Data("vault helper: executable could not start\n".utf8))
      return 126
    }
    return 0
  }

  private static func defaultHelperAuthorization(
    _ token: String?,
    _ executable: URL,
    _ arguments: [String]
  ) -> Bool {
    TaskCapabilityBroker.consumeVaultHelper(
      token,
      executable: executable,
      arguments: arguments
    )
  }

  private static func appendBounded(_ chunk: Data, to target: inout Data) {
    guard target.count < maximumOutputBytes else { return }
    target.append(chunk.prefix(maximumOutputBytes - target.count))
  }

  private static func redact(_ data: Data, secrets: [Data]) -> Data {
    var text = String(decoding: data, as: UTF8.self)
    for secret in secrets where secret.count >= 4 {
      let literal = String(decoding: secret, as: UTF8.self)
      text = text.replacingOccurrences(of: literal, with: "[REDACTED]")
      text = text.replacingOccurrences(of: secret.base64EncodedString(), with: "[REDACTED]")
    }
    return Data(text.utf8)
  }

  private static func temporarySecretFile(_ data: Data, id: String, rootURL: URL) throws -> URL {
    let directory = rootURL.appendingPathComponent("Runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: directory.path
    )
    let url = directory.appendingPathComponent("\(id)-\(UUID().uuidString).session")
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: url.path
    )
    return url
  }

  private static func parseBinding(_ value: String) throws -> Binding {
    guard let equals = value.firstIndex(of: "=") else {
      throw CredentialVaultError.invalidInput("Binding must be CREDENTIAL_ID=ENV_NAME.")
    }
    let id = String(value[..<equals])
    let environment = String(value[value.index(after: equals)...])
    guard id.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
      environment.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    else {
      throw CredentialVaultError.invalidInput("Binding must be CREDENTIAL_ID=ENV_NAME.")
    }
    return Binding(id: id, environment: environment)
  }

  private static func secretKind(_ value: String) throws -> VaultSecretKind {
    guard let kind = VaultSecretKind(rawValue: value) else {
      throw CredentialVaultError.invalidInput("Unknown credential kind.")
    }
    return kind
  }

  private static func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func usage() -> CredentialVaultError {
    .invalidInput(
      "usage: Aven vault status|list|env-keys|import-env|import-file|refresh|prune|remove|run"
    )
  }

  private struct Binding {
    let id: String
    let environment: String
  }

  private final class Options {
    private var storage: [String: [String]] = [:]
    private var consumed: Set<String> = []

    init(_ arguments: [String], repeatable: Set<String> = []) throws {
      guard arguments.count.isMultiple(of: 2) else { throw VaultCommand.usage() }
      var index = 0
      while index < arguments.count {
        let option = arguments[index]
        guard option.hasPrefix("--"), option.count > 2 else { throw VaultCommand.usage() }
        let name = String(option.dropFirst(2))
        let value = arguments[index + 1]
        guard storage[name] == nil || repeatable.contains(name) else {
          throw CredentialVaultError.invalidInput("Duplicate option --\(name).")
        }
        storage[name, default: []].append(value)
        index += 2
      }
    }

    func required(_ name: String) throws -> String {
      guard let value = value(name) else {
        throw CredentialVaultError.invalidInput("Missing --\(name).")
      }
      return value
    }

    func value(_ name: String) -> String? {
      consumed.insert(name)
      return storage[name]?.last
    }

    func values(_ name: String) -> [String] {
      consumed.insert(name)
      return storage[name] ?? []
    }

    func duration(_ name: String) throws -> TimeInterval? {
      guard let text = value(name) else { return nil }
      guard let value = TimeInterval(text), value.isFinite else {
        throw CredentialVaultError.invalidInput("--\(name) must be seconds.")
      }
      return value
    }

    func rejectUnused() throws {
      let extras = Set(storage.keys).subtracting(consumed)
      guard extras.isEmpty else {
        throw CredentialVaultError.invalidInput("Unknown option --\(extras.sorted()[0]).")
      }
    }
  }
}

enum TOTP {
  static func currentCode(seed: Data, date: Date = Date()) throws -> String {
    let text = String(decoding: seed, as: UTF8.self)
      .replacingOccurrences(of: " ", with: "")
      .uppercased()
    let key = try decodeBase32(text)
    let counter = UInt64(date.timeIntervalSince1970 / 30)
    var bigEndian = counter.bigEndian
    let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
    let hash = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key))
    let bytes = Array(hash)
    let offset = Int(bytes[bytes.count - 1] & 0x0f)
    let value =
      (UInt32(bytes[offset] & 0x7f) << 24)
      | (UInt32(bytes[offset + 1]) << 16)
      | (UInt32(bytes[offset + 2]) << 8)
      | UInt32(bytes[offset + 3])
    return String(format: "%06u", value % 1_000_000)
  }

  private static func decodeBase32(_ value: String) throws -> Data {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
    var buffer = 0
    var bits = 0
    var result = Data()
    for character in value where character != "=" {
      guard let part = lookup[character] else {
        throw CredentialVaultError.invalidInput("TOTP seed is not valid Base32.")
      }
      buffer = (buffer << 5) | part
      bits += 5
      if bits >= 8 {
        bits -= 8
        result.append(UInt8((buffer >> bits) & 0xff))
      }
    }
    guard !result.isEmpty else {
      throw CredentialVaultError.invalidInput("TOTP seed is empty.")
    }
    return result
  }
}

extension JSONEncoder {
  fileprivate static var vault: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension NSLock {
  fileprivate func withVaultLock<T>(_ operation: () -> T) -> T {
    lock()
    defer { unlock() }
    return operation()
  }
}
