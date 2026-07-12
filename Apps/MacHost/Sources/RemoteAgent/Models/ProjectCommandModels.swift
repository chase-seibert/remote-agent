import Foundation

enum ProjectCommandKind: String, Codable, Sendable {
  case make
  case gitCommit
  case gitPush
}

struct ProjectCommandResult: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let sessionID: UUID
  let projectPath: String
  let kind: ProjectCommandKind
  let title: String
  let command: String
  let output: String
  let exitCode: Int32?
  let startedAt: Date
  let completedAt: Date?

  var isRunning: Bool { completedAt == nil }

  var succeeded: Bool { !isRunning && exitCode == 0 }

  var duration: TimeInterval {
    (completedAt ?? Date()).timeIntervalSince(startedAt)
  }
}

struct ProjectCommandOutcome: Sendable {
  let kind: ProjectCommandKind
  let title: String
  let command: String
  let output: String
  let exitCode: Int32?
  let startedAt: Date
  let completedAt: Date

  var succeeded: Bool { exitCode == 0 }
}
