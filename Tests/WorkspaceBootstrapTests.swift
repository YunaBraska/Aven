import Foundation

@main
enum WorkspaceBootstrapTests {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else { fail("template path is required") }
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("aven-bootstrap-\(UUID().uuidString)", isDirectory: true)
    let template = root.appendingPathComponent("template", isDirectory: true)
    let workspace = root.appendingPathComponent("data/Assistant", isDirectory: true)
    let preserved = workspace.appendingPathComponent("memory/preserved.md")
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.copyItem(
      at: URL(fileURLWithPath: CommandLine.arguments[1]),
      to: template
    )
    try verifiesStorageMigration(in: root)
    try verifiesHistoricalWorkspaceArchival(in: root)

    try WorkspaceBootstrap.prepare(
      workspaceURL: workspace,
      templateURL: template,
      sqliteURL: URL(fileURLWithPath: "/usr/bin/sqlite3")
    )

    let installedRules = try String(
      contentsOf: workspace.appendingPathComponent("AGENTS.md"),
      encoding: .utf8
    )
    expect(installedRules.contains("You begin without a stored name"), "managed rules were not installed")
    let installedSkillRoot = workspace.appendingPathComponent(".agents/skills")
    let templateSkillRoot = template.appendingPathComponent("skills")
    let bundledSkills = try skillNames(at: templateSkillRoot)
    expect(!bundledSkills.isEmpty, "the template must contain skills")
    expect(
      try skillNames(at: installedSkillRoot) == bundledSkills,
      "every bundled skill must be discovered and installed dynamically"
    )
    let assistantControl = installedSkillRoot.appendingPathComponent("assistant-control/SKILL.md")
    expect(fileManager.fileExists(atPath: assistantControl.path), "assistant control skill was not installed")
    expect(
      fileManager.fileExists(
        atPath: installedSkillRoot.appendingPathComponent("quality-review/SKILL.md").path
      ),
      "quality review skill was not installed"
    )
    expect(
      fileManager.fileExists(
        atPath: installedSkillRoot.appendingPathComponent("diagram-workbench/SKILL.md").path
      ),
      "diagram workbench skill was not installed"
    )
    for skill in [
      "artifact-inspection", "authenticated-rest", "browser-testing", "git-workflow",
      "operations-observability",
      "web-research", "pragmatic-rest", "macos-operations", "modern-languages", "ui-ux",
      "macos-preferences", "macos-app-lifecycle", "macos-automation",
      "voice-small-talk", "voice-games", "spoken-clarity", "on-demand-context",
    ] {
      expect(
        fileManager.fileExists(
          atPath: installedSkillRoot.appendingPathComponent("\(skill)/SKILL.md").path
        ),
        "optional skill \(skill) was not installed"
      )
    }
    let environmentAdaptation = installedSkillRoot.appendingPathComponent(
      "environment-adaptation/SKILL.md"
    )
    expect(
      fileManager.fileExists(
        atPath: workspace.appendingPathComponent("decisions/assistant-policy.md").path
      ),
      "portable assistant policy was not installed"
    )
    let database = workspace.appendingPathComponent("database/assistant.sqlite3")
    expect(fileManager.fileExists(atPath: database.path), "memory database was not initialized")
    expect(query(database, "PRAGMA user_version;") == "3", "memory schema was not applied")
    expect(
      query(database, "SELECT coalesce(display_name, '<unnamed>') FROM assistant_identity;")
        == "<unnamed>",
      "assistant identity must begin unnamed"
    )
    expect(permissions(workspace) == 0o700, "workspace permissions must be private")
    expect(permissions(database) == 0o600, "database permissions must be private")
    let databaseModifiedAt = try modificationDate(database)
    let unchangedSkill = installedSkillRoot.appendingPathComponent("calendar-access/SKILL.md")
    let unchangedSkillModifiedAt = try modificationDate(unchangedSkill)

