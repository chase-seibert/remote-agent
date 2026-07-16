import Foundation
import Network
import zlib

struct HTTPRequest: Sendable {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data
  let remoteHost: String
}

struct HTTPResponse: Sendable {
  let status: Int
  let body: Data
  let contentType: String
  let headers: [String: String]

  init(
    status: Int,
    body: Data = Data(),
    contentType: String = "application/json",
    headers: [String: String] = [:]
  ) {
    self.status = status
    self.body = body
    self.contentType = contentType
    self.headers = headers
  }

  static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return HTTPResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
  }

  static func error(
    status: Int,
    message: String,
    headers: [String: String] = [:]
  ) -> HTTPResponse {
    struct ErrorBody: Encodable { let error: String }
    let response = json(ErrorBody(error: message), status: status)
    return HTTPResponse(
      status: response.status,
      body: response.body,
      contentType: response.contentType,
      headers: headers
    )
  }
}

enum HTTPBodyCompression {
  static let minimumBodyByteCount = 32 * 1_024

  static func deflate(_ data: Data) -> Data? {
    guard !data.isEmpty else { return data }
    var compressedByteCount = compressBound(uLong(data.count))
    var compressed = Data(count: Int(compressedByteCount))
    let status = compressed.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        compress2(
          destination.bindMemory(to: Bytef.self).baseAddress,
          &compressedByteCount,
          source.bindMemory(to: Bytef.self).baseAddress,
          uLong(data.count),
          Z_BEST_SPEED
        )
      }
    }
    guard status == Z_OK else { return nil }
    compressed.removeSubrange(Int(compressedByteCount)..<compressed.count)
    return compressed
  }
}

enum HTTPRequestParseResult {
  case incomplete
  case request(HTTPRequest)
  case failure(HTTPResponse)
}

struct HTTPRequestParser {
  static let maximumHeaderByteCount = 32 * 1_024
  static let maximumBodyByteCount = 2 * 1_024 * 1_024
  private static let separator = Data("\r\n\r\n".utf8)

  private var buffer = Data()
  private var headerSearchStart = 0
  private var parsedHead: ParsedHead?

  var isWaitingForBody: Bool { parsedHead != nil }

  static func parse(buffer: Data, remoteHost: String) -> HTTPRequestParseResult {
    var parser = HTTPRequestParser()
    return parser.append(buffer, remoteHost: remoteHost)
  }

  mutating func append(_ data: Data, remoteHost: String) -> HTTPRequestParseResult {
    buffer.append(data)
    if parsedHead == nil {
      switch parseHead() {
      case .incomplete:
        return .incomplete
      case .failure(let response):
        return .failure(response)
      case .head(let head):
        parsedHead = head
      }
    }

    guard let parsedHead else { return .incomplete }
    guard buffer.count >= parsedHead.requiredByteCount else { return .incomplete }
    let body = buffer.subdata(in: parsedHead.bodyStart..<parsedHead.requiredByteCount)
    return .request(
      HTTPRequest(
        method: parsedHead.method,
        path: parsedHead.path,
        query: parsedHead.query,
        headers: parsedHead.headers,
        body: body,
        remoteHost: remoteHost
      ))
  }

