import Foundation
import RemoteAgentProtocol

protocol RemoteAPIClientProtocol: Sendable {
  func health() async throws -> HealthResponse
  func projects() async throws -> [AgentProject]
  func sessions(projectID: String?) async throws -> [AgentSession]
  func sessionStatuses(ids: [UUID]) async throws -> [SessionStatusSnapshot]
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
  func createSession(projectID: String, codexModel: String?) async throws -> AgentSession
  func models() async throws -> [CodexModelOption]
  func setSessionCodexModel(id: UUID, codexModel: String?) async throws -> AgentSession
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
  func models() async throws -> [CodexModelOption] { [] }

  func createSession(projectID: String, codexModel _: String?) async throws -> AgentSession {
    try await createSession(projectID: projectID)
  }

  func setSessionCodexModel(id _: UUID, codexModel _: String?) async throws -> AgentSession {
    throw RemoteAPIError.notConnected
  }
  func sessionStatuses(ids _: [UUID]) async throws -> [SessionStatusSnapshot] {
    throw RemoteAPIError.http(status: 404, detail: "Session status polling is unavailable")
  }

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

actor RemoteAPIRequestScheduler {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let maximumConcurrentRequests: Int
  private var activeRequestCount = 0
  private var waiters: [Waiter] = []

  init(maximumConcurrentRequests: Int) {
    self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
  }

  func acquire() async throws {
    try Task.checkCancellation()
    if activeRequestCount < maximumConcurrentRequests {
      activeRequestCount += 1
      return
    }

    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  func release() {
    if waiters.isEmpty {
      activeRequestCount = max(0, activeRequestCount - 1)
      return
    }
    let waiter = waiters.removeFirst()
    waiter.continuation.resume()
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }
}

final class RemoteAPIClient: RemoteAPIClientProtocol, @unchecked Sendable {
  private static let requestTimeout: TimeInterval = 8
  private static let retryBaseDelay: TimeInterval = 0.25
  private static let maximumRetryCount = 3

  private let configuration: APIConfiguration
  private let session: URLSession
  private let ownsSession: Bool
  private let requestScheduler: RemoteAPIRequestScheduler
  private let retryJitter: @Sendable (TimeInterval) -> TimeInterval
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    configuration: APIConfiguration,
    session: URLSession? = nil,
    maximumConcurrentRequests: Int = 4,
    retryJitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { delay in
      delay * Double.random(in: 0.8...1.2)
    }
  ) {
    self.configuration = configuration
    requestScheduler = RemoteAPIRequestScheduler(
      maximumConcurrentRequests: maximumConcurrentRequests
    )
    self.retryJitter = retryJitter
    if let session {
      self.session = session
      ownsSession = false
    } else {
      self.session = URLSession(configuration: Self.makeSessionConfiguration())
      ownsSession = true
    }
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

  deinit {
    if ownsSession { session.invalidateAndCancel() }
  }

  static func makeSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = 30
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    return configuration
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

  func sessionStatuses(ids: [UUID]) async throws -> [SessionStatusSnapshot] {
    guard !ids.isEmpty else { return [] }
    let value =
      ids
      .sorted { $0.uuidString < $1.uuidString }
      .map(\.uuidString)
      .joined(separator: ",")
    return try await request(
      path: RemoteAgentEndpoint.sessionStatus,
      queryItems: [URLQueryItem(name: "ids", value: value)]
    )
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

  func setSessionCodexModel(id: UUID, codexModel: String?) async throws -> AgentSession {
    try await request(
      path: RemoteAgentEndpoint.session(id),
      method: "PATCH",
      body: SessionUpdateRequest(codexModel: codexModel),
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
    try await createSession(projectID: projectID, codexModel: nil)
  }

  func createSession(projectID: String, codexModel: String?) async throws -> AgentSession {
    try await request(
      path: RemoteAgentEndpoint.sessions,
      method: "POST",
      body: CreateSessionRequest(projectID: projectID, codexModel: codexModel),
      expectedStatus: 201
    )
  }

  func models() async throws -> [CodexModelOption] {
    try await request(path: RemoteAgentEndpoint.models)
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
    request.timeoutInterval = Self.requestTimeout
    request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("deflate", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await data(for: request, mayRetry: method == "GET")

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

  private func data(for request: URLRequest, mayRetry: Bool) async throws -> (Data, URLResponse) {
    let maximumAttempts = mayRetry ? Self.maximumRetryCount + 1 : 1
    for attempt in 0..<maximumAttempts {
      do {
        let result = try await perform(request)
        if mayRetry,
          attempt < maximumAttempts - 1,
          let response = result.1 as? HTTPURLResponse,
          response.statusCode == 429 || response.statusCode == 503
        {
          try await sleepBeforeRetry(attempt: attempt, response: response)
          continue
        }
        return result
      } catch {
        if Task.isCancelled { throw CancellationError() }
        guard mayRetry, attempt < maximumAttempts - 1, Self.isTransient(error) else {
          throw RemoteAPIError.unreachable(error.localizedDescription)
        }
        try await sleepBeforeRetry(attempt: attempt, response: nil)
      }
    }
    throw RemoteAPIError.unreachable("The request could not be completed.")
  }

  private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await requestScheduler.acquire()
    do {
      let result = try await session.data(for: request)
      await requestScheduler.release()
      return result
    } catch {
      await requestScheduler.release()
      throw error
    }
  }

  private func sleepBeforeRetry(
    attempt: Int,
    response: HTTPURLResponse?
  ) async throws {
    let exponentialDelay = Self.retryBaseDelay * pow(2, Double(attempt))
    let jitteredDelay = max(0, retryJitter(exponentialDelay))
    let retryAfterDelay = response.flatMap(Self.retryAfterDelay) ?? 0
    try await Task.sleep(for: .seconds(max(jitteredDelay, retryAfterDelay)))
  }

  private static func retryAfterDelay(_ response: HTTPURLResponse) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After"),
      let seconds = TimeInterval(value), seconds >= 0
    else { return nil }
    return seconds
  }

  private static func isTransient(_ error: Error) -> Bool {
    let error = error as NSError
    guard error.domain == NSURLErrorDomain else { return false }
    switch URLError.Code(rawValue: error.code) {
    case .cannotFindHost, .cannotConnectToHost, .dataNotAllowed, .dnsLookupFailed,
      .internationalRoamingOff, .networkConnectionLost, .notConnectedToInternet, .timedOut:
      return true
    default:
      return false
    }
  }

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
