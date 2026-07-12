import Foundation
import Network

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

  init(status: Int, body: Data = Data(), contentType: String = "application/json") {
    self.status = status
    self.body = body
    self.contentType = contentType
  }

  static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return HTTPResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
  }

  static func error(status: Int, message: String) -> HTTPResponse {
    struct ErrorBody: Encodable { let error: String }
    return .json(ErrorBody(error: message), status: status)
  }
}

enum HTTPRequestParseResult {
  case incomplete
  case request(HTTPRequest)
  case failure(HTTPResponse)
}

enum HTTPRequestParser {
  static let maximumHeaderByteCount = 32 * 1_024
  static let maximumBodyByteCount = 2 * 1_024 * 1_024

  static func parse(buffer: Data, remoteHost: String) -> HTTPRequestParseResult {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: separator) else {
      if buffer.count > maximumHeaderByteCount {
        return .failure(.error(status: 431, message: "Request headers are too large"))
      }
      return .incomplete
    }
    guard headerRange.lowerBound <= maximumHeaderByteCount else {
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
      guard parsed <= maximumBodyByteCount else {
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
    guard buffer.count >= requiredByteCount else { return .incomplete }
    let body = buffer.subdata(in: bodyStart..<requiredByteCount)

    let target = String(pieces[1])
    guard let components = URLComponents(string: target) else {
      return .failure(.error(status: 400, message: "Invalid request target"))
    }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] {
      query[item.name] = item.value ?? ""
    }
    return .request(
      HTTPRequest(
        method: String(pieces[0]),
        path: components.path,
        query: query,
        headers: headers,
        body: body,
        remoteHost: remoteHost
      ))
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

final class RemoteAPIServer: @unchecked Sendable {
  typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

  private var listener: NWListener?
  private let queue = DispatchQueue(label: "RemoteAgent.HTTPServer")
  private let handler: Handler
  private let stateChanged: @Sendable (String) -> Void

  init(handler: @escaping Handler, stateChanged: @escaping @Sendable (String) -> Void) {
    self.handler = handler
    self.stateChanged = stateChanged
  }

  func start(port: UInt16) throws {
    stop()
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw RemoteAgentError.invalidRequest("API port must be between 1 and 65535.")
    }
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let listener = try NWListener(using: parameters, on: nwPort)
    listener.service = NWListener.Service(
      name: "Remote Agent",
      type: "_remoteagent._tcp"
    )
    listener.stateUpdateHandler = { [stateChanged] state in
      switch state {
      case .ready: stateChanged("Listening on all interfaces · port \(port)")
      case .failed(let error): stateChanged("API failed: \(error.localizedDescription)")
      case .cancelled: stateChanged("API stopped")
      default: break
      }
    }
    listener.newConnectionHandler = { [handler, queue] connection in
      HTTPConnection(connection: connection, handler: handler).start(on: queue)
    }
    self.listener = listener
    listener.start(queue: queue)
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }
}

private final class HTTPConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let handler: RemoteAPIServer.Handler
  private var buffer = Data()
  private var retainUntilFinished: HTTPConnection?
  private var requestReceived = false
  private var finished = false
  private var queue: DispatchQueue?

  init(connection: NWConnection, handler: @escaping RemoteAPIServer.Handler) {
    self.connection = connection
    self.handler = handler
  }

  func start(on queue: DispatchQueue) {
    retainUntilFinished = self
    self.queue = queue
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.finish()
      default:
        break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 15) { [weak self] in
      guard let self, !self.requestReceived, !self.finished else { return }
      self.send(.error(status: 408, message: "Request timed out"))
    }
    receive()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      guard !self.finished else { return }
      if let data { self.buffer.append(data) }
      switch HTTPRequestParser.parse(buffer: self.buffer, remoteHost: self.remoteHost) {
      case .request(let request):
        self.requestReceived = true
        Task {
          let response = await self.handler(request)
          self.send(response)
        }
      case .failure(let response):
        self.requestReceived = true
        self.send(response)
      case .incomplete:
        if complete || error != nil {
          self.finish()
        } else {
          self.receive()
        }
      }
    }
  }

  private var remoteHost: String {
    guard case .hostPort(let host, _) = connection.endpoint else {
      return String(describing: connection.endpoint)
    }
    return String(describing: host)
  }

  private func send(_ response: HTTPResponse) {
    guard !finished else { return }
    requestReceived = true
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
    default: reason = "Internal Server Error"
    }
    var data = Data("HTTP/1.1 \(response.status) \(reason)\r\n".utf8)
    data.append(Data("Content-Type: \(response.contentType)\r\n".utf8))
    data.append(Data("Content-Length: \(response.body.count)\r\n".utf8))
    data.append(Data("Cache-Control: no-store\r\n".utf8))
    data.append(Data("X-Content-Type-Options: nosniff\r\n".utf8))
    data.append(Data("Connection: close\r\n\r\n".utf8))
    data.append(response.body)
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] _ in
        self?.finish()
      })
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    connection.stateUpdateHandler = nil
    connection.cancel()
    queue = nil
    retainUntilFinished = nil
  }
}
