import Foundation
import RemoteAgentProtocol

protocol RemoteAPIClientProtocol: Sendable {
  func health() async throws -> HealthResponse
  func projects() async throws -> [AgentProject]
  func sessions(projectID: String?) async throws -> [AgentSession]
  func session(id: UUID) async throws -> AgentSession
  func renameSession(id: UUID, title: String) async throws -> AgentSession
  func setSessionPinned(id: UUID, isPinned: Bool) async throws -> AgentSession
  func deleteSession(id: UUID) async throws -> AgentSession
  func markSessionRead(id: UUID) async throws -> AgentSession
  func markSessionUnread(id: UUID) async throws -> AgentSession
  func documents(projectID: String) async throws -> [ProjectDocument]
  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  func createSession(projectID: String) async throws -> AgentSession
  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse
  func enqueuePrompt(_ text: String, sessionID: UUID) async throws -> QueuedPrompt
  func updateQueuedPrompt(_ promptID: UUID, text: String, sessionID: UUID) async throws
    -> QueuedPrompt
  func deleteQueuedPrompt(_ promptID: UUID, sessionID: UUID) async throws -> QueuedPrompt
  func projectCommandConfiguration(sessionID: UUID) async throws
    -> ProjectCommandConfigurationResponse
  func selectMakeTarget(_ target: String, sessionID: UUID) async throws -> AgentSession
  func runProjectCommand(
    _ action: ProjectCommandAction,
    target: String?,
    sessionID: UUID
  ) async throws -> AcceptedResponse
  func projectCommandResult(sessionID: UUID, resultID: UUID) async throws
    -> RemoteProjectCommandResult
}

extension RemoteAPIClientProtocol {
  func markSessionUnread(id _: UUID) async throws -> AgentSession {
    throw RemoteAPIError.notConnected
  }

  func enqueuePrompt(_: String, sessionID _: UUID) async throws -> QueuedPrompt {
    throw RemoteAPIError.notConnected
  }

  func updateQueuedPrompt(_: UUID, text _: String, sessionID _: UUID) async throws
    -> QueuedPrompt
  {
    throw RemoteAPIError.notConnected
  }

  func deleteQueuedPrompt(_: UUID, sessionID _: UUID) async throws -> QueuedPrompt {
    throw RemoteAPIError.notConnected
  }

  func projectCommandConfiguration(sessionID _: UUID) async throws
    -> ProjectCommandConfigurationResponse
  {
    throw RemoteAPIError.notConnected
  }

  func selectMakeTarget(_: String, sessionID _: UUID) async throws -> AgentSession {
    throw RemoteAPIError.notConnected
  }

  func runProjectCommand(
    _: ProjectCommandAction,
    target _: String?,
    sessionID _: UUID
  ) async throws -> AcceptedResponse {
    throw RemoteAPIError.notConnected
  }

  func projectCommandResult(sessionID _: UUID, resultID _: UUID) async throws
    -> RemoteProjectCommandResult
  {
    throw RemoteAPIError.notConnected
  }
}

