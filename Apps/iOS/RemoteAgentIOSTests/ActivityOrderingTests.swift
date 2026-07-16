import RemoteAgentProtocol
import XCTest

@testable import RemoteAgentIOS

final class CompletionNotificationContextTests: XCTestCase {
  func testCompletionNotificationIncludesProjectSessionAndFinalResponse() {
    let now = Date()
    let session = AgentSession(
      id: UUID(),
      projectID: "remote-agent-ios",
      projectPath: "/Users/example/projects/remote-agent-ios",
      codexSessionID: nil,
      title: "Improve app notifications",
      createdAt: now,
      updatedAt: now,
      messages: [
        AgentMessage(
          id: UUID(),
          role: .user,
          text: "Add more context",
          createdAt: now,
          state: .complete
        ),
        AgentMessage(
          id: UUID(),
          role: .assistant,
          text: "Added the project, session, and final response.\n\nEverything is ready.",
          createdAt: now,
          state: .complete
        ),
      ],
      isRunning: false
    )

    let context = CompletionNotificationContext(session: session)

    XCTAssertEqual(context.title, "Agent finished")
    XCTAssertEqual(context.subtitle, "Improve app notifications")
    XCTAssertEqual(
      context.body,
      "Project: remote-agent-ios\nAdded the project, session, and final response. Everything is ready."
    )
  }

  func testFailedNotificationShowsFailureDetails() {
    let now = Date()
    let session = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Run integration tests",
      createdAt: now,
      updatedAt: now,
      messages: [
        AgentMessage(
          id: UUID(),
          role: .system,
          text: "The test runner could not connect to the simulator.",
          createdAt: now,
          state: .failed
        )
      ],
      isRunning: false
    )

    let context = CompletionNotificationContext(session: session)

    XCTAssertEqual(context.title, "Agent failed")
    XCTAssertEqual(context.subtitle, "Run integration tests")
    XCTAssertEqual(
      context.body,
      "Project: project\nThe test runner could not connect to the simulator."
    )
  }

  func testCompletionNotificationFallsBackToRequestContext() {
    let now = Date()
    let session = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Pending response",
      createdAt: now,
      updatedAt: now,
      messages: [
        AgentMessage(
          id: UUID(),
          role: .user,
          text: "Explain how background polling works",
          createdAt: now,
          state: .complete
        )
      ],
      isRunning: false
    )

    let context = CompletionNotificationContext(session: session)

    XCTAssertEqual(
      context.body,
      "Project: project\nRequest: Explain how background polling works"
    )
  }

  func testCompletionNotificationPreviewIsConcise() {
    let now = Date()
    let session = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Long response",
      createdAt: now,
      updatedAt: now,
      messages: [
        AgentMessage(
          id: UUID(),
          role: .assistant,
          text: String(repeating: "context ", count: 100),
          createdAt: now,
          state: .complete
        )
      ],
      isRunning: false
    )

    let context = CompletionNotificationContext(session: session)
    let preview = context.body.components(separatedBy: "\n").last ?? ""

    XCTAssertLessThanOrEqual(preview.count, 240)
    XCTAssertTrue(preview.hasSuffix("…"))
  }
}

@MainActor
final class ConnectionLifecycleTests: XCTestCase {
  func testRepeatedForegroundActivationCoalescesRefresh() async throws {
    let context = makeContext()

    context.model.sceneActivityChanged(isActive: true)
    await context.client.waitUntilHealthRequestStarts()
    context.model.sceneActivityChanged(isActive: true)
    await Task.yield()

    let healthRequestCount = await context.client.healthRequestCount
    XCTAssertEqual(healthRequestCount, 1)

    await context.client.releaseHealthRequests()
    try await context.client.waitUntilSnapshotLoads()

    let projectRequestCount = await context.client.projectRequestCount
    let sessionRequestCount = await context.client.sessionRequestCount
    XCTAssertEqual(projectRequestCount, 1)
    XCTAssertEqual(sessionRequestCount, 1)
    XCTAssertTrue(context.model.connectionState.isConnected)
  }

  func testDisconnectPreventsSuspendedRefreshFromOverwritingState() async {
    let context = makeContext()

    context.model.sceneActivityChanged(isActive: true)
    await context.client.waitUntilHealthRequestStarts()
    context.model.disconnect()
    await context.client.releaseHealthRequests()
    for _ in 0..<10 { await Task.yield() }

    let projectRequestCount = await context.client.projectRequestCount
    let sessionRequestCount = await context.client.sessionRequestCount
    XCTAssertEqual(context.model.connectionState, .disconnected)
    XCTAssertEqual(projectRequestCount, 0)
    XCTAssertEqual(sessionRequestCount, 0)
  }

  func testDisconnectPreventsSuspendedSessionMutationFromOverwritingState() async {
    let context = makeContext()
    let originalTitle = context.model.selectedSession?.title

    let rename = Task {
      await context.model.renameSession(
        context.model.selectedSessionID!,
        title: "Response from the old Mac"
      )
    }
    await context.client.waitUntilRenameStarts()
    context.model.disconnect()
    await context.client.releaseRenameRequest()

    let didRename = await rename.value
    XCTAssertFalse(didRename)
    XCTAssertEqual(context.model.selectedSession?.title, originalTitle)
    XCTAssertEqual(context.model.connectionState, .disconnected)
    XCTAssertNil(context.model.presentedError)
  }

