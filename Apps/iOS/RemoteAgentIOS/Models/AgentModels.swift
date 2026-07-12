import Foundation

struct AgentProject: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let name: String
  let path: String
}

enum MessageRole: String, Codable, Sendable {
  case user
  case assistant
  case system
}

enum MessageState: String, Codable, Sendable {
  case complete
  case pending
  case failed
}

struct AgentMessage: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let role: MessageRole
  let text: String
  let createdAt: Date
  let state: MessageState
}

struct AgentSession: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let projectID: String
  let projectPath: String
  let codexSessionID: String?
  let title: String
  let createdAt: Date
  let updatedAt: Date
  let messages: [AgentMessage]
  var isRunning: Bool
  var currentReasoning: String?
  var isUnread: Bool
  var isPinned: Bool

  init(
    id: UUID,
    projectID: String,
    projectPath: String,
    codexSessionID: String?,
    title: String,
    createdAt: Date,
    updatedAt: Date,
    messages: [AgentMessage],
    isRunning: Bool,
    currentReasoning: String? = nil,
    isUnread: Bool = false,
    isPinned: Bool = false
  ) {
    self.id = id
    self.projectID = projectID
    self.projectPath = projectPath
    self.codexSessionID = codexSessionID
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messages = messages
    self.isRunning = isRunning
    self.currentReasoning = currentReasoning
    self.isUnread = isUnread
    self.isPinned = isPinned
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case projectID
    case projectPath
    case codexSessionID
    case title
    case createdAt
    case updatedAt
    case messages
    case isRunning
    case currentReasoning
    case isUnread
    case isPinned
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    projectID = try container.decode(String.self, forKey: .projectID)
    projectPath = try container.decode(String.self, forKey: .projectPath)
    codexSessionID = try container.decodeIfPresent(String.self, forKey: .codexSessionID)
    title = try container.decode(String.self, forKey: .title)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    messages = try container.decode([AgentMessage].self, forKey: .messages)
    isRunning = try container.decode(Bool.self, forKey: .isRunning)
    currentReasoning = try container.decodeIfPresent(String.self, forKey: .currentReasoning)
    isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
  }
}

struct QueuedPrompt: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let text: String
  let createdAt: Date

  init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
  }
}

struct HealthResponse: Codable, Equatable, Sendable {
  let status: String
  let version: String
}

struct AcceptedResponse: Codable, Equatable, Sendable {
  let sessionID: UUID
  let status: String
}

struct APIErrorResponse: Codable, Sendable {
  let error: String
}

enum ProjectDocumentKind: String, Codable, Hashable, Sendable {
  case markdown
  case html
  case code

  var isBrowsable: Bool {
    switch self {
    case .markdown, .html: true
    case .code: false
    }
  }

  static func inferred(from relativePath: String) -> ProjectDocumentKind? {
    let name = (relativePath as NSString).lastPathComponent.lowercased()
    let pathExtension = (relativePath as NSString).pathExtension.lowercased()
    switch pathExtension {
    case "md", "markdown": return .markdown
    case "html", "htm": return .html
    case "c", "cc", "cpp", "cs", "css", "dart", "entitlements", "fs", "fsx", "go",
      "gql", "gradle", "graphql", "h", "hpp", "java", "js", "json", "jsonc", "jsx",
      "kt", "kts", "less", "lua", "m", "mm", "php", "plist", "proto", "py", "r", "rb",
      "rs", "sass", "scala", "scss", "sh", "sql", "svelte", "swift", "toml", "ts", "tsx",
      "vue", "xml", "xcconfig", "yaml", "yml", "zsh":
      return .code
    default:
      return
        ["dockerfile", "gemfile", "makefile", "podfile", "rakefile"].contains(name) ? .code : nil
    }
  }
}

struct ProjectDocument: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let name: String
  let relativePath: String
  let kind: ProjectDocumentKind
  let byteCount: Int
}

struct ProjectDocumentContent: Codable, Hashable, Sendable {
  let document: ProjectDocument
  let content: String
}

extension Array where Element == ProjectDocument {
  var browsable: [ProjectDocument] {
    filter { $0.kind.isBrowsable }
  }
}

extension Array where Element == AgentProject {
  func sortedByRecentActivity(sessions: [AgentSession]) -> [AgentProject] {
    let latestActivity = Dictionary(grouping: sessions, by: \.projectID)
      .compactMapValues { projectSessions in
        projectSessions.map(\.updatedAt).max()
      }

    return self.sorted(by: { (left: AgentProject, right: AgentProject) -> Bool in
      switch (latestActivity[left.id], latestActivity[right.id]) {
      case (let leftDate?, let rightDate?) where leftDate != rightDate:
        return leftDate > rightDate
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
      }
    })
  }
}

extension Array where Element == AgentSession {
  func sortedByRecentActivity() -> [AgentSession] {
    self.sorted(by: { left, right in
      if left.isPinned != right.isPinned { return left.isPinned }
      if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
      return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    })
  }

  func mostRecent(limit: Int) -> [AgentSession] {
    Array(sortedByRecentActivity().prefix(Swift.max(0, limit)))
  }
}