    let customSkill = installedSkillRoot.appendingPathComponent("user-owned/SKILL.md")
    try fileManager.createDirectory(
      at: customSkill.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("custom".utf8).write(to: customSkill)

    try Data("user update".utf8).write(to: preserved)
    try Data("tampered rules".utf8).write(to: workspace.appendingPathComponent("AGENTS.md"))
    try Data("old controls".utf8).write(to: assistantControl)
    try Data("old path policy".utf8).write(to: environmentAdaptation)
    let malformedSkill = templateSkillRoot.appendingPathComponent("malformed-skill")
    try fileManager.createDirectory(at: malformedSkill, withIntermediateDirectories: true)
    try Data("not a skill".utf8).write(to: malformedSkill.appendingPathComponent("README.md"))
    try WorkspaceBootstrap.prepare(
      workspaceURL: workspace,
      templateURL: template,
      sqliteURL: URL(fileURLWithPath: "/usr/bin/sqlite3")
    )
    expect(
      try String(
        contentsOf: workspace.appendingPathComponent("memory/preserved.md"),
        encoding: .utf8
      ) == "user update",
      "bootstrap must not overwrite user-owned memory"
    )
    expect(
      try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        .contains("You begin without a stored name"),
      "request-boundary bootstrap must restore managed rules"
    )
    expect(
      try String(contentsOf: assistantControl, encoding: .utf8).contains("result set"),
      "request-boundary bootstrap must update managed assistant controls"
    )
    expect(
      try String(contentsOf: environmentAdaptation, encoding: .utf8)
        .contains("does not maintain a writable-path allowlist"),
      "request-boundary bootstrap must update managed environment rules"
    )
    expect(
      try String(contentsOf: customSkill, encoding: .utf8) == "custom",
      "dynamic skill updates must preserve user-owned skills"
    )
    expect(
      try modificationDate(database) == databaseModifiedAt,
      "an unchanged schema must not start a SQLite rewrite"
    )
    expect(
      try modificationDate(unchangedSkill) == unchangedSkillModifiedAt,
      "an unchanged bundled skill must not be recopied"
    )
    expect(
      !fileManager.fileExists(atPath: installedSkillRoot.appendingPathComponent("malformed-skill").path),
      "one malformed optional skill must be isolated from the remaining bootstrap"
    )
    print("Workspace bootstrap tests passed")
  }

  private static func verifiesStorageMigration(in root: URL) throws {
    let parent = root.appendingPathComponent("storage", isDirectory: true)
    let legacy = parent.appendingPathComponent("Voice Assistant", isDirectory: true)
    let current = parent.appendingPathComponent("Aven", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("preserved".utf8).write(to: legacy.appendingPathComponent("memory"))

    expect(
      try AssistantStorageMigration.prepare(legacyURL: legacy, currentURL: current) == .migrated,
      "legacy Application Support should migrate atomically"
    )
    expect(
      try String(contentsOf: current.appendingPathComponent("memory"), encoding: .utf8) == "preserved",
      "storage migration must preserve assistant data"
    )
    expect(!FileManager.default.fileExists(atPath: legacy.path), "old storage name must be removed")

    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("legacy".utf8).write(to: legacy.appendingPathComponent("conflict"))
    expect(
      try AssistantStorageMigration.prepare(legacyURL: legacy, currentURL: current) == .conflict,
      "two nonempty stores must never be merged destructively"
    )
    expect(
      FileManager.default.fileExists(atPath: legacy.appendingPathComponent("conflict").path),
      "conflicting legacy data must remain intact"
    )
  }

  private static func verifiesHistoricalWorkspaceArchival(in root: URL) throws {
    let legacy = root.appendingPathComponent("VoiceAssistant", isDirectory: true)
    let archive = root.appendingPathComponent("private/Historical Workspace", isDirectory: true)
    try FileManager.default.createDirectory(
      at: legacy.appendingPathComponent("decisions", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("# Voice Assistant\n\nEigener Arbeitsbereich des Menüleisten-Assistenten.\n".utf8)
      .write(to: legacy.appendingPathComponent("README.md"))
    try Data("""
      # 0001 – Begrenzte Berechtigungen des Sprachassistenten

      Der Assistent erhält Schreibzugriff.
      """.utf8).write(
        to: legacy.appendingPathComponent("decisions/0001-assistant-boundaries.md")
      )

    expect(
      try AssistantStorageMigration.prepareLegacyWorkspace(
        legacyURL: legacy,
        archiveURL: archive
      ) == .migrated,
      "verified home-directory workspace should move into private Aven storage"
    )
    expect(!FileManager.default.fileExists(atPath: legacy.path), "old home folder must be removed")
    expect(
      AssistantPaths.isVerifiedLegacyWorkspace(archive),
      "the private archive must retain verifiable thread-ownership evidence"
    )
  }

  private static func query(_ database: URL, _ sql: String) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("sqlite query failed") }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func permissions(_ url: URL) -> Int {
    let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as! NSNumber).intValue
  }

  private static func skillNames(at root: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      return values.isDirectory == true ? url.lastPathComponent : nil
    })
  }

  private static func modificationDate(_ url: URL) throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let date = attributes[.modificationDate] as? Date else {
      fail("missing modification date for \(url.path)")
    }
    return date
  }

  private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
      if try !condition() { fail(message) }
    } catch {
      fail("\(message): \(error.localizedDescription)")
    }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}