  func testPollingMultipleRunningSessionsUsesOneStatusRequestPerTick() async throws {
    let now = Date()
    let first = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "First",
      createdAt: now,
      updatedAt: now,
      messages: [],
      isRunning: false
    )
    let second = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Second",
      createdAt: now,
      updatedAt: now,
      messages: [],
      isRunning: false
    )
    let project = AgentProject(id: "project", name: "Project", path: "/project")
    let client = DeferredLifecycleAPIClient(project: project, session: first)
    let suite = "ConnectionLifecycleTests.Polling.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      testConfiguration: APIConfiguration(host: "test.local", port: 8765, token: "token"),
      client: client,
      sessions: [first, second],
      draftStore: DraftStore(defaults: defaults),
      completionNotifications: BadgeRecordingNotificationService()
    )

    let sentFirst = await model.sendPrompt("Run first", to: first.id)
    let sentSecond = await model.sendPrompt("Run second", to: second.id)
    XCTAssertTrue(sentFirst)
    XCTAssertTrue(sentSecond)
    try await client.waitUntilStatusRequestCount(1)
    try await Task.sleep(for: .milliseconds(100))

    let statusRequestCount = await client.statusRequestCount
    let requestedStatusIDs = await client.requestedStatusIDs
    let sessionRequestCount = await client.sessionRequestCount
    XCTAssertEqual(statusRequestCount, 1)
    XCTAssertEqual(Set(requestedStatusIDs.first ?? []), Set([first.id, second.id]))
    XCTAssertEqual(sessionRequestCount, 0)
    model.disconnect()
  }

  func testReasoningUsesStatusAndQueuedTurnRefreshesWithoutStoppingPolling() async throws {
    let now = Date()
    let running = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Focused polling",
      createdAt: now,
      updatedAt: now,
      messages: [
        AgentMessage(
          id: UUID(),
          role: .user,
          text: "Run the task",
          createdAt: now,
          state: .complete
        )
      ],
      isRunning: true,
      contentRevision: 1
    )
    let client = StatusPollingAPIClient(session: running)
    let suite = "ConnectionLifecycleTests.StatusPolling.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      testConfiguration: APIConfiguration(host: "test.local", port: 8765, token: "token"),
      client: client,
      sessions: [running],
      draftStore: DraftStore(defaults: defaults),
      completionNotifications: BadgeRecordingNotificationService()
    )
    model.selectSession(running.id)

    try await client.waitUntilStatusRequestCount(1)
    let transcriptRequestsWhileReasoning = await client.sessionRequestCount
    XCTAssertEqual(model.selectedSession?.currentReasoning, "Checking the focused session.")
    XCTAssertEqual(transcriptRequestsWhileReasoning, 0)

    await client.advanceToQueuedTurn()
    try await client.waitUntilSessionRequestCount(1)
    for _ in 0..<100 {
      if model.selectedSession?.messages.last?.text == "Queued follow up" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(model.selectedSession?.isRunning == true)
    XCTAssertEqual(model.selectedSession?.messages.last?.text, "Queued follow up")

    await client.completeTurn()
    try await client.waitUntilSessionRequestCount(2)
    for _ in 0..<100 {
      if model.selectedSession?.isRunning == false { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    let completedTranscriptRequests = await client.sessionRequestCount
    XCTAssertFalse(model.selectedSession?.isRunning ?? true)
    XCTAssertEqual(model.selectedSession?.messages.last?.text, "Finished")
    XCTAssertEqual(completedTranscriptRequests, 2)
    model.disconnect()
  }

  func testMissingStatusEndpointFallsBackToFullSessionSnapshot() async throws {
    let now = Date()
    let running = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Legacy host",
      createdAt: now,
      updatedAt: now,
      messages: [],
      isRunning: true
    )
    let completed = AgentSession(
      id: running.id,
      projectID: running.projectID,
      projectPath: running.projectPath,
      codexSessionID: nil,
      title: running.title,
      createdAt: running.createdAt,
      updatedAt: now.addingTimeInterval(1),
      messages: [
        AgentMessage(
          id: UUID(),
          role: .assistant,
          text: "Legacy host finished",
          createdAt: now.addingTimeInterval(1),
          state: .complete
        )
      ],
      isRunning: false
    )
    let client = LegacyPollingAPIClient(session: completed)
    let suite = "ConnectionLifecycleTests.LegacyPolling.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      testConfiguration: APIConfiguration(host: "test.local", port: 8765, token: "token"),
      client: client,
      sessions: [running],
      draftStore: DraftStore(defaults: defaults),
      completionNotifications: BadgeRecordingNotificationService()
    )
    model.selectSession(running.id)

    try await client.waitUntilFullSnapshotRequest()
    for _ in 0..<100 {
      if model.selectedSession?.isRunning == false { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    let statusRequests = await client.statusRequestCount
    let fullSnapshotRequests = await client.fullSnapshotRequestCount
    XCTAssertEqual(statusRequests, 1)
    XCTAssertEqual(fullSnapshotRequests, 1)
    XCTAssertEqual(model.selectedSession?.messages.last?.text, "Legacy host finished")
    model.disconnect()
  }

  private func makeContext() -> (
    model: AppModel,
    client: DeferredLifecycleAPIClient
  ) {
    let suite = "ConnectionLifecycleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let now = Date()
    let session = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Connection lifecycle",
      createdAt: now,
      updatedAt: now,
      messages: [],
      isRunning: false
    )
    let project = AgentProject(id: "project", name: "Project", path: "/project")
    let client = DeferredLifecycleAPIClient(project: project, session: session)
    let model = AppModel(
      testConfiguration: APIConfiguration(host: "test.local", port: 8765, token: "token"),
      client: client,
      sessions: [session],
      draftStore: DraftStore(defaults: defaults),
      completionNotifications: BadgeRecordingNotificationService()
    )
    return (model, client)
  }
}

final class ActivityOrderingTests: XCTestCase {
  func testPendingProjectCommandCountsAsActiveWork() {
    let now = Date()
    let resultID = UUID()
    let session = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/tmp/project",
      codexSessionID: nil,
      title: "Command",
      createdAt: now,
      updatedAt: now,
      messages: [
        AgentMessage(
          id: resultID,
          role: .system,
          text: "Running make test…",
          createdAt: now,
          state: .pending,
          projectCommandResultID: resultID
        )
      ],
      isRunning: false
    )

