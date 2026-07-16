import Darwin
import Foundation
import RemoteAgentProtocol

enum APIIPAddressFamily: String, Sendable {
  case ipv4 = "IPv4"
  case ipv6 = "IPv6"
}

struct APIListenerAddress: Identifiable, Hashable, Sendable {
  let interfaceName: String
  let address: String
  let family: APIIPAddressFamily
  let isLoopback: Bool

  var id: String { "\(interfaceName)|\(address)" }

  func endpoint(port: UInt16) -> String {
    switch family {
    case .ipv4: "\(address):\(port)"
    case .ipv6: "[\(address)]:\(port)"
    }
  }

  func healthURL(port: UInt16) -> URL? {
    let escapedAddress = address.replacingOccurrences(of: "%", with: "%25")
    let host = family == .ipv6 ? "[\(escapedAddress)]" : escapedAddress
    return URL(string: "http://\(host):\(port)\(RemoteAgentEndpoint.health)")
  }
}

enum APIListenerAddressResolver {
  static func activeAddresses() -> [APIListenerAddress] {
    var firstInterface: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstInterface) == 0, let firstInterface else { return [] }
    defer { freeifaddrs(firstInterface) }

    var addresses: Set<APIListenerAddress> = []
    var current: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while let interface = current {
      defer { current = interface.pointee.ifa_next }
      let flags = Int32(interface.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
        let socketAddress = interface.pointee.ifa_addr
      else { continue }

      let family: APIIPAddressFamily
      let socketLength: socklen_t
      switch Int32(socketAddress.pointee.sa_family) {
      case AF_INET:
        family = .ipv4
        socketLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      case AF_INET6:
        family = .ipv6
        socketLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
      default:
        continue
      }

      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          socketAddress,
          socketLength,
          &host,
          socklen_t(host.count),
          nil,
          0,
          NI_NUMERICHOST
        ) == 0
      else { continue }

      let interfaceName = String(cString: interface.pointee.ifa_name)
      let address = String(cString: host)
      guard address != "0.0.0.0", address != "::" else { continue }
      addresses.insert(
        APIListenerAddress(
          interfaceName: interfaceName,
          address: address,
          family: family,
          isLoopback: flags & IFF_LOOPBACK != 0
        ))
    }

    return addresses.sorted {
      if $0.isLoopback != $1.isLoopback { return !$0.isLoopback }
      if $0.interfaceName != $1.interfaceName { return $0.interfaceName < $1.interfaceName }
      if $0.family != $1.family { return $0.family == .ipv4 }
      return $0.address.localizedStandardCompare($1.address) == .orderedAscending
    }
  }
}

struct APIHealthProbeSuccess: Equatable, Sendable {
  let version: String
  let durationMilliseconds: Int
}

enum APIHealthTestState: Equatable, Sendable {
  case testing
  case succeeded(APIHealthProbeSuccess)
  case failed(String)

  var isTesting: Bool {
    if case .testing = self { return true }
    return false
  }
}

enum APIHealthProbeError: LocalizedError {
  case invalidAddress
  case invalidResponse
  case httpStatus(Int)
  case unhealthy(String)

  var errorDescription: String? {
    switch self {
    case .invalidAddress:
      "The address could not be converted into a health-check URL."
    case .invalidResponse:
      "The host did not return an HTTP response."
    case .httpStatus(let status):
      "The health endpoint returned HTTP \(status)."
    case .unhealthy(let status):
      "The health endpoint returned status \(status)."
    }
  }
}

enum APIHealthProbe {
  private struct HealthResponse: Decodable {
    let status: String
    let version: String
  }

  static func test(
    address: APIListenerAddress,
    port: UInt16,
    bearerToken: String,
    session: URLSession = .shared
  ) async throws -> APIHealthProbeSuccess {
    guard let url = address.healthURL(port: port) else {
      throw APIHealthProbeError.invalidAddress
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue("Remote Agent Mac Diagnostics", forHTTPHeaderField: "X-Remote-Agent-Client")

    let startedAt = Date()
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw APIHealthProbeError.invalidResponse
    }
    guard response.statusCode == 200 else {
      throw APIHealthProbeError.httpStatus(response.statusCode)
    }
    let health = try JSONDecoder().decode(HealthResponse.self, from: data)
    guard health.status == "ok" else {
      throw APIHealthProbeError.unhealthy(health.status)
    }
    return APIHealthProbeSuccess(
      version: health.version,
      durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    )
  }
}
