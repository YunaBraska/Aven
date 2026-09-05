import Darwin
import Foundation

@main
enum VaultHelperTests {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "__test_voice_assistant_vault_exec" {
      let helperArguments = ["__voice_assistant_vault_exec"] + Array(arguments.dropFirst())
      Darwin.exit(VaultCommand.run(arguments: helperArguments) { _, _, _ in true })
    }
    if VaultCommand.handles(arguments) {
      Darwin.exit(VaultCommand.run(arguments: arguments))
    }
    if arguments.first == "signal-resistant" {
      Darwin.signal(SIGTERM, SIG_IGN)
      while true { Darwin.pause() }
    }
    terminatesTheEntireCredentialProcessGroup()
    forceKillsASignalResistantLeader()
    print("Vault helper tests passed")
  }

  private static func forceKillsASignalResistantLeader() {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "__test_voice_assistant_vault_exec",
      executable.path,
      "signal-resistant",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    Thread.sleep(forTimeInterval: 0.1)
    let groupID = process.processIdentifier
    _ = Darwin.kill(-groupID, SIGTERM)
    Thread.sleep(forTimeInterval: 0.1)
    expect(process.isRunning, "the test leader should ignore graceful termination")
    _ = Darwin.kill(-groupID, SIGKILL)
    process.waitUntilExit()
    expect(!process.isRunning, "forced timeout escalation must terminate a resistant leader")
  }

  private static func terminatesTheEntireCredentialProcessGroup() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-vault-helper-\(UUID().uuidString)")
    let child = root.appendingPathComponent("descendant")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      sleep 60 >/dev/null 2>&1 &
      printf '%s\n' "$!"
      exit 0
      """
    try! Data(script.utf8).write(to: child)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["__test_voice_assistant_vault_exec", child.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    try! process.run()

    let groupID = Darwin.getpgid(process.processIdentifier)
    expect(groupID == process.processIdentifier, "the helper must own a process group before exec")
    let data = output.fileHandleForReading.availableData
    let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let descendantID = pid_t(value) else {
      process.waitUntilExit()
      let detail = String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      fail("the descendant PID should be observable (status \(process.terminationStatus): \(detail))")
    }

    process.waitUntilExit()
    _ = Darwin.kill(-groupID, SIGKILL)
    let deadline = Date(timeIntervalSinceNow: 2)
    while Darwin.kill(descendantID, 0) == 0, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    expect(Darwin.kill(descendantID, 0) == -1 && errno == ESRCH, "the descendant must not survive")
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}
