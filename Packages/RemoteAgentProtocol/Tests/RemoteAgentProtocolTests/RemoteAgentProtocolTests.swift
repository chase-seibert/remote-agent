import Foundation
import XCTest

@testable import RemoteAgentProtocol

final class RemoteAgentProtocolTests: XCTestCase {
  func testSessionEndpointsUseCanonicalUUIDForm() {
    let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    XCTAssertEqual(
      RemoteAgentEndpoint.session(id),
      "/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )
    XCTAssertEqual(
      RemoteAgentEndpoint.sessionMessages(id),
      "/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/messages"
    )
  }

  func testSessionUpdateOmitsUnsetFields() throws {
    let data = try JSONEncoder().encode(SessionUpdateRequest(isPinned: true))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])

    XCTAssertEqual(object, ["isPinned": true])
  }
}