  private mutating func parseHead() -> HeadParseResult {
    let searchStart = min(headerSearchStart, buffer.count)
    guard
      let headerRange = buffer.range(
        of: Self.separator,
        in: searchStart..<buffer.endIndex
      )
    else {
      if buffer.count > Self.maximumHeaderByteCount {
        return .failure(.error(status: 431, message: "Request headers are too large"))
      }
      headerSearchStart = max(0, buffer.count - (Self.separator.count - 1))
      return .incomplete
    }
    guard headerRange.lowerBound <= Self.maximumHeaderByteCount else {
      return .failure(.error(status: 431, message: "Request headers are too large"))
    }
    guard let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else {
      return .failure(.error(status: 400, message: "Request headers are not valid UTF-8"))
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      return .failure(.error(status: 400, message: "Missing request line"))
    }
    let pieces = requestLine.split(separator: " ")
    guard pieces.count == 3, pieces[2].hasPrefix("HTTP/1.") else {
      return .failure(.error(status: 400, message: "Invalid request line"))
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
      guard pair.count == 2 else {
        return .failure(.error(status: 400, message: "Invalid request header"))
      }
      let name = pair[0].lowercased()
      let value = pair[1].trimmingCharacters(in: .whitespaces)
      if let existing = headers[name] {
        guard name != "content-length" else {
          return .failure(.error(status: 400, message: "Duplicate Content-Length"))
        }
        headers[name] = existing + ", " + value
      } else {
        headers[name] = value
      }
    }

    if headers["transfer-encoding"] != nil {
      return .failure(.error(status: 400, message: "Transfer-Encoding is not supported"))
    }
    let contentLength: Int
    if let value = headers["content-length"] {
      guard let parsed = Int(value), parsed >= 0 else {
        return .failure(.error(status: 400, message: "Invalid Content-Length"))
      }
      guard parsed <= Self.maximumBodyByteCount else {
        return .failure(.error(status: 413, message: "Request body is too large"))
      }
      contentLength = parsed
    } else {
      contentLength = 0
    }

    let bodyStart = headerRange.upperBound
    let (requiredByteCount, overflow) = bodyStart.addingReportingOverflow(contentLength)
    guard !overflow else {
      return .failure(.error(status: 413, message: "Request body is too large"))
    }
    let target = String(pieces[1])
    guard let components = URLComponents(string: target) else {
      return .failure(.error(status: 400, message: "Invalid request target"))
    }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] {
      query[item.name] = item.value ?? ""
    }
    return .head(
      ParsedHead(
        method: String(pieces[0]),
        path: components.path,
        query: query,
        headers: headers,
        bodyStart: bodyStart,
        requiredByteCount: requiredByteCount
      ))
  }

  private struct ParsedHead {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let bodyStart: Int
    let requiredByteCount: Int
  }

  private enum HeadParseResult {
    case incomplete
    case head(ParsedHead)
    case failure(HTTPResponse)
  }
}

enum APIAuthentication {
  static func matches(authorizationHeader: String?, token: String) -> Bool {
    guard let authorizationHeader,
      authorizationHeader.hasPrefix("Bearer ")
    else { return false }
    let supplied = Array(authorizationHeader.dropFirst("Bearer ".count).utf8)
    let expected = Array(token.utf8)
    guard supplied.count == expected.count else { return false }
    var difference: UInt8 = 0
    for index in supplied.indices {
      difference |= supplied[index] ^ expected[index]
    }
    return difference == 0
  }
}

struct RemoteAPIServerConfiguration: Sendable {
  let maximumConnections: Int
  let priorityConnectionReserve: Int
  let maximumConnectionsPerHost: Int
  let priorityConnectionReservePerHost: Int
  let maximumHandlers: Int
  let priorityHandlerReserve: Int
  let maximumHandlersPerHost: Int
  let priorityHandlerReservePerHost: Int
  let headerTimeout: TimeInterval
  let priorityHeaderTimeout: TimeInterval
  let bodyIdleTimeout: TimeInterval
  let bodyTimeout: TimeInterval
  let handlerTimeout: TimeInterval
  let responseWriteTimeout: TimeInterval

  init(
    maximumConnections: Int = 64,
    priorityConnectionReserve: Int = 4,
    maximumConnectionsPerHost: Int = 16,
    priorityConnectionReservePerHost: Int = 2,
    maximumHandlers: Int = 16,
    priorityHandlerReserve: Int = 2,
    maximumHandlersPerHost: Int = 4,
    priorityHandlerReservePerHost: Int = 1,
    headerTimeout: TimeInterval = 10,
    priorityHeaderTimeout: TimeInterval = 2,
    bodyIdleTimeout: TimeInterval = 10,
    bodyTimeout: TimeInterval = 30,
    handlerTimeout: TimeInterval = 30,
    responseWriteTimeout: TimeInterval = 30
  ) {
    self.maximumConnections = max(1, maximumConnections)
    self.priorityConnectionReserve = min(
      max(0, priorityConnectionReserve),
      self.maximumConnections - 1
    )
    self.maximumConnectionsPerHost = max(1, maximumConnectionsPerHost)
    self.priorityConnectionReservePerHost = min(
      max(0, priorityConnectionReservePerHost),
      self.maximumConnectionsPerHost - 1
    )
    self.maximumHandlers = max(1, maximumHandlers)
    self.priorityHandlerReserve = min(max(0, priorityHandlerReserve), self.maximumHandlers - 1)
    self.maximumHandlersPerHost = max(1, maximumHandlersPerHost)
    self.priorityHandlerReservePerHost = min(
      max(0, priorityHandlerReservePerHost),
      self.maximumHandlersPerHost - 1
    )
    self.headerTimeout = max(0.01, headerTimeout)
    self.priorityHeaderTimeout = max(0.01, priorityHeaderTimeout)
    self.bodyIdleTimeout = max(0.01, bodyIdleTimeout)
    self.bodyTimeout = max(0.01, bodyTimeout)
    self.handlerTimeout = max(0.01, handlerTimeout)
    self.responseWriteTimeout = max(0.01, responseWriteTimeout)
  }
}

