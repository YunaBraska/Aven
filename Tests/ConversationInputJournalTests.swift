import Foundation

@main
enum ConversationInputJournalTests {
  static func main() {
    persistsUntilAcknowledged()
    preservesFifoAcrossRestarts()
    snapshotsAttachmentsUntilAcknowledged()
    quarantinesDamagedJournalBeforeAcceptingNewInput()
    quarantinesStructurallyValidEmptyEntries()
    rejectsUnsafeOrUnboundedInput()
    print("Conversation input journal tests passed")
  }

  private static func persistsUntilAcknowledged() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-input-journal-\(UUID().uuidString)")
    let file = root.appendingPathComponent("pending.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = ConversationInputJournal(fileURL: file)
    let input = try! journal.enqueue(text: "never lose this")

    expect(journal.count == 1, "an accepted input must be durable before routing")
    expect(
      ConversationInputJournal(fileURL: file).pendingInputs == [input],
      "an unacknowledged input must survive an app restart"
    )
    try! journal.acknowledge(input)
    expect(
      ConversationInputJournal(fileURL: file).pendingInputs.isEmpty,
      "only acknowledged input should leave the journal"
    )
  }

  private static func preservesFifoAcrossRestarts() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-input-order-\(UUID().uuidString)")
    let file = root.appendingPathComponent("pending.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = ConversationInputJournal(fileURL: file)
    _ = try! journal.enqueue(text: "first")
    _ = try! journal.enqueue(text: "second")

    expect(
      ConversationInputJournal(fileURL: file).pendingInputs.map(\.text) == ["first", "second"],
      "recovered inputs must preserve submission order"
    )
  }

  private static func snapshotsAttachmentsUntilAcknowledged() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-input-attachment-\(UUID().uuidString)")
    let file = root.appendingPathComponent("pending.json")
    let source = root.appendingPathComponent("source.txt")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data("accepted contents".utf8).write(to: source)
    let journal = ConversationInputJournal(fileURL: file)
    let input = try! journal.enqueue(text: "inspect this", attachments: [source])

    expect(input.attachments.count == 1, "an accepted attachment must have one private snapshot")
    let snapshot = input.attachments[0]
    expect(snapshot != source, "the durable queue must not retain the mutable source path")
    try! Data("changed later".utf8).write(to: source)
    expect(
      try! String(contentsOf: snapshot, encoding: .utf8) == "accepted contents",
      "later source changes must not alter an accepted attachment"
    )
    let recovered = ConversationInputJournal(fileURL: file).pendingInputs[0]
    expect(
      try! String(contentsOf: recovered.attachments[0], encoding: .utf8) == "accepted contents",
      "the immutable attachment snapshot must survive restart"
    )
    try! journal.acknowledge(input)
    expect(
      !FileManager.default.fileExists(atPath: snapshot.path),
      "acknowledgement must remove private attachment snapshots"
    )
  }

  private static func quarantinesDamagedJournalBeforeAcceptingNewInput() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-input-corrupt-\(UUID().uuidString)")
    let file = root.appendingPathComponent("pending.json")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data("not a journal".utf8).write(to: file)

    let journal = ConversationInputJournal(fileURL: file)
    expect(journal.pendingInputs.isEmpty, "a damaged journal must not be treated as queued input")
    expect(journal.recoveryWarning != nil, "a damaged journal must report recovery")
    expect(
      (try! FileManager.default.contentsOfDirectory(atPath: root.path))
        .contains(where: { $0.contains("corrupt-") }),
      "a damaged journal must be quarantined instead of overwritten"
    )
    _ = try! journal.enqueue(text: "safe replacement")
    expect(journal.count == 1, "a recovered journal should accept new durable input")
  }

  private static func quarantinesStructurallyValidEmptyEntries() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-input-empty-\(UUID().uuidString)")
    let file = root.appendingPathComponent("pending.json")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let entry = """
      [{"attachments":[],"createdAt":0,"id":"00000000-0000-0000-0000-000000000001","text":"   "}]
      """
    try! Data(entry.utf8).write(to: file)

    let journal = ConversationInputJournal(fileURL: file)
    expect(journal.pendingInputs.isEmpty, "persisted empty input must never reach the live queue")
    expect(journal.recoveryWarning != nil, "invalid persisted input must be quarantined visibly")
  }

  private static func rejectsUnsafeOrUnboundedInput() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-input-bounds-\(UUID().uuidString)")
    let file = root.appendingPathComponent("pending.json")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let attachment = root.appendingPathComponent("attachment.txt")
    let emptyAttachment = root.appendingPathComponent("empty.txt")
    try! Data("safe".utf8).write(to: attachment)
    try! Data().write(to: emptyAttachment)
    let symlink = root.appendingPathComponent("attachment-link.txt")
    try! FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: attachment)
    let journal = ConversationInputJournal(fileURL: file)

    expectThrows("oversized messages must be rejected") {
      _ = try journal.enqueue(
        text: String(repeating: "x", count: ConversationInputJournal.maximumMessageBytes + 1)
      )
    }
    expectThrows("symbolic-link attachments must be rejected") {
      _ = try journal.enqueue(text: "unsafe", attachments: [symlink])
    }
    expectThrows("empty attachments must be rejected") {
      _ = try journal.enqueue(text: "empty", attachments: [emptyAttachment])
    }
    expectThrows("attachment count must be bounded") {
      _ = try journal.enqueue(
        text: "too many",
        attachments: Array(repeating: attachment, count: ConversationInputJournal.maximumAttachments + 1)
      )
    }
  }

  private static func expectThrows(_ message: String, _ operation: () throws -> Void) {
    do {
      try operation()
      expect(false, message)
    } catch {
      return
    }
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
      exit(1)
    }
  }
}
