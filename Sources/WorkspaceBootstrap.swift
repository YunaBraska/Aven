import Foundation

enum WorkspaceBootstrapError: LocalizedError {
  case templateMissing
  case unsafePath(String)
  case databaseInitialization

  var errorDescription: String? {
    switch self {
    case .templateMissing: "Assistant resources are missing from the app."
    case .unsafePath(let path): "Assistant storage uses an unsafe path: \(path)"
    case .databaseInitialization: "Assistant memory could not be initialized."
    }
  }
}

enum WorkspaceBootstrap {
  private static let managedPaths = [
    "AGENTS.md",
    "README.md",
    "database/README.md",
    "database/maintain.sql",
    "database/schema.sql",
    "decisions/assistant-policy.md",
  ]

  static func prepare(
    workspaceURL: URL = AssistantPaths.workspaceURL,
    templateURL: URL? = Bundle.main.resourceURL?.appendingPathComponent(
      "AssistantTemplate",
      isDirectory: true
    ),
    sqliteURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  ) throws {
    guard let templateURL, isSafeDirectory(templateURL) else {
      throw WorkspaceBootstrapError.templateMissing
    }
    let rootURL = workspaceURL.deletingLastPathComponent()
    try preparePrivateDirectory(rootURL)
    if !FileManager.default.fileExists(atPath: workspaceURL.path) {
      try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }
    try preparePrivateDirectory(workspaceURL)
    try installManagedResources(from: templateURL, to: workspaceURL)
    try installManagedSkills(from: templateURL, to: workspaceURL)
    try installMissingResources(from: templateURL, to: workspaceURL, excluding: ["skills"])
    try initializeDatabase(workspaceURL: workspaceURL, sqliteURL: sqliteURL)
  }

  private static func installManagedResources(from templateURL: URL, to workspaceURL: URL) throws {
    for relativePath in managedPaths {
      let source = templateURL.appendingPathComponent(relativePath)
      let destination = workspaceURL.appendingPathComponent(relativePath)
      guard FileManager.default.fileExists(atPath: source.path) else { continue }
      try preparePrivateDirectory(destination.deletingLastPathComponent())
      if FileManager.default.fileExists(atPath: destination.path) {
        let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
          throw WorkspaceBootstrapError.unsafePath(destination.path)
        }
        if resourcesEqual(source, destination) { continue }
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  private static func installManagedSkills(from templateURL: URL, to workspaceURL: URL) throws {
    let sourceRoot = templateURL.appendingPathComponent("skills", isDirectory: true)
    guard isSafeDirectory(sourceRoot) else { return }
    let destinationRoot = workspaceURL
      .appendingPathComponent(".agents", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
    try preparePrivateDirectory(destinationRoot)
    let skills = try FileManager.default.contentsOfDirectory(
      at: sourceRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    for source in skills.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard let values = try? source.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      ) else { continue }
      guard values.isDirectory == true, values.isSymbolicLink != true,
        FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path)
      else { continue }
      let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
      if FileManager.default.fileExists(atPath: destination.path) {
        guard let destinationValues = try? destination.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { continue }
        guard destinationValues.isDirectory == true, destinationValues.isSymbolicLink != true
        else { continue }
        if resourcesEqual(source, destination) { continue }
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  private static func installMissingResources(
    from source: URL,
    to destination: URL,
    excluding excludedNames: Set<String> = []
  ) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    for entry in entries {
      if excludedNames.contains(entry.lastPathComponent) { continue }
      let relative = entry.path.replacingOccurrences(of: source.path + "/", with: "")
      if managedPaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
        continue
      }
      let target = destination.appendingPathComponent(entry.lastPathComponent)
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw WorkspaceBootstrapError.unsafePath(entry.path) }
      if values.isDirectory == true {
        try preparePrivateDirectory(target)
        try installMissingResources(from: entry, to: target)
      } else if !FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.copyItem(at: entry, to: target)
      }
    }
  }

  private static func initializeDatabase(workspaceURL: URL, sqliteURL: URL) throws {
    let databaseDirectory = workspaceURL.appendingPathComponent("database", isDirectory: true)
    try preparePrivateDirectory(databaseDirectory)
    let databaseURL = databaseDirectory.appendingPathComponent("assistant.sqlite3")
    let schemaURL = databaseDirectory.appendingPathComponent("schema.sql")
    let appliedSchemaURL = databaseDirectory.appendingPathComponent(".applied-schema.sql")
    let schema = try Data(contentsOf: schemaURL)
    if FileManager.default.fileExists(atPath: databaseURL.path),
      (try? Data(contentsOf: appliedSchemaURL)) == schema
    {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: databaseURL.path
      )
      return
    }
    let process = Process()
    let input = Pipe()
    let errors = Pipe()
    process.executableURL = sqliteURL
    process.arguments = [databaseURL.path]
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    do {
      try process.run()
      try input.fileHandleForWriting.write(contentsOf: schema)
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
    } catch {
      throw WorkspaceBootstrapError.databaseInitialization
    }
    guard process.terminationStatus == 0 else {
      throw WorkspaceBootstrapError.databaseInitialization
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: databaseURL.path
    )
    try schema.write(to: appliedSchemaURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: appliedSchemaURL.path
    )
  }

  private static func resourcesEqual(_ left: URL, _ right: URL) -> Bool {
    guard let leftValues = try? left.resourceValues(forKeys: [.isDirectoryKey]),
      let rightValues = try? right.resourceValues(forKeys: [.isDirectoryKey]),
      leftValues.isDirectory == rightValues.isDirectory
    else { return false }
    if leftValues.isDirectory != true {
      return (try? Data(contentsOf: left)) == (try? Data(contentsOf: right))
    }
    guard let leftFiles = relativeFiles(in: left), let rightFiles = relativeFiles(in: right),
      leftFiles == rightFiles
    else { return false }
    return leftFiles.allSatisfy { relative in
      (try? Data(contentsOf: left.appendingPathComponent(relative)))
        == (try? Data(contentsOf: right.appendingPathComponent(relative)))
    }
  }

  private static func relativeFiles(in root: URL) -> Set<String>? {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return nil }
    var result = Set<String>()
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      ), values.isSymbolicLink != true
      else { return nil }
      if values.isRegularFile == true {
        result.insert(String(url.path.dropFirst(root.path.count + 1)))
      }
    }
    return result
  }

  private static func preparePrivateDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      guard isSafeDirectory(url) else { throw WorkspaceBootstrapError.unsafePath(url.path) }
    } else {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: url.path
    )
  }

  private static func isSafeDirectory(_ url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path),
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else {
      return false
    }
    return values.isDirectory == true && values.isSymbolicLink != true
  }
}
