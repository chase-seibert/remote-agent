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
    XCTAssertEqual(
      RemoteAgentEndpoint.sessionUnread(id),
      "/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/unread"
    )
    XCTAssertEqual(
      RemoteAgentEndpoint.sessionPromptQueue(id),
      "/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/prompt-queue"
    )
    let promptID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    XCTAssertEqual(
      RemoteAgentEndpoint.sessionQueuedPrompt(id, promptID: promptID),
      "/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/prompt-queue/99999999-8888-7777-6666-555555555555"
    )
    XCTAssertEqual(
      RemoteAgentEndpoint.sessionProjectCommands(id),
      "/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/project-commands"
    )
    let resultID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    XCTAssertEqual(
      RemoteAgentEndpoint.sessionProjectCommandResult(id, resultID: resultID),
      "/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/project-commands/11111111-2222-3333-4444-555555555555"
    )
  }

  func testSessionUpdateOmitsUnsetFields() throws {
    let data = try JSONEncoder().encode(SessionUpdateRequest(isPinned: true))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])

    XCTAssertEqual(object, ["isPinned": true])
  }

  func testCommitAndPushActionUsesStableWireValue() throws {
    let data = try JSONEncoder().encode(
      ProjectCommandRequest(action: .gitCommitAndPush)
    )
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(object["action"] as? String, "gitCommitAndPush")
  }

  func testQueuedPromptRequestsUseTextField() throws {
    let create = try JSONEncoder().encode(QueuedPromptCreateRequest(text: "Follow up"))
    let update = try JSONEncoder().encode(QueuedPromptUpdateRequest(text: "Edited"))

    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: create) as? [String: String],
      ["text": "Follow up"]
    )
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: update) as? [String: String],
      ["text": "Edited"]
    )
  }
}