    XCTAssertTrue(session.hasPendingProjectCommand)
    XCTAssertTrue(session.hasActiveWork)
  }

  func testRightwardHorizontalSwipeNavigatesToSessions() {
    XCTAssertTrue(
      SessionListSwipeGesture.shouldNavigate(
        translation: CGSize(width: 96, height: 12),
        predictedEndTranslation: CGSize(width: 120, height: 15)
      )
    )
  }

  func testQuickRightwardFlickNavigatesToSessions() {
    XCTAssertTrue(
      SessionListSwipeGesture.shouldNavigate(
        translation: CGSize(width: 40, height: 5),
        predictedEndTranslation: CGSize(width: 100, height: 8)
      )
    )
  }

  func testShortVerticalAndLeftwardDragsStayInConversation() {
    XCTAssertFalse(
      SessionListSwipeGesture.shouldNavigate(
        translation: CGSize(width: 55, height: 4),
        predictedEndTranslation: CGSize(width: 70, height: 5)
      )
    )
    XCTAssertFalse(
      SessionListSwipeGesture.shouldNavigate(
        translation: CGSize(width: 90, height: -120),
        predictedEndTranslation: CGSize(width: 120, height: -180)
      )
    )
    XCTAssertFalse(
      SessionListSwipeGesture.shouldNavigate(
        translation: CGSize(width: -100, height: 4),
        predictedEndTranslation: CGSize(width: -140, height: 6)
      )
    )
  }

  func testProjectsSortByLatestSessionActivityWithUnusedProjectsLast() {
    let olderProject = AgentProject(id: "older", name: "Older", path: "/older")
    let newestProject = AgentProject(id: "newest", name: "Newest", path: "/newest")
    let unusedZebra = AgentProject(id: "zebra", name: "Zebra", path: "/zebra")
    let unusedAlpha = AgentProject(id: "alpha", name: "Alpha", path: "/alpha")
    let now = Date()
    let sessions = [
      makeSession(
        projectID: olderProject.id, title: "Older", updatedAt: now.addingTimeInterval(-60)),
      makeSession(projectID: newestProject.id, title: "Newest", updatedAt: now),
    ]

    let result = [unusedZebra, olderProject, unusedAlpha, newestProject]
      .sortedByRecentActivity(sessions: sessions)

    XCTAssertEqual(result.map(\.id), ["newest", "older", "alpha", "zebra"])
  }

  func testSessionsSortNewestFirstAndUseTitleForTies() {
    let now = Date()
    let result = [
      makeSession(projectID: "project", title: "Older", updatedAt: now.addingTimeInterval(-60)),
      makeSession(projectID: "project", title: "Zulu", updatedAt: now),
      makeSession(projectID: "project", title: "Alpha", updatedAt: now),
    ].sortedByRecentActivity()

    XCTAssertEqual(result.map(\.title), ["Alpha", "Zulu", "Older"])
  }

  func testPinnedSessionsSortBeforeMoreRecentUnpinnedSessions() {
    let now = Date()
    let result = [
      makeSession(projectID: "project", title: "Recent", updatedAt: now),
      makeSession(
        projectID: "project",
        title: "Pinned",
        updatedAt: now.addingTimeInterval(-3_600),
        isPinned: true
      ),
    ].sortedByRecentActivity()

    XCTAssertEqual(result.map(\.title), ["Pinned", "Recent"])
  }

  func testRecentSessionsAreGloballySortedAndCappedAtFifty() {
    let sessions = (0..<55).map { index in
      makeSession(
        projectID: "project-\(index % 3)",
        title: "Session \(index)",
        updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    let result = sessions.mostRecent(limit: 50)

    XCTAssertEqual(result.count, 50)
    XCTAssertEqual(result.first?.title, "Session 54")
    XCTAssertEqual(result.last?.title, "Session 5")
  }

  private func makeSession(
    projectID: String,
    title: String,
    updatedAt: Date,
    isPinned: Bool = false
  ) -> AgentSession {
    AgentSession(
      id: UUID(),
      projectID: projectID,
      projectPath: "/\(projectID)",
      codexSessionID: nil,
      title: title,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      messages: [],
      isRunning: false,
      isPinned: isPinned
    )
  }
}

@MainActor
final class SessionManagementTests: XCTestCase {
  func testPinningAndDeletingSessionUpdatesLocalState() async {
    let session = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Managed session",
      createdAt: Date(),
      updatedAt: Date(),
      messages: [],
      isRunning: false
    )
    let client = SessionManagementAPIClient(session: session)
    let suite = "SessionManagementTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      testConfiguration: APIConfiguration(host: "test.local", port: 8765, token: "token"),
      client: client,
      sessions: [session],
      draftStore: DraftStore(defaults: defaults)
    )

    let didPin = await model.setSessionPinned(session.id, isPinned: true)
    XCTAssertTrue(didPin)
    XCTAssertTrue(model.selectedSession?.isPinned == true)
    let didDelete = await model.deleteSession(session.id)
    XCTAssertTrue(didDelete)
    XCTAssertTrue(model.sessions.isEmpty)
    XCTAssertNil(model.selectedSessionID)
    let deletedSessionIDs = await client.deletedSessionIDs
    XCTAssertEqual(deletedSessionIDs, [session.id])
  }
}

@MainActor
final class UnreadBadgeTests: XCTestCase {
  func testInitialUnreadSessionsSetAppBadgeCount() async throws {
    let first = makeSession(isUnread: true)
    let second = makeSession(isUnread: true)
    let notifications = BadgeRecordingNotificationService()
    _ = makeModel(
      sessions: [first, second],
      client: UnreadBadgeAPIClient(updatedSession: first),
      notifications: notifications
    )

    try await waitForBadgeCount(2, notifications: notifications)
    let badgeCounts = await notifications.badgeCounts
    XCTAssertEqual(badgeCounts.last, 2)
  }

  func testMarkingSessionReadClearsAppBadge() async throws {
    let unread = makeSession(isUnread: true)
    var read = unread
    read.isUnread = false
    let notifications = BadgeRecordingNotificationService()
    let model = makeModel(
      sessions: [unread],
      client: UnreadBadgeAPIClient(updatedSession: read),
      notifications: notifications
    )
    try await waitForBadgeCount(1, notifications: notifications)

    await model.markSessionRead(unread.id)

    try await waitForBadgeCount(0, notifications: notifications)
    let badgeCounts = await notifications.badgeCounts
    XCTAssertEqual(badgeCounts, [1, 0])
  }

  func testMarkingSessionUnreadSetsAppBadge() async throws {
    let read = makeSession(isUnread: false)
    var unread = read
    unread.isUnread = true
    let notifications = BadgeRecordingNotificationService()
    let client = UnreadBadgeAPIClient(updatedSession: unread)
    let model = makeModel(
      sessions: [read],
      client: client,
      notifications: notifications
    )
    try await waitForBadgeCount(0, notifications: notifications)

    let markedUnread = await model.markSessionUnread(read.id)
    XCTAssertTrue(markedUnread)

    try await waitForBadgeCount(1, notifications: notifications)
    XCTAssertTrue(model.sessions.first?.isUnread == true)
    let markedSessionIDs = await client.markedUnreadSessionIDs
    XCTAssertEqual(markedSessionIDs, [read.id])
  }