final class RemoteAPIClient: RemoteAPIClientProtocol, @unchecked Sendable {
  private let configuration: APIConfiguration
  private let session: URLSession
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(configuration: APIConfiguration, session: URLSession = .shared) {
    self.configuration = configuration
    self.session = session
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      if let date = Self.dateWithFractionalSeconds.date(from: value)
        ?? Self.dateWithoutFractionalSeconds.date(from: value)
      {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO-8601 date."
      )
    }
  }

  func health() async throws -> HealthResponse {
    try await request(path: RemoteAgentEndpoint.health)
  }

  func projects() async throws -> [AgentProject] {
    try await request(path: RemoteAgentEndpoint.projects)
  }

  func sessions(projectID: String? = nil) async throws -> [AgentSession] {
    var query: [URLQueryItem] = []
    if let projectID { query.append(URLQueryItem(name: "project_id", value: projectID)) }
    return try await request(path: RemoteAgentEndpoint.sessions, queryItems: query)
  }

  func session(id: UUID) async throws -> AgentSession {
    try await request(path: RemoteAgentEndpoint.session(id))
  }

  func renameSession(id: UUID, title: String) async throws -> AgentSession {
    try await request(
      path: RemoteAgentEndpoint.session(id),
      method: "PATCH",
      body: SessionUpdateRequest(title: title),
      expectedStatus: 200
    )
  }

  func setSessionPinned(id: UUID, isPinned: Bool) async throws -> AgentSession {
    try await request(
      path: RemoteAgentEndpoint.session(id),
      method: "PATCH",
      body: SessionUpdateRequest(isPinned: isPinned),
      expectedStatus: 200
    )
  }

  func deleteSession(id: UUID) async throws -> AgentSession {
    try await request(
      path: RemoteAgentEndpoint.session(id),
      method: "DELETE",
      expectedStatus: 200
    )
  }

  func markSessionRead(id: UUID) async throws -> AgentSession {
    try await request(path: RemoteAgentEndpoint.sessionRead(id), method: "POST")
  }

  func markSessionUnread(id: UUID) async throws -> AgentSession {
    try await request(path: RemoteAgentEndpoint.sessionUnread(id), method: "POST")
  }

  func documents(projectID: String) async throws -> [ProjectDocument] {
    try await request(
      path: RemoteAgentEndpoint.documents,
      queryItems: [URLQueryItem(name: "project_id", value: projectID)]
    )
  }

  func documentContent(projectID: String, documentID: String) async throws
    -> ProjectDocumentContent
  {
    try await request(
      path: RemoteAgentEndpoint.document(documentID),
      queryItems: [URLQueryItem(name: "project_id", value: projectID)]
    )
  }

  func createSession(projectID: String) async throws -> AgentSession {
    try await request(
      path: RemoteAgentEndpoint.sessions,
      method: "POST",
      body: CreateSessionRequest(projectID: projectID),
      expectedStatus: 201
    )
  }

  func sendMessage(_ text: String, sessionID: UUID) async throws -> AcceptedResponse {
    try await request(
      path: RemoteAgentEndpoint.sessionMessages(sessionID),
      method: "POST",
      body: SendMessageRequest(text: text),
      expectedStatus: 202
    )
  }

  func enqueuePrompt(_ text: String, sessionID: UUID) async throws -> QueuedPrompt {
    try await request(
      path: RemoteAgentEndpoint.sessionPromptQueue(sessionID),
      method: "POST",
      body: QueuedPromptCreateRequest(text: text),
      expectedStatus: 201
    )
  }

  func updateQueuedPrompt(_ promptID: UUID, text: String, sessionID: UUID) async throws
    -> QueuedPrompt
  {
    try await request(
      path: RemoteAgentEndpoint.sessionQueuedPrompt(sessionID, promptID: promptID),
      method: "PATCH",
      body: QueuedPromptUpdateRequest(text: text),
      expectedStatus: 200
    )
  }

  func deleteQueuedPrompt(_ promptID: UUID, sessionID: UUID) async throws -> QueuedPrompt {
    try await request(
      path: RemoteAgentEndpoint.sessionQueuedPrompt(sessionID, promptID: promptID),
      method: "DELETE",
      expectedStatus: 200
    )
  }

  func projectCommandConfiguration(sessionID: UUID) async throws
    -> ProjectCommandConfigurationResponse
  {
    try await request(path: RemoteAgentEndpoint.sessionProjectCommands(sessionID))
  }

  func selectMakeTarget(_ target: String, sessionID: UUID) async throws -> AgentSession {
    try await request(
      path: RemoteAgentEndpoint.session(sessionID),
      method: "PATCH",
      body: SessionUpdateRequest(selectedMakeTarget: target),
      expectedStatus: 200
    )
  }

  func runProjectCommand(
    _ action: ProjectCommandAction,
    target: String?,
    sessionID: UUID
  ) async throws -> AcceptedResponse {
    try await request(
      path: RemoteAgentEndpoint.sessionProjectCommands(sessionID),
      method: "POST",
      body: ProjectCommandRequest(action: action, target: target),
      expectedStatus: 202
    )
  }

  func projectCommandResult(sessionID: UUID, resultID: UUID) async throws
    -> RemoteProjectCommandResult
  {
    try await request(
      path: RemoteAgentEndpoint.sessionProjectCommandResult(sessionID, resultID: resultID)
    )
  }

  private func request<Response: Decodable>(
    path: String,
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    expectedStatus: Int = 200
  ) async throws -> Response {
    try await request(
      path: path,
      queryItems: queryItems,
      method: method,
      bodyData: nil,
      expectedStatus: expectedStatus
    )
  }

  private func request<Response: Decodable, Body: Encodable>(
    path: String,
    queryItems: [URLQueryItem] = [],
    method: String,
    body: Body,
    expectedStatus: Int
  ) async throws -> Response {
    let bodyData = try encoder.encode(body)
    return try await request(
      path: path,
      queryItems: queryItems,
      method: method,
      bodyData: bodyData,
      expectedStatus: expectedStatus
    )
  }

  private func request<Response: Decodable>(
    path: String,
    queryItems: [URLQueryItem],
    method: String,
    bodyData: Data?,
    expectedStatus: Int
  ) async throws -> Response {
    let baseURL = try configuration.baseURL
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw RemoteAPIError.invalidResponse
    }
    components.path = path
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else { throw RemoteAPIError.invalidResponse }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = bodyData
    request.timeoutInterval = 15
    request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw RemoteAPIError.unreachable(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw RemoteAPIError.invalidResponse
    }
    guard httpResponse.statusCode == expectedStatus else {
      let detail =
        (try? decoder.decode(APIErrorResponse.self, from: data).error)
        ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
      throw RemoteAPIError.http(status: httpResponse.statusCode, detail: detail)
    }

    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw RemoteAPIError.invalidData
    }
  }

  private struct CreateSessionRequest: Encodable { let projectID: String }
  private struct SendMessageRequest: Encodable { let text: String }

  private static let dateWithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let dateWithoutFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

enum RemoteAPIError: LocalizedError, Equatable {
  case notConnected
  case documentNotFound(String)
  case unreachable(String)
  case invalidResponse
  case invalidData
  case http(status: Int, detail: String)

  var errorDescription: String? {
    switch self {
    case .notConnected:
      return "Connect to the Mac before opening project files."
    case .documentNotFound(let path):
      return "The linked project file is unavailable: \(path)"
    case .unreachable(let detail):
      return "Could not reach the Mac. \(detail)"
    case .invalidResponse:
      return "The Mac returned an invalid network response."
    case .invalidData:
      return "The Mac returned data this version of the app could not read."
    case .http(let status, let detail):
      if status == 401 { return "The Mac rejected the bearer token." }
      if status == 409 { return detail }
      return "The Mac returned error \(status): \(detail)"
    }
  }
}
