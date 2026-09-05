import Foundation

struct AssistantDataController {
  let rootURL: URL
  let legacyWorkspaceURL: URL?
  private let eraseCredentials: () throws -> Void

  init(
    rootURL: URL = AssistantPaths.rootURL,
    legacyWorkspaceURL: URL? = nil,
    eraseCredentials: @escaping () throws -> Void = { try CredentialVault().eraseAll() }
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.legacyWorkspaceURL = legacyWorkspaceURL?.standardizedFileURL
      ?? (rootURL.standardizedFileURL == AssistantPaths.rootURL.standardizedFileURL
        ? AssistantPaths.legacyWorkspaceURL.standardizedFileURL : nil)
    self.eraseCredentials = eraseCredentials
  }

  func eraseAll(defaults: UserDefaults = .standard, domain: String) throws {
    try eraseCredentials()
    try removePrivateDirectory(rootURL)
    if let legacyWorkspaceURL, AssistantPaths.isVerifiedLegacyWorkspace(legacyWorkspaceURL) {
      try removePrivateDirectory(legacyWorkspaceURL)
    }
    defaults.removePersistentDomain(forName: domain)
  }

  private func removePrivateDirectory(_ url: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else { return }
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let home = manager.homeDirectoryForCurrentUser.standardizedFileURL
    guard values.isDirectory == true, values.isSymbolicLink != true,
      url.path != "/", url != home, url.pathComponents.count > 3
    else {
      throw CredentialVaultError.storage("assistant data path is unsafe")
    }
    try manager.removeItem(at: url)
  }
}