final class RemoteAPIServer: @unchecked Sendable {
  typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

  private var listener: NWListener?
  private var listenerID: UUID?
  private var listenerIsStopping = false
  private var startupResult: StartupResult?
  private var startupContinuation: CheckedContinuation<Void, Error>?
  private var stopContinuations: [CheckedContinuation<Void, Never>] = []
  private var connections: [UUID: ConnectionRecord] = [:]
  private let queue = DispatchQueue(label: "RemoteAgent.HTTPServer")
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let advertisesBonjour: Bool
  private let configuration: RemoteAPIServerConfiguration
  private let handlerAdmission: HTTPHandlerAdmission
  private let handler: Handler
  private let stateChanged: @Sendable (String) -> Void

  init(
    advertisesBonjour: Bool = true,
    configuration: RemoteAPIServerConfiguration = RemoteAPIServerConfiguration(),
    handler: @escaping Handler,
    stateChanged: @escaping @Sendable (String) -> Void
  ) {
    self.advertisesBonjour = advertisesBonjour
    self.configuration = configuration
    handlerAdmission = HTTPHandlerAdmission(configuration: configuration)
    self.handler = handler
    self.stateChanged = stateChanged
    queue.setSpecific(key: queueKey, value: 1)
  }

  func start(port: UInt16) throws {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw RemoteAgentError.invalidRequest("API port must be between 1 and 65535.")
    }
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let listener = try NWListener(using: parameters, on: nwPort)
    if advertisesBonjour {
      listener.service = NWListener.Service(
        name: "Remote Agent",
        type: "_remoteagent._tcp"
      )
    }
    let id = UUID()
    listener.stateUpdateHandler = { [weak self] state in
      self?.listenerDidChange(state, id: id)
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection, listenerID: id)
    }
    try syncOnQueue {
      guard self.listener == nil else {
        throw RemoteAgentError.invalidRequest(
          "The API listener must finish stopping before it can be started again."
        )
      }
      self.listener = listener
      listenerID = id
      listenerIsStopping = false
      startupResult = nil
      startupContinuation = nil
      listener.start(queue: queue)
    }
  }

  func startAndWait(port: UInt16) async throws {
    try start(port: port)
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        if let startupResult {
          resume(continuation, with: startupResult)
        } else if listener == nil {
          continuation.resume(throwing: CancellationError())
        } else {
          startupContinuation = continuation
        }
      }
    }
  }

  func stop() {
    syncOnQueue { requestStopLocked() }
  }

  func stopAndWait() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        guard listener != nil else {
          continuation.resume()
          return
        }
        stopContinuations.append(continuation)
        requestStopLocked()
      }
    }
  }

  var boundPort: UInt16? {
    syncOnQueue { listenerIsStopping ? nil : listener?.port?.rawValue }
  }

  var activeConnectionCount: Int {
    syncOnQueue { connections.count }
  }

  private func accept(_ connection: NWConnection, listenerID: UUID) {
    guard self.listenerID == listenerID else {
      connection.cancel()
      return
    }
    let remoteHost = Self.remoteHost(for: connection.endpoint)
    let hostConnectionCount = connections.values.lazy.filter { $0.remoteHost == remoteHost }.count
    guard connections.count < configuration.maximumConnections,
      hostConnectionCount < configuration.maximumConnectionsPerHost
    else {
      connection.cancel()
      return
    }

    let normalConnectionLimit =
      configuration.maximumConnections - configuration.priorityConnectionReserve
    let normalHostConnectionLimit =
      configuration.maximumConnectionsPerHost - configuration.priorityConnectionReservePerHost
    let requiresPriorityRequest =
      connections.count >= normalConnectionLimit
      || hostConnectionCount >= normalHostConnectionLimit

    let id = UUID()
    let connectionQueue = DispatchQueue(label: "RemoteAgent.HTTPConnection.\(id.uuidString)")
    let connectionHandler = HTTPConnection(
      connection: connection,
      remoteHost: remoteHost,
      handler: handler,
      queue: connectionQueue,
      configuration: configuration,
      handlerAdmission: handlerAdmission,
      requiresPriorityRequest: requiresPriorityRequest
    ) { [weak self] in
      self?.queue.async { [weak self] in
        self?.connections[id] = nil
      }
    }
    connections[id] = ConnectionRecord(remoteHost: remoteHost, connection: connectionHandler)
    connectionHandler.start()
  }

  private static func remoteHost(for endpoint: NWEndpoint) -> String {
    guard case .hostPort(let host, _) = endpoint else { return String(describing: endpoint) }
    return String(describing: host)
  }

  private func listenerDidChange(_ state: NWListener.State, id: UUID) {
    guard listenerID == id else { return }
    switch state {
    case .ready:
      let port = listener?.port?.rawValue ?? 0
      finishStartupLocked(with: .ready)
      stateChanged("Listening on all interfaces · port \(port)")
    case .failed(let error):
      if !listenerIsStopping {
        stateChanged("API failed: \(error.localizedDescription)")
      }
      finishStartupLocked(with: .failed(error))
      listener?.cancel()
      finishListenerLocked()
    case .cancelled:
      finishStartupLocked(with: .failed(CancellationError()))
      stateChanged("API stopped")
      finishListenerLocked()
    default:
      break
    }
  }

  private func requestStopLocked() {
    guard let listener else {
      finishStopContinuationsLocked()
      return
    }
    guard !listenerIsStopping else { return }
    listenerIsStopping = true
    finishStartupLocked(with: .failed(CancellationError()))
    listener.cancel()
    cancelConnectionsLocked()
  }

  private func finishListenerLocked() {
    listener = nil
    listenerID = nil
    listenerIsStopping = false
    cancelConnectionsLocked()
    finishStopContinuationsLocked()
  }

  private func finishStartupLocked(with result: StartupResult) {
    guard startupResult == nil else { return }
    startupResult = result
    guard let continuation = startupContinuation else { return }
    startupContinuation = nil
    resume(continuation, with: result)
  }

  private func resume(
    _ continuation: CheckedContinuation<Void, Error>,
    with result: StartupResult
  ) {
    switch result {
    case .ready:
      continuation.resume()
    case .failed(let error):
      continuation.resume(throwing: error)
    }
  }

  private func finishStopContinuationsLocked() {
    let continuations = stopContinuations
    stopContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func cancelConnectionsLocked() {
    let activeConnections = connections.values.map(\.connection)
    connections.removeAll()
    for connection in activeConnections {
      connection.cancel()
    }
  }

  private func syncOnQueue<Value>(_ operation: () throws -> Value) rethrows -> Value {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try operation()
    }
    return try queue.sync(execute: operation)
  }

  private enum StartupResult {
    case ready
    case failed(Error)
  }

  private struct ConnectionRecord {
    let remoteHost: String
    let connection: HTTPConnection
  }
}

