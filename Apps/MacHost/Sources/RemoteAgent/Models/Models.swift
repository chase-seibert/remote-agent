import Foundation
import RemoteAgentProtocol

struct AgentProject: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let name: String
  let path: String

  init(path: String) {
    self.path = path
    name = URL(fileURLWithPath: path).lastPathComponent
    id = Self.stableID(for: path)
  }

  static func stableID(for path: String) -> String {
    Data(path.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

enum ProjectSorter {
  static func byMostRecentSession(
    _ projects: [AgentProject],
    sessions: [AgentSession]
  ) -> [AgentProject] {
    let recentActivity = Dictionary(grouping: sessions, by: \.projectID)
      .mapValues { projectSessions in projectSessions.map(\.updatedAt).max()! }

    return projects.sorted { lhs, rhs in
      switch (recentActivity[lhs.id], recentActivity[rhs.id]) {
      case (let lhsDate?, let rhsDate?) where lhsDate != rhsDate:
        return lhsDate > rhsDate
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
    }
  }
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
  var text: String
  let createdAt: Date
  var state: MessageState
  var projectCommandResultID: UUID?

  init(
    id: UUID = UUID(),
    role: MessageRole,
    text: String,
    createdAt: Date = Date(),
    state: MessageState = .complete,
    projectCommandResultID: UUID? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.createdAt = createdAt
    self.state = state
    self.projectCommandResultID = projectCommandResultID
  }
}

struct AgentSession: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let projectID: String
  let projectPath: String
  var codexSessionID: String?
  var title: String
  let createdAt: Date
  var updatedAt: Date
  var messages: [AgentMessage]
  var isRunning: Bool
  var currentReasoning: String?
  var isUnread: Bool
  var isPinned: Bool
  var selectedMakeTarget: String?
  var queuedPrompts: [QueuedPrompt]

  init(project: AgentProject) {
    id = UUID()
    projectID = project.id
    projectPath = project.path
    codexSessionID = nil
    title = "New Session"
    createdAt = Date()
    updatedAt = Date()
    messages = []
    isRunning = false
    currentReasoning = nil
    isUnread = false
    isPinned = false
    selectedMakeTarget = nil
    queuedPrompts = []
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
    case selectedMakeTarget
    case queuedPrompts
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
    selectedMakeTarget = try container.decodeIfPresent(String.self, forKey: .selectedMakeTarget)
    queuedPrompts = try container.decodeIfPresent([QueuedPrompt].self, forKey: .queuedPrompts) ?? []
  }
}

enum SessionListStatus: String, Sendable {
  case running = "Running"
  case unread = "Unread"
  case failed = "Failed"
  case newSession = "New"
  case ready = "Ready"
}

extension AgentSession {
  var projectName: String {
    URL(fileURLWithPath: projectPath).lastPathComponent
  }

  var listStatus: SessionListStatus {
    if isRunning { return .running }
    if isUnread { return .unread }
    if messages.last?.state == .failed { return .failed }
    if messages.isEmpty { return .newSession }
    return .ready
  }
}

enum SessionSorter {
  static func mostRecent(_ sessions: [AgentSession], limit: Int = 50) -> [AgentSession] {
    guard limit > 0 else { return [] }
    return Array(
      sessions.sorted { lhs, rhs in
        if lhs.isPinned != rhs.isPinned {
          return lhs.isPinned
        }
        if lhs.updatedAt != rhs.updatedAt {
          return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }.prefix(limit)
    )
  }
}

enum ProjectDocumentKind: String, Codable, Sendable {
  case markdown
  case html
  case code

  static func inferred(from fileURL: URL) -> ProjectDocumentKind? {
    let name = fileURL.lastPathComponent.lowercased()
    switch fileURL.pathExtension.lowercased() {
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

struct LocalDocumentReference: Identifiable, Codable, Hashable, Sendable {
  let path: String

  var id: String { path }
  var fileURL: URL { URL(fileURLWithPath: path) }
  var name: String { fileURL.lastPathComponent }

  var kind: ProjectDocumentKind? {
    ProjectDocumentKind.inferred(from: fileURL)
  }

  init?(fileURL: URL) {
    let standardized = fileURL.standardizedFileURL
    guard standardized.isFileURL else { return nil }
    path = standardized.path
    guard kind != nil else { return nil }
  }
}

struct CodexTurnResult: Sendable {
  let sessionID: String
  let response: String
}

struct APIActivityEntry: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let timestamp: Date
  let remoteHost: String
  let clientName: String
  let method: String
  let path: String
  let statusCode: Int
  let durationMilliseconds: Int
  let isRemoteClient: Bool

  init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    remoteHost: String,
    clientName: String,
    method: String,
    path: String,
    statusCode: Int,
    durationMilliseconds: Int,
    isRemoteClient: Bool
  ) {
    self.id = id
    self.timestamp = timestamp
    self.remoteHost = remoteHost
    self.clientName = clientName
    self.method = method
    self.path = path
    self.statusCode = statusCode
    self.durationMilliseconds = durationMilliseconds
    self.isRemoteClient = isRemoteClient
  }
}

enum APIClientClassifier {
  static func isRemote(host: String) -> Bool {
    let normalized =
      host
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .lowercased()
    return normalized != "127.0.0.1"
      && normalized != "::1"
      && normalized != "localhost"
  }
}

enum RemoteAgentError: LocalizedError {
  case codexNotFound
  case commandFailed(String)
  case invalidCodexOutput
  case projectNotFound
  case sessionNotFound
  case queuedPromptNotFound
  case sessionBusy
  case invalidRequest(String)

  var errorDescription: String? {
    switch self {
    case .codexNotFound:
      return "Codex CLI was not found. Choose its path in Settings."
    case .commandFailed(let message):
      return message
    case .invalidCodexOutput:
      return "Codex finished without returning a session ID or response."
    case .projectNotFound:
      return "The selected project no longer exists."
    case .sessionNotFound:
      return "The selected session no longer exists."
    case .queuedPromptNotFound:
      return "That queued prompt is no longer waiting to run."
    case .sessionBusy:
      return "That session is already processing a prompt."
    case .invalidRequest(let reason):
      return reason
    }
  }
}
