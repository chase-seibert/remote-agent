import XCTest

@testable import RemoteAgentIOS

@MainActor
final class BackgroundRefreshTests: XCTestCase {
  func testBackgroundRefreshIsScheduledOnlyForActiveSessions() {
    let runningScheduler = RecordingBackgroundRefreshScheduler()
    let runningContext = makeContext(
      initialSession: makeSession(isRunning: true),
      refreshedSessions: [],
      scheduler: runningScheduler
    )

    runningContext.model.sceneActivityChanged(isActive: false)

    XCTAssertEqual(runningScheduler.scheduleCount, 1)
    runningContext.model.disconnect()

    let idleScheduler = RecordingBackgroundRefreshScheduler()
    let idleContext = makeContext(
      initialSession: makeSession(isRunning: false),
      refreshedSessions: [],
      scheduler: idleScheduler
    )

    idleContext.model.sceneActivityChanged(isActive: false)

    XCTAssertEqual(idleScheduler.scheduleCount, 0)
    XCTAssertGreaterThan(idleScheduler.cancelCount, 0)
    idleContext.model.disconnect()
  }

  func testBackgroundRefreshNotifiesWhenRunningSessionCompletes() async {
    let running = makeSession(isRunning: true)
    var completed = running
    completed.isRunning = false
    let scheduler = RecordingBackgroundRefreshScheduler()
    let context = makeContext(
      initialSession: running,
      refreshedSessions: [completed],
      scheduler: scheduler
    )
    context.model.sceneActivityChanged(isActive: false)

    await context.model.performBackgroundRefresh()

    let notifiedSessionIDs = await context.notifications.notifiedSessionIDs
    XCTAssertEqual(notifiedSessionIDs, [running.id])
    XCTAssertTrue(
      context.watchStore.sessionIDs(serverIdentifier: context.configuration.serverIdentifier)
        .isEmpty
    )
    XCTAssertGreaterThan(scheduler.scheduleCount, 0)
    XCTAssertGreaterThan(scheduler.cancelCount, 0)
    context.model.disconnect()
  }

  func testBackgroundRefreshWaitsForHealthBeforeCheckingSessions() async {
    let running = makeSession(isRunning: true)
    let scheduler = RecordingBackgroundRefreshScheduler()
    let context = makeContext(
      initialSession: running,
      refreshedSessions: [running],
      scheduler: scheduler
    )
    context.model.sceneActivityChanged(isActive: false)

    await context.model.performBackgroundRefresh()

    let requests = await context.client.requests
    XCTAssertEqual(requests, ["health", "sessions"])
    context.model.disconnect()
  }

  func testFailedBackgroundReconnectDoesNotCheckSessionsAndRemainsScheduled() async {
    let running = makeSession(isRunning: true)
    let scheduler = RecordingBackgroundRefreshScheduler()
    let context = makeContext(
      initialSession: running,
      refreshedSessions: [],
      scheduler: scheduler,
      healthSucceeds: false
    )
    context.model.sceneActivityChanged(isActive: false)

    await context.model.performBackgroundRefresh()

    let requests = await context.client.requests
    let notifiedSessionIDs = await context.notifications.notifiedSessionIDs
    XCTAssertEqual(requests, ["health"])
    XCTAssertTrue(notifiedSessionIDs.isEmpty)
    XCTAssertGreaterThanOrEqual(scheduler.scheduleCount, 3)
    context.model.disconnect()
  }

  func testPersistedActiveSessionNotifiesAfterAppRelaunch() async {
    let completed = makeSession(isRunning: false)
    let scheduler = RecordingBackgroundRefreshScheduler()
    let context = makeContext(
      initialSession: nil,
      refreshedSessions: [completed],
      scheduler: scheduler
    )
    context.watchStore.save(
      [completed.id],
      serverIdentifier: context.configuration.serverIdentifier
    )

    await context.model.performBackgroundRefresh()

    let notifiedSessionIDs = await context.notifications.notifiedSessionIDs
    XCTAssertEqual(notifiedSessionIDs, [completed.id])
    XCTAssertTrue(
      context.watchStore.sessionIDs(serverIdentifier: context.configuration.serverIdentifier)
        .isEmpty
    )
    context.model.disconnect()
  }

  private func makeContext(
    initialSession: AgentSession?,
    refreshedSessions: [AgentSession],
    scheduler: RecordingBackgroundRefreshScheduler,
    healthSucceeds: Bool = true
  ) -> (
    model: AppModel,
    notifications: BackgroundNotificationRecorder,
    watchStore: BackgroundSessionWatchStore,
    configuration: APIConfiguration,
    client: BackgroundRefreshAPIClient
  ) {
    let suite = "BackgroundRefreshTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let configuration = APIConfiguration(host: "test.local", port: 8765, token: "token")
    let notifications = BackgroundNotificationRecorder()
    let watchStore = BackgroundSessionWatchStore(defaults: defaults)
    let client = BackgroundRefreshAPIClient(
      sessions: refreshedSessions,
      healthSucceeds: healthSucceeds
    )
    let model = AppModel(
      testConfiguration: configuration,
      client: client,
      sessions: initialSession.map { [$0] } ?? [],
      draftStore: DraftStore(defaults: defaults),
      completionNotifications: notifications,
      backgroundRefreshScheduler: scheduler,
      backgroundSessionWatchStore: watchStore
    )
    return (model, notifications, watchStore, configuration, client)
  }

  private func makeSession(isRunning: Bool) -> AgentSession {
    AgentSession(
      id: UUID(),
      projectID: "project",
      projectPath: "/project",
      codexSessionID: nil,
      title: "Long-running task",
      createdAt: Date(),
      updatedAt: Date(),
      messages: [],
      isRunning: isRunning
    )
  }
}

private final class RecordingBackgroundRefreshScheduler: BackgroundRefreshScheduling {
  private(set) var scheduleCount = 0
  private(set) var cancelCount = 0

  func schedule() {
    scheduleCount += 1
  }

  func cancel() {
    cancelCount += 1
  }
}

private actor BackgroundNotificationRecorder: CompletionNotificationServing {
  private(set) var notifiedSessionIDs: [UUID] = []

  func requestAuthorizationIfNeeded() async {}
  func setUnreadBadgeCount(_: Int) async {}

  func notifyCompletion(for session: AgentSession) async {
    notifiedSessionIDs.append(session.id)
  }
}

private actor BackgroundRefreshAPIClient: RemoteAPIClientProtocol {
  let storedSessions: [AgentSession]
  let healthSucceeds: Bool
  private(set) var requests: [String] = []

  init(sessions: [AgentSession], healthSucceeds: Bool) {
    storedSessions = sessions
    self.healthSucceeds = healthSucceeds
  }

  func sessions(projectID _: String?) async throws -> [AgentSession] {
    requests.append("sessions")
    return storedSessions
  }

  func health() async throws -> HealthResponse {
    requests.append("health")
    guard healthSucceeds else { throw RemoteAPIError.unreachable("Mac is unavailable") }
    return HealthResponse(status: "ok", version: "test")
  }
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
