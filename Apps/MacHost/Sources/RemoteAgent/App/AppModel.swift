import AppKit
import Foundation
import RemoteAgentProtocol

private struct APIErrorBody: Codable { let error: String }
private struct APIHealth: Codable {
  let status: String
  let version: String
}
private struct CreateSessionBody: Codable { let projectID: String }
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
  @Published private(set) var apiStatus = "API stopped"
  @Published private(set) var crashRelaunchStatus = "Not configured"
  @Published private(set) var apiActivityLog: [APIActivityEntry] = []
  @Published var presentedError: String?

  let settings: AppSettings
  private let store: SessionStore
  private let activityStore: APIActivityStore
  private let scanner = ProjectScanner()
  private let codex = CodexCLIClient()
  private let documents = ProjectDocumentService()
  private var apiServer: RemoteAPIServer?
  private var apiRestartTask: Task<Void, Never>?
  private var apiGeneration = 0
  private var didStart = false

  init(
    settings: AppSettings,
    store: SessionStore = SessionStore(),
    activityStore: APIActivityStore = APIActivityStore()
  ) {
    self.settings = settings
    self.store = store
    self.activityStore = activityStore
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
        sessions[index].isRunning = false
      }
      persist()
    } catch {
      presentedError = "Could not load saved sessions: \(error.localizedDescription)"
    }
    do {
      apiActivityLog = try await activityStore.load()
    } catch {
      presentedError = "Could not load API activity: \(error.localizedDescription)"
    }
    await refreshProjects()
    restartAPI()
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
    let targetID = projectID ?? selectedProjectID
    guard let project = projects.first(where: { $0.id == targetID }) else {
      presentedError = RemoteAgentError.projectNotFound.localizedDescription
      return nil
    }
    let session = AgentSession(project: project)
    sessions.append(session)
    if select {
      selectedProjectID = project.id
      selectSession(session.id)
    }
    persist()
    return session
  }

  func requestNewSession() {
    guard !projects.isEmpty else {
      presentedError =
        "No projects are available. Choose a projects folder in Settings, then refresh."
      return
    }
    isShowingNewSessionPicker = true
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
    persist()
  }

  @discardableResult
  func deleteSession(_ id: UUID) throws -> AgentSession {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      throw RemoteAgentError.sessionNotFound
    }
    guard !sessions[index].isRunning else {
      throw RemoteAgentError.sessionBusy
    }
    let deleted = sessions.remove(at: index)
    if selectedSessionID == id { selectSession(recentSessions.first?.id) }
    persist()
    return deleted
  }

  @discardableResult
  func setSessionPinned(_ id: UUID, isPinned: Bool) throws -> AgentSession {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      throw RemoteAgentError.sessionNotFound
    }
    sessions[index].isPinned = isPinned
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
    sessions[index].title = trimmed
    let updated = sessions[index]
    persist()
    return updated
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
    guard !sessions[index].isRunning else {
      presentedError = RemoteAgentError.sessionBusy.localizedDescription
      return
    }

    if sessions[index].messages.isEmpty {
      let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
      sessions[index].title = String(oneLine.prefix(60))
    }
    sessions[index].messages.append(AgentMessage(role: .user, text: trimmed))
    sessions[index].isRunning = true
    sessions[index].isUnread = false
    sessions[index].updatedAt = Date()
    let projectPath = sessions[index].projectPath
    let codexSessionID = sessions[index].codexSessionID
    persist()

    do {
      let result = try await codex.send(
        prompt: trimmed,
        projectPath: projectPath,
        existingSessionID: codexSessionID,
        configuredExecutable: settings.codexPath
      )
      guard let updatedIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[updatedIndex].codexSessionID = result.sessionID
      sessions[updatedIndex].messages.append(
        AgentMessage(role: .assistant, text: result.response)
      )
      sessions[updatedIndex].isRunning = false
      sessions[updatedIndex].isUnread = selectedSessionID != id || !NSApp.isActive
      sessions[updatedIndex].updatedAt = Date()
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
      sessions[updatedIndex].isUnread = selectedSessionID != id || !NSApp.isActive
      sessions[updatedIndex].updatedAt = Date()
      persist()
      presentedError = error.localizedDescription
    }
  }

  func showProjectInFinder(_ project: AgentProject) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
  }

  func restartAPI() {
    apiRestartTask?.cancel()
    apiRestartTask = nil
    apiGeneration += 1
    let generation = apiGeneration
    apiServer?.stop()
    apiServer = nil
    guard settings.apiEnabled else {
      apiStatus = "API disabled"
      return
    }

    guard (1...65_535).contains(settings.apiPort) else {
      apiStatus = "API failed: port must be between 1 and 65535"
      return
    }

    let server = RemoteAPIServer { [weak self] request in
      guard let self else { return .json(APIErrorBody(error: "App unavailable"), status: 500) }
      let startedAt = Date()
      let response = await self.handleAPI(request)
      await self.recordAPIActivity(request: request, response: response, startedAt: startedAt)
      return response
    } stateChanged: { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.apiGeneration == generation else { return }
        self.apiStatus = state
      }
    }
    apiServer = server
    apiStatus = "Starting API…"
    do {
      try server.start(port: UInt16(settings.apiPort))
    } catch {
      apiServer = nil
      apiStatus = "API failed: \(error.localizedDescription)"
    }
  }

  func scheduleAPIRestart() {
    apiRestartTask?.cancel()
    apiRestartTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      self?.restartAPI()
    }
  }

  func configureCrashRelaunch() {
    crashRelaunchStatus = CrashRelaunchController.shared.configure(
      enabled: settings.autoRelaunchAfterCrash
    )
  }

  func clearAPIActivityLog() {
    apiActivityLog = []
    persistAPIActivity()
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
    if request.method == "GET", request.path == RemoteAgentEndpoint.sessions {
      let result =
        request.query["project_id"].map { projectID in
          sessions.filter { $0.projectID == projectID }
        } ?? sessions
      return .json(SessionSorter.mostRecent(result, limit: result.count))
    }
    if request.method == "POST", request.path == RemoteAgentEndpoint.sessions {
      guard let body = try? JSONDecoder().decode(CreateSessionBody.self, from: request.body),
        projects.contains(where: { $0.id == body.projectID })
      else { return .json(APIErrorBody(error: "Invalid projectID"), status: 400) }
      guard let session = createSession(projectID: body.projectID, select: false) else {
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
      if request.method == "PATCH", parts.count == 3 {
        guard let body = try? JSONDecoder().decode(SessionUpdateRequest.self, from: request.body),
          body.title != nil || body.isPinned != nil
        else {
          return .json(
            APIErrorBody(error: "A title or isPinned field is required"),
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
          return .json(updated)
        } catch {
          return .json(APIErrorBody(error: error.localizedDescription), status: 400)
        }
      }
      if request.method == "DELETE", parts.count == 3 {
        guard !session.isRunning else {
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
      if request.method == "POST", parts.count == 4, parts[3] == "messages" {
        guard !session.isRunning else {
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

  private func recordAPIActivity(
    request: HTTPRequest,
    response: HTTPResponse,
    startedAt: Date
  ) {
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
    let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    apiActivityLog.append(
      APIActivityEntry(
        remoteHost: request.remoteHost,
        clientName: clientName,
        method: request.method,
        path: requestPath,
        statusCode: response.status,
        durationMilliseconds: duration,
        isRemoteClient: APIClientClassifier.isRemote(host: request.remoteHost)
      )
    )
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
    let snapshot = apiActivityLog
    Task {
      do { try await activityStore.save(snapshot) } catch {
        presentedError = "Could not save API activity: \(error.localizedDescription)"
      }
    }
  }
}
