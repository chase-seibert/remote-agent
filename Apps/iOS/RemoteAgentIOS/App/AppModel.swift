import Foundation
import RemoteAgentProtocol
import UIKit

#if DEBUG
  enum DebugAppFixture {
    private static var name: String? {
      ProcessInfo.processInfo.environment["REMOTE_AGENT_FIXTURE"]
    }

    static var isEnabled: Bool { name != nil }

    static var recentSessionsEnabled: Bool {
      name == "recent-sessions" || recentSessionDetailEnabled || renameSessionEnabled
    }

    static var recentSessionDetailEnabled: Bool {
      name == "recent-session-detail"
    }

    static var renameSessionEnabled: Bool {
      name == "rename-session"
    }

    static var promptQueueEnabled: Bool {
      name == "prompt-queue"
    }

    static var longConversationEnabled: Bool {
      longConversationEntry != nil
    }

    static var longConversationEntry: LongConversationEntry? {
      switch name {
      case "long-conversation": .direct
      case "long-conversation-from-list": .sessionList
      case "long-conversation-from-session": .anotherSession
      default: nil
      }
    }

    static var conversationEnabled: Bool {
      promptQueueEnabled || longConversationEnabled
    }

    static var codePreviewEnabled: Bool {
      name == "code-preview"
    }

    static var documentBrowserEnabled: Bool {
      name == "document-browser"
    }

    enum LongConversationEntry {
      case direct
      case sessionList
      case anotherSession
    }
  }
#endif

enum ConnectionState: Equatable {
  case loading
  case notConfigured
  case disconnected
  case connecting
  case connected(version: String)
  case failed(message: String)

  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var connectionState: ConnectionState = .loading
  @Published private(set) var projects: [AgentProject] = []
  @Published private(set) var sessions: [AgentSession] = []
  @Published private(set) var queuedPromptsBySession: [UUID: [QueuedPrompt]] = [:]
  @Published private(set) var deliveringQueuedPromptIDs: Set<UUID> = []
  @Published private(set) var configuration: APIConfiguration?
  @Published var selectedSessionID: UUID?
  @Published var presentedError: String?

  private let configurationStore: ConfigurationStore
  private let draftStore: DraftStore
  private let completionNotifications: any CompletionNotificationServing
  private var client: RemoteAPIClientProtocol?
  private var pollHandles: [UUID: PollHandle] = [:]
  private var unreadBadgeSyncTask: Task<Void, Never>?
  private var sendingSessionIDs: Set<UUID> = []
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
  private var pendingCompletionNotifications = 0
  private var appIsActive = true
  private var didStart = false
  private var protocolVersion = RemoteAgentProtocolVersion.current

  init(
    configurationStore: ConfigurationStore = ConfigurationStore(),
    draftStore: DraftStore = DraftStore(),
    completionNotifications: any CompletionNotificationServing = CompletionNotificationService()
  ) {
    self.configurationStore = configurationStore
    self.draftStore = draftStore
    self.completionNotifications = completionNotifications
    #if DEBUG
      if DebugAppFixture.recentSessionsEnabled {
        didStart = true
        installRecentSessionsFixture()
      } else if DebugAppFixture.promptQueueEnabled {
        didStart = true
        installPromptQueueFixture()
      } else if DebugAppFixture.longConversationEnabled {
        didStart = true
        installLongConversationFixture(entry: DebugAppFixture.longConversationEntry ?? .direct)
      }
    #endif
  }

  #if DEBUG
    init(
      testConfiguration: APIConfiguration,
      client: RemoteAPIClientProtocol,
      sessions: [AgentSession],
      draftStore: DraftStore,
      completionNotifications: any CompletionNotificationServing = CompletionNotificationService()
    ) {
      self.configurationStore = ConfigurationStore()
      self.draftStore = draftStore
      self.completionNotifications = completionNotifications
      configuration = testConfiguration
      self.client = client
      self.sessions = sessions
      selectedSessionID = sessions.first?.id
      connectionState = .connected(version: "test")
      protocolVersion = "test"
      didStart = true
      loadQueuedPromptsForSessions()
      syncUnreadSessionBadge()
    }
  #endif

