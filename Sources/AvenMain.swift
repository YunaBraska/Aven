import AppKit
import Darwin

@main
@MainActor
enum AvenMain {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if VaultCommand.handles(arguments) {
      Darwin.exit(VaultCommand.run(arguments: arguments))
    }
    if CalendarCommand.handles(arguments) {
      Darwin.exit(CalendarCommand.run(arguments: arguments))
    }
    if AssistantControlCommand.handles(arguments) {
      Darwin.exit(AssistantControlCommand.run(arguments: arguments))
    }
    if AssistantContextCommand.handles(arguments) {
      Darwin.exit(AssistantContextCommand.run(arguments: arguments))
    }
    var storageWarnings: [String] = []
    do {
      if try AssistantStorageMigration.prepare() == .conflict {
        storageWarnings.append(
          "Legacy Aven data could not be merged automatically. Both storage folders were preserved."
        )
      }
    } catch {
      storageWarnings.append("Legacy Aven data could not be migrated: \(error.localizedDescription)")
    }
    do {
      if try AssistantStorageMigration.prepareLegacyWorkspace() == .conflict {
        storageWarnings.append(
          "The historical assistant workspace could not be archived automatically. Both copies were preserved."
        )
      }
    } catch {
      storageWarnings.append(
        "The historical assistant workspace could not be archived: \(error.localizedDescription)"
      )
    }
    guard let instanceLock = SingleInstanceLock.acquire() else {
      if let identifier = Bundle.main.bundleIdentifier {
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
          .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
          .activate()
      }
      Darwin.exit(0)
    }
    let capabilitySessionStarted = TaskCapabilityBroker.beginSession()
    defer {
      if capabilitySessionStarted { _ = TaskCapabilityBroker.endSession() }
    }
    let startupError: String?
    do {
      try WorkspaceBootstrap.prepare()
      startupError = nil
    } catch {
      startupError = error.localizedDescription
    }
    let application = NSApplication.shared
    let delegate = AppDelegate(
      startupError: startupError,
      startupWarning: storageWarnings.isEmpty ? nil : storageWarnings.joined(separator: " ")
    )
    application.delegate = delegate
    withExtendedLifetime(instanceLock) {
      withExtendedLifetime(delegate) {
        application.run()
      }
    }
  }
}
