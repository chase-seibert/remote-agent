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

    static var connectionStatus: ConnectionStatus? {
      switch name {
      case "connection-connected": .connected
      case "connection-failed": .failed
      default: nil
      }
    }

    enum LongConversationEntry {
      case direct
      case sessionList
      case anotherSession
    }

    enum ConnectionStatus {
      case connected
      case failed
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
  @Published private(set) var codexModels: [CodexModelOption] = []
  @Published private(set) var isRefreshingCodexModels = false
  @Published private(set) var projectCommandConfigurations:
    [UUID: ProjectCommandConfigurationResponse] = [:]
  @Published private(set) var runningProjectCommandSessionIDs: Set<UUID> = []
  @Published private(set) var configuration: APIConfiguration?
  @Published var selectedSessionID: UUID?
  @Published var presentedError: String?

  private let configurationStore: ConfigurationStore
  private let draftStore: DraftStore
  private let completionNotifications: any CompletionNotificationServing
  private let backgroundRefreshScheduler: any BackgroundRefreshScheduling
  private let backgroundSessionWatchStore: BackgroundSessionWatchStore
  private var client: RemoteAPIClientProtocol?
  private var connectionHandle: OperationHandle?
  private var connectionTarget: APIConfiguration?
  private var refreshHandle: OperationHandle?
  private var foregroundRefreshHandle: OperationHandle?
  private var pollStates: [UUID: PollState] = [:]
  private var pollTask: OperationHandle?
  private var unreadBadgeSyncTask: Task<Void, Never>?
  private var sendingSessionIDs: Set<UUID> = []
  private var newlyCreatedSessionIDs: Set<UUID> = []
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
  private var pendingCompletionNotifications = 0
  private var appIsActive = true
  private var didStart = false
  private var protocolVersion = RemoteAgentProtocolVersion.current
  private var clientGeneration: UInt64 = 0
  private var usesLegacyFullSessionPolling = false

  init(
    configurationStore: ConfigurationStore = ConfigurationStore(),
    draftStore: DraftStore = DraftStore(),
    completionNotifications: any CompletionNotificationServing = CompletionNotificationService(),
    backgroundRefreshScheduler: any BackgroundRefreshScheduling = BackgroundRefreshScheduler(),
    backgroundSessionWatchStore: BackgroundSessionWatchStore = BackgroundSessionWatchStore()
  ) {
    self.configurationStore = configurationStore
    self.draftStore = draftStore
    self.completionNotifications = completionNotifications
    self.backgroundRefreshScheduler = backgroundRefreshScheduler
    self.backgroundSessionWatchStore = backgroundSessionWatchStore
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
      } else if let status = DebugAppFixture.connectionStatus {
        didStart = true
        installConnectionStatusFixture(status)
      }
    #endif
  }

  #if DEBUG
    init(
      testConfiguration: APIConfiguration,
      client: RemoteAPIClientProtocol,
      sessions: [AgentSession],
      draftStore: DraftStore,
      completionNotifications: any CompletionNotificationServing = CompletionNotificationService(),
      backgroundRefreshScheduler: any BackgroundRefreshScheduling = BackgroundRefreshScheduler(),
      backgroundSessionWatchStore: BackgroundSessionWatchStore = BackgroundSessionWatchStore()
    ) {
      self.configurationStore = ConfigurationStore()
      self.draftStore = draftStore
      self.completionNotifications = completionNotifications
      self.backgroundRefreshScheduler = backgroundRefreshScheduler
      self.backgroundSessionWatchStore = backgroundSessionWatchStore
      configuration = testConfiguration
      self.client = client
      clientGeneration = 1
      self.sessions = sessions
      selectedSessionID = sessions.first?.id
      connectionState = .connected(version: "test")
      protocolVersion = "test"
      didStart = true
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
          currentReasoning: index == 0 ? "Checking the latest navigation behavior." : nil,
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
        isRunning: true,
        currentReasoning: "Verifying FIFO delivery before updating the tests.",
        queuedPrompts: [
          QueuedPrompt(
            text: "Add tests for FIFO delivery.", createdAt: now.addingTimeInterval(-30)),
          QueuedPrompt(
            text: "Then update the documentation.", createdAt: now.addingTimeInterval(-15)),
        ]
      )
      configuration = APIConfiguration(host: "fixture.local", port: 8765, token: "fixture")
      applySnapshot(projects: [project], sessions: [session])
      selectSession(session.id)
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

    private func installConnectionStatusFixture(_ status: DebugAppFixture.ConnectionStatus) {
      configuration = APIConfiguration(
        host: "chases-mac.local",
        port: 8765,
        token: "fixture"
      )
      switch status {
      case .connected:
        connectionState = .connected(version: "1")
      case .failed:
        connectionState = .failed(
          message: "The saved Mac did not respond. Make sure it is awake and on the same Wi-Fi."
        )
      }
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

    if let connectionHandle, connectionTarget == proposed {
      await connectionHandle.task.value
      return
    }

    cancelConnection()
    cancelRefresh()
    cancelPolling()
    invalidateClient()
    connectionState = .connecting
    presentedError = nil
    let handleID = UUID()
    connectionTarget = proposed
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performConnection(to: proposed, handleID: handleID)
      self.finishConnection(handleID: handleID)
    }
    connectionHandle = OperationHandle(id: handleID, task: task)
    await task.value
  }

  private func performConnection(to proposed: APIConfiguration, handleID: UUID) async {
    let proposedClient = RemoteAPIClient(configuration: proposed)
    logConnectionDiagnostic("Connecting to \(proposed.host):\(proposed.port)")
    do {
      let health = try await proposedClient.health()
      guard health.status == "ok" else { throw RemoteAPIError.invalidData }
      try Task.checkCancellation()
      guard connectionHandle?.id == handleID else { return }
      logConnectionDiagnostic("Health check succeeded; loading projects and sessions")

      async let loadedProjects = proposedClient.projects()
      async let loadedSessions = proposedClient.sessions(projectID: nil)
      let snapshot = try await (loadedProjects, loadedSessions)
      try Task.checkCancellation()
      guard connectionHandle?.id == handleID else { return }
      logConnectionDiagnostic(
        "Snapshot loaded: \(snapshot.0.count) projects, \(snapshot.1.count) sessions"
      )

      try configurationStore.save(proposed)
      configuration = proposed
      let generation = installClient(proposedClient)
      protocolVersion = health.version
      projectCommandConfigurations = [:]
      runningProjectCommandSessionIDs = []
      let completionTasks = applySnapshot(projects: snapshot.0, sessions: snapshot.1)
      codexModels = (try? await proposedClient.models()) ?? []
      connectionState = .connected(version: health.version)
      logConnectionDiagnostic("Connected with protocol version \(health.version)")
      await migrateLegacyQueuedPrompts(using: proposedClient, generation: generation)
      try Task.checkCancellation()
      guard connectionHandle?.id == handleID else { return }
      startPollingForRunningSessions()
      await waitForCompletionNotifications(completionTasks)
    } catch is CancellationError {
      logConnectionDiagnostic("Connection attempt canceled")
      return
    } catch {
      guard connectionHandle?.id == handleID else { return }
      logConnectionDiagnostic("Connection failed: \(error.localizedDescription)")
      invalidateClient()
      connectionState = .failed(message: error.localizedDescription)
      presentedError = error.localizedDescription
    }
  }

  private func logConnectionDiagnostic(_ message: String) {
    #if DEBUG
      print("[RemoteAgentConnection] \(message)")
    #endif
  }

  private func finishConnection(handleID: UUID) {
    guard connectionHandle?.id == handleID else { return }
    connectionHandle = nil
    connectionTarget = nil
  }

  private func cancelConnection() {
    let task = connectionHandle?.task
    connectionHandle = nil
    connectionTarget = nil
    task?.cancel()
  }

  @discardableResult
  private func installClient(_ client: any RemoteAPIClientProtocol) -> UInt64 {
    clientGeneration &+= 1
    self.client = client
    usesLegacyFullSessionPolling = false
    return clientGeneration
  }

  private func invalidateClient() {
    clientGeneration &+= 1
    client = nil
    sendingSessionIDs.removeAll()
    runningProjectCommandSessionIDs.removeAll()
    usesLegacyFullSessionPolling = false
  }

  private var currentClientContext: ClientContext? {
    guard let client else { return nil }
    return ClientContext(client: client, generation: clientGeneration)
  }

  private func isCurrent(_ context: ClientContext) -> Bool {
    client != nil && context.generation == clientGeneration
  }

  private func withCurrentClient<Value: Sendable>(
    _ operation: (any RemoteAPIClientProtocol) async throws -> Value
  ) async throws -> Value {
    guard let context = currentClientContext else { throw RemoteAPIError.notConnected }
    return try await withClient(context, operation)
  }

  private func withClient<Value: Sendable>(
    _ context: ClientContext,
    _ operation: (any RemoteAPIClientProtocol) async throws -> Value
  ) async throws -> Value {
    do {
      let value = try await operation(context.client)
      try Task.checkCancellation()
      guard isCurrent(context) else { throw CancellationError() }
      return value
    } catch {
      guard isCurrent(context), !Task.isCancelled else { throw CancellationError() }
      throw error
    }
  }

  func retryConnection() async {
    if let connectionHandle {
      await connectionHandle.task.value
      return
    }
    guard let configuration else {
      connectionState = .notConfigured
      return
    }
    await connect(host: configuration.host, port: configuration.port, token: configuration.token)
  }

  func disconnect() {
    backgroundRefreshScheduler.cancel()
    cancelForegroundRefresh()
    cancelRefresh()
    cancelConnection()
    cancelPolling()
    invalidateClient()
    connectionState = configuration == nil ? .notConfigured : .disconnected
  }

  func removeConfiguration() {
    do {
      if let serverIdentifier = configuration?.serverIdentifier {
        backgroundSessionWatchStore.clear(serverIdentifier: serverIdentifier)
      }
      try configurationStore.clear()
      configuration = nil
      projects = []
      sessions = []
      selectedSessionID = nil
      syncUnreadSessionBadge()
      disconnect()
    } catch {
      presentedError = error.localizedDescription
    }
  }

  func refresh() async {
    if let connectionHandle {
      await connectionHandle.task.value
      return
    }
    guard client != nil else {
      await retryConnection()
      return
    }

    if let refreshHandle {
      await refreshHandle.task.value
      return
    }

    let handleID = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performRefresh(handleID: handleID)
      self.finishRefresh(handleID: handleID)
    }
    refreshHandle = OperationHandle(id: handleID, task: task)
    await task.value
  }

  private func performRefresh(handleID: UUID) async {
    guard let context = currentClientContext else { return }
    let client = context.client
    do {
      let health = try await client.health()
      guard health.status == "ok" else { throw RemoteAPIError.invalidData }
      try Task.checkCancellation()
      guard refreshHandle?.id == handleID else { return }
      async let loadedProjects = client.projects()
      async let loadedSessions = client.sessions(projectID: nil)
      let snapshot = try await (loadedProjects, loadedSessions)
      try Task.checkCancellation()
      guard refreshHandle?.id == handleID else { return }
      protocolVersion = health.version
      let completionTasks = applySnapshot(projects: snapshot.0, sessions: snapshot.1)
      codexModels = (try? await client.models()) ?? codexModels
      connectionState = .connected(version: health.version)
      await migrateLegacyQueuedPrompts(using: client, generation: context.generation)
      try Task.checkCancellation()
      guard refreshHandle?.id == handleID else { return }
      startPollingForRunningSessions()
      await waitForCompletionNotifications(completionTasks)
    } catch is CancellationError {
      return
    } catch {
      guard refreshHandle?.id == handleID else { return }
      connectionState = .failed(message: error.localizedDescription)
    }
  }

  private func finishRefresh(handleID: UUID) {
    guard refreshHandle?.id == handleID else { return }
    refreshHandle = nil
  }

  private func cancelRefresh() {
    let task = refreshHandle?.task
    refreshHandle = nil
    task?.cancel()
  }

  func selectSession(_ id: UUID?) {
    selectedSessionID = id
    guard let id else { return }
    if sessions.first(where: { $0.id == id })?.hasActiveWork == true {
      startPolling(sessionID: id)
    }
  }

  func markSessionRead(_ id: UUID) async {
    guard sessions.first(where: { $0.id == id })?.isUnread == true else { return }
    do {
      let updated = try await withCurrentClient { client in
        try await client.markSessionRead(id: id)
      }
      replaceSession(updated)
    } catch is CancellationError {
    } catch {}
  }

  @discardableResult
  func markSessionUnread(_ id: UUID) async -> Bool {
    guard sessions.first(where: { $0.id == id })?.isUnread == false else { return true }
    guard client != nil else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      let updated = try await withCurrentClient { client in
        try await client.markSessionUnread(id: id)
      }
      replaceSession(updated)
      connectionState = .connected(version: protocolVersion)
      return true
    } catch is CancellationError {
      return false
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  func renameSession(_ id: UUID, title rawTitle: String) async -> Bool {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= 120 else {
      presentedError = "Session names must be between 1 and 120 characters."
      return false
    }
    guard client != nil else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      let updated = try await withCurrentClient { client in
        try await client.renameSession(id: id, title: title)
      }
      replaceSession(updated)
      connectionState = .connected(version: protocolVersion)
      return true
    } catch is CancellationError {
      return false
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  func setSessionPinned(_ id: UUID, isPinned: Bool) async -> Bool {
    guard client != nil else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      let updated = try await withCurrentClient { client in
        try await client.setSessionPinned(id: id, isPinned: isPinned)
      }
      replaceSession(updated)
      connectionState = .connected(version: protocolVersion)
      return true
    } catch is CancellationError {
      return false
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  func deleteSession(_ id: UUID) async -> Bool {
    guard sessions.first(where: { $0.id == id })?.hasActiveWork == false,
      !runningProjectCommandSessionIDs.contains(id)
    else {
      presentedError = "Wait for this session to finish before deleting it."
      return false
    }
    guard client != nil else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      _ = try await withCurrentClient { client in
        try await client.deleteSession(id: id)
      }
      finishPolling(sessionID: id)
      sendingSessionIDs.remove(id)
      runningProjectCommandSessionIDs.remove(id)
      projectCommandConfigurations[id] = nil
      saveDraft("", sessionID: id)
      if let serverIdentifier = configuration?.serverIdentifier {
        draftStore.saveQueuedPrompts([], serverIdentifier: serverIdentifier, sessionID: id)
      }
      sessions.removeAll { $0.id == id }
      newlyCreatedSessionIDs.remove(id)
      if selectedSessionID == id { selectedSessionID = nil }
      syncUnreadSessionBadge()
      reconcileBackgroundRefreshState()
      connectionState = .connected(version: protocolVersion)
      return true
    } catch is CancellationError {
      return false
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  var suggestedCodexModel: String? {
    sessions.sorted { $0.updatedAt > $1.updatedAt }.compactMap(\.codexModel).first
  }

  func createSession(projectID: String, codexModel: String? = nil) async {
    guard projects.contains(where: { $0.id == projectID }), client != nil else { return }
    do {
      let session = try await withCurrentClient { client in
        try await client.createSession(projectID: projectID, codexModel: codexModel)
      }
      replaceSession(session)
      selectedSessionID = session.id
      newlyCreatedSessionIDs.insert(session.id)
      connectionState = .connected(version: protocolVersion)
    } catch is CancellationError {
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
    }
  }

  func setSessionCodexModel(_ id: UUID, codexModel: String?) async {
    do {
      let session = try await withCurrentClient { client in
        try await client.setSessionCodexModel(id: id, codexModel: codexModel)
      }
      replaceSession(session)
    } catch {
      presentedError = error.localizedDescription
    }
  }

  func refreshCodexModels() async {
    guard client != nil, !isRefreshingCodexModels else { return }
    isRefreshingCodexModels = true
    defer { isRefreshingCodexModels = false }
    do {
      codexModels = try await withCurrentClient { client in try await client.models() }
    } catch {
      guard codexModels.isEmpty else { return }
      presentedError = "Could not load models from the Mac: \(error.localizedDescription)"
    }
  }

  func documents(projectID: String) async throws -> [ProjectDocument] {
    try await withCurrentClient { client in
      try await client.documents(projectID: projectID)
    }
  }

  func projectCommandConfiguration(sessionID: UUID) -> ProjectCommandConfigurationResponse? {
    projectCommandConfigurations[sessionID]
  }

  func isProjectCommandRunning(sessionID: UUID) -> Bool {
    runningProjectCommandSessionIDs.contains(sessionID)
      || projectCommandConfigurations[sessionID]?.isRunning == true
      || sessions.first(where: { $0.id == sessionID })?.hasPendingProjectCommand == true
  }

  func loadProjectCommandConfiguration(sessionID: UUID) async {
    guard client != nil, connectionState.isConnected else { return }
    do {
      let configuration = try await withCurrentClient { client in
        try await client.projectCommandConfiguration(sessionID: sessionID)
      }
      projectCommandConfigurations[sessionID] = configuration
      if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
        sessions[index].selectedMakeTarget = configuration.selectedMakeTarget
      }
    } catch is CancellationError {
    } catch {
      presentedError = error.localizedDescription
    }
  }

  func selectMakeTarget(_ target: String, sessionID: UUID) async {
    guard client != nil,
      let previousConfiguration = projectCommandConfigurations[sessionID],
      previousConfiguration.makeTargets.contains(target)
    else { return }
    projectCommandConfigurations[sessionID] = ProjectCommandConfigurationResponse(
      sessionID: previousConfiguration.sessionID,
      makeTargets: previousConfiguration.makeTargets,
      selectedMakeTarget: target,
      isRunning: previousConfiguration.isRunning
    )
    if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
      sessions[index].selectedMakeTarget = target
    }
    do {
      let updated = try await withCurrentClient { client in
        try await client.selectMakeTarget(target, sessionID: sessionID)
      }
      replaceSession(updated)
      await loadProjectCommandConfiguration(sessionID: sessionID)
    } catch is CancellationError {
    } catch {
      projectCommandConfigurations[sessionID] = previousConfiguration
      if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
        sessions[index].selectedMakeTarget = previousConfiguration.selectedMakeTarget
      }
      presentedError = error.localizedDescription
    }
  }

  func runProjectCommand(_ action: ProjectCommandAction, sessionID: UUID) async {
    guard let context = currentClientContext,
      let original = sessions.first(where: { $0.id == sessionID }),
      !original.hasActiveWork,
      !runningProjectCommandSessionIDs.contains(sessionID)
    else { return }
    let target = action == .make ? projectCommandConfigurations[sessionID]?.selectedMakeTarget : nil
    if action == .make, target == nil {
      presentedError = "Choose a Make target before running it."
      return
    }

    runningProjectCommandSessionIDs.insert(sessionID)
    updateProjectCommandRunningState(sessionID: sessionID, isRunning: true)
    do {
      let accepted = try await withClient(context) { client in
        try await client.runProjectCommand(
          action,
          target: target,
          sessionID: sessionID
        )
      }
      guard accepted.sessionID == sessionID, accepted.status == "accepted" else {
        throw RemoteAPIError.invalidData
      }

      for _ in 0..<5 {
        let updated = try await withClient(context) { client in
          try await client.session(id: sessionID)
        }
        replaceSession(updated)
        if updated.messages.count > original.messages.count || updated.hasPendingProjectCommand {
          if !updated.hasPendingProjectCommand {
            runningProjectCommandSessionIDs.remove(sessionID)
            updateProjectCommandRunningState(sessionID: sessionID, isRunning: false)
          }
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      startPolling(
        sessionID: sessionID,
        acceptedBaseline: PollBaseline(
          messageCount: original.messages.count,
          updatedAt: original.updatedAt,
          contentRevision: original.contentRevision
        )
      )
    } catch is CancellationError {
      runningProjectCommandSessionIDs.remove(sessionID)
      updateProjectCommandRunningState(sessionID: sessionID, isRunning: false)
    } catch {
      runningProjectCommandSessionIDs.remove(sessionID)
      updateProjectCommandRunningState(sessionID: sessionID, isRunning: false)
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
    }
  }

  func projectCommandResult(sessionID: UUID, resultID: UUID) async throws
    -> RemoteProjectCommandResult
  {
    try await withCurrentClient { client in
      try await client.projectCommandResult(sessionID: sessionID, resultID: resultID)
    }
  }

  private func updateProjectCommandRunningState(sessionID: UUID, isRunning: Bool) {
    if let current = projectCommandConfigurations[sessionID] {
      projectCommandConfigurations[sessionID] = ProjectCommandConfigurationResponse(
        sessionID: current.sessionID,
        makeTargets: current.makeTargets,
        selectedMakeTarget: current.selectedMakeTarget,
        isRunning: isRunning
      )
    }
    reconcileBackgroundRefreshState()
  }

  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    try await withCurrentClient { client in
      try await client.documentContent(projectID: projectID, documentID: documentID)
    }
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
    guard connectionState.isConnected, client != nil else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }

    let shouldQueue =
      session.hasActiveWork
      || runningProjectCommandSessionIDs.contains(sessionID)
      || sendingSessionIDs.contains(sessionID)
      || !session.queuedPrompts.isEmpty

    if shouldQueue {
      return await enqueuePromptOnHost(text, sessionID: sessionID, clearDraftOnSuccess: true)
    }

    return await sendPromptImmediately(text, to: sessionID, clearDraftOnSuccess: true)
  }

  func queuedPrompts(sessionID: UUID) -> [QueuedPrompt] {
    sessions.first(where: { $0.id == sessionID })?.queuedPrompts ?? []
  }

  func canAcceptPrompt(sessionID: UUID) -> Bool {
    configuration != nil && connectionState.isConnected && client != nil
      && sessions.contains(where: { $0.id == sessionID })
  }

  func updateQueuedPrompt(_ promptID: UUID, text rawText: String, sessionID: UUID) async -> Bool {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      presentedError = "Queued prompt text cannot be empty."
      return false
    }
    guard client != nil else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      let updated = try await withCurrentClient { client in
        try await client.updateQueuedPrompt(promptID, text: text, sessionID: sessionID)
      }
      guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
        let promptIndex = sessions[sessionIndex].queuedPrompts.firstIndex(where: {
          $0.id == promptID
        })
      else { return false }
      sessions[sessionIndex].queuedPrompts[promptIndex] = updated
      connectionState = .connected(version: protocolVersion)
      return true
    } catch is CancellationError {
      return false
    } catch {
      await handleQueueMutationFailure(error, sessionID: sessionID)
      return false
    }
  }

  func removeQueuedPrompt(_ promptID: UUID, sessionID: UUID) async -> Bool {
    guard client != nil else {
      presentedError = RemoteAPIError.notConnected.localizedDescription
      return false
    }
    do {
      _ = try await withCurrentClient { client in
        try await client.deleteQueuedPrompt(promptID, sessionID: sessionID)
      }
      guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
        return false
      }
      sessions[sessionIndex].queuedPrompts.removeAll { $0.id == promptID }
      connectionState = .connected(version: protocolVersion)
      return true
    } catch is CancellationError {
      return false
    } catch {
      await handleQueueMutationFailure(error, sessionID: sessionID)
      return false
    }
  }

  private func sendPromptImmediately(
    _ text: String,
    to sessionID: UUID,
    clearDraftOnSuccess: Bool
  ) async -> Bool {
    guard let context = currentClientContext,
      let original = sessions.first(where: { $0.id == sessionID }), !original.hasActiveWork,
      !runningProjectCommandSessionIDs.contains(sessionID),
      !sendingSessionIDs.contains(sessionID)
    else { return false }

    sendingSessionIDs.insert(sessionID)
    defer {
      if isCurrent(context) { sendingSessionIDs.remove(sessionID) }
    }

    let optimisticMessage = AgentMessage(
      id: UUID(),
      role: .user,
      text: text,
      createdAt: Date(),
      state: .complete
    )
    if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
      sessions[index].messages.append(optimisticMessage)
    }

    do {
      let accepted = try await withClient(context) { client in
        try await client.sendMessage(text, sessionID: sessionID)
      }
      guard accepted.sessionID == sessionID, accepted.status == "accepted" else {
        throw RemoteAPIError.invalidData
      }
      if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
        sessions[index].isRunning = true
        sessions[index].currentReasoning = nil
      }
      reconcileBackgroundRefreshState()
      Task { await completionNotifications.requestAuthorizationIfNeeded() }
      if clearDraftOnSuccess { saveDraft("", sessionID: sessionID) }
      startPolling(
        sessionID: sessionID,
        acceptedBaseline: PollBaseline(
          messageCount: original.messages.count,
          updatedAt: original.updatedAt,
          contentRevision: original.contentRevision
        )
      )
      return true
    } catch is CancellationError {
      return false
    } catch {
      if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
        sessions[index].messages.removeAll { $0.id == optimisticMessage.id }
      }
      if case RemoteAPIError.http(status: 409, detail: _) = error {
        return await enqueuePromptOnHost(
          text,
          sessionID: sessionID,
          clearDraftOnSuccess: clearDraftOnSuccess
        )
      }
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
    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      newlyCreatedSessionIDs.remove(sessionID)
    }
    guard let serverIdentifier = configuration?.serverIdentifier else { return }
    draftStore.save(value, serverIdentifier: serverIdentifier, sessionID: sessionID)
  }

  func discardUntouchedNewSession(_ id: UUID) async {
    guard newlyCreatedSessionIDs.contains(id) else { return }
    guard let session = sessions.first(where: { $0.id == id }),
      session.messages.isEmpty,
      session.queuedPrompts.isEmpty,
      draft(sessionID: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      newlyCreatedSessionIDs.remove(id)
      return
    }
    _ = await deleteSession(id)
  }

  private func enqueuePromptOnHost(
    _ text: String,
    sessionID: UUID,
    clearDraftOnSuccess: Bool
  ) async -> Bool {
    guard let context = currentClientContext else { return false }
    do {
      let queued = try await withClient(context) { client in
        try await client.enqueuePrompt(text, sessionID: sessionID)
      }
      if let index = sessions.firstIndex(where: { $0.id == sessionID }),
        !sessions[index].queuedPrompts.contains(where: { $0.id == queued.id })
      {
        sessions[index].queuedPrompts.append(queued)
      }
      if clearDraftOnSuccess { saveDraft("", sessionID: sessionID) }
      Task { await completionNotifications.requestAuthorizationIfNeeded() }
      startPolling(sessionID: sessionID)
      connectionState = .connected(version: protocolVersion)
      return true
    } catch is CancellationError {
      return false
    } catch {
      presentedError = error.localizedDescription
      if case RemoteAPIError.unreachable = error {
        connectionState = .failed(message: error.localizedDescription)
      }
      return false
    }
  }

  private func handleQueueMutationFailure(_ error: Error, sessionID: UUID) async {
    presentedError = error.localizedDescription
    if case RemoteAPIError.unreachable = error {
      connectionState = .failed(message: error.localizedDescription)
      return
    }
    guard
      let updated = try? await withCurrentClient({ client in
        try await client.session(id: sessionID)
      })
    else { return }
    replaceSession(updated)
  }

  private func migrateLegacyQueuedPrompts(
    using client: any RemoteAPIClientProtocol,
    generation: UInt64
  ) async {
    guard let serverIdentifier = configuration?.serverIdentifier else { return }
    for session in sessions {
      var legacy = draftStore.queuedPrompts(
        serverIdentifier: serverIdentifier,
        sessionID: session.id
      )
      while let prompt = legacy.first {
        do {
          let queued = try await client.enqueuePrompt(prompt.text, sessionID: session.id)
          try Task.checkCancellation()
          guard clientGeneration == generation, self.client != nil else { return }
          if let index = sessions.firstIndex(where: { $0.id == session.id }),
            !sessions[index].queuedPrompts.contains(where: { $0.id == queued.id })
          {
            sessions[index].queuedPrompts.append(queued)
          }
          legacy.removeFirst()
          draftStore.saveQueuedPrompts(
            legacy,
            serverIdentifier: serverIdentifier,
            sessionID: session.id
          )
          startPolling(sessionID: session.id)
        } catch {
          break
        }
      }
    }
  }

  func sceneActivityChanged(isActive: Bool) {
    appIsActive = isActive
    if isActive {
      backgroundRefreshScheduler.cancel()
      endBackgroundTask()
      startForegroundRefresh()
    } else if sessions.contains(where: \.hasActiveWork)
      || !runningProjectCommandSessionIDs.isEmpty
    {
      cancelForegroundRefresh()
      cancelRefresh()
      reconcileBackgroundRefreshState()
      beginBackgroundPolling()
    } else {
      cancelForegroundRefresh()
      cancelRefresh()
      backgroundRefreshScheduler.cancel()
      cancelPolling()
    }
  }

  private func startForegroundRefresh() {
    guard foregroundRefreshHandle == nil else { return }
    let handleID = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.refreshForForeground()
      self.finishForegroundRefresh(handleID: handleID)
    }
    foregroundRefreshHandle = OperationHandle(id: handleID, task: task)
  }

  private func finishForegroundRefresh(handleID: UUID) {
    guard foregroundRefreshHandle?.id == handleID else { return }
    foregroundRefreshHandle = nil
  }

  private func cancelForegroundRefresh() {
    let task = foregroundRefreshHandle?.task
    foregroundRefreshHandle = nil
    task?.cancel()
  }

  func performBackgroundRefresh() async {
    appIsActive = false

    if client == nil {
      if didStart {
        await retryConnection()
      } else {
        await start()
      }
      reconcileBackgroundRefreshState()
      return
    }

    let watchedSessionIDs = backgroundWatchedSessionIDs()
    guard !activeBackgroundSessionIDs.isEmpty || !watchedSessionIDs.isEmpty else {
      backgroundRefreshScheduler.cancel()
      return
    }

    // The delivered request is no longer pending, so queue the next opportunity before doing I/O.
    backgroundRefreshScheduler.schedule()
    do {
      guard let context = currentClientContext else { return }
      let health = try await withClient(context) { client in
        try await client.health()
      }
      guard health.status == "ok" else { throw RemoteAPIError.invalidData }
      let loadedSessions = try await withClient(context) { client in
        try await client.sessions(projectID: nil)
      }
      try Task.checkCancellation()
      guard !appIsActive else { return }
      protocolVersion = health.version
      let completionTasks = applySnapshot(projects: projects, sessions: loadedSessions)
      connectionState = .connected(version: health.version)
      await waitForCompletionNotifications(completionTasks)
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, !appIsActive else { return }
      connectionState = .failed(message: error.localizedDescription)
    }
    reconcileBackgroundRefreshState()
  }

  func refreshForForeground() async {
    await refresh()
    guard appIsActive, connectionState.isConnected, let selectedSessionID else { return }
    await markSessionRead(selectedSessionID)
  }

  @discardableResult
  private func applySnapshot(projects: [AgentProject], sessions: [AgentSession])
    -> [Task<Void, Never>]
  {
    let previousSessions = Dictionary(uniqueKeysWithValues: self.sessions.map { ($0.id, $0) })
    let watchedSessionIDs = backgroundWatchedSessionIDs()
    var completionTasks: [Task<Void, Never>] = []
    self.projects = projects
    self.sessions = sessions
    for session in sessions {
      if let task = notifyIfCompleted(
        previous: previousSessions[session.id],
        updated: session,
        watchedSessionIDs: watchedSessionIDs
      ) {
        completionTasks.append(task)
      }
    }

    if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
      self.selectedSessionID = nil
    }
    syncUnreadSessionBadge()
    reconcileBackgroundRefreshState()
    return completionTasks
  }

  @discardableResult
  private func replaceSession(_ updated: AgentSession) -> Task<Void, Never>? {
    let watchedSessionIDs = backgroundWatchedSessionIDs()
    let completionTask: Task<Void, Never>?
    if let index = sessions.firstIndex(where: { $0.id == updated.id }) {
      let previous = sessions[index]
      sessions[index] = updated
      completionTask = notifyIfCompleted(
        previous: previous,
        updated: updated,
        watchedSessionIDs: watchedSessionIDs
      )
    } else {
      sessions.append(updated)
      completionTask = notifyIfCompleted(
        previous: nil,
        updated: updated,
        watchedSessionIDs: watchedSessionIDs
      )
    }
    syncUnreadSessionBadge()
    reconcileBackgroundRefreshState()
    return completionTask
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
    for session in sessions where session.hasActiveWork {
      startPolling(sessionID: session.id)
    }
  }

  private func startPolling(sessionID: UUID, acceptedBaseline: PollBaseline? = nil) {
    guard appIsActive, client != nil else { return }
    if pollStates[sessionID] == nil {
      pollStates[sessionID] = PollState(acceptedBaseline: acceptedBaseline)
    }
    startPollingTaskIfNeeded()
  }

  private func startPollingTaskIfNeeded() {
    guard appIsActive, client != nil, !pollStates.isEmpty, pollTask == nil else { return }
    let handleID = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.pollActiveSessions(handleID: handleID)
      self.finishPollingTask(handleID: handleID)
    }
    pollTask = OperationHandle(id: handleID, task: task)
  }

  private func pollActiveSessions(handleID: UUID) async {
    while !Task.isCancelled, appIsActive, !pollStates.isEmpty {
      do {
        try await Task.sleep(for: .seconds(1))
        let completionTasks: [Task<Void, Never>]
        if usesLegacyFullSessionPolling {
          completionTasks = try await pollFullSessionSnapshot(handleID: handleID)
        } else {
          do {
            completionTasks = try await pollSessionStatuses(handleID: handleID)
          } catch RemoteAPIError.http(status: 404, detail: _) {
            usesLegacyFullSessionPolling = true
            completionTasks = try await pollFullSessionSnapshot(handleID: handleID)
          }
        }
        guard pollTask?.id == handleID else { break }
        connectionState = .connected(version: protocolVersion)
        await waitForCompletionNotifications(completionTasks)
      } catch is CancellationError {
        break
      } catch {
        guard pollTask?.id == handleID else { break }
        connectionState = .failed(message: error.localizedDescription)
        for sessionID in Array(pollStates.keys) {
          finishPolling(sessionID: sessionID)
        }
        break
      }
    }
  }

  private func pollSessionStatuses(handleID: UUID) async throws -> [Task<Void, Never>] {
    let watchedSessionIDs = pollStates.keys.sorted { $0.uuidString < $1.uuidString }
    var statuses: [SessionStatusSnapshot] = []
    var batchStart = 0
    while batchStart < watchedSessionIDs.count {
      let batchEnd = min(batchStart + 50, watchedSessionIDs.count)
      let batch = Array(watchedSessionIDs[batchStart..<batchEnd])
      let batchStatuses = try await withCurrentClient { client in
        try await client.sessionStatuses(ids: batch)
      }
      statuses.append(contentsOf: batchStatuses)
      batchStart = batchEnd
    }
    guard pollTask?.id == handleID else { throw CancellationError() }

    let statusesByID = Dictionary(
      statuses.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    var deferredSessionIDs: Set<UUID> = []
    var sessionsToRefresh: [UUID] = []
    var completionTasks: [Task<Void, Never>] = []
    var shouldSyncUnreadBadge = false
    var shouldReconcileBackgroundState = false

    for sessionID in watchedSessionIDs {
      guard var state = pollStates[sessionID],
        let status = statusesByID[sessionID],
        let current = sessions.first(where: { $0.id == sessionID })
      else {
        shouldReconcileBackgroundState =
          finishPolling(sessionID: sessionID)
          || shouldReconcileBackgroundState
        continue
      }

      if let baseline = state.acceptedBaseline,
        !state.observedRunning,
        !status.hasActiveWork
      {
        let serverAcceptedTurn =
          status.contentRevision > baseline.contentRevision
          || status.messageCount > baseline.messageCount
          || status.updatedAt > baseline.updatedAt
        if !serverAcceptedTurn, state.graceAttemptsRemaining > 0 {
          state.graceAttemptsRemaining -= 1
          pollStates[sessionID] = state
          deferredSessionIDs.insert(sessionID)
          continue
        }
      }

      if status.hasActiveWork {
        state.observedRunning = true
      }
      pollStates[sessionID] = state

      if statusRequiresFullSession(status, current: current) {
        sessionsToRefresh.append(sessionID)
      } else if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
        shouldReconcileBackgroundState =
          sessions[index].isRunning != status.isRunning
          || shouldReconcileBackgroundState
        shouldSyncUnreadBadge =
          sessions[index].isUnread != status.isUnread
          || shouldSyncUnreadBadge
        sessions[index].isRunning = status.isRunning
        sessions[index].currentReasoning = status.currentReasoning
        sessions[index].isUnread = status.isUnread
      }
    }

    for sessionID in sessionsToRefresh {
      let updated = try await withCurrentClient { client in
        try await client.session(id: sessionID)
      }
      guard pollTask?.id == handleID else { throw CancellationError() }
      if let task = replaceSession(updated) {
        completionTasks.append(task)
      }
    }

    for sessionID in watchedSessionIDs where !deferredSessionIDs.contains(sessionID) {
      guard var state = pollStates[sessionID] else { continue }
      if sessions.first(where: { $0.id == sessionID })?.hasActiveWork == true {
        state.observedRunning = true
        pollStates[sessionID] = state
      } else {
        shouldReconcileBackgroundState =
          finishPolling(sessionID: sessionID)
          || shouldReconcileBackgroundState
      }
    }

    if shouldSyncUnreadBadge { syncUnreadSessionBadge() }
    if shouldReconcileBackgroundState { reconcileBackgroundRefreshState() }
    return completionTasks
  }

  private func statusRequiresFullSession(
    _ status: SessionStatusSnapshot,
    current: AgentSession
  ) -> Bool {
    status.contentRevision != current.contentRevision
      || status.messageCount != current.messages.count
      || status.updatedAt != current.updatedAt
      || status.isRunning != current.isRunning
      || status.hasPendingProjectCommand != current.hasPendingProjectCommand
      || status.queuedPromptCount != current.queuedPrompts.count
  }

  private func pollFullSessionSnapshot(handleID: UUID) async throws -> [Task<Void, Never>] {
    let updatedSessions = try await withCurrentClient { client in
      try await client.sessions(projectID: nil)
    }
    guard pollTask?.id == handleID else { throw CancellationError() }
    let updatesByID = Dictionary(uniqueKeysWithValues: updatedSessions.map { ($0.id, $0) })
    let completionTasks = applySnapshot(projects: projects, sessions: updatedSessions)
    for sessionID in Array(pollStates.keys) {
      guard var state = pollStates[sessionID], let updated = updatesByID[sessionID] else {
        finishPolling(sessionID: sessionID)
        continue
      }
      if updated.hasActiveWork {
        state.observedRunning = true
        pollStates[sessionID] = state
        continue
      }

      if let baseline = state.acceptedBaseline, !state.observedRunning {
        let serverAcceptedTurn =
          updated.contentRevision > baseline.contentRevision
          || updated.messages.count > baseline.messageCount
          || updated.updatedAt > baseline.updatedAt
        if !serverAcceptedTurn, state.graceAttemptsRemaining > 0 {
          state.graceAttemptsRemaining -= 1
          pollStates[sessionID] = state
          continue
        }
      }
      finishPolling(sessionID: sessionID)
    }
    return completionTasks
  }

  @discardableResult
  private func finishPolling(sessionID: UUID) -> Bool {
    guard pollStates.removeValue(forKey: sessionID) != nil else { return false }
    if sessions.first(where: { $0.id == sessionID })?.hasPendingProjectCommand != true {
      runningProjectCommandSessionIDs.remove(sessionID)
      updateProjectCommandRunningState(sessionID: sessionID, isRunning: false)
    }
    if !appIsActive, pollStates.isEmpty, pendingCompletionNotifications == 0 {
      endBackgroundTask()
    }
    return true
  }

  private func finishPollingTask(handleID: UUID) {
    guard pollTask?.id == handleID else { return }
    pollTask = nil
    startPollingTaskIfNeeded()
  }

  private func cancelPolling() {
    let task = pollTask?.task
    pollTask = nil
    pollStates.removeAll()
    task?.cancel()
    endBackgroundTask()
  }

  @discardableResult
  private func notifyIfCompleted(
    previous: AgentSession?,
    updated: AgentSession,
    watchedSessionIDs: Set<UUID>
  ) -> Task<Void, Never>? {
    let wasActive = previous?.hasActiveWork ?? watchedSessionIDs.contains(updated.id)
    guard wasActive, !updated.hasActiveWork else { return nil }
    pendingCompletionNotifications += 1
    return Task {
      await completionNotifications.notifyCompletion(for: updated)
      pendingCompletionNotifications -= 1
      if !appIsActive, pollStates.isEmpty, pendingCompletionNotifications == 0 {
        endBackgroundTask()
      }
    }
  }

  private func waitForCompletionNotifications(_ tasks: [Task<Void, Never>]) async {
    for task in tasks {
      await task.value
    }
  }

  private var activeBackgroundSessionIDs: Set<UUID> {
    Set(sessions.lazy.filter(\.hasActiveWork).map(\.id))
      .union(runningProjectCommandSessionIDs)
  }

  private func backgroundWatchedSessionIDs() -> Set<UUID> {
    guard let serverIdentifier = configuration?.serverIdentifier else { return [] }
    return backgroundSessionWatchStore.sessionIDs(serverIdentifier: serverIdentifier)
  }

  private func reconcileBackgroundRefreshState() {
    guard let serverIdentifier = configuration?.serverIdentifier else {
      backgroundRefreshScheduler.cancel()
      return
    }
    let activeSessionIDs = activeBackgroundSessionIDs
    backgroundSessionWatchStore.save(activeSessionIDs, serverIdentifier: serverIdentifier)
    guard !appIsActive, client != nil, !activeSessionIDs.isEmpty else {
      backgroundRefreshScheduler.cancel()
      return
    }
    backgroundRefreshScheduler.schedule()
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
    let contentRevision: UInt64
  }

  private struct PollState {
    let acceptedBaseline: PollBaseline?
    var observedRunning: Bool
    var graceAttemptsRemaining: Int

    init(acceptedBaseline: PollBaseline?) {
      self.acceptedBaseline = acceptedBaseline
      observedRunning = acceptedBaseline == nil
      graceAttemptsRemaining = acceptedBaseline == nil ? 0 : 5
    }
  }

  private struct ClientContext: Sendable {
    let client: any RemoteAPIClientProtocol
    let generation: UInt64
  }

  private struct OperationHandle {
    let id: UUID
    let task: Task<Void, Never>
  }
}
