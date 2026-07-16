import Foundation
import UserNotifications

protocol CompletionNotificationServing: Sendable {
  func requestAuthorizationIfNeeded() async
  func setUnreadBadgeCount(_ count: Int) async
  func notifyCompletion(for session: AgentSession) async
}

struct CompletionNotificationContext: Equatable, Sendable {
  let title: String
  let subtitle: String
  let body: String

  init(session: AgentSession) {
    let finalMessage = session.messages.last.flatMap { message in
      message.role != .user && message.state != .pending && !message.text.isEmpty
        ? message : nil
    }
    let failed = session.messages.last?.state == .failed
    let projectName = URL(fileURLWithPath: session.projectPath).lastPathComponent

    title = failed ? "Agent failed" : "Agent finished"
    subtitle = session.title

    var bodyLines = ["Project: \(projectName.isEmpty ? session.projectID : projectName)"]
    if let finalMessage, let preview = Self.preview(finalMessage.text) {
      bodyLines.append(preview)
    } else if let request = session.messages.last(where: { $0.role == .user }),
      let preview = Self.preview(request.text)
    {
      bodyLines.append("Request: \(preview)")
    }
    body = bodyLines.joined(separator: "\n")
  }

  private static func preview(_ text: String) -> String? {
    let normalized =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !normalized.isEmpty else { return nil }

    let limit = 240
    guard normalized.count > limit else { return normalized }

    let candidate = normalized.prefix(limit - 1)
    if let lastWhitespace = candidate.lastIndex(where: { $0.isWhitespace }) {
      return String(candidate[..<lastWhitespace]) + "…"
    }
    return String(candidate) + "…"
  }
}

actor CompletionNotificationService: CompletionNotificationServing {
  private let center = UNUserNotificationCenter.current()

  func requestAuthorizationIfNeeded() async {
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
  }

  func setUnreadBadgeCount(_ count: Int) async {
    let count = max(0, count)
    if count > 0 {
      await requestAuthorizationIfNeeded()
      guard !Task.isCancelled else { return }
      let settings = await center.notificationSettings()
      guard settings.badgeSetting == .enabled else { return }
    }
    try? await center.setBadgeCount(count)
  }

  func notifyCompletion(for session: AgentSession) async {
    let settings = await center.notificationSettings()
    guard
      settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional
    else { return }

    let context = CompletionNotificationContext(session: session)
    let content = UNMutableNotificationContent()
    content.title = context.title
    content.subtitle = context.subtitle
    content.body = context.body
    content.sound = .default
    content.threadIdentifier = "project-\(session.projectID)"
    content.targetContentIdentifier = session.id.uuidString
    content.userInfo = [
      "sessionID": session.id.uuidString,
      "projectID": session.projectID,
    ]

    let version = Int(session.updatedAt.timeIntervalSince1970)
    let request = UNNotificationRequest(
      identifier: "agent-completion-\(session.id.uuidString)-\(version)",
      content: content,
      trigger: nil
    )
    try? await center.add(request)
  }
}
