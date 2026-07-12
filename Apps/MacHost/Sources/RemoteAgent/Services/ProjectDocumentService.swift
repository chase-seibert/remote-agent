import Foundation

struct ProjectDocumentService: Sendable {
  static let maximumByteCount = 2 * 1_024 * 1_024

  func list(projectPath: String) async throws -> [ProjectDocument] {
    try await Task.detached {
      try Self.scan(projectPath: projectPath)
    }.value
  }

  func content(projectPath: String, documentID: String) async throws -> ProjectDocumentContent {
    try await Task.detached {
      let documents = try Self.scan(projectPath: projectPath)
      guard let document = documents.first(where: { $0.id == documentID }) else {
        throw RemoteAgentError.invalidRequest("Document not found")
      }
      guard document.byteCount <= Self.maximumByteCount else {
        throw RemoteAgentError.invalidRequest("Document is larger than 2 MB")
      }

      let rootURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
      let fileURL = rootURL.appendingPathComponent(document.relativePath).standardizedFileURL
      guard fileURL.path.hasPrefix(rootURL.path + "/") else {
        throw RemoteAgentError.invalidRequest("Document is outside the project")
      }
      let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      guard let content = String(data: data, encoding: .utf8) else {
        throw RemoteAgentError.invalidRequest("Document is not UTF-8 text")
      }
      return ProjectDocumentContent(document: document, content: content)
    }.value
  }

  private static func scan(projectPath: String) throws -> [ProjectDocument] {
    let rootURL = URL(fileURLWithPath: projectPath, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      throw RemoteAgentError.invalidRequest("Could not read project documents")
    }

    let skippedDirectories: Set<String> = [
      ".build", "build", "DerivedData", "node_modules", "Pods",
    ]
    var documents: [ProjectDocument] = []

    for case let fileURL as URL in enumerator {
      let fileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
      guard fileURL.path.hasPrefix(rootURL.path + "/") else {
        enumerator.skipDescendants()
        continue
      }
      let values = try fileURL.resourceValues(forKeys: resourceKeys)
      if values.isDirectory == true {
        if skippedDirectories.contains(fileURL.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true,
        let kind = ProjectDocumentKind.inferred(from: fileURL)
      else { continue }

      let relativePath = String(fileURL.path.dropFirst(rootURL.path.count + 1))
      documents.append(
        ProjectDocument(
          id: stableID(for: relativePath),
          name: fileURL.lastPathComponent,
          relativePath: relativePath,
          kind: kind,
          byteCount: values.fileSize ?? 0
        ))
    }

    return documents.sorted {
      $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
    }
  }

  private static func stableID(for relativePath: String) -> String {
    Data(relativePath.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
