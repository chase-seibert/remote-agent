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

  public static func sessionProjectCommands(_ id: UUID) -> String {
    "\(session(id))/project-commands"
  }

  public static func sessionProjectCommandResult(_ sessionID: UUID, resultID: UUID) -> String {
    "\(sessionProjectCommands(sessionID))/\(resultID.uuidString)"
  }

  public static func document(_ id: String) -> String {
    "\(documents)/\(id)"
  }
}

public struct SessionUpdateRequest: Codable, Equatable, Sendable {
  public let title: String?
  public let isPinned: Bool?
  public let selectedMakeTarget: String?

  public init(
    title: String? = nil,
    isPinned: Bool? = nil,
    selectedMakeTarget: String? = nil
  ) {
    self.title = title
    self.isPinned = isPinned
    self.selectedMakeTarget = selectedMakeTarget
  }
}

public enum ProjectCommandAction: String, Codable, Equatable, Sendable {
  case make
  case gitCommit
  case gitPush
  case gitCommitAndPush
}

public struct ProjectCommandRequest: Codable, Equatable, Sendable {
  public let action: ProjectCommandAction
  public let target: String?

  public init(action: ProjectCommandAction, target: String? = nil) {
    self.action = action
    self.target = target
  }
}

public struct ProjectCommandConfigurationResponse: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let makeTargets: [String]
  public let selectedMakeTarget: String?
  public let isRunning: Bool

  public init(
    sessionID: UUID,
    makeTargets: [String],
    selectedMakeTarget: String?,
    isRunning: Bool
  ) {
    self.sessionID = sessionID
    self.makeTargets = makeTargets
    self.selectedMakeTarget = selectedMakeTarget
    self.isRunning = isRunning
  }
}

public enum RemoteProjectCommandKind: String, Codable, Equatable, Sendable {
  case make
  case gitCommit
  case gitPush
}

public struct RemoteProjectCommandResult: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let projectPath: String
  public let kind: RemoteProjectCommandKind
  public let title: String
  public let command: String
  public let output: String
  public let exitCode: Int32?
  public let startedAt: Date
  public let completedAt: Date?

  public init(
    id: UUID,
    sessionID: UUID,
    projectPath: String,
    kind: RemoteProjectCommandKind,
    title: String,
    command: String,
    output: String,
    exitCode: Int32?,
    startedAt: Date,
    completedAt: Date?
  ) {
    self.id = id
    self.sessionID = sessionID
    self.projectPath = projectPath
    self.kind = kind
    self.title = title
    self.command = command
    self.output = output
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  public var isRunning: Bool { completedAt == nil }
  public var succeeded: Bool { !isRunning && exitCode == 0 }
}
