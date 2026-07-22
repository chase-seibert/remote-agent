import AppKit
import Foundation
import Network
import RemoteAgentProtocol

private struct APIErrorBody: Codable { let error: String }
private struct APIHealth: Codable {
  let status: String
  let version: String
}
private struct SendMessageBody: Codable { let text: String }
private struct AcceptedBody: Codable {
  let sessionID: UUID
  let status: String
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var projects: [AgentProject] = []
  @Published private(set) var sessions: [AgentSession] = []
  @Published var selectedProjectID: String?
  @Published var selectedSessionID: UUID?
  @Published var isShowingNewSessionPicker = false
  @Published var pendingNewSessionProjectID: String?
  @Published private(set) var apiStatus = "API stopped"
  @Published private(set) var apiListeningPort: UInt16?
  @Published private(set) var apiListenerAddresses: [APIListenerAddress] = []
  @Published private(set) var apiHealthTestStates: [String: APIHealthTestState] = [:]
  @Published private(set) var crashRelaunchStatus = "Not configured"
  @Published private(set) var apiActivityLog: [APIActivityEntry] = []
  @Published private(set) var projectCommandResults: [UUID: ProjectCommandResult] = [:]
  @Published private(set) var runningProjectCommandSessionIDs: Set<UUID> = []
  @Published private(set) var codexModels: [CodexModelOption] = []
  @Published private(set) var isRefreshingCodexModels = false
  @Published private(set) var codexModelCatalogError: String?
  @Published var presentedError: String?

  let settings: AppSettings
  private let store: SessionStore
  private let activityStore: APIActivityStore
  private let projectCommandResultStore: ProjectCommandResultStore
  private let projectCommands: ProjectCommandService
  private let scanner = ProjectScanner()
  private let codex: any CodexSending
  private let codexModelCatalog: any CodexModelListing
  private let documents = ProjectDocumentService()
  private let advertisesAPIWithBonjour: Bool
  private var apiServer: RemoteAPIServer?
  private var apiServerAttemptID: UUID?
  private var apiLifecycleTask: Task<Void, Never>?
  private var apiRestartDebounceTask: Task<Void, Never>?
  private var apiActivityPersistenceTask: Task<Void, Never>?
  private lazy var apiActivityBatcher = APIActivityBatcher { [weak self] entries in
    await self?.appendAPIActivity(entries)
  }
  private var apiGeneration = 0
  private var apiHealthTestIDs: [String: UUID] = [:]
  private var didStart = false

  init(
    settings: AppSettings,
    store: SessionStore = SessionStore(),
    activityStore: APIActivityStore = APIActivityStore(),
    projectCommandResultStore: ProjectCommandResultStore = ProjectCommandResultStore(),
    projectCommands: ProjectCommandService = ProjectCommandService(),
    codex: any CodexSending = CodexCLIClient(),
    codexModelCatalog: any CodexModelListing = CodexModelCatalogClient(),
    advertisesAPIWithBonjour: Bool = true
  ) {
    self.settings = settings
    self.store = store
    self.activityStore = activityStore
    self.projectCommandResultStore = projectCommandResultStore
    self.projectCommands = projectCommands
    self.codex = codex
    self.codexModelCatalog = codexModelCatalog
    self.advertisesAPIWithBonjour = advertisesAPIWithBonjour
  }

  var selectedProject: AgentProject? {
    projects.first { $0.id == selectedProjectID }
  }

  var selectedSession: AgentSession? {
    sessions.first { $0.id == selectedSessionID }
  }

  var recentSessions: [AgentSession] {
    SessionSorter.mostRecent(sessions)
  }

  var mostRecentlyUsedCodexModel: String? {
    recentSessions.compactMap(\.codexModel).first ?? normalizedCodexModel(settings.codexModel)
  }

  var lastRemoteClientActivityAt: Date? {
    apiActivityLog.last(where: \.isRemoteClient)?.timestamp
  }

  func isRemoteClientActive(at date: Date = Date()) -> Bool {
    guard let lastRemoteClientActivityAt else { return false }
    return date.timeIntervalSince(lastRemoteClientActivityAt) <= 30
  }