  func testForegroundRefreshMarksAlreadyVisibleSessionRead() async {
    let previouslyRead = makeSession(isUnread: false)
    var unreadOnServer = previouslyRead
    unreadOnServer.isUnread = true
    let client = ForegroundUnreadAPIClient(session: unreadOnServer)
    let notifications = BadgeRecordingNotificationService()
    let model = makeModel(
      sessions: [previouslyRead],
      client: client,
      notifications: notifications
    )

    await model.refreshForForeground()

    XCTAssertFalse(model.selectedSession?.isUnread ?? true)
    let markedSessionIDs = await client.markedSessionIDs
    XCTAssertEqual(markedSessionIDs, [previouslyRead.id])
  }

  private func makeModel(
    sessions: [AgentSession],
    client: RemoteAPIClientProtocol,
    notifications: BadgeRecordingNotificationService
  ) -> AppModel {
    let suite = "UnreadBadgeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return AppModel(
      testConfiguration: APIConfiguration(host: "test.local", port: 8765, token: "token"),
      client: client,
      sessions: sessions,
      draftStore: DraftStore(defaults: defaults),
      completionNotifications: notifications
    )
  }

  private func makeSession(isUnread: Bool) -> AgentSession {
    AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Test",
      createdAt: Date(),
      updatedAt: Date(),
      messages: [],
      isRunning: false,
      isUnread: isUnread
    )
  }

  private func waitForBadgeCount(
    _ expected: Int,
    notifications: BadgeRecordingNotificationService
  ) async throws {
    for _ in 0..<100 {
      if await notifications.badgeCounts.last == expected { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for badge count \(expected)")
  }
}

@MainActor
final class PromptQueueTests: XCTestCase {
  func testOutgoingMessageAppearsBeforeWorkingState() async throws {
    let session = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Test",
      createdAt: Date(),
      updatedAt: Date(),
      messages: [],
      isRunning: false
    )
    let client = DeferredPromptAPIClient()
    let suite = "PromptQueueTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      testConfiguration: APIConfiguration(host: "test.local", port: 8765, token: "token"),
      client: client,
      sessions: [session],
      draftStore: DraftStore(defaults: defaults)
    )

    let sendTask = Task { await model.sendPrompt("Start the work", to: session.id) }
    await client.waitUntilSendBegins()

    XCTAssertEqual(model.selectedSession?.messages.last?.text, "Start the work")
    XCTAssertEqual(model.selectedSession?.messages.last?.role, .user)
    XCTAssertFalse(model.selectedSession?.isRunning ?? true)

    await client.acceptSend()
    let didSend = await sendTask.value

    XCTAssertTrue(didSend)
    XCTAssertTrue(model.selectedSession?.isRunning == true)
  }

  func testPromptQueuesOnServerWhileSessionRuns() async throws {
    let context = makeContext(isRunning: true)

    let didQueue = await context.model.sendPrompt("Follow up", to: context.session.id)
    XCTAssertTrue(didQueue)

    XCTAssertEqual(
      context.model.queuedPrompts(sessionID: context.session.id).map(\.text),
      ["Follow up"]
    )
    let queuedTexts = await context.client.queuedTexts
    XCTAssertEqual(queuedTexts, ["Follow up"])
    let sentMessages = await context.client.sentMessages
    XCTAssertTrue(sentMessages.isEmpty)
  }

  func testQueuedPromptCanBeEditedAndRemovedOnServer() async throws {
    let context = makeContext(isRunning: true, queuedTexts: ["Original"])
    let prompt = try XCTUnwrap(context.model.queuedPrompts(sessionID: context.session.id).first)

    let didUpdate = await context.model.updateQueuedPrompt(
      prompt.id,
      text: "Edited on the Mac",
      sessionID: context.session.id
    )
    XCTAssertTrue(didUpdate)
    XCTAssertEqual(
      context.model.queuedPrompts(sessionID: context.session.id).map(\.text),
      ["Edited on the Mac"]
    )
    let updatedTexts = await context.client.updatedTexts
    XCTAssertEqual(updatedTexts, ["Edited on the Mac"])

    let didRemove = await context.model.removeQueuedPrompt(prompt.id, sessionID: context.session.id)
    XCTAssertTrue(didRemove)
    XCTAssertTrue(context.model.queuedPrompts(sessionID: context.session.id).isEmpty)
    let deletedPromptIDs = await context.client.deletedPromptIDs
    XCTAssertEqual(deletedPromptIDs, [prompt.id])
  }

  private func makeContext(
    isRunning: Bool,
    queuedTexts: [String] = []
  ) -> (model: AppModel, client: PromptQueueAPIClient, session: AgentSession) {
    let suite = "PromptQueueTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = DraftStore(defaults: defaults)
    let configuration = APIConfiguration(host: "test.local", port: 8765, token: "token")
    let session = AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Test",
      createdAt: Date(),
      updatedAt: Date(),
      messages: [],
      isRunning: isRunning,
      queuedPrompts: queuedTexts.map { QueuedPrompt(text: $0) }
    )
    let client = PromptQueueAPIClient()
    let model = AppModel(
      testConfiguration: configuration,
      client: client,
      sessions: [session],
      draftStore: store
    )
    return (model, client, session)
  }
}

