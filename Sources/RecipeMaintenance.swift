import Foundation

struct RecipeMaintenanceReport: Equatable {
  let expired: Int
  let deleted: Int
  let errors: Int
}

enum RecipeMaintenance {
  private struct Metadata: Decodable {
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
      case expiresAt = "expires_at"
    }
  }

  private static let gracePeriod: TimeInterval = 30 * 24 * 60 * 60

  static func maintain(
    rootURL: URL = AssistantPaths.workspaceURL.appendingPathComponent("recipes", isDirectory: true),
    now: Date = Date()
  ) -> RecipeMaintenanceReport {
    let activeURL = rootURL.appendingPathComponent("active", isDirectory: true)
    let expiredURL = rootURL.appendingPathComponent("expired", isDirectory: true)
    guard prepare(rootURL), prepare(activeURL), prepare(expiredURL) else {
      return RecipeMaintenanceReport(expired: 0, deleted: 0, errors: 1)
    }

    var expired = 0
    var deleted = 0
    var errors = 0
    for recipeURL in safeDirectories(in: activeURL) {
      guard let expiry = expiryDate(recipeURL), expiry <= now else { continue }
      let destination = uniqueDestination(for: recipeURL, in: expiredURL)
      do {
        try FileManager.default.moveItem(at: recipeURL, to: destination)
        try Self.timestamp(now).write(
          to: destination.appendingPathComponent(".expired-at"),
          atomically: true,
          encoding: .utf8
        )
        expired += 1
      } catch {
        errors += 1
      }
    }

    let deletionCutoff = now.addingTimeInterval(-gracePeriod)
    for recipeURL in safeDirectories(in: expiredURL) {
      guard let expiredAt = expiredDate(recipeURL), expiredAt <= deletionCutoff else { continue }
      do {
        try FileManager.default.removeItem(at: recipeURL)
        deleted += 1
      } catch {
        errors += 1
      }
    }
    return RecipeMaintenanceReport(expired: expired, deleted: deleted, errors: errors)
  }

  private static func prepare(_ directoryURL: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: directoryURL.path
      )
      return true
    } catch {
      return false
    }
  }

  private static func safeDirectories(in rootURL: URL) -> [URL] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    let values = try? FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    )
    return (values ?? []).filter { url in
      guard let attributes = try? url.resourceValues(forKeys: keys) else { return false }
      return attributes.isDirectory == true && attributes.isSymbolicLink != true
    }
  }

  private static func expiryDate(_ recipeURL: URL) -> Date? {
    let metadataURL = recipeURL.appendingPathComponent("recipe.json")
    guard let data = try? Data(contentsOf: metadataURL),
      let metadata = try? JSONDecoder().decode(Metadata.self, from: data)
    else {
      return nil
    }
    return date(metadata.expiresAt)
  }

  private static func expiredDate(_ recipeURL: URL) -> Date? {
    let markerURL = recipeURL.appendingPathComponent(".expired-at")
    guard let value = try? String(contentsOf: markerURL, encoding: .utf8) else { return nil }
    return date(value)
  }

  private static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  private static func uniqueDestination(for sourceURL: URL, in expiredURL: URL) -> URL {
    let preferred = expiredURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
    guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
    return expiredURL.appendingPathComponent(
      "\(sourceURL.lastPathComponent)-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}
