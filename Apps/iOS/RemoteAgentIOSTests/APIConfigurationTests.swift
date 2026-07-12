import XCTest

@testable import RemoteAgentIOS

final class APIConfigurationTests: XCTestCase {
  func testBuildsBaseURLFromHostname() throws {
    let url = try APIConfiguration.makeBaseURL(host: "chases-mac.local", port: 8765)
    XCTAssertEqual(url.absoluteString, "http://chases-mac.local:8765")
  }

  func testNormalizesPlainHTTPURLAndReplacesPort() throws {
    let url = try APIConfiguration.makeBaseURL(host: "http://192.168.1.7:9000/", port: 8765)
    XCTAssertEqual(url.absoluteString, "http://192.168.1.7:8765")
  }

  func testSupportsIPv6Literal() throws {
    let url = try APIConfiguration.makeBaseURL(host: "fe80::1", port: 8765)
    XCTAssertEqual(url.absoluteString, "http://[fe80::1]:8765")
  }

  func testRejectsHTTPSAndPaths() {
    XCTAssertThrowsError(try APIConfiguration.makeBaseURL(host: "https://mac.local", port: 8765))
    XCTAssertThrowsError(try APIConfiguration.makeBaseURL(host: "http://mac.local/api", port: 8765))
  }

  func testRejectsInvalidPort() {
    XCTAssertThrowsError(try APIConfiguration.makeBaseURL(host: "mac.local", port: 0))
    XCTAssertThrowsError(try APIConfiguration.makeBaseURL(host: "mac.local", port: 65_536))
  }
}
