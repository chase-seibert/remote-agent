import Foundation

public enum RemoteAgentProtocolVersion {
  public static let current = "1"
}

public enum RemoteAgentEndpoint {
  public static let health = "/v1/health"
  public static let projects = "/v1/projects"
  public static let sessions = "/v1/sessions"
  public static let documents = "/v1/documents"

  public static func session(_ id: UUID) -> String {
    "\(sessions)/\(id.uuidString)"
  }

  public static func sessionRead(_ id: UUID) -> String {
    "\(session(id))/read"
  }

  public static func sessionMessages(_ id: UUID) -> String {
    "\(session(id))/messages"
  }

  public static func document(_ id: String) -> String {
    "\(documents)/\(id)"
  }
}

public struct SessionUpdateRequest: Codable, Equatable, Sendable {
  public let title: String?
  public let isPinned: Bool?

  public init(title: String? = nil, isPinned: Bool? = nil) {
    self.title = title
    self.isPinned = isPinned
  }
}
