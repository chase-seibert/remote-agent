import Foundation

enum ProjectLinkDestination: Equatable {
  case web(URL)
  case document(relativePath: String)
  case unsupported
}

enum ProjectLinkResolver {
  static let internalScheme = "remoteagent-project"

  static func destination(
    for url: URL,
    projectPath: String,
    currentDocumentRelativePath: String? = nil
  ) -> ProjectLinkDestination {
    let scheme = url.scheme?.lowercased()
    if ["http", "https", "mailto"].contains(scheme) {
      return .web(url)
    }

    let rawPath: String
    switch scheme {
    case internalScheme:
      rawPath = url.path
    case nil, "file":
      rawPath = url.path
    default:
      return .unsupported
    }

    let projectRoot = (projectPath as NSString).standardizingPath
    let candidate: String
    if rawPath.hasPrefix(projectRoot + "/") {
      candidate = String(rawPath.dropFirst(projectRoot.count + 1))
    } else if scheme == internalScheme {
      candidate = String(rawPath.drop(while: { $0 == "/" }))
    } else if rawPath.hasPrefix("/") {
      return .unsupported
    } else {
      let baseDirectory =
        currentDocumentRelativePath.map {
          ($0 as NSString).deletingLastPathComponent
        } ?? ""
      candidate = (baseDirectory as NSString).appendingPathComponent(rawPath)
    }

    let decodedCandidate = candidate.removingPercentEncoding ?? candidate
    guard let relativePath = normalizedRelativePath(decodedCandidate) else {
      return .unsupported
    }
    guard ProjectDocumentKind.inferred(from: relativePath) != nil else {
      return .unsupported
    }
    return .document(relativePath: relativePath)
  }

  private static func normalizedRelativePath(_ path: String) -> String? {
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        guard !components.isEmpty else { return nil }
        components.removeLast()
      default:
        components.append(component)
      }
    }
    guard !components.isEmpty else { return nil }
    return components.joined(separator: "/")
  }

  static func baseURL(for documentRelativePath: String) -> URL? {
    var components = URLComponents()
    components.scheme = internalScheme
    components.host = "project"
    components.path = "/\(documentRelativePath)"
    return components.url
  }
}
