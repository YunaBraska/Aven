import Darwin
import Foundation

enum ConversationInputJournalError: LocalizedError {
  case invalidMessage
  case messageTooLarge
  case queueFull
  case tooManyAttachments
  case invalidAttachment
  case attachmentTooLarge
  case storage(String)

  var errorDescription: String? {
    switch self {
    case .invalidMessage:
      "The message is empty."
    case .messageTooLarge:
      "The message is too large to queue safely."
    case .queueFull:
      "Too many requests are already waiting. Finish or clear existing requests first."
    case .tooManyAttachments:
      "Too many attachments were added to one request."
    case .invalidAttachment:
      "An attachment must be a local regular file, not a symbolic link."
    case .attachmentTooLarge:
      "An attachment is too large to queue safely."
    case .storage(let detail):
      "The message could not be queued safely: \(detail)"
    }
  }
}

final class ConversationInputJournal: @unchecked Sendable {
  static let maximumMessageBytes = 64 * 1_024
  static let maximumPendingInputs = 256
  static let maximumAttachments = 16
  static let maximumAttachmentBytes = 64 * 1_024 * 1_024
  static let maximumTotalAttachmentBytes = 256 * 1_024 * 1_024

  private struct Entry: Codable {
    let id: UUID
    let createdAt: Date
    let text: String
    let attachments: [String]

    var input: ConversationInput {
      ConversationInput(
        text: text,
        attachments: attachments.map { URL(fileURLWithPath: $0) },
        deliveryIDs: [id]
      )
    }
  }

  private let fileURL: URL
  private let lock = NSLock()
  private var entries: [Entry]
  private let persistenceBlocker: String?

  /// A recoverable startup condition, such as a quarantined damaged journal.
  let recoveryWarning: String?

  init(fileURL: URL = AssistantPaths.pendingInputsURL) {
    self.fileURL = fileURL.standardizedFileURL
    let loaded = Self.load(fileURL: self.fileURL)
    entries = loaded.entries
    recoveryWarning = loaded.warning
    persistenceBlocker = loaded.persistenceBlocker
  }

  var pendingInputs: [ConversationInput] {
    lock.withInputJournalLock { entries.map(\.input) }
  }

  var count: Int {
    lock.withInputJournalLock { entries.count }
  }

