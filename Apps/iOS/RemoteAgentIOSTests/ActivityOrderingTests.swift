import XCTest

@testable import RemoteAgentIOS

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
  func testPromptQueuesWithoutCallingServerWhileSessionRuns() async throws {
    let context = makeContext(isRunning: true)

    let didQueue = await context.model.sendPrompt("Follow up", to: context.session.id)
    XCTAssertTrue(didQueue)

    XCTAssertEqual(
      context.model.queuedPrompts(sessionID: context.session.id).map(\.text),
      ["Follow up"]
    )
    let sentMessages = await context.client.sentMessages
    XCTAssertTrue(sentMessages.isEmpty)
  }

  func testIdleSessionDispatchesOnlyFirstPersistedPrompt() async throws {
    let context = makeContext(isRunning: false, queuedTexts: ["First", "Second"])

    context.model.selectSession(context.session.id)
    for _ in 0..<100 {
      if !(await context.client.sentMessages).isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    let sentMessages = await context.client.sentMessages
    XCTAssertEqual(sentMessages, ["First"])
    XCTAssertEqual(
      context.model.queuedPrompts(sessionID: context.session.id).map(\.text),
      ["Second"]
    )
    XCTAssertTrue(context.model.selectedSession?.isRunning == true)
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
      isRunning: isRunning
    )
    store.saveQueuedPrompts(
      queuedTexts.map { QueuedPrompt(text: $0) },
      serverIdentifier: configuration.serverIdentifier,
      sessionID: session.id
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

private actor UnreadBadgeAPIClient: RemoteAPIClientProtocol {
  let updatedSession: AgentSession

  init(updatedSession: AgentSession) {
    self.updatedSession = updatedSession
  }

  func markSessionRead(id: UUID) async throws -> AgentSession {
    updatedSession
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

  func health() async throws -> HealthResponse { throw RemoteAPIError.invalidData }
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

  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse {
    sentMessages.append(text)
    return AcceptedResponse(sessionID: sessionID, status: "accepted")
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
      makeDocument(path: "README.md", kind: .markdown),
      makeDocument(path: "docs/report.html", kind: .html),
      makeDocument(path: "Sources/App.swift", kind: .code),
    ]

    XCTAssertEqual(
      documents.browsable.map(\.relativePath),
      ["README.md", "docs/report.html"]
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

  private func makeDocument(path: String, kind: ProjectDocumentKind) -> ProjectDocument {
    ProjectDocument(
      id: path,
      name: (path as NSString).lastPathComponent,
      relativePath: path,
      kind: kind,
      byteCount: 42
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
}