private final class HTTPHandlerAdmission: @unchecked Sendable {
  private let configuration: RemoteAPIServerConfiguration
  private let lock = NSLock()
  private var activeCount = 0
  private var activeCountsByHost: [String: Int] = [:]

  init(configuration: RemoteAPIServerConfiguration) {
    self.configuration = configuration
  }

  func acquire(remoteHost: String, isPriority: Bool) -> Bool {
    lock.withLock {
      let hostCount = activeCountsByHost[remoteHost, default: 0]
      let totalLimit =
        isPriority
        ? configuration.maximumHandlers
        : configuration.maximumHandlers - configuration.priorityHandlerReserve
      let hostLimit =
        isPriority
        ? configuration.maximumHandlersPerHost
        : configuration.maximumHandlersPerHost - configuration.priorityHandlerReservePerHost
      guard activeCount < totalLimit, hostCount < hostLimit else { return false }
      activeCount += 1
      activeCountsByHost[remoteHost] = hostCount + 1
      return true
    }
  }

  func release(remoteHost: String) {
    lock.withLock {
      activeCount = max(0, activeCount - 1)
      let nextHostCount = max(0, activeCountsByHost[remoteHost, default: 0] - 1)
      activeCountsByHost[remoteHost] = nextHostCount == 0 ? nil : nextHostCount
    }
  }
}

