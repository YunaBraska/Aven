import Darwin
import Foundation

final class SingleInstanceLock {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  static func acquire(at fileURL: URL = AssistantPaths.instanceLockURL) -> SingleInstanceLock? {
    let manager = FileManager.default
    do {
      try manager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return nil
    }
    let descriptor = Darwin.open(fileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
      Darwin.close(descriptor)
      return nil
    }
    _ = Darwin.ftruncate(descriptor, 0)
    let processID = "\(ProcessInfo.processInfo.processIdentifier)\n"
    _ = processID.withCString { pointer in
      Darwin.write(descriptor, pointer, strlen(pointer))
    }
    return SingleInstanceLock(descriptor: descriptor)
  }

  deinit {
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    Darwin.close(descriptor)
  }
}
