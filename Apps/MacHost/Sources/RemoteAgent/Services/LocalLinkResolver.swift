import Foundation

enum LocalLinkResolver {
  static func fileURL(for link: URL, relativeTo baseDirectory: URL?) -> URL? {
    if link.isFileURL {
      return link.standardizedFileURL
    }
    guard link.scheme == nil else { return nil }

    let decodedPath = link.path.removingPercentEncoding ?? link.path
    guard !decodedPath.isEmpty else { return nil }
    if decodedPath.hasPrefix("/") {
      return URL(fileURLWithPath: decodedPath).standardizedFileURL
    }
    guard let baseDirectory else { return nil }
    return baseDirectory.appendingPathComponent(decodedPath).standardizedFileURL
  }

  static func document(
    for link: URL,
    relativeTo baseDirectory: URL?
  ) -> LocalDocumentReference? {
    guard let fileURL = fileURL(for: link, relativeTo: baseDirectory) else { return nil }
    return LocalDocumentReference(fileURL: fileURL)
  }
}
