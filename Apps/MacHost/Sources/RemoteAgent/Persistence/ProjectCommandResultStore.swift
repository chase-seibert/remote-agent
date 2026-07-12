import Foundation

actor ProjectCommandResultStore {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first!
      self.fileURL =
        support
        .appendingPathComponent("Remote Agent", isDirectory: true)
        .appendingPathComponent("project-command-results.json")
    }
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func load() throws -> [ProjectCommandResult] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    return try decoder.decode([ProjectCommandResult].self, from: Data(contentsOf: fileURL))
  }

  func save(_ results: [ProjectCommandResult]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let recentResults = Array(
      results.sorted {
        ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt)
      }.prefix(200)
    )
    try encoder.encode(recentResults).write(to: fileURL, options: .atomic)
  }
}