private actor SessionManagementAPIClient: RemoteAPIClientProtocol {
  private var storedSession: AgentSession
  private(set) var deletedSessionIDs: [UUID] = []

  init(session: AgentSession) {
    storedSession = session
  }

  func setSessionPinned(id: UUID, isPinned: Bool) async throws -> AgentSession {
    guard storedSession.id == id else { throw RemoteAPIError.invalidData }
    storedSession.isPinned = isPinned
    return storedSession
  }

  func deleteSession(id: UUID) async throws -> AgentSession {
    guard storedSession.id == id else { throw RemoteAPIError.invalidData }
    deletedSessionIDs.append(id)
    return storedSession
  }

  func health() async throws -> HealthResponse { throw RemoteAPIError.invalidData }
  func projects() async throws -> [AgentProject] { throw RemoteAPIError.invalidData }
  func sessions(projectID: String?) async throws -> [AgentSession] {
    throw RemoteAPIError.invalidData
  }
  func session(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func renameSession(id: UUID, title: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func markSessionRead(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func documents(projectID: String) async throws -> [ProjectDocument] {
    throw RemoteAPIError.invalidData
  }
  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse {
    throw RemoteAPIError.invalidData
  }
}

private actor BadgeRecordingNotificationService: CompletionNotificationServing {
  private(set) var badgeCounts: [Int] = []

  func requestAuthorizationIfNeeded() async {}

  func setUnreadBadgeCount(_ count: Int) async {
    badgeCounts.append(count)
  }

  func notifyCompletion(for session: AgentSession) async {}
}

private actor DeferredLifecycleAPIClient: RemoteAPIClientProtocol {
  private let project: AgentProject
  private let storedSession: AgentSession
  private var holdHealthRequests = true
  private var healthContinuations: [CheckedContinuation<Void, Never>] = []
  private var renameContinuation: CheckedContinuation<Void, Never>?
  private var renameStarted = false
  private(set) var healthRequestCount = 0
  private(set) var projectRequestCount = 0
  private(set) var sessionRequestCount = 0
  private(set) var statusRequestCount = 0
  private(set) var requestedStatusIDs: [[UUID]] = []

  init(project: AgentProject, session: AgentSession) {
    self.project = project
    storedSession = session
  }

  func health() async throws -> HealthResponse {
    healthRequestCount += 1
    if holdHealthRequests {
      await withCheckedContinuation { healthContinuations.append($0) }
    }
    return HealthResponse(status: "ok", version: "test")
  }

  func projects() async throws -> [AgentProject] {
    projectRequestCount += 1
    return [project]
  }

  func sessions(projectID _: String?) async throws -> [AgentSession] {
    sessionRequestCount += 1
    return [storedSession]
  }

  func sessionStatuses(ids: [UUID]) async throws -> [SessionStatusSnapshot] {
    statusRequestCount += 1
    requestedStatusIDs.append(ids)
    return ids.map { id in
      SessionStatusSnapshot(
        id: id,
        contentRevision: storedSession.contentRevision,
        messageCount: storedSession.messages.count,
        updatedAt: storedSession.updatedAt,
        isRunning: storedSession.isRunning,
        currentReasoning: storedSession.currentReasoning,
        isUnread: storedSession.isUnread,
        hasPendingProjectCommand: storedSession.hasPendingProjectCommand,
        queuedPromptCount: storedSession.queuedPrompts.count
      )
    }
  }

  func waitUntilHealthRequestStarts() async {
    while healthRequestCount == 0 { await Task.yield() }
  }

  func releaseHealthRequests() {
    holdHealthRequests = false
    let continuations = healthContinuations
    healthContinuations = []
    for continuation in continuations {
      continuation.resume()
    }
  }

  func waitUntilSnapshotLoads() async throws {
    for _ in 0..<100 {
      if projectRequestCount > 0, sessionRequestCount > 0 { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteAPIError.unreachable("Timed out waiting for the snapshot")
  }

  func waitUntilSessionRequestCount(_ expectedCount: Int) async throws {
    for _ in 0..<200 {
      if sessionRequestCount >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteAPIError.unreachable("Timed out waiting for session polling")
  }

  func waitUntilStatusRequestCount(_ expectedCount: Int) async throws {
    for _ in 0..<200 {
      if statusRequestCount >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteAPIError.unreachable("Timed out waiting for status polling")
  }

  func session(id _: UUID) async throws -> AgentSession { storedSession }
  func renameSession(id _: UUID, title: String) async throws -> AgentSession {
    renameStarted = true
    await withCheckedContinuation { renameContinuation = $0 }
    return AgentSession(
      id: storedSession.id,
      projectID: storedSession.projectID,
      projectPath: storedSession.projectPath,
      codexSessionID: storedSession.codexSessionID,
      title: title,
      createdAt: storedSession.createdAt,
      updatedAt: storedSession.updatedAt,
      messages: storedSession.messages,
      isRunning: storedSession.isRunning,
      currentReasoning: storedSession.currentReasoning,
      isUnread: storedSession.isUnread,
      isPinned: storedSession.isPinned,
      selectedMakeTarget: storedSession.selectedMakeTarget,
      queuedPrompts: storedSession.queuedPrompts,
      contentRevision: storedSession.contentRevision
    )
  }

  func waitUntilRenameStarts() async {
    while !renameStarted { await Task.yield() }
  }

  func releaseRenameRequest() {
    renameContinuation?.resume()
    renameContinuation = nil
  }
  func setSessionPinned(id _: UUID, isPinned _: Bool) async throws -> AgentSession {
    storedSession
  }
  func deleteSession(id _: UUID) async throws -> AgentSession { storedSession }
  func markSessionRead(id _: UUID) async throws -> AgentSession { storedSession }
  func documents(projectID _: String) async throws -> [ProjectDocument] { [] }
  func documentContent(projectID _: String, documentID _: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID _: String) async throws -> AgentSession { storedSession }
  func sendMessage(_: String, sessionID: UUID) async throws -> AcceptedResponse {
    AcceptedResponse(sessionID: sessionID, status: "accepted")
  }
}

private actor StatusPollingAPIClient: RemoteAPIClientProtocol {
  private var storedSession: AgentSession
  private(set) var statusRequestCount = 0
  private(set) var sessionRequestCount = 0

  init(session: AgentSession) {
    storedSession = session
    storedSession.currentReasoning = "Checking the focused session."
  }

  func sessionStatuses(ids: [UUID]) async throws -> [SessionStatusSnapshot] {
    statusRequestCount += 1
    guard ids.contains(storedSession.id) else { return [] }
    return [
      SessionStatusSnapshot(
        id: storedSession.id,
        contentRevision: storedSession.contentRevision,
        messageCount: storedSession.messages.count,
        updatedAt: storedSession.updatedAt,
        isRunning: storedSession.isRunning,
        currentReasoning: storedSession.currentReasoning,
        isUnread: storedSession.isUnread,
        hasPendingProjectCommand: storedSession.hasPendingProjectCommand,
        queuedPromptCount: storedSession.queuedPrompts.count
      )
    ]
  }

  func session(id: UUID) async throws -> AgentSession {
    guard id == storedSession.id else { throw RemoteAPIError.invalidData }
    sessionRequestCount += 1
    return storedSession
  }

  func completeTurn() {
    var messages = storedSession.messages
    let completedAt = storedSession.updatedAt.addingTimeInterval(1)
    messages.append(
      AgentMessage(
        id: UUID(),
        role: .assistant,
        text: "Finished",
        createdAt: completedAt,
        state: .complete
      )
    )
    storedSession = replacingStoredSession(
      messages: messages,
      updatedAt: completedAt,
      isRunning: false,
      currentReasoning: nil,
      contentRevision: storedSession.contentRevision &+ 1
    )
  }

  func advanceToQueuedTurn() {
    let completedAt = storedSession.updatedAt.addingTimeInterval(1)
    var messages = storedSession.messages
    messages.append(
      AgentMessage(
        id: UUID(),
        role: .assistant,
        text: "First finished",
        createdAt: completedAt,
        state: .complete
      )
    )
    messages.append(
      AgentMessage(
        id: UUID(),
        role: .user,
        text: "Queued follow up",
        createdAt: completedAt,
        state: .complete
      )
    )
    storedSession = replacingStoredSession(
      messages: messages,
      updatedAt: completedAt,
      isRunning: true,
      currentReasoning: "Starting the queued follow up.",
      contentRevision: storedSession.contentRevision &+ 1
    )
  }

  private func replacingStoredSession(
    messages: [AgentMessage],
    updatedAt: Date,
    isRunning: Bool,
    currentReasoning: String?,
    contentRevision: UInt64
  ) -> AgentSession {
    AgentSession(
      id: storedSession.id,
      projectID: storedSession.projectID,
      projectPath: storedSession.projectPath,
      codexSessionID: storedSession.codexSessionID,
      title: storedSession.title,
      createdAt: storedSession.createdAt,
      updatedAt: updatedAt,
      messages: messages,
      isRunning: isRunning,
      currentReasoning: currentReasoning,
      isUnread: storedSession.isUnread,
      isPinned: storedSession.isPinned,
      selectedMakeTarget: storedSession.selectedMakeTarget,
      queuedPrompts: storedSession.queuedPrompts,
      contentRevision: contentRevision
    )
  }

  func waitUntilStatusRequestCount(_ expectedCount: Int) async throws {
    for _ in 0..<300 {
      if statusRequestCount >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteAPIError.unreachable("Timed out waiting for status polling")
  }

  func waitUntilSessionRequestCount(_ expectedCount: Int) async throws {
    for _ in 0..<300 {
      if sessionRequestCount >= expectedCount { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteAPIError.unreachable("Timed out waiting for a targeted session refresh")
  }

  func health() async throws -> HealthResponse { throw RemoteAPIError.invalidData }
  func projects() async throws -> [AgentProject] { throw RemoteAPIError.invalidData }
  func sessions(projectID _: String?) async throws -> [AgentSession] {
    throw RemoteAPIError.invalidData
  }
  func renameSession(id _: UUID, title _: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func setSessionPinned(id _: UUID, isPinned _: Bool) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func deleteSession(id _: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func markSessionRead(id _: UUID) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func documents(projectID _: String) async throws -> [ProjectDocument] {
    throw RemoteAPIError.invalidData
  }
  func documentContent(projectID _: String, documentID _: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID _: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func sendMessage(_: String, sessionID _: UUID) async throws -> AcceptedResponse {
    throw RemoteAPIError.invalidData
  }
}

private actor LegacyPollingAPIClient: RemoteAPIClientProtocol {
  private let storedSession: AgentSession
  private(set) var statusRequestCount = 0
  private(set) var fullSnapshotRequestCount = 0

  init(session: AgentSession) {
    storedSession = session
  }

  func sessionStatuses(ids _: [UUID]) async throws -> [SessionStatusSnapshot] {
    statusRequestCount += 1
    throw RemoteAPIError.http(status: 404, detail: "Route not found")
  }

  func sessions(projectID _: String?) async throws -> [AgentSession] {
    fullSnapshotRequestCount += 1
    return [storedSession]
  }

  func waitUntilFullSnapshotRequest() async throws {
    for _ in 0..<300 {
      if fullSnapshotRequestCount > 0 { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteAPIError.unreachable("Timed out waiting for legacy full-session polling")
  }

  func health() async throws -> HealthResponse { throw RemoteAPIError.invalidData }
  func projects() async throws -> [AgentProject] { throw RemoteAPIError.invalidData }
  func session(id _: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func renameSession(id _: UUID, title _: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func setSessionPinned(id _: UUID, isPinned _: Bool) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func deleteSession(id _: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func markSessionRead(id _: UUID) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func documents(projectID _: String) async throws -> [ProjectDocument] {
    throw RemoteAPIError.invalidData
  }
  func documentContent(projectID _: String, documentID _: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID _: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func sendMessage(_: String, sessionID _: UUID) async throws -> AcceptedResponse {
    throw RemoteAPIError.invalidData
  }
}

private actor UnreadBadgeAPIClient: RemoteAPIClientProtocol {
  let updatedSession: AgentSession
  private(set) var markedUnreadSessionIDs: [UUID] = []

  init(updatedSession: AgentSession) {
    self.updatedSession = updatedSession
  }

  func markSessionRead(id: UUID) async throws -> AgentSession {
    updatedSession
  }

  func markSessionUnread(id: UUID) async throws -> AgentSession {
    markedUnreadSessionIDs.append(id)
    return updatedSession
  }

  func health() async throws -> HealthResponse { throw RemoteAPIError.invalidData }
  func projects() async throws -> [AgentProject] { throw RemoteAPIError.invalidData }
  func sessions(projectID: String?) async throws -> [AgentSession] {
    throw RemoteAPIError.invalidData
  }
  func session(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func renameSession(id: UUID, title: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func setSessionPinned(id: UUID, isPinned: Bool) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func deleteSession(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func documents(projectID: String) async throws -> [ProjectDocument] {
    throw RemoteAPIError.invalidData
  }
  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse {
    throw RemoteAPIError.invalidData
  }
}

private actor ForegroundUnreadAPIClient: RemoteAPIClientProtocol {
  private var storedSession: AgentSession
  private(set) var markedSessionIDs: [UUID] = []

  init(session: AgentSession) {
    storedSession = session
  }

  func projects() async throws -> [AgentProject] { [] }

  func sessions(projectID: String?) async throws -> [AgentSession] {
    [storedSession]
  }

  func markSessionRead(id: UUID) async throws -> AgentSession {
    guard storedSession.id == id else { throw RemoteAPIError.invalidData }
    markedSessionIDs.append(id)
    storedSession.isUnread = false
    return storedSession
  }

  func health() async throws -> HealthResponse {
    HealthResponse(status: "ok", version: "test")
  }
  func session(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func renameSession(id: UUID, title: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func setSessionPinned(id: UUID, isPinned: Bool) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func deleteSession(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func documents(projectID: String) async throws -> [ProjectDocument] {
    throw RemoteAPIError.invalidData
  }
  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse {
    throw RemoteAPIError.invalidData
  }
}

private actor PromptQueueAPIClient: RemoteAPIClientProtocol {
  private(set) var sentMessages: [String] = []
  private(set) var queuedTexts: [String] = []
  private(set) var updatedTexts: [String] = []
  private(set) var deletedPromptIDs: [UUID] = []

  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse {
    sentMessages.append(text)
    return AcceptedResponse(sessionID: sessionID, status: "accepted")
  }

  func enqueuePrompt(_ text: String, sessionID _: UUID) async throws -> QueuedPrompt {
    queuedTexts.append(text)
    return QueuedPrompt(text: text)
  }

  func updateQueuedPrompt(_ promptID: UUID, text: String, sessionID _: UUID) async throws
    -> QueuedPrompt
  {
    updatedTexts.append(text)
    return QueuedPrompt(id: promptID, text: text)
  }

  func deleteQueuedPrompt(_ promptID: UUID, sessionID _: UUID) async throws -> QueuedPrompt {
    deletedPromptIDs.append(promptID)
    return QueuedPrompt(id: promptID, text: "Deleted")
  }

  func health() async throws -> HealthResponse { throw RemoteAPIError.invalidData }
  func projects() async throws -> [AgentProject] { throw RemoteAPIError.invalidData }
  func sessions(projectID: String?) async throws -> [AgentSession] {
    throw RemoteAPIError.invalidData
  }
  func session(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func renameSession(id: UUID, title: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func setSessionPinned(id: UUID, isPinned: Bool) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func deleteSession(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func markSessionRead(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func documents(projectID: String) async throws -> [ProjectDocument] {
    throw RemoteAPIError.invalidData
  }
  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
}

private actor DeferredPromptAPIClient: RemoteAPIClientProtocol {
  private var requestedSessionID: UUID?
  private var continuation: CheckedContinuation<AcceptedResponse, Never>?

  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse {
    requestedSessionID = sessionID
    return await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilSendBegins() async {
    while requestedSessionID == nil { await Task.yield() }
  }

  func acceptSend() {
    guard let requestedSessionID, let continuation else { return }
    self.continuation = nil
    continuation.resume(
      returning: AcceptedResponse(sessionID: requestedSessionID, status: "accepted")
    )
  }

  func health() async throws -> HealthResponse { throw RemoteAPIError.invalidData }
  func projects() async throws -> [AgentProject] { throw RemoteAPIError.invalidData }
  func sessions(projectID: String?) async throws -> [AgentSession] {
    throw RemoteAPIError.invalidData
  }
  func session(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func renameSession(id: UUID, title: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func setSessionPinned(id: UUID, isPinned: Bool) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func deleteSession(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func markSessionRead(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func documents(projectID: String) async throws -> [ProjectDocument] {
    throw RemoteAPIError.invalidData
  }
  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
}

final class ProjectLinkResolverTests: XCTestCase {
  private let projectPath = "/Users/example/projects/sample"

  func testResolvesAbsoluteMacProjectPath() throws {
    let url = try XCTUnwrap(URL(string: "/Users/example/projects/sample/reports/status.md"))
    XCTAssertEqual(
      ProjectLinkResolver.destination(for: url, projectPath: projectPath),
      .document(relativePath: "reports/status.md")
    )
  }

  func testResolvesRelativeDocumentLink() throws {
    let url = try XCTUnwrap(URL(string: "../shared/details.html"))
    XCTAssertEqual(
      ProjectLinkResolver.destination(
        for: url,
        projectPath: projectPath,
        currentDocumentRelativePath: "reports/weekly/status.md"
      ),
      .document(relativePath: "reports/shared/details.html")
    )
  }

  func testResolvesSourceCodeAndExtensionlessBuildFiles() throws {
    let swiftURL = try XCTUnwrap(URL(string: "../Sources/App.swift"))
    let makefileURL = try XCTUnwrap(URL(string: "../Makefile"))

    XCTAssertEqual(
      ProjectLinkResolver.destination(
        for: swiftURL,
        projectPath: projectPath,
        currentDocumentRelativePath: "docs/status.md"
      ),
      .document(relativePath: "Sources/App.swift")
    )
    XCTAssertEqual(
      ProjectLinkResolver.destination(
        for: makefileURL,
        projectPath: projectPath,
        currentDocumentRelativePath: "docs/status.md"
      ),
      .document(relativePath: "Makefile")
    )
  }

  func testPreservesWebLinksAndRejectsOutsideFiles() throws {
    let webURL = try XCTUnwrap(URL(string: "https://example.com/report"))
    let outsideURL = try XCTUnwrap(URL(string: "/Users/example/private/report.md"))
    XCTAssertEqual(
      ProjectLinkResolver.destination(for: webURL, projectPath: projectPath), .web(webURL))
    XCTAssertEqual(
      ProjectLinkResolver.destination(for: outsideURL, projectPath: projectPath),
      .unsupported
    )
  }

  func testResolvesHTMLLinksAgainstCustomProjectBaseURL() throws {
    let baseURL = try XCTUnwrap(ProjectLinkResolver.baseURL(for: "reports/status.html"))
    let siblingURL = try XCTUnwrap(URL(string: "details.html", relativeTo: baseURL)?.absoluteURL)
    let absoluteMacURL = try XCTUnwrap(
      URL(string: "/Users/example/projects/sample/reports/archive.md", relativeTo: baseURL)?
        .absoluteURL
    )

    XCTAssertEqual(
      ProjectLinkResolver.destination(
        for: siblingURL,
        projectPath: projectPath,
        currentDocumentRelativePath: "reports/status.html"
      ),
      .document(relativePath: "reports/details.html")
    )
    XCTAssertEqual(
      ProjectLinkResolver.destination(for: absoluteMacURL, projectPath: projectPath),
      .document(relativePath: "reports/archive.md")
    )
  }
}

@MainActor
final class ProjectDocumentBrowsingTests: XCTestCase {
  func testBrowserIncludesDocumentationButNotCode() {
    let documents = [
      makeDocument(
        path: "README.md", kind: .markdown, modifiedAt: Date(timeIntervalSince1970: 100)),
      makeDocument(
        path: "docs/report.html", kind: .html, modifiedAt: Date(timeIntervalSince1970: 300)),
      makeDocument(
        path: "Sources/App.swift", kind: .code, modifiedAt: Date(timeIntervalSince1970: 400)),
    ]

    XCTAssertEqual(
      documents.browsable.map(\.relativePath),
      ["docs/report.html", "README.md"]
    )
  }

  func testBrowserSupportsManualNameAndSizeSorting() {
    let documents = [
      makeDocument(
        path: "z-last.md", kind: .markdown, byteCount: 100,
        modifiedAt: Date(timeIntervalSince1970: 300)),
      makeDocument(
        path: "a-first.html", kind: .html, byteCount: 300,
        modifiedAt: Date(timeIntervalSince1970: 100)),
      makeDocument(
        path: "middle.md", kind: .markdown, byteCount: 200,
        modifiedAt: Date(timeIntervalSince1970: 200)),
    ]

    XCTAssertEqual(
      documents.browsable(sortedBy: .name).map(\.relativePath),
      ["a-first.html", "middle.md", "z-last.md"]
    )
    XCTAssertEqual(
      documents.browsable(sortedBy: .size).map(\.relativePath),
      ["a-first.html", "middle.md", "z-last.md"]
    )
  }

  func testCodeDocumentRemainsAvailableForConversationLinks() async throws {
    let code = makeDocument(path: "Sources/App.swift", kind: .code)
    let client = DocumentCatalogAPIClient(documents: [code])
    let suite = "ProjectDocumentBrowsingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      testConfiguration: APIConfiguration(host: "test.local", port: 8765, token: "token"),
      client: client,
      sessions: [],
      draftStore: DraftStore(defaults: defaults),
      completionNotifications: BadgeRecordingNotificationService()
    )

    let linkedDocument = try await model.document(
      projectID: "project",
      relativePath: "Sources/App.swift"
    )

    XCTAssertEqual(linkedDocument, code)
  }

  private func makeDocument(
    path: String,
    kind: ProjectDocumentKind,
    byteCount: Int = 42,
    modifiedAt: Date? = nil
  ) -> ProjectDocument {
    ProjectDocument(
      id: path,
      name: (path as NSString).lastPathComponent,
      relativePath: path,
      kind: kind,
      byteCount: byteCount,
      modifiedAt: modifiedAt
    )
  }
}

private actor DocumentCatalogAPIClient: RemoteAPIClientProtocol {
  let catalog: [ProjectDocument]

  init(documents: [ProjectDocument]) {
    catalog = documents
  }

  func documents(projectID: String) async throws -> [ProjectDocument] { catalog }

  func health() async throws -> HealthResponse { throw RemoteAPIError.invalidData }
  func projects() async throws -> [AgentProject] { throw RemoteAPIError.invalidData }
  func sessions(projectID: String?) async throws -> [AgentSession] {
    throw RemoteAPIError.invalidData
  }
  func session(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func renameSession(id: UUID, title: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func setSessionPinned(id: UUID, isPinned: Bool) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func deleteSession(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func markSessionRead(id: UUID) async throws -> AgentSession { throw RemoteAPIError.invalidData }
  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    throw RemoteAPIError.invalidData
  }
  func createSession(projectID: String) async throws -> AgentSession {
    throw RemoteAPIError.invalidData
  }
  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse {
    throw RemoteAPIError.invalidData
  }
}

final class CodeDocumentPreviewTests: XCTestCase {
  func testLineNumbersIncludeBlankAndTrailingLines() {
    XCTAssertEqual(CodeDocumentPreview.lineNumbers(for: "let value = 1\n\n"), "1\n2\n3")
    XCTAssertEqual(CodeDocumentPreview.lineNumbers(for: ""), "1")
  }
}

final class MarkdownDocumentParserTests: XCTestCase {
  func testParsesRichMarkdownBlocks() {
    let markdown = """
      # Project Notes

      This has **bold**, *italic*, and `inline code`.

      - First item
        - Nested item
      1. Ordered item
      - [x] Finished task

      > A helpful quote

      ```swift
      let answer = 42
      ```

      ---
      """

    XCTAssertEqual(
      MarkdownDocumentParser.parse(markdown),
      [
        .heading(level: 1, content: "Project Notes"),
        .paragraph("This has **bold**, *italic*, and `inline code`."),
        .unorderedListItem(depth: 0, content: "First item"),
        .unorderedListItem(depth: 1, content: "Nested item"),
        .orderedListItem(depth: 0, number: "1", content: "Ordered item"),
        .unorderedListItem(depth: 0, content: "[x] Finished task"),
        .quote("A helpful quote"),
        .code(language: "swift", content: "let answer = 42"),
        .rule,
      ]
    )
  }

  func testTreatsUnclosedFenceAsCodeUntilEndOfFile() {
    XCTAssertEqual(
      MarkdownDocumentParser.parse("```\nprint(\"Hello\")"),
      [.code(language: nil, content: "print(\"Hello\")")]
    )
  }

  func testParsesMarkdownTableWithAlignmentAndMissingCells() {
    let markdown = """
      # Team Review

      Team | Capacity usage | Readout
      :--- | :---: | ---:
      Expansion | 99.39% | Monthly \\| weekly
      Formation | 69.19%
      """

    XCTAssertEqual(
      MarkdownDocumentParser.parse(markdown),
      [
        .heading(level: 1, content: "Team Review"),
        .table(
          headers: ["Team", "Capacity usage", "Readout"],
          alignments: [.leading, .center, .trailing],
          rows: [
            ["Expansion", "99.39%", "Monthly \\| weekly"],
            ["Formation", "69.19%", ""],
          ]
        ),
      ]
    )
  }
}