  func enqueue(text: String, attachments: [URL] = []) throws -> ConversationInput {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ConversationInputJournalError.invalidMessage }
    guard normalized.lengthOfBytes(using: .utf8) <= Self.maximumMessageBytes
    else { throw ConversationInputJournalError.messageTooLarge }
    guard attachments.count <= Self.maximumAttachments
    else { throw ConversationInputJournalError.tooManyAttachments }
    let sizes = try attachments.map(Self.validateAttachment)
    guard sizes.reduce(0, +) <= Self.maximumTotalAttachmentBytes
    else { throw ConversationInputJournalError.attachmentTooLarge }
    return try lock.withInputJournalLock {
      if let persistenceBlocker {
        throw ConversationInputJournalError.storage(persistenceBlocker)
      }
      guard entries.count < Self.maximumPendingInputs else {
        throw ConversationInputJournalError.queueFull
      }
      let id = UUID()
      let stagedAttachments: [URL]
      do {
        stagedAttachments = try snapshot(attachments, for: id)
      } catch let error as ConversationInputJournalError {
        throw error
      } catch {
        throw ConversationInputJournalError.storage(error.localizedDescription)
      }
      let entry = Entry(
        id: id,
        createdAt: Date(),
        text: normalized,
        attachments: stagedAttachments.map(\.path)
      )
      var updated = entries
      updated.append(entry)
      do {
        try persist(updated)
      } catch {
        removeAttachmentSnapshots(for: [id])
        throw error
      }
      entries = updated
      return entry.input
    }
  }

  func acknowledge(_ input: ConversationInput) throws {
    let delivered = Set(input.deliveryIDs)
    guard !delivered.isEmpty else { return }
    try lock.withInputJournalLock {
      let updated = entries.filter { !delivered.contains($0.id) }
      guard updated.count != entries.count else { return }
      try persist(updated)
      entries = updated
      removeAttachmentSnapshots(for: delivered)
    }
  }

  func clear() throws {
    try lock.withInputJournalLock {
      try persist([])
      let removed = Set(entries.map(\.id))
      entries = []
      removeAttachmentSnapshots(for: removed)
    }
  }

  private func persist(_ values: [Entry]) throws {
    do {
      let manager = FileManager.default
      let directory = fileURL.deletingLastPathComponent()
      try manager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let data = try JSONEncoder.journalEncoder.encode(values)
      try data.write(to: fileURL, options: .atomic)
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      throw ConversationInputJournalError.storage(error.localizedDescription)
    }
  }

  private func snapshot(_ attachments: [URL], for id: UUID) throws -> [URL] {
    guard !attachments.isEmpty else { return [] }
    let manager = FileManager.default
    let directory = attachmentRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    try manager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      return try attachments.enumerated().map { index, source in
        let destination = directory.appendingPathComponent(
          String(format: "%02d-%@", index, source.lastPathComponent)
        )
        if clonefile(source.standardizedFileURL.path, destination.path, 0) != 0 {
          try? manager.removeItem(at: destination)
          try manager.copyItem(at: source.standardizedFileURL, to: destination)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
      }
    } catch {
      try? manager.removeItem(at: directory)
      throw error
    }
  }

  private var attachmentRoot: URL {
    fileURL.deletingLastPathComponent().appendingPathComponent("pending-attachments", isDirectory: true)
  }

  private func removeAttachmentSnapshots(for ids: Set<UUID>) {
    for id in ids {
      try? FileManager.default.removeItem(
        at: attachmentRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
      )
    }
  }

  private static func validateAttachment(_ value: URL) throws -> Int {
    let url = value.standardizedFileURL
    guard url.isFileURL,
      url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      ), values.isRegularFile == true, values.isSymbolicLink != true
    else { throw ConversationInputJournalError.invalidAttachment }
    guard let size = values.fileSize, size > 0, size <= Self.maximumAttachmentBytes
    else { throw ConversationInputJournalError.attachmentTooLarge }
    return size
  }

  private struct LoadResult {
    let entries: [Entry]
    let warning: String?
    let persistenceBlocker: String?
  }

  private static func load(fileURL: URL) -> LoadResult {
    let manager = FileManager.default
    guard manager.fileExists(atPath: fileURL.path) else {
      return LoadResult(entries: [], warning: nil, persistenceBlocker: nil)
    }
    guard let values = try? fileURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ), values.isRegularFile == true, values.isSymbolicLink != true,
      let data = try? Data(contentsOf: fileURL),
      let entries = try? JSONDecoder.journalDecoder.decode([Entry].self, from: data),
      entries.allSatisfy(Self.isValidPersistedEntry)
    else {
      return quarantineDamagedJournal(fileURL, manager: manager)
    }
    removeOrphanedSnapshots(fileURL: fileURL, retainedIDs: Set(entries.map(\.id)))
    return LoadResult(entries: entries, warning: nil, persistenceBlocker: nil)
  }

  private static func isValidPersistedEntry(_ entry: Entry) -> Bool {
    let normalized = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized == entry.text,
      normalized.lengthOfBytes(using: .utf8) <= maximumMessageBytes,
      entry.attachments.count <= maximumAttachments
    else { return false }
    do {
      let total = try entry.attachments
        .map { try validateAttachment(URL(fileURLWithPath: $0)) }
        .reduce(0, +)
      return total <= maximumTotalAttachmentBytes
    } catch {
      return false
    }
  }

  private static func removeOrphanedSnapshots(fileURL: URL, retainedIDs: Set<UUID>) {
    let root = fileURL.deletingLastPathComponent()
      .appendingPathComponent("pending-attachments", isDirectory: true)
    guard let directories = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    let retained = Set(retainedIDs.map { $0.uuidString.lowercased() })
    for directory in directories where !retained.contains(directory.lastPathComponent) {
      guard let values = try? directory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      ), values.isDirectory == true, values.isSymbolicLink != true else { continue }
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private static func quarantineDamagedJournal(
    _ fileURL: URL,
    manager: FileManager
  ) -> LoadResult {
    let quarantineURL = fileURL.deletingPathExtension()
      .appendingPathExtension("corrupt-\(UUID().uuidString).json")
    do {
      try manager.moveItem(at: fileURL, to: quarantineURL)
      return LoadResult(
        entries: [],
        warning: "A damaged pending-input journal was saved as \(quarantineURL.lastPathComponent).",
        persistenceBlocker: nil
      )
    } catch {
      return LoadResult(
        entries: [],
        warning: "A damaged pending-input journal could not be recovered.",
        persistenceBlocker: "the damaged journal could not be quarantined: \(error.localizedDescription)"
      )
    }
  }
}

private extension NSLock {
  func withInputJournalLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try operation()
  }
}

private extension JSONEncoder {
  static var journalEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

private extension JSONDecoder {
  static var journalDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}
