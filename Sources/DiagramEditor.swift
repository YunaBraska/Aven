import Foundation

enum DiagramEditorError: LocalizedError, Equatable {
  case invalidPath
  case unsupportedFormat
  case unsafeFile
  case tooLarge
  case invalidDiagram
  case invalidURL

  var errorDescription: String? {
    switch self {
    case .invalidPath: "The diagram path is invalid."
    case .unsupportedFormat: "Only draw.io XML files can be opened in the web editor."
    case .unsafeFile: "The diagram must be a regular file and not a symbolic link."
    case .tooLarge: "The diagram is too large for a safe browser handoff."
    case .invalidDiagram: "The file is not valid draw.io XML."
    case .invalidURL: "The browser editor link could not be created."
    }
  }
}

struct DiagramEditorRequest: Equatable {
  let fileURL: URL
  let editorURL: URL
}

enum DiagramEditor {
  private static let maximumBytes = 60_000

  static func request(path: String) throws -> DiagramEditorRequest {
    guard path.hasPrefix("/") else { throw DiagramEditorError.invalidPath }
    let fileURL = URL(fileURLWithPath: path).standardizedFileURL
    guard ["drawio", "xml"].contains(fileURL.pathExtension.lowercased()) else {
      throw DiagramEditorError.unsupportedFormat
    }
    let values = try fileURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw DiagramEditorError.unsafeFile
    }
    guard let size = values.fileSize, size <= maximumBytes else {
      throw DiagramEditorError.tooLarge
    }
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard data.count <= maximumBytes else { throw DiagramEditorError.tooLarge }
    guard isDrawIODocument(data) else { throw DiagramEditorError.invalidDiagram }
    guard let xml = String(data: data, encoding: .utf8),
      let payload = try? JSONSerialization.data(withJSONObject: ["type": "xml", "data": xml]),
      let json = String(data: payload, encoding: .utf8),
      let encoded = json.addingPercentEncoding(
        withAllowedCharacters: CharacterSet.alphanumerics.union(
          CharacterSet(charactersIn: "-._~")
        )
      ),
      let editorURL = URL(string: "https://app.diagrams.net/?splash=0#create=\(encoded)")
    else { throw DiagramEditorError.invalidURL }
    return DiagramEditorRequest(fileURL: fileURL, editorURL: editorURL)
  }

  private static func isDrawIODocument(_ data: Data) -> Bool {
    let delegate = DiagramRootDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), let root = delegate.rootElement else { return false }
    return root == "mxfile" || root == "mxGraphModel"
  }
}

private final class DiagramRootDelegate: NSObject, XMLParserDelegate {
  private(set) var rootElement: String?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    if rootElement == nil { rootElement = elementName }
  }
}