  var selectedSession: AgentSession? {
    sessions.first { $0.id == selectedSessionID }
  }

  var visibleProjects: [AgentProject] {
    projects.sortedByRecentActivity(sessions: sessions)
  }

  var recentSessions: [AgentSession] {
    sessions.mostRecent(limit: 50)
  }

  var hasSavedConfiguration: Bool { configuration != nil }

  var hasUnreadSessions: Bool { sessions.contains(where: \.isUnread) }

  func projectName(for session: AgentSession) -> String {
    projects.first(where: { $0.id == session.projectID })?.name
      ?? URL(fileURLWithPath: session.projectPath).lastPathComponent
  }

  func start() async {
    guard !didStart else { return }
    didStart = true
    do {
      guard let configuration = try configurationStore.load() else {
        connectionState = .notConfigured
        return
      }
      self.configuration = configuration
      await connect(
        host: configuration.host,
        port: configuration.port,
        token: configuration.token
      )
    } catch {
      connectionState = .failed(message: error.localizedDescription)
      presentedError = error.localizedDescription
    }
  }

  #if DEBUG
    private func installRecentSessionsFixture() {
      let now = Date()
      let projects = [
        AgentProject(id: "ios", name: "Remote Agent iOS", path: "/Users/example/ios"),
        AgentProject(id: "host", name: "Remote Agent Host", path: "/Users/example/host"),
        AgentProject(id: "website", name: "Product Website", path: "/Users/example/website"),
      ]
      let sessions = (0..<55).map { index in
        let project = projects[index % projects.count]
        let state: MessageState = index == 2 ? .failed : .complete
        return AgentSession(
          id: UUID(),
          projectID: project.id,
          projectPath: project.path,
          codexSessionID: nil,
          title: [
            "Polish the session navigation",
            "Review unread badge behavior",
            "Fix the deployment workflow",
            "Update project documentation",
          ][index % 4],
          createdAt: now.addingTimeInterval(TimeInterval(-index * 3_600)),
          updatedAt: now.addingTimeInterval(TimeInterval(-index * 3_600)),
          messages: [
            AgentMessage(
              id: UUID(),
              role: index == 2 ? .system : .assistant,
              text: index == 2 ? "The agent could not complete this session." : "Fixture activity",
              createdAt: now.addingTimeInterval(TimeInterval(-index * 3_600)),
              state: state
            )
          ],
          isRunning: index == 0,
          isUnread: index < 2,
          isPinned: index == 7 || index == 12
        )
      }
      configuration = APIConfiguration(host: "fixture.local", port: 8765, token: "fixture")
      applySnapshot(projects: projects, sessions: sessions)
      selectSession(sessions[0].id)
      connectionState = .connected(version: "fixture")
    }

    private func installPromptQueueFixture() {
      let now = Date()
      let project = AgentProject(
        id: "fixture-prompt-queue",
        name: "Prompt Queue",
        path: "/Users/example/prompt-queue"
      )
      let session = AgentSession(
        id: UUID(),
        projectID: project.id,
        projectPath: project.path,
        codexSessionID: nil,
        title: "Queue follow-up prompts",
        createdAt: now.addingTimeInterval(-300),
        updatedAt: now,
        messages: [
          AgentMessage(
            id: UUID(),
            role: .user,
            text: "Implement prompt queues.",
            createdAt: now.addingTimeInterval(-120),
            state: .complete
          ),
          AgentMessage(
            id: UUID(),
            role: .assistant,
            text: "I’m working on the queue implementation.",
            createdAt: now.addingTimeInterval(-60),
            state: .complete
          ),
        ],
        isRunning: true
      )
      configuration = APIConfiguration(host: "fixture.local", port: 8765, token: "fixture")
      applySnapshot(projects: [project], sessions: [session])
      selectSession(session.id)
      queuedPromptsBySession[session.id] = [
        QueuedPrompt(text: "Add tests for FIFO delivery.", createdAt: now.addingTimeInterval(-30)),
        QueuedPrompt(
          text: "Then update the documentation.", createdAt: now.addingTimeInterval(-15)),
      ]
      connectionState = .connected(version: "fixture")
    }

