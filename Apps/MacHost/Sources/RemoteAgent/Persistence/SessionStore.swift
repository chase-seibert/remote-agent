import Foundation

actor SessionStore {
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
        .appendingPathComponent("sessions.json")
    }
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func load() throws -> [AgentSession] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    return try decoder.decode([AgentSession].self, from: Data(contentsOf: fileURL))
  }

  func save(_ sessions: [AgentSession]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(sessions).write(to: fileURL, options: .atomic)
  }
}
