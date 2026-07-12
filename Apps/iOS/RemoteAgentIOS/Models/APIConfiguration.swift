import Foundation

struct APIConfiguration: Equatable, Sendable {
  let host: String
  let port: Int
  let token: String

  var serverIdentifier: String { "\(host.lowercased()):\(port)" }

  var baseURL: URL {
    get throws {
      try Self.makeBaseURL(host: host, port: port)
    }
  }

  static func makeBaseURL(host rawHost: String, port: Int) throws -> URL {
    guard (1...65_535).contains(port) else { throw ConfigurationError.invalidPort }

    let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ConfigurationError.missingHost }

    var components: URLComponents
    if trimmed.contains("://") {
      guard var parsed = URLComponents(string: trimmed) else {
        throw ConfigurationError.invalidHost
      }
      guard parsed.scheme?.lowercased() == "http" else {
        throw ConfigurationError.localHTTPRequired
      }
      guard parsed.user == nil, parsed.password == nil, parsed.query == nil,
        parsed.fragment == nil, parsed.host != nil,
        parsed.path.isEmpty || parsed.path == "/"
      else {
        throw ConfigurationError.invalidHost
      }
      parsed.path = ""
      parsed.port = port
      components = parsed
    } else {
      let host = trimmed.contains(":") && !trimmed.hasPrefix("[") ? "[\(trimmed)]" : trimmed
      guard var parsed = URLComponents(string: "http://\(host)") else {
        throw ConfigurationError.invalidHost
      }
      parsed.port = port
      components = parsed
    }

    guard let url = components.url, components.host?.isEmpty == false else {
      throw ConfigurationError.invalidHost
    }
    return url
  }
}

enum ConfigurationError: LocalizedError, Equatable {
  case missingHost
  case invalidHost
  case invalidPort
  case missingToken
  case localHTTPRequired

  var errorDescription: String? {
    switch self {
    case .missingHost:
      return "Enter the Mac hostname or local IP address."
    case .invalidHost:
      return "Enter a hostname, local IP address, or plain HTTP URL without a path."
    case .invalidPort:
      return "Port must be between 1 and 65535."
    case .missingToken:
      return "Enter the bearer token from Remote Agent on the Mac."
    case .localHTTPRequired:
      return "This version connects to the Mac using HTTP on the local network."
    }
  }
}
