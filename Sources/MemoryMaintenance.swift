import Foundation

enum MemoryMaintenance {
  static func maintain(
    workspaceURL: URL = AssistantPaths.workspaceURL,
    maintenanceURL: URL? = Bundle.main.resourceURL?
      .appendingPathComponent("AssistantTemplate/database/maintain.sql"),
    sqliteURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  ) -> Bool {
    let databaseURL = workspaceURL.appendingPathComponent("database/assistant.sqlite3")
    guard let maintenanceURL else { return false }
    let databaseValues = try? databaseURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    let maintenanceValues = try? maintenanceURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard FileManager.default.isExecutableFile(atPath: sqliteURL.path),
      databaseValues?.isRegularFile == true, databaseValues?.isSymbolicLink != true,
      maintenanceValues?.isRegularFile == true, maintenanceValues?.isSymbolicLink != true,
      let sql = try? Data(contentsOf: maintenanceURL)
    else { return false }

    let process = Process()
    let input = Pipe()
    process.executableURL = sqliteURL
    process.arguments = [databaseURL.path]
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      var guardedSQL = Data(".bail on\n".utf8)
      guardedSQL.append(sql)
      try input.fileHandleForWriting.write(contentsOf: guardedSQL)
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
