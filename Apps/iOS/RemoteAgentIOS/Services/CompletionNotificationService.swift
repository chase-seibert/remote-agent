import Foundation
import UserNotifications

protocol CompletionNotificationServing: Sendable {
  func requestAuthorizationIfNeeded() async
  func setUnreadBadgeCount(_ count: Int) async
  func notifyCompletion(for session: AgentSession) async
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

    let failed = session.messages.last?.state == .failed
    let projectName = URL(fileURLWithPath: session.projectPath).lastPathComponent
    let content = UNMutableNotificationContent()
    content.title = failed ? "Agent failed" : "Agent finished"
    content.body = "\(session.title) in \(projectName)"
    content.sound = .default
    content.userInfo = ["sessionID": session.id.uuidString]

    let version = Int(session.updatedAt.timeIntervalSince1970)
    let request = UNNotificationRequest(
      identifier: "agent-completion-\(session.id.uuidString)-\(version)",
      content: content,
      trigger: nil
    )
    try? await center.add(request)
  }
}