    private func installLongConversationFixture(entry: DebugAppFixture.LongConversationEntry) {
      let now = Date()
      let project = AgentProject(
        id: "fixture-long-conversation",
        name: "Long Conversation",
        path: "/Users/example/long-conversation"
      )
      let messages = (1...120).map { index in
        let text: String
        if index == 120 {
          text = "LATEST MESSAGE — bottom navigation verified."
        } else if index.isMultiple(of: 10) {
          text = """
            Conversation message \(index) has variable-height content.

            It includes a second paragraph so the scroll test exercises real transcript measurement.

            ```swift
            let messageIndex = \(index)
            ```
            """
        } else {
          text =
            "Conversation message \(index). This fixture is intentionally long enough to require scrolling."
        }
        return AgentMessage(
          id: UUID(),
          role: index.isMultiple(of: 2) ? .assistant : .user,
          text: text,
          createdAt: now.addingTimeInterval(TimeInterval(index - 120) * 30),
          state: .complete
        )
      }
      let session = AgentSession(
        id: UUID(),
        projectID: project.id,
        projectPath: project.path,
        codexSessionID: nil,
        title: "Scroll to latest message",
        createdAt: now.addingTimeInterval(-3_600),
        updatedAt: now,
        messages: messages,
        isRunning: false
      )
      let startingSession = AgentSession(
        id: UUID(),
        projectID: project.id,
        projectPath: project.path,
        codexSessionID: nil,
        title: "Starting Point",
        createdAt: now.addingTimeInterval(-7_200),
        updatedAt: now.addingTimeInterval(-60),
        messages: [
          AgentMessage(
            id: UUID(),
            role: .assistant,
            text: "Open the long session from here.",
            createdAt: now.addingTimeInterval(-60),
            state: .complete
          )
        ],
        isRunning: false
      )
      configuration = APIConfiguration(host: "fixture.local", port: 8765, token: "fixture")
      applySnapshot(projects: [project], sessions: [startingSession, session])
      switch entry {
      case .direct:
        selectSession(session.id)
      case .sessionList:
        selectSession(nil)
      case .anotherSession:
        selectSession(startingSession.id)
      }
      connectionState = .connected(version: "fixture")
    }
  #endif

  func connect(host: String, port: Int, token rawToken: String) async {
    let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      presentedError = ConfigurationError.missingToken.localizedDescription
      return
    }

    let proposed = APIConfiguration(
      host: host.trimmingCharacters(in: .whitespacesAndNewlines),
      port: port,
      token: token
    )
    do {
      _ = try proposed.baseURL
    } catch {
      presentedError = error.localizedDescription
      return
    }