private final class HTTPConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let remoteHost: String
  private let handler: RemoteAPIServer.Handler
  private let queue: DispatchQueue
  private let configuration: RemoteAPIServerConfiguration
  private let handlerAdmission: HTTPHandlerAdmission
  private let requiresPriorityRequest: Bool
  private let didFinish: @Sendable () -> Void
  private var parser = HTTPRequestParser()
  private var phase = Phase.readingHeaders
  private var bodyIdleGeneration = 0
  private var finished = false
  private var acceptsDeflateResponse = false

  init(
    connection: NWConnection,
    remoteHost: String,
    handler: @escaping RemoteAPIServer.Handler,
    queue: DispatchQueue,
    configuration: RemoteAPIServerConfiguration,
    handlerAdmission: HTTPHandlerAdmission,
    requiresPriorityRequest: Bool,
    didFinish: @escaping @Sendable () -> Void
  ) {
    self.connection = connection
    self.remoteHost = remoteHost
    self.handler = handler
    self.queue = queue
    self.configuration = configuration
    self.handlerAdmission = handlerAdmission
    self.requiresPriorityRequest = requiresPriorityRequest
    self.didFinish = didFinish
  }

  func start() {
    queue.async { [self] in
      startLocked()
    }
  }

  private func startLocked() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.finish()
      default:
        break
      }
    }
    connection.start(queue: queue)
    let timeout =
      requiresPriorityRequest
      ? min(configuration.headerTimeout, configuration.priorityHeaderTimeout)
      : configuration.headerTimeout
    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
      guard let self, self.phase == .readingHeaders, !self.finished else { return }
      self.send(.error(status: 408, message: "Request headers timed out"))
    }
    receive()
  }

  func cancel() {
    queue.async { [self] in
      finish()
    }
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      guard !self.finished else { return }
      let receivedData = data ?? Data()
      switch self.parser.append(receivedData, remoteHost: self.remoteHost) {
      case .request(let request):
        self.acceptsDeflateResponse = Self.acceptsDeflate(request.headers["accept-encoding"])
        let isPriorityRequest = Self.isPriorityRequest(request)
        if self.requiresPriorityRequest, !isPriorityRequest {
          self.send(
            .error(
              status: 503,
              message: "The host is busy; retry this request shortly.",
              headers: ["Retry-After": "1"]
            ))
          return
        }
        guard
          self.handlerAdmission.acquire(
            remoteHost: self.remoteHost,
            isPriority: isPriorityRequest
          )
        else {
          self.send(
            .error(
              status: 503,
              message: "The host is already running its maximum number of requests.",
              headers: ["Retry-After": "1"]
            ))
          return
        }
        self.phase = .handling
        self.scheduleHandlerDeadline()
        Task {
          [
            handler = self.handler,
            handlerAdmission = self.handlerAdmission,
            remoteHost = self.remoteHost,
            request,
            weak self,
          ] in
          let response = await handler(request)
          handlerAdmission.release(remoteHost: remoteHost)
          guard let queue = self?.queue else { return }
          queue.async { [weak self] in
            self?.send(response)
          }
        }
      case .failure(let response):
        self.send(response)
      case .incomplete:
        if self.parser.isWaitingForBody {
          if self.phase == .readingHeaders {
            self.phase = .readingBody
            self.scheduleBodyDeadline()
          }
          if !receivedData.isEmpty { self.scheduleBodyIdleDeadline() }
        }
        if complete || error != nil {
          self.finish()
        } else {
          self.receive()
        }
      }
    }
  }

  private static func isPriorityRequest(_ request: HTTPRequest) -> Bool {
    guard request.method == "GET" else { return false }
    if request.path == "/v1/health" { return true }
    if request.path == "/v1/session-status" { return true }
    let components = request.path.split(separator: "/")
    return components.count == 2 && components[0] == "v1" && components[1] == "sessions"
      || components.count == 3 && components[0] == "v1" && components[1] == "sessions"
  }

  private static func acceptsDeflate(_ value: String?) -> Bool {
    value?.split(separator: ",").contains { item in
      item.split(separator: ";", maxSplits: 1)[0]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedCaseInsensitiveCompare("deflate") == .orderedSame
    } == true
  }

  private func scheduleBodyIdleDeadline() {
    bodyIdleGeneration += 1
    let generation = bodyIdleGeneration
    queue.asyncAfter(deadline: .now() + configuration.bodyIdleTimeout) { [weak self] in
      guard let self, self.phase == .readingBody, self.bodyIdleGeneration == generation else {
        return
      }
      self.send(.error(status: 408, message: "Request body stalled"))
    }
  }

  private func scheduleBodyDeadline() {
    queue.asyncAfter(deadline: .now() + configuration.bodyTimeout) { [weak self] in
      guard let self, self.phase == .readingBody else { return }
      self.send(.error(status: 408, message: "Request body timed out"))
    }
  }

  private func scheduleHandlerDeadline() {
    queue.asyncAfter(deadline: .now() + configuration.handlerTimeout) { [weak self] in
      guard let self, self.phase == .handling else { return }
      self.send(
        .error(
          status: 504,
          message: "The request is still running on the host; reconnect to see its result."
        ))
    }
  }

  private func send(_ response: HTTPResponse) {
    guard !finished, phase != .writing, phase != .draining else { return }
    phase = .writing
    let reason: String
    switch response.status {
    case 200: reason = "OK"
    case 201: reason = "Created"
    case 202: reason = "Accepted"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 404: reason = "Not Found"
    case 409: reason = "Conflict"
    case 408: reason = "Request Timeout"
    case 413: reason = "Payload Too Large"
    case 431: reason = "Request Header Fields Too Large"
    case 503: reason = "Service Unavailable"
    case 504: reason = "Gateway Timeout"
    default: reason = "Internal Server Error"
    }
    var body = response.body
    var headers = response.headers
    if acceptsDeflateResponse, body.count >= HTTPBodyCompression.minimumBodyByteCount,
      let compressed = HTTPBodyCompression.deflate(body), compressed.count < body.count
    {
      body = compressed
      headers["Content-Encoding"] = "deflate"
      headers["Vary"] = "Accept-Encoding"
    }
    var data = Data("HTTP/1.1 \(response.status) \(reason)\r\n".utf8)
    data.append(Data("Content-Type: \(response.contentType)\r\n".utf8))
    data.append(Data("Content-Length: \(body.count)\r\n".utf8))
    data.append(Data("Cache-Control: no-store\r\n".utf8))
    data.append(Data("X-Content-Type-Options: nosniff\r\n".utf8))
    for (name, value) in headers {
      data.append(Data("\(name): \(value)\r\n".utf8))
    }
    data.append(Data("Connection: close\r\n\r\n".utf8))
    data.append(body)
    connection.send(
      content: data,
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] error in
        self?.queue.async { [weak self] in
          guard let self else { return }
          guard self.phase == .writing else { return }
          if error != nil {
            self.finish()
          } else {
            self.phase = .draining
            self.waitForPeerClose()
          }
        }
      })
    queue.asyncAfter(deadline: .now() + configuration.responseWriteTimeout) { [weak self] in
      guard let self, self.phase == .writing || self.phase == .draining else { return }
      self.finish()
    }
  }

  private func waitForPeerClose() {
    guard !finished, phase == .draining else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
      [weak self] _, _, complete, error in
      guard let self, !self.finished, self.phase == .draining else { return }
      if complete || error != nil {
        self.finish()
      } else {
        self.waitForPeerClose()
      }
    }
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    phase = .finished
    connection.stateUpdateHandler = nil
    connection.cancel()
    didFinish()
  }

  private enum Phase: Equatable {
    case readingHeaders
    case readingBody
    case handling
    case writing
    case draining
    case finished
  }
}
