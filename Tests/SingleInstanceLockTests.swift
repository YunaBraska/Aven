import Foundation

@main
enum SingleInstanceLockTests {
  static func main() {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe" {
      let acquired = SingleInstanceLock.acquire(
        at: URL(fileURLWithPath: CommandLine.arguments[2])
      )
      exit(acquired == nil ? 0 : 1)
    }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-instance-lock-\(UUID().uuidString)")
    let file = root.appendingPathComponent("Aven.lock")
    defer { try? FileManager.default.removeItem(at: root) }

    var first: SingleInstanceLock? = SingleInstanceLock.acquire(at: file)
    expect(first != nil, "the first Aven instance should acquire the lock")
    expect(probe(file) == 0, "a second Aven process must be rejected")
    first = nil
    expect(probe(file) == 1, "the lock should be reusable after shutdown")
    print("Single-instance tests passed")
  }

  private static func probe(_ file: URL) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--probe", file.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
      exit(1)
    }
  }
}