  func start() async {
    guard !didStart else { return }
    didStart = true
    configureCrashRelaunch()
    do {
      sessions = try await store.load()
      for index in sessions.indices {
        var contentChanged = false
        if sessions[index].isRunning {
          contentChanged = true
        }
        sessions[index].isRunning = false
        sessions[index].currentReasoning = nil
        if sessions[index].selectedMakeTarget == nil {
          sessions[index].selectedMakeTarget = settings.selectedMakeTarget(
            sessionID: sessions[index].id
          )
          contentChanged = sessions[index].selectedMakeTarget != nil || contentChanged
        }
        if contentChanged { sessions[index].recordContentChange() }
      }
      persist()
    } catch {
      presentedError = "Could not load saved sessions: \(error.localizedDescription)"
    }
    do {
      let results = try await projectCommandResultStore.load()
      let messageIDs = Set(sessions.flatMap(\.messages).map(\.id))
      var repairedInterruptedCommand = false
      var linkedLegacyCommandMessage = false
      let retainedResults = results.filter { messageIDs.contains($0.id) }.map { result in
        guard result.isRunning else { return result }
        repairedInterruptedCommand = true
        let completedAt = Date()
        if let sessionIndex = sessions.firstIndex(where: { $0.id == result.sessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
            $0.id == result.id
          })
        {
          sessions[sessionIndex].messages[messageIndex].text =
            "\(result.title) was interrupted. Click to view output."
          sessions[sessionIndex].messages[messageIndex].state = .failed
          sessions[sessionIndex].updatedAt = completedAt
          sessions[sessionIndex].recordContentChange()
        }
        return ProjectCommandResult(
          id: result.id,
          sessionID: result.sessionID,
          projectPath: result.projectPath,
          kind: result.kind,
          title: result.title,
          command: result.command,
          output: "Command was interrupted because Remote Agent stopped before it completed.",
          exitCode: nil,
          startedAt: result.startedAt,
          completedAt: completedAt
        )
      }
      for result in retainedResults {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == result.sessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
            $0.id == result.id
          }),
          sessions[sessionIndex].messages[messageIndex].projectCommandResultID == nil
        else { continue }
        sessions[sessionIndex].messages[messageIndex].projectCommandResultID = result.id
        sessions[sessionIndex].recordContentChange()
        linkedLegacyCommandMessage = true
      }
      projectCommandResults = Dictionary(
        retainedResults.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      if retainedResults.count != results.count || repairedInterruptedCommand {
        try await projectCommandResultStore.save(retainedResults)
      }
      if repairedInterruptedCommand || linkedLegacyCommandMessage { persist() }
    } catch {
      presentedError = "Could not load project command results: \(error.localizedDescription)"
    }
    do {
      apiActivityLog = try await activityStore.load()
    } catch {
      presentedError = "Could not load API activity: \(error.localizedDescription)"
    }
    await refreshProjects()
    await refreshCodexModels()
    restartAPI()
    scheduleQueuedPromptsForIdleSessions()
  }

  func refreshProjects() async {
    do {
      projects = try await scanner.scan(rootPath: settings.projectsRoot)
      if let selectedSessionID,
        !sessions.contains(where: { $0.id == selectedSessionID })
      {
        self.selectedSessionID = nil
      }
      if let selectedSession {
        selectedProjectID = selectedSession.projectID
      } else if let mostRecentSession = recentSessions.first {
        selectSession(mostRecentSession.id)
      } else if selectedProjectID == nil
        || !projects.contains(where: { $0.id == selectedProjectID })
      {
        selectedProjectID =
          ProjectSorter.byMostRecentSession(projects, sessions: sessions).first?.id
      }
    } catch {
      presentedError = error.localizedDescription
    }
  }

  @discardableResult
  func createSession(projectID: String? = nil, select: Bool = true) -> AgentSession? {
    createSession(projectID: projectID, codexModel: nil, select: select)
  }

  @discardableResult
  func createSession(
    projectID: String? = nil,
    codexModel: String?,
    select: Bool = true
  ) -> AgentSession? {
    let targetID = projectID ?? selectedProjectID
    guard let project = projects.first(where: { $0.id == targetID }) else {
      presentedError = RemoteAgentError.projectNotFound.localizedDescription
      return nil
    }
    let selectedModel =
      normalizedCodexModel(codexModel) ?? normalizedCodexModel(settings.codexModel)
    let session = AgentSession(project: project, codexModel: selectedModel)
    if let selectedModel { settings.codexModel = selectedModel }
    sessions.append(session)
    if select {
      selectedProjectID = project.id
      selectSession(session.id)
    }
    persist()
    return session
  }

  func requestNewSession(projectID: String? = nil) {
    guard !projects.isEmpty else {
      presentedError =
        "No projects are available. Choose a projects folder in Settings, then refresh."
      return
    }
    pendingNewSessionProjectID = projectID
    isShowingNewSessionPicker = true
  }

  func applyCodexModel(_ rawModel: String) {
    settings.codexModel = normalizedCodexModel(rawModel) ?? ""
  }

  func refreshCodexModels() async {
    guard !isRefreshingCodexModels else { return }
    isRefreshingCodexModels = true
    defer { isRefreshingCodexModels = false }
    do {
      codexModels = try await codexModelCatalog.listModels(
        configuredExecutable: settings.codexPath
      )
      codexModelCatalogError = nil
    } catch {
      codexModelCatalogError = error.localizedDescription
    }
  }

  func selectSession(_ id: UUID?) {
    selectedSessionID = id
    if let id, let session = sessions.first(where: { $0.id == id }) {
      selectedProjectID = session.projectID
    }
    if NSApp?.isActive == true, let id {
      markSessionRead(id)
    }
  }

  func appActivationChanged(isActive: Bool) {
    if isActive, let selectedSessionID {
      markSessionRead(selectedSessionID)
    }
  }

  func markSessionRead(_ id: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == id }),
      sessions[index].isUnread
    else { return }
    sessions[index].isUnread = false
    sessions[index].recordContentChange()
    persist()
  }

  func markSessionUnread(_ id: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == id }),
      !sessions[index].isUnread
    else { return }
    sessions[index].isUnread = true
    sessions[index].recordContentChange()
    persist()
  }

  @discardableResult
  func deleteSession(_ id: UUID) throws -> AgentSession {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      throw RemoteAgentError.sessionNotFound
    }
    guard !sessions[index].isRunning,
      !runningProjectCommandSessionIDs.contains(id)
    else {
      throw RemoteAgentError.sessionBusy
    }
    let deleted = sessions.remove(at: index)
    settings.clearSelectedMakeTarget(sessionID: id)
    projectCommandResults = projectCommandResults.filter { $0.value.sessionID != id }
    persistProjectCommandResults()
    if selectedSessionID == id { selectSession(recentSessions.first?.id) }
    persist()
    return deleted
  }

  @discardableResult
  func setSessionPinned(_ id: UUID, isPinned: Bool) throws -> AgentSession {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      throw RemoteAgentError.sessionNotFound
    }
    guard sessions[index].isPinned != isPinned else { return sessions[index] }
    sessions[index].isPinned = isPinned
    sessions[index].recordContentChange()
    let updated = sessions[index]
    persist()
    return updated
  }

  @discardableResult
  func renameSession(_ id: UUID, title: String) throws -> AgentSession {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 120 else {
      throw RemoteAgentError.invalidRequest("Session title must be between 1 and 120 characters")
    }
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      throw RemoteAgentError.sessionNotFound
    }
    guard sessions[index].title != trimmed else { return sessions[index] }
    sessions[index].title = trimmed
    sessions[index].recordContentChange()
    let updated = sessions[index]
    persist()
    return updated
  }

  @discardableResult
  func setSessionCodexModel(_ id: UUID, codexModel: String?) throws -> AgentSession {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      throw RemoteAgentError.sessionNotFound
    }
    guard !sessions[index].isRunning else { throw RemoteAgentError.sessionBusy }
    let normalized = normalizedCodexModel(codexModel)
    guard sessions[index].codexModel != normalized else { return sessions[index] }
    sessions[index].codexModel = normalized
    sessions[index].recordContentChange()
    if let normalized { settings.codexModel = normalized }
    let updated = sessions[index]
    persist()
    return updated
  }

  @discardableResult
  func enqueuePrompt(_ text: String, sessionID: UUID) throws -> QueuedPrompt {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw RemoteAgentError.invalidRequest("Queued prompt text cannot be empty")
    }
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
      throw RemoteAgentError.sessionNotFound
    }
    let prompt = QueuedPrompt(text: trimmed)
    sessions[index].queuedPrompts.append(prompt)
    sessions[index].recordContentChange()
    persist()
    Task { @MainActor [weak self] in
      await self?.drainPromptQueueIfPossible(sessionID: sessionID)
    }
    return prompt
  }

  @discardableResult
  func updateQueuedPrompt(_ promptID: UUID, sessionID: UUID, text: String) throws
    -> QueuedPrompt
  {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw RemoteAgentError.invalidRequest("Queued prompt text cannot be empty")
    }
    guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
      throw RemoteAgentError.sessionNotFound
    }
    guard
      let promptIndex = sessions[sessionIndex].queuedPrompts.firstIndex(where: {
        $0.id == promptID
      })
    else {
      throw RemoteAgentError.queuedPromptNotFound
    }
    let existing = sessions[sessionIndex].queuedPrompts[promptIndex]
    let updated = QueuedPrompt(id: existing.id, text: trimmed, createdAt: existing.createdAt)
    sessions[sessionIndex].queuedPrompts[promptIndex] = updated
    sessions[sessionIndex].recordContentChange()
    persist()
    return updated
  }

  @discardableResult
  func removeQueuedPrompt(_ promptID: UUID, sessionID: UUID) throws -> QueuedPrompt {
    guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
      throw RemoteAgentError.sessionNotFound
    }
    guard
      let promptIndex = sessions[sessionIndex].queuedPrompts.firstIndex(where: {
        $0.id == promptID
      })
    else {
      throw RemoteAgentError.queuedPromptNotFound
    }
    let removed = sessions[sessionIndex].queuedPrompts.remove(at: promptIndex)
    sessions[sessionIndex].recordContentChange()
    persist()
    return removed
  }

  func sendPrompt(_ text: String, to sessionID: UUID? = nil) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let id = sessionID ?? selectedSessionID,
      let index = sessions.firstIndex(where: { $0.id == id })
    else {
      presentedError = RemoteAgentError.sessionNotFound.localizedDescription
      return
    }
    guard !sessions[index].isRunning,
      !runningProjectCommandSessionIDs.contains(id)
    else {
      presentedError = RemoteAgentError.sessionBusy.localizedDescription
      return
    }

    if sessions[index].messages.isEmpty {
      let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
      sessions[index].title = String(oneLine.prefix(60))
    }
    sessions[index].messages.append(AgentMessage(role: .user, text: trimmed))
    sessions[index].isRunning = true
    sessions[index].currentReasoning = nil
    sessions[index].isUnread = false
    sessions[index].updatedAt = Date()
    sessions[index].recordContentChange()
    let projectPath = sessions[index].projectPath
    let codexSessionID = sessions[index].codexSessionID
    let codexModel = sessions[index].codexModel
    persist()

    do {
      let result = try await codex.send(
        prompt: trimmed,
        projectPath: projectPath,
        existingSessionID: codexSessionID,
        configuredExecutable: settings.codexPath,
        model: codexModel,
        onEvent: { [weak self] event in
          guard let reasoning = event.reasoningText else { return }
          Task { @MainActor [weak self] in
            self?.updateCurrentReasoning(reasoning, sessionID: id)
          }
        }
      )
      guard let updatedIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[updatedIndex].codexSessionID = result.sessionID
      sessions[updatedIndex].messages.append(
        AgentMessage(role: .assistant, text: result.response)
      )
      sessions[updatedIndex].isRunning = false
      sessions[updatedIndex].currentReasoning = nil
      sessions[updatedIndex].isUnread = selectedSessionID != id || !NSApp.isActive
      sessions[updatedIndex].updatedAt = Date()
      sessions[updatedIndex].recordContentChange()
      persist()
    } catch {
      guard let updatedIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[updatedIndex].messages.append(
        AgentMessage(
          role: .system,
          text: error.localizedDescription,
          state: .failed
        )
      )
      sessions[updatedIndex].isRunning = false
      sessions[updatedIndex].currentReasoning = nil
      sessions[updatedIndex].isUnread = selectedSessionID != id || !NSApp.isActive
      sessions[updatedIndex].updatedAt = Date()
      sessions[updatedIndex].recordContentChange()
      persist()
      presentedError = error.localizedDescription
    }
    await drainPromptQueueIfPossible(sessionID: id)
  }

  private func normalizedCodexModel(_ model: String?) -> String? {
    guard let model else { return nil }
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func scheduleQueuedPromptsForIdleSessions() {
    for session in sessions where !session.queuedPrompts.isEmpty {
      Task { @MainActor [weak self] in
        await self?.drainPromptQueueIfPossible(sessionID: session.id)
      }
    }
  }

  private func drainPromptQueueIfPossible(sessionID: UUID) async {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
      !sessions[index].isRunning,
      !runningProjectCommandSessionIDs.contains(sessionID),
      let prompt = sessions[index].queuedPrompts.first
    else { return }

    sessions[index].queuedPrompts.removeFirst()
    sessions[index].recordContentChange()
    persist()
    await sendPrompt(prompt.text, to: sessionID)
  }

  private func updateCurrentReasoning(_ reasoning: String, sessionID: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
      sessions[index].isRunning
    else { return }
    sessions[index].currentReasoning = reasoning
  }

  func makeTargets(for session: AgentSession) -> [String] {
    MakeTargetDiscovery.targets(projectPath: session.projectPath)
  }

  func activeMakeTarget(for session: AgentSession) -> String? {
    let targets = makeTargets(for: session)
    guard !targets.isEmpty else { return nil }
    let selected = sessions.first(where: { $0.id == session.id })?.selectedMakeTarget
    if let selected, targets.contains(selected) { return selected }
    return ["build", "test", "run"].first(where: targets.contains) ?? targets.first
  }

  func selectMakeTarget(_ target: String, for session: AgentSession) {
    guard makeTargets(for: session).contains(target),
      let index = sessions.firstIndex(where: { $0.id == session.id })
    else { return }
    var updatedSessions = sessions
    guard updatedSessions[index].selectedMakeTarget != target else { return }
    updatedSessions[index].selectedMakeTarget = target
    updatedSessions[index].recordContentChange()
    sessions = updatedSessions
    persist()
  }

  func projectCommandResult(messageID: UUID) -> ProjectCommandResult? {
    projectCommandResults[messageID]
  }

  func isProjectCommandRunning(sessionID: UUID) -> Bool {
    runningProjectCommandSessionIDs.contains(sessionID)
  }

  func runActiveMakeTarget(sessionID: UUID) async {
    guard let session = sessions.first(where: { $0.id == sessionID }),
      let target = activeMakeTarget(for: session)
    else {
      presentedError = "No Makefile targets are available for this project."
      return
    }
    selectMakeTarget(target, for: session)
    await runProjectCommand(sessionID: sessionID, action: .make(target))
  }

  func runGitCommit(sessionID: UUID) async {
    await runProjectCommand(sessionID: sessionID, action: .gitCommit)
  }

  func runGitPush(sessionID: UUID) async {
    await runProjectCommand(sessionID: sessionID, action: .gitPush)
  }

  func runGitCommitAndPush(sessionID: UUID) async {
    await runProjectCommand(sessionID: sessionID, action: .gitCommitAndPush)
  }

  private enum ProjectCommandAction {
    case make(String)
    case gitCommit
    case gitPush
    case gitCommitAndPush

    var descriptor: ProjectCommandDescriptor {
      switch self {
      case .make(let target):
        ProjectCommandDescriptor(
          kind: .make,
          title: "Make \(target)",
          command: "make \(target)",
          runningText: "Running make \(target)… Click to view output."
        )
      case .gitCommit:
        ProjectCommandDescriptor(
          kind: .gitCommit,
          title: "Git Commit",
          command: "git add --all && git commit",
          runningText: "Running git add and commit… Click to view output."
        )
      case .gitPush:
        ProjectCommandDescriptor(
          kind: .gitPush,
          title: "Git Push",
          command: "git push",
          runningText: "Running git push… Click to view output."
        )
      case .gitCommitAndPush:
        ProjectCommandDescriptor(
          kind: .gitCommit,
          title: "Git Commit & Push",
          command: "git add --all && git commit && git push",
          runningText: "Running git add, commit, and push… Click to view output."
        )
      }
    }
  }

  private struct ProjectCommandDescriptor {
    let kind: ProjectCommandKind
    let title: String
    let command: String
    let runningText: String
  }

  private func runProjectCommand(sessionID: UUID, action: ProjectCommandAction) async {
    guard let session = sessions.first(where: { $0.id == sessionID }) else {
      presentedError = RemoteAgentError.sessionNotFound.localizedDescription
      return
    }
    guard !session.isRunning else {
      presentedError = "Wait for the agent turn to finish before running a project command."
      return
    }
    guard !runningProjectCommandSessionIDs.contains(sessionID) else { return }
    runningProjectCommandSessionIDs.insert(sessionID)
    defer {
      runningProjectCommandSessionIDs.remove(sessionID)
      Task { @MainActor [weak self] in
        await self?.drainPromptQueueIfPossible(sessionID: sessionID)
      }
    }

    guard
      let messageID = await recordProjectCommandStarted(
        action.descriptor,
        sessionID: sessionID,
        projectPath: session.projectPath
      )
    else { return }

    let outcome: ProjectCommandOutcome
    switch action {
    case .make(let target):
      outcome = await projectCommands.runMake(target: target, projectPath: session.projectPath)
    case .gitCommit:
      outcome = await projectCommands.runGitCommit(projectPath: session.projectPath)
    case .gitPush:
      outcome = await projectCommands.runGitPush(projectPath: session.projectPath)
    case .gitCommitAndPush:
      outcome = await projectCommands.runGitCommitAndPush(projectPath: session.projectPath)
    }
    await recordProjectCommandFinished(
      outcome,
      messageID: messageID,
      sessionID: sessionID,
      projectPath: session.projectPath
    )
  }

  private func recordProjectCommandStarted(
    _ descriptor: ProjectCommandDescriptor,
    sessionID: UUID,
    projectPath: String
  ) async -> UUID? {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
    let startedAt = Date()
    let messageID = UUID()
    projectCommandResults[messageID] = ProjectCommandResult(
      id: messageID,
      sessionID: sessionID,
      projectPath: projectPath,
      kind: descriptor.kind,
      title: descriptor.title,
      command: descriptor.command,
      output: "Command is running. Output will appear here when it completes.",
      exitCode: nil,
      startedAt: startedAt,
      completedAt: nil
    )
    sessions[index].messages.append(
      AgentMessage(
        id: messageID,
        role: .system,
        text: descriptor.runningText,
        createdAt: startedAt,
        state: .pending,
        projectCommandResultID: messageID
      )
    )
    sessions[index].updatedAt = startedAt
    sessions[index].isUnread = false
    sessions[index].recordContentChange()
    persist()
    do {
      try await projectCommandResultStore.save(Array(projectCommandResults.values))
    } catch {
      presentedError = "Could not save project command output: \(error.localizedDescription)"
    }
    return messageID
  }

  private func recordProjectCommandFinished(
    _ outcome: ProjectCommandOutcome,
    messageID: UUID,
    sessionID: UUID,
    projectPath: String
  ) async {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
      let messageIndex = sessions[index].messages.firstIndex(where: { $0.id == messageID })
    else { return }
    let result = ProjectCommandResult(
      id: messageID,
      sessionID: sessionID,
      projectPath: projectPath,
      kind: outcome.kind,
      title: outcome.title,
      command: outcome.command,
      output: outcome.output,
      exitCode: outcome.exitCode,
      startedAt: outcome.startedAt,
      completedAt: outcome.completedAt
    )
    projectCommandResults[messageID] = result
    sessions[index].messages[messageIndex].text = placeholderText(for: outcome)
    sessions[index].messages[messageIndex].state = outcome.succeeded ? .complete : .failed
    sessions[index].updatedAt = outcome.completedAt
    sessions[index].isUnread = selectedSessionID != sessionID || NSApp?.isActive != true
    sessions[index].recordContentChange()
    persist()
    do {
      try await projectCommandResultStore.save(Array(projectCommandResults.values))
    } catch {
      presentedError = "Could not save project command output: \(error.localizedDescription)"
    }
  }

  private func placeholderText(for outcome: ProjectCommandOutcome) -> String {
    let status = outcome.succeeded ? "succeeded" : "failed"
    switch outcome.kind {
    case .make:
      return "\(outcome.title) \(status). Click to view output."
    case .gitCommit:
      return "\(outcome.title) \(status). Click to view output."
    case .gitPush:
      return "Git push \(status). Click to view output."
    }
  }

  func showProjectInFinder(_ project: AgentProject) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
  }

  func restartAPI() {
    apiRestartDebounceTask?.cancel()
    apiRestartDebounceTask = nil
    apiGeneration += 1
    let generation = apiGeneration
    let previousLifecycleTask = apiLifecycleTask
    let serverToStop = apiServer
    apiServer = nil
    apiServerAttemptID = nil
    clearAPIListenerDiagnostics()
    let shouldEnable = settings.apiEnabled
    let configuredPort = settings.apiPort

    if !shouldEnable {
      apiStatus = serverToStop == nil ? "API disabled" : "Stopping API…"
    } else if !(1...65_535).contains(configuredPort) {
      apiStatus = "API failed: port must be between 1 and 65535"
    } else {
      apiStatus = serverToStop == nil ? "Starting API…" : "Restarting API…"
    }

    apiLifecycleTask = Task { [weak self, previousLifecycleTask, serverToStop] in
      await previousLifecycleTask?.value
      if let serverToStop {
        await serverToStop.stopAndWait()
      }
      guard let self, self.apiGeneration == generation else { return }
      guard shouldEnable else {
        self.apiStatus = "API disabled"
        return
      }
      guard (1...65_535).contains(configuredPort) else { return }
      await self.startAPIWithRetry(port: UInt16(configuredPort), generation: generation)
    }
  }

  private func startAPIWithRetry(port: UInt16, generation: Int) async {
    let retryDelays: [Duration] = [
      .milliseconds(50), .milliseconds(100), .milliseconds(200), .milliseconds(400),
      .milliseconds(800),
    ]
    let activityBatcher = apiActivityBatcher
    for attempt in 0...retryDelays.count {
      guard apiGeneration == generation else { return }
      let attemptID = UUID()
      let server = RemoteAPIServer(advertisesBonjour: advertisesAPIWithBonjour) {
        [weak self, activityBatcher] request in
        guard let self else {
          return .json(APIErrorBody(error: "App unavailable"), status: 500)
        }
        let startedAt = Date()
        let response = await self.handleAPI(request)
        let completedAt = Date()
        let entry = Self.makeAPIActivityEntry(
          request: request,
          response: response,
          startedAt: startedAt,
          completedAt: completedAt
        )
        await activityBatcher.record(entry)
        return response
      } stateChanged: { [weak self] state in
        Task { @MainActor [weak self] in
          guard let self, self.apiGeneration == generation,
            self.apiServerAttemptID == attemptID
          else { return }
          self.apiStatus = state
          self.apiListeningPort = self.apiServer?.boundPort
          self.refreshAPIListenerAddresses()
        }
      }
      apiServer = server
      apiServerAttemptID = attemptID
      do {
        try await server.startAndWait(port: port)
        guard apiGeneration == generation, apiServerAttemptID == attemptID else {
          await server.stopAndWait()
          return
        }
        return
      } catch {
        if apiServerAttemptID == attemptID {
          apiServer = nil
          apiServerAttemptID = nil
          clearAPIListenerDiagnostics()
        }
        await server.stopAndWait()
        guard apiGeneration == generation else { return }
        if Self.isAddressInUse(error), attempt < retryDelays.count {
          apiStatus = "Port \(port) is still releasing; retrying…"
          try? await Task.sleep(for: retryDelays[attempt])
          continue
        }
        apiStatus = "API failed: \(error.localizedDescription)"
        return
      }
    }
  }

  func scheduleAPIRestart() {
    apiRestartDebounceTask?.cancel()
    apiRestartDebounceTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      guard let self else { return }
      self.apiRestartDebounceTask = nil
      self.restartAPI()
    }
  }

  private static func isAddressInUse(_ error: Error) -> Bool {
    if let networkError = error as? NWError,
      case .posix(let code) = networkError
    {
      return code == .EADDRINUSE
    }
    let error = error as NSError
    return error.domain == NSPOSIXErrorDomain && error.code == Int(EADDRINUSE)
  }

  func configureCrashRelaunch() {
    crashRelaunchStatus = CrashRelaunchController.shared.configure(
      enabled: settings.autoRelaunchAfterCrash
    )
  }

  func clearAPIActivityLog() {
    let activityBatcher = apiActivityBatcher
    Task { await activityBatcher.discardPending() }
    apiActivityLog = []
    persistAPIActivity()
  }

  func refreshAPIListenerAddresses() {
    guard apiListeningPort != nil else {
      apiListenerAddresses = []
      apiHealthTestStates = [:]
      apiHealthTestIDs = [:]
      return
    }
    let addresses = APIListenerAddressResolver.activeAddresses()
    let addressIDs = Set(addresses.map(\.id))
    apiListenerAddresses = addresses
    apiHealthTestStates = apiHealthTestStates.filter { addressIDs.contains($0.key) }
    apiHealthTestIDs = apiHealthTestIDs.filter { addressIDs.contains($0.key) }
  }

  func testAPIListenerAddress(_ address: APIListenerAddress) async {
    guard let port = apiListeningPort,
      apiListenerAddresses.contains(address)
    else { return }
    let generation = apiGeneration
    let bearerToken = settings.apiToken
    let testID = UUID()
    apiHealthTestIDs[address.id] = testID
    apiHealthTestStates[address.id] = .testing
    do {
      let success = try await APIHealthProbe.test(
        address: address,
        port: port,
        bearerToken: bearerToken
      )
      guard apiGeneration == generation,
        apiListeningPort == port,
        settings.apiToken == bearerToken,
        apiHealthTestIDs[address.id] == testID
      else { return }
      apiHealthTestStates[address.id] = .succeeded(success)
    } catch {
      guard apiGeneration == generation,
        apiListeningPort == port,
        settings.apiToken == bearerToken,
        apiHealthTestIDs[address.id] == testID
      else { return }
      apiHealthTestStates[address.id] = .failed(error.localizedDescription)
    }
  }

  private func clearAPIListenerDiagnostics() {
    apiListeningPort = nil
    apiListenerAddresses = []
    apiHealthTestStates = [:]
    apiHealthTestIDs = [:]
  }

  func handleAPI(_ request: HTTPRequest) async -> HTTPResponse {
    guard
      APIAuthentication.matches(
        authorizationHeader: request.headers["authorization"],
        token: settings.apiToken
      )
    else {
      return .json(APIErrorBody(error: "Missing or invalid bearer token"), status: 401)
    }

    if request.method == "GET", request.path == RemoteAgentEndpoint.health {
      return .json(APIHealth(status: "ok", version: RemoteAgentProtocolVersion.current))
    }
    if request.method == "GET", request.path == RemoteAgentEndpoint.projects {
      return .json(ProjectSorter.byMostRecentSession(projects, sessions: sessions))
    }
    if request.method == "GET", request.path == RemoteAgentEndpoint.models {
      if codexModels.isEmpty { await refreshCodexModels() }
      guard !codexModels.isEmpty else {
        return .json(
          APIErrorBody(error: codexModelCatalogError ?? "No Codex models are available"),
          status: 503)
      }
      return .json(codexModels)
    }
    if request.method == "GET", request.path == RemoteAgentEndpoint.sessionStatus {
      guard let rawIDs = request.query["ids"] else {
        return .json(APIErrorBody(error: "An ids query parameter is required"), status: 400)
      }
      let rawComponents = rawIDs.split(separator: ",", omittingEmptySubsequences: false)
      guard !rawComponents.isEmpty, rawComponents.count <= 50 else {
        return .json(APIErrorBody(error: "Between 1 and 50 session IDs are required"), status: 400)
      }
      let requestedIDs = rawComponents.compactMap { UUID(uuidString: String($0)) }
      guard requestedIDs.count == rawComponents.count else {
        return .json(APIErrorBody(error: "Every session ID must be a UUID"), status: 400)
      }
      let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
      let statusSnapshots = requestedIDs.compactMap { id in
        sessionsByID[id].map { sessionStatusSnapshot(for: $0) }
      }
      return .json(statusSnapshots)
    }
    if request.method == "GET", request.path == RemoteAgentEndpoint.sessions {
      let result =
        request.query["project_id"].map { projectID in
          sessions.filter { $0.projectID == projectID }
        } ?? sessions
      return .json(SessionSorter.mostRecent(result, limit: result.count))
    }
    if request.method == "POST", request.path == RemoteAgentEndpoint.sessions {
      guard let body = try? JSONDecoder().decode(CreateSessionRequest.self, from: request.body),
        projects.contains(where: { $0.id == body.projectID })
      else { return .json(APIErrorBody(error: "Invalid projectID"), status: 400) }
      guard
        let session = createSession(
          projectID: body.projectID, codexModel: body.codexModel, select: false
        )
      else {
        return .json(APIErrorBody(error: "Could not create session"), status: 500)
      }
      return .json(session, status: 201)
    }

    if request.method == "GET", request.path == RemoteAgentEndpoint.documents {
      guard let projectID = request.query["project_id"],
        let project = projects.first(where: { $0.id == projectID })
      else { return .json(APIErrorBody(error: "Invalid project_id"), status: 400) }
      do {
        return .json(try await documents.list(projectPath: project.path))
      } catch {
        return .json(APIErrorBody(error: error.localizedDescription), status: 500)
      }
    }

    let documentParts = request.path.split(separator: "/").map(String.init)
    if request.method == "GET", documentParts.count == 3,
      documentParts[0] == "v1", documentParts[1] == "documents",
      let projectID = request.query["project_id"],
      let project = projects.first(where: { $0.id == projectID })
    {
      do {
        return .json(
          try await documents.content(
            projectPath: project.path,
            documentID: documentParts[2]
          ))
      } catch let error as RemoteAgentError {
        return .json(APIErrorBody(error: error.localizedDescription), status: 400)
      } catch {
        return .json(APIErrorBody(error: error.localizedDescription), status: 500)
      }
    }

    let parts = request.path.split(separator: "/").map(String.init)
    if parts.count >= 3, parts[0] == "v1", parts[1] == "sessions",
      let sessionID = UUID(uuidString: parts[2])
    {
      guard let session = sessions.first(where: { $0.id == sessionID }) else {
        return .json(APIErrorBody(error: "Session not found"), status: 404)
      }
      if request.method == "GET", parts.count == 3 {
        return .json(session)
      }
      if request.method == "GET", parts.count == 4, parts[3] == "project-commands" {
        return .json(
          ProjectCommandConfigurationResponse(
            sessionID: sessionID,
            makeTargets: makeTargets(for: session),
            selectedMakeTarget: activeMakeTarget(for: session),
            isRunning: isProjectCommandRunning(sessionID: sessionID)
          ))
      }
      if request.method == "GET", parts.count == 5, parts[3] == "project-commands",
        let resultID = UUID(uuidString: parts[4]),
        let result = projectCommandResults[resultID], result.sessionID == sessionID
      {
        return .json(result.remoteResult)
      }
      if request.method == "POST", parts.count == 4, parts[3] == "project-commands" {
        guard !session.isRunning,
          !runningProjectCommandSessionIDs.contains(sessionID)
        else {
          return .json(APIErrorBody(error: "Session is busy"), status: 409)
        }
        guard
          let body = try? JSONDecoder().decode(
            RemoteAgentProtocol.ProjectCommandRequest.self,
            from: request.body
          )
        else {
          return .json(APIErrorBody(error: "Invalid project command"), status: 400)
        }
        switch body.action {
        case .make:
          guard let target = body.target ?? activeMakeTarget(for: session),
            makeTargets(for: session).contains(target)
          else {
            return .json(APIErrorBody(error: "Invalid Make target"), status: 400)
          }
          selectMakeTarget(target, for: session)
          Task { @MainActor [weak self] in
            await self?.runActiveMakeTarget(sessionID: sessionID)
          }
        case .gitCommit:
          Task { @MainActor [weak self] in await self?.runGitCommit(sessionID: sessionID) }
        case .gitPush:
          Task { @MainActor [weak self] in await self?.runGitPush(sessionID: sessionID) }
        case .gitCommitAndPush:
          Task { @MainActor [weak self] in
            await self?.runGitCommitAndPush(sessionID: sessionID)
          }
        }
        return .json(AcceptedBody(sessionID: sessionID, status: "accepted"), status: 202)
      }
      if request.method == "GET", parts.count == 4, parts[3] == "prompt-queue" {
        return .json(session.queuedPrompts)
      }
      if request.method == "POST", parts.count == 4, parts[3] == "prompt-queue" {
        guard
          let body = try? JSONDecoder().decode(
            QueuedPromptCreateRequest.self,
            from: request.body
          )
        else {
          return .json(APIErrorBody(error: "A text field is required"), status: 400)
        }
        do {
          return .json(try enqueuePrompt(body.text, sessionID: sessionID), status: 201)
        } catch {
          return .json(APIErrorBody(error: error.localizedDescription), status: 400)
        }
      }
      if parts.count == 5, parts[3] == "prompt-queue",
        let promptID = UUID(uuidString: parts[4])
      {
        if request.method == "PATCH" {
          guard
            let body = try? JSONDecoder().decode(
              QueuedPromptUpdateRequest.self,
              from: request.body
            )
          else {
            return .json(APIErrorBody(error: "A text field is required"), status: 400)
          }
          do {
            return .json(
              try updateQueuedPrompt(promptID, sessionID: sessionID, text: body.text)
            )
          } catch RemoteAgentError.queuedPromptNotFound {
            return .json(APIErrorBody(error: "Queued prompt not found"), status: 404)
          } catch {
            return .json(APIErrorBody(error: error.localizedDescription), status: 400)
          }
        }
        if request.method == "DELETE" {
          do {
            return .json(try removeQueuedPrompt(promptID, sessionID: sessionID))
          } catch RemoteAgentError.queuedPromptNotFound {
            return .json(APIErrorBody(error: "Queued prompt not found"), status: 404)
          } catch {
            return .json(APIErrorBody(error: error.localizedDescription), status: 400)
          }
        }
      }
      if request.method == "PATCH", parts.count == 3 {
        guard let body = try? JSONDecoder().decode(SessionUpdateRequest.self, from: request.body),
          body.title != nil || body.isPinned != nil || body.selectedMakeTarget != nil
            || body.codexModel != nil
        else {
          return .json(
            APIErrorBody(error: "A session update field is required"),
            status: 400
          )
        }
        do {
          var updated = session
          if let title = body.title {
            updated = try renameSession(sessionID, title: title)
          }
          if let isPinned = body.isPinned {
            updated = try setSessionPinned(sessionID, isPinned: isPinned)
          }
          if let target = body.selectedMakeTarget {
            guard makeTargets(for: session).contains(target) else {
              return .json(APIErrorBody(error: "Invalid Make target"), status: 400)
            }
            selectMakeTarget(target, for: session)
            guard let selected = sessions.first(where: { $0.id == sessionID }) else {
              return .json(APIErrorBody(error: "Session not found"), status: 404)
            }
            updated = selected
          }
          if body.codexModel != nil {
            updated = try setSessionCodexModel(sessionID, codexModel: body.codexModel)
          }
          return .json(updated)
        } catch {
          return .json(APIErrorBody(error: error.localizedDescription), status: 400)
        }
      }
      if request.method == "DELETE", parts.count == 3 {
        guard !session.isRunning,
          !runningProjectCommandSessionIDs.contains(sessionID)
        else {
          return .json(APIErrorBody(error: "Session is busy"), status: 409)
        }
        do {
          return .json(try deleteSession(sessionID))
        } catch {
          return .json(APIErrorBody(error: error.localizedDescription), status: 400)
        }
      }
      if request.method == "POST", parts.count == 4, parts[3] == "read" {
        markSessionRead(sessionID)
        guard let updated = sessions.first(where: { $0.id == sessionID }) else {
          return .json(APIErrorBody(error: "Session not found"), status: 404)
        }
        return .json(updated)
      }
      if request.method == "POST", parts.count == 4, parts[3] == "unread" {
        markSessionUnread(sessionID)
        guard let updated = sessions.first(where: { $0.id == sessionID }) else {
          return .json(APIErrorBody(error: "Session not found"), status: 404)
        }
        return .json(updated)
      }
      if request.method == "POST", parts.count == 4, parts[3] == "messages" {
        guard !session.isRunning,
          !runningProjectCommandSessionIDs.contains(sessionID)
        else {
          return .json(APIErrorBody(error: "Session is busy"), status: 409)
        }
        guard let body = try? JSONDecoder().decode(SendMessageBody.self, from: request.body),
          !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return .json(APIErrorBody(error: "A non-empty text field is required"), status: 400)
        }
        Task { @MainActor [weak self] in await self?.sendPrompt(body.text, to: sessionID) }
        return .json(AcceptedBody(sessionID: sessionID, status: "accepted"), status: 202)
      }
    }
    return .json(APIErrorBody(error: "Route not found"), status: 404)
  }

  private func sessionStatusSnapshot(for session: AgentSession) -> SessionStatusSnapshot {
    SessionStatusSnapshot(
      id: session.id,
      contentRevision: session.contentRevision,
      messageCount: session.messages.count,
      updatedAt: session.updatedAt,
      isRunning: session.isRunning,
      currentReasoning: session.currentReasoning,
      isUnread: session.isUnread,
      hasPendingProjectCommand: runningProjectCommandSessionIDs.contains(session.id)
        || session.messages.contains {
          $0.projectCommandResultID != nil && $0.state == .pending
        },
      queuedPromptCount: session.queuedPrompts.count
    )
  }

  private nonisolated static func makeAPIActivityEntry(
    request: HTTPRequest,
    response: HTTPResponse,
    startedAt: Date,
    completedAt: Date
  ) -> APIActivityEntry {
    let rawClientName =
      request.headers["x-remote-agent-client"]
      ?? request.headers["user-agent"]
      ?? "Unknown client"
    let clientName = String(
      rawClientName
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .prefix(100)
    )
    let query = request.query
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "&")
    let requestPath = query.isEmpty ? request.path : "\(request.path)?\(query)"
    return APIActivityEntry(
      timestamp: completedAt,
      remoteHost: request.remoteHost,
      clientName: clientName,
      method: request.method,
      path: requestPath,
      statusCode: response.status,
      responsePayloadByteCount: response.body.count,
      durationMilliseconds: max(0, Int(completedAt.timeIntervalSince(startedAt) * 1_000)),
      isRemoteClient: APIClientClassifier.isRemote(host: request.remoteHost)
    )
  }

  private func appendAPIActivity(_ entries: [APIActivityEntry]) {
    apiActivityLog.append(contentsOf: entries)
    if apiActivityLog.count > 500 {
      apiActivityLog.removeFirst(apiActivityLog.count - 500)
    }
    persistAPIActivity()
  }

  private func persist() {
    let snapshot = sessions
    Task {
      do { try await store.save(snapshot) } catch {
        presentedError = "Could not save sessions: \(error.localizedDescription)"
      }
    }
  }

  private func persistAPIActivity() {
    apiActivityPersistenceTask?.cancel()
    let snapshot = apiActivityLog
    let store = activityStore
    apiActivityPersistenceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(200))
        try Task.checkCancellation()
        try await store.save(snapshot)
      } catch is CancellationError {
        return
      } catch {
        self?.presentedError = "Could not save API activity: \(error.localizedDescription)"
      }
    }
  }

  private func persistProjectCommandResults() {
    let snapshot = Array(projectCommandResults.values)
    Task {
      do { try await projectCommandResultStore.save(snapshot) } catch {
        presentedError = "Could not save project command output: \(error.localizedDescription)"
      }
    }
  }
}