    cancelPolling()
    connectionState = .connecting
    let proposedClient = RemoteAPIClient(configuration: proposed)
    do {
      let health = try await proposedClient.health()
      guard health.status == "ok" else { throw RemoteAPIError.invalidData }

      async let loadedProjects = proposedClient.projects()
      async let loadedSessions = proposedClient.sessions(projectID: nil)
      let snapshot = try await (loadedProjects, loadedSessions)

      try configurationStore.save(proposed)
      configuration = proposed
      client = proposedClient
      protocolVersion = health.version
      queuedPromptsBySession = [:]
      applySnapshot(projects: snapshot.0, sessions: snapshot.1)
      loadQueuedPromptsForSessions()
      connectionState = .connected(version: health.version)
      startPollingForRunningSessions()
      deliverQueuedPromptsForIdleSessions()
    } catch {
      client = nil
      connectionState = .failed(message: error.localizedDescription)
      presentedError = error.localizedDescription
    }
  }

  func retryConnection() async {
    guard let configuration else {
      connectionState = .notConfigured
      return
    }
    await connect(host: configuration.host, port: configuration.port, token: configuration.token)
  }

  func disconnect() {
    cancelPolling()
    client = nil
    connectionState = configuration == nil ? .notConfigured : .disconnected
  }

  func removeConfiguration() {
    do {
      try configurationStore.clear()
      configuration = nil
      projects = []
      sessions = []
      queuedPromptsBySession = [:]
      deliveringQueuedPromptIDs = []
      selectedSessionID = nil
      syncUnreadSessionBadge()
      disconnect()
    } catch {
      presentedError = error.localizedDescription
    }
  }

  func refresh() async {
    guard let client else {
      await retryConnection()
      return
    }
    do {
      async let loadedProjects = client.projects()
      async let loadedSessions = client.sessions(projectID: nil)
      let snapshot = try await (loadedProjects, loadedSessions)
      applySnapshot(projects: snapshot.0, sessions: snapshot.1)
      loadQueuedPromptsForSessions()
      connectionState = .connected(version: protocolVersion)
      startPollingForRunningSessions()
      deliverQueuedPromptsForIdleSessions()
    } catch {
      connectionState = .failed(message: error.localizedDescription)
    }
  }

  func selectSession(_ id: UUID?) {
    selectedSessionID = id
    guard let id else { return }
    loadQueuedPromptsIfNeeded(sessionID: id)
    guard sessions.first(where: { $0.id == id })?.isRunning == true else {
      Task { await deliverNextQueuedPromptIfPossible(sessionID: id) }
      return
    }
    startPolling(sessionID: id)
  }

  func markSessionRead(_ id: UUID) async {
    guard sessions.first(where: { $0.id == id })?.isUnread == true, let client else { return }
    do {
      let updated = try await client.markSessionRead(id: id)
      replaceSession(updated)
    } catch {
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
    }
  }

  func renameSession(_ id: UUID, title rawTitle: String) async -> Bool {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= 120 else {
      presentedError = "Session names must be between 1 and 120 characters."
      return false
    }
    guard let client else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      replaceSession(try await client.renameSession(id: id, title: title))
      connectionState = .connected(version: protocolVersion)
      return true
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  func setSessionPinned(_ id: UUID, isPinned: Bool) async -> Bool {
    guard let client else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      replaceSession(try await client.setSessionPinned(id: id, isPinned: isPinned))
      connectionState = .connected(version: protocolVersion)
      return true
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  func deleteSession(_ id: UUID) async -> Bool {
    guard sessions.first(where: { $0.id == id })?.isRunning == false else {
      presentedError = "Wait for this session to finish before deleting it."
      return false
    }
    guard let client else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      _ = try await client.deleteSession(id: id)
      pollHandles[id]?.task.cancel()
      pollHandles[id] = nil
      let queuedPromptIDs = Set((queuedPromptsBySession[id] ?? []).map(\.id))
      deliveringQueuedPromptIDs.subtract(queuedPromptIDs)
      queuedPromptsBySession[id] = nil
      sendingSessionIDs.remove(id)
      saveDraft("", sessionID: id)
      if let serverIdentifier = configuration?.serverIdentifier {
        draftStore.saveQueuedPrompts([], serverIdentifier: serverIdentifier, sessionID: id)
      }
      sessions.removeAll { $0.id == id }
      if selectedSessionID == id { selectedSessionID = nil }
      syncUnreadSessionBadge()
      connectionState = .connected(version: protocolVersion)
      return true
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  func createSession(projectID: String) async {
    guard projects.contains(where: { $0.id == projectID }), let client else { return }
    do {
      let session = try await client.createSession(projectID: projectID)
      replaceSession(session)
      loadQueuedPromptsIfNeeded(sessionID: session.id)
      selectedSessionID = session.id
      connectionState = .connected(version: protocolVersion)
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
    }
  }

  func documents(projectID: String) async throws -> [ProjectDocument] {
    guard let client else { throw RemoteAPIError.notConnected }
    return try await client.documents(projectID: projectID)
  }

  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    guard let client else { throw RemoteAPIError.notConnected }
    return try await client.documentContent(projectID: projectID, documentID: documentID)
  }

  func document(projectID: String, relativePath: String) async throws -> ProjectDocument {
    let documents = try await documents(projectID: projectID)
    guard let document = documents.first(where: { $0.relativePath == relativePath }) else {
      throw RemoteAPIError.documentNotFound(relativePath)
    }
    return document
  }

  func sendPrompt(_ rawText: String, to sessionID: UUID) async -> Bool {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, configuration != nil,
      let session = sessions.first(where: { $0.id == sessionID })
    else { return false }

    loadQueuedPromptsIfNeeded(sessionID: sessionID)
    let shouldQueue =
      session.isRunning
      || sendingSessionIDs.contains(sessionID)
      || !connectionState.isConnected
      || client == nil
      || !(queuedPromptsBySession[sessionID] ?? []).isEmpty

    if shouldQueue {
      enqueuePrompt(text, sessionID: sessionID)
      saveDraft("", sessionID: sessionID)
      if !session.isRunning, connectionState.isConnected {
        Task { await deliverNextQueuedPromptIfPossible(sessionID: sessionID) }
      }
      return true
    }

    return await sendPromptImmediately(text, to: sessionID, clearDraftOnSuccess: true)
  }

  func queuedPrompts(sessionID: UUID) -> [QueuedPrompt] {
    queuedPromptsBySession[sessionID] ?? []
  }

  func canAcceptPrompt(sessionID: UUID) -> Bool {
    configuration != nil && sessions.contains(where: { $0.id == sessionID })
  }

  func removeQueuedPrompt(_ promptID: UUID, sessionID: UUID) {
    guard !deliveringQueuedPromptIDs.contains(promptID) else { return }
    loadQueuedPromptsIfNeeded(sessionID: sessionID)
    guard var prompts = queuedPromptsBySession[sessionID] else { return }
    prompts.removeAll { $0.id == promptID }
    queuedPromptsBySession[sessionID] = prompts
    persistQueuedPrompts(sessionID: sessionID)
  }

  private func sendPromptImmediately(
    _ text: String,
    to sessionID: UUID,
    clearDraftOnSuccess: Bool
  ) async -> Bool {
    guard let client,
      let original = sessions.first(where: { $0.id == sessionID }), !original.isRunning,
      !sendingSessionIDs.contains(sessionID)
    else { return false }

    sendingSessionIDs.insert(sessionID)
    defer { sendingSessionIDs.remove(sessionID) }

    do {
      let accepted = try await client.sendMessage(text, sessionID: sessionID)
      guard accepted.sessionID == sessionID, accepted.status == "accepted" else {
        throw RemoteAPIError.invalidData
      }
      if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
        sessions[index].isRunning = true
      }
      Task { await completionNotifications.requestAuthorizationIfNeeded() }
      if clearDraftOnSuccess { saveDraft("", sessionID: sessionID) }
      startPolling(
        sessionID: sessionID,
        acceptedBaseline: PollBaseline(
          messageCount: original.messages.count,
          updatedAt: original.updatedAt
        )
      )
      return true
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  func draft(sessionID: UUID) -> String {
    guard let serverIdentifier = configuration?.serverIdentifier else { return "" }
    return draftStore.draft(serverIdentifier: serverIdentifier, sessionID: sessionID)
  }

  func saveDraft(_ value: String, sessionID: UUID) {
    guard let serverIdentifier = configuration?.serverIdentifier else { return }
    draftStore.save(value, serverIdentifier: serverIdentifier, sessionID: sessionID)
  }

  private func enqueuePrompt(_ text: String, sessionID: UUID) {
    var prompts = queuedPromptsBySession[sessionID] ?? []
    prompts.append(QueuedPrompt(text: text))
    queuedPromptsBySession[sessionID] = prompts
    persistQueuedPrompts(sessionID: sessionID)
  }

  private func loadQueuedPromptsForSessions() {
    for session in sessions {
      loadQueuedPromptsIfNeeded(sessionID: session.id)
    }
  }

  private func loadQueuedPromptsIfNeeded(sessionID: UUID) {
    guard queuedPromptsBySession[sessionID] == nil,
      let serverIdentifier = configuration?.serverIdentifier
    else { return }
    queuedPromptsBySession[sessionID] = draftStore.queuedPrompts(
      serverIdentifier: serverIdentifier,
      sessionID: sessionID
    )
  }

  private func persistQueuedPrompts(sessionID: UUID) {
    guard let serverIdentifier = configuration?.serverIdentifier else { return }
    draftStore.saveQueuedPrompts(
      queuedPromptsBySession[sessionID] ?? [],
      serverIdentifier: serverIdentifier,
      sessionID: sessionID
    )
  }

  private func deliverQueuedPromptsForIdleSessions() {
    for session in sessions
    where !session.isRunning && !queuedPrompts(sessionID: session.id).isEmpty {
      Task { await deliverNextQueuedPromptIfPossible(sessionID: session.id) }
    }
  }

  private func deliverNextQueuedPromptIfPossible(sessionID: UUID) async {
    loadQueuedPromptsIfNeeded(sessionID: sessionID)
    guard connectionState.isConnected,
      sessions.first(where: { $0.id == sessionID })?.isRunning == false,
      !sendingSessionIDs.contains(sessionID),
      let prompt = queuedPromptsBySession[sessionID]?.first,
      !deliveringQueuedPromptIDs.contains(prompt.id)
    else { return }

    deliveringQueuedPromptIDs.insert(prompt.id)
    let accepted = await sendPromptImmediately(
      prompt.text,
      to: sessionID,
      clearDraftOnSuccess: false
    )
    deliveringQueuedPromptIDs.remove(prompt.id)

    guard accepted else { return }
    var prompts = queuedPromptsBySession[sessionID] ?? []
    prompts.removeAll { $0.id == prompt.id }
    queuedPromptsBySession[sessionID] = prompts
    persistQueuedPrompts(sessionID: sessionID)
  }

  func sceneActivityChanged(isActive: Bool) {
    appIsActive = isActive
    if isActive {
      endBackgroundTask()
      Task { await refresh() }
    } else if sessions.contains(where: \.isRunning) {
      beginBackgroundPolling()
    } else {
      cancelPolling()
    }
  }

  private func applySnapshot(projects: [AgentProject], sessions: [AgentSession]) {
    let previousSessions = Dictionary(uniqueKeysWithValues: self.sessions.map { ($0.id, $0) })
    self.projects = projects
    self.sessions = sessions
    for session in sessions {
      if let previous = previousSessions[session.id] {
        notifyIfCompleted(previous: previous, updated: session)
      }
    }

    if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
      self.selectedSessionID = nil
    }
    syncUnreadSessionBadge()
  }

  private func replaceSession(_ updated: AgentSession) {
    if let index = sessions.firstIndex(where: { $0.id == updated.id }) {
      let previous = sessions[index]
      sessions[index] = updated
      notifyIfCompleted(previous: previous, updated: updated)
    } else {
      sessions.append(updated)
      loadQueuedPromptsIfNeeded(sessionID: updated.id)
    }
    syncUnreadSessionBadge()
  }

  private func syncUnreadSessionBadge() {
    #if DEBUG
      // Visual fixtures exercise in-app unread badges without presenting a system permission sheet.
      if DebugAppFixture.isEnabled { return }
    #endif
    let unreadCount = sessions.lazy.filter(\.isUnread).count
    unreadBadgeSyncTask?.cancel()
    let completionNotifications = completionNotifications
    unreadBadgeSyncTask = Task {
      guard !Task.isCancelled else { return }
      await completionNotifications.setUnreadBadgeCount(unreadCount)
    }
  }

  private func startPollingForRunningSessions() {
    guard appIsActive else { return }
    for session in sessions where session.isRunning {
      startPolling(sessionID: session.id)
    }
  }

  private func startPolling(sessionID: UUID, acceptedBaseline: PollBaseline? = nil) {
    guard appIsActive, client != nil, pollHandles[sessionID] == nil else { return }
    let handleID = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.poll(
        sessionID: sessionID,
        handleID: handleID,
        acceptedBaseline: acceptedBaseline
      )
    }
    pollHandles[sessionID] = PollHandle(id: handleID, task: task)
  }

  private func poll(sessionID: UUID, handleID: UUID, acceptedBaseline: PollBaseline?) async {
    guard let client else {
      finishPolling(sessionID: sessionID, handleID: handleID)
      return
    }

    var observedRunning = acceptedBaseline == nil
    var graceAttemptsRemaining = acceptedBaseline == nil ? 0 : 5

    while !Task.isCancelled, appIsActive {
      do {
        try await Task.sleep(for: .seconds(1))
        let updated = try await client.session(id: sessionID)
        replaceSession(updated)
        connectionState = .connected(version: protocolVersion)

        if updated.isRunning {
          observedRunning = true
          continue
        }

        if let baseline = acceptedBaseline, !observedRunning {
          let serverAcceptedTurn =
            updated.messages.count > baseline.messageCount
            || updated.updatedAt > baseline.updatedAt
          if !serverAcceptedTurn, graceAttemptsRemaining > 0 {
            graceAttemptsRemaining -= 1
            continue
          }
        }
        break
      } catch is CancellationError {
        break
      } catch {
        connectionState = .failed(message: error.localizedDescription)
        break
      }
    }
    finishPolling(sessionID: sessionID, handleID: handleID)
  }

  private func finishPolling(sessionID: UUID, handleID: UUID) {
    guard pollHandles[sessionID]?.id == handleID else { return }
    pollHandles[sessionID] = nil
    if !appIsActive, pollHandles.isEmpty, pendingCompletionNotifications == 0 {
      endBackgroundTask()
    }
  }

  private func cancelPolling() {
    for handle in pollHandles.values {
      handle.task.cancel()
    }
    pollHandles.removeAll()
    endBackgroundTask()
  }

  private func notifyIfCompleted(previous: AgentSession, updated: AgentSession) {
    guard previous.isRunning, !updated.isRunning else { return }
    Task { [weak self] in
      await Task.yield()
      await self?.deliverNextQueuedPromptIfPossible(sessionID: updated.id)
    }
    pendingCompletionNotifications += 1
    Task {
      await completionNotifications.notifyCompletion(for: updated)
      pendingCompletionNotifications -= 1
      if !appIsActive, pollHandles.isEmpty, pendingCompletionNotifications == 0 {
        endBackgroundTask()
      }
    }
  }

  private func beginBackgroundPolling() {
    guard backgroundTaskID == .invalid else { return }
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(
      withName: "Finish active agent polling"
    ) { [weak self] in
      Task { @MainActor [weak self] in
        self?.cancelPolling()
      }
    }
  }

  private func endBackgroundTask() {
    guard backgroundTaskID != .invalid else { return }
    let taskID = backgroundTaskID
    backgroundTaskID = .invalid
    UIApplication.shared.endBackgroundTask(taskID)
  }

  private struct PollBaseline {
    let messageCount: Int
    let updatedAt: Date
  }

  private struct PollHandle {
    let id: UUID
    let task: Task<Void, Never>
  }
}
