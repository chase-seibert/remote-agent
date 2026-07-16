import RemoteAgentProtocol
import XCTest

@testable import RemoteAgentIOS

final class RemoteAPIClientTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    super.tearDown()
  }

  func testDefaultSessionWaitsForConnectivityAndAvoidsCachedResponses() {
    let configuration = RemoteAPIClient.makeSessionConfiguration()

    XCTAssertTrue(configuration.waitsForConnectivity)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 8)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(configuration.urlCache)
  }

  func testSafeGETRetriesTransientConnectionFailure() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let attempts = LockedCounter()

    MockURLProtocol.requestHandler = { request in
      if attempts.increment() == 1 { throw URLError(.networkConnectionLost) }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(#"{"status":"ok","version":"1"}"#.utf8)
      )
    }

    let health = try await client.health()

    XCTAssertEqual(health, HealthResponse(status: "ok", version: "1"))
    XCTAssertEqual(attempts.value, 2)
  }

  func testSafeGETRetriesBusyResponseUsingRetryAfter() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration),
      retryJitter: { _ in 0 }
    )
    let attempts = LockedCounter()

    MockURLProtocol.requestHandler = { request in
      let attempt = attempts.increment()
      let status = attempt == 1 ? 503 : 200
      let headers = attempt == 1 ? ["Retry-After": "0"] : nil
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: status,
          httpVersion: nil,
          headerFields: headers
        )!,
        Data(#"{"status":"ok","version":"1"}"#.utf8)
      )
    }

    let health = try await client.health()

    XCTAssertEqual(health, HealthResponse(status: "ok", version: "1"))
    XCTAssertEqual(attempts.value, 2)
  }

  func testRequestSchedulerBoundsConcurrentWorkAndDrainsWaitersFairly() async throws {
    let scheduler = RemoteAPIRequestScheduler(maximumConcurrentRequests: 2)
    let gate = AsyncTestGate()
    let probe = SchedulerConcurrencyProbe()

    let work = Task {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<8 {
          group.addTask {
            try await scheduler.acquire()
            await probe.enter(index: index)
            await gate.wait()
            await probe.leave()
            await scheduler.release()
          }
        }
        try await group.waitForAll()
      }
    }

    await probe.waitUntilStarted(count: 2)
    let initialMaximum = await probe.maximumActiveCount
    XCTAssertEqual(initialMaximum, 2)
    await gate.release()
    try await work.value

    let finalMaximum = await probe.maximumActiveCount
    let startedIndexes = await probe.startedIndexes
    XCTAssertEqual(finalMaximum, 2)
    XCTAssertEqual(startedIndexes.sorted(), Array(0..<8))
  }

  func testMutationDoesNotRetryAfterAmbiguousConnectionFailure() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let attempts = LockedCounter()

    MockURLProtocol.requestHandler = { _ in
      _ = attempts.increment()
      throw URLError(.networkConnectionLost)
    }

    do {
      _ = try await client.sendMessage("Do not duplicate", sessionID: UUID())
      XCTFail("Expected the mutation to fail")
    } catch {
      guard let remoteError = error as? RemoteAPIError else {
        return XCTFail("Expected a RemoteAPIError")
      }
      guard case .unreachable = remoteError else {
        return XCTFail("Expected an unreachable error")
      }
    }
    XCTAssertEqual(attempts.value, 1)
  }

  func testHealthAddsBearerToken() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "secret-token"),
      session: session
    )

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/v1/health")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
      let data = Data(#"{"status":"ok","version":"1"}"#.utf8)
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        data
      )
    }

    let health = try await client.health()
    XCTAssertEqual(health, HealthResponse(status: "ok", version: "1"))
  }

  func testSessionStatusRequestsOnlyWatchedIDsAndDecodesLightweightState() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let secondID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, RemoteAgentEndpoint.sessionStatus)
      let components = try XCTUnwrap(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
      )
      let ids = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "ids" })?.value)
      XCTAssertEqual(ids, "\(secondID.uuidString),\(firstID.uuidString)")
      let data = Data(
        """
        [{
          "id":"\(firstID.uuidString)",
          "contentRevision":7,
          "messageCount":42,
          "updatedAt":"2026-07-16T12:00:00Z",
          "isRunning":true,
          "currentReasoning":"Checking the focused session.",
          "isUnread":false,
          "hasPendingProjectCommand":false,
          "queuedPromptCount":1
        }]
        """.utf8
      )
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        data
      )
    }

    let statuses = try await client.sessionStatuses(ids: [firstID, secondID])

    XCTAssertEqual(statuses.count, 1)
    XCTAssertEqual(statuses.first?.id, firstID)
    XCTAssertEqual(statuses.first?.contentRevision, 7)
    XCTAssertEqual(statuses.first?.messageCount, 42)
    XCTAssertEqual(statuses.first?.currentReasoning, "Checking the focused session.")
    XCTAssertTrue(statuses.first?.hasActiveWork == true)
  }

  func testDecodesSessionAndFractionalDate() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()
    let messageID = UUID()

    MockURLProtocol.requestHandler = { request in
      let json = """
        {
          "id":"\(sessionID.uuidString)",
          "projectID":"opaque",
          "projectPath":"/Users/example/project",
          "codexSessionID":null,
          "title":"Test",
          "createdAt":"2026-07-11T20:00:00Z",
          "updatedAt":"2026-07-11T20:00:01.123Z",
          "messages":[{
            "id":"\(messageID.uuidString)",
            "role":"assistant",
            "text":"Done",
            "createdAt":"2026-07-11T20:00:01Z",
            "state":"complete"
          }],
          "isRunning":true,
          "currentReasoning":"Inspecting the session pipeline."
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.session(id: sessionID)
    XCTAssertEqual(result.id, sessionID)
    XCTAssertEqual(result.messages.first?.id, messageID)
    XCTAssertEqual(result.messages.first?.text, "Done")
    XCTAssertTrue(result.isRunning)
    XCTAssertEqual(result.currentReasoning, "Inspecting the session pipeline.")
    XCTAssertEqual(result.contentRevision, 0)
    XCTAssertFalse(result.isUnread)
    XCTAssertFalse(result.isPinned)
  }

  func testMarksSessionReadOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/v1/sessions/\(sessionID.uuidString)/read")
      XCTAssertEqual(request.httpMethod, "POST")
      let json = """
        {
          "id":"\(sessionID.uuidString)",
          "projectID":"opaque",
          "projectPath":"/Users/example/project",
          "codexSessionID":null,
          "title":"Read session",
          "createdAt":"2026-07-11T20:00:00Z",
          "updatedAt":"2026-07-11T20:00:01Z",
          "messages":[],
          "isRunning":false,
          "isUnread":false
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.markSessionRead(id: sessionID)
    XCTAssertFalse(result.isUnread)
  }

  func testMarksSessionUnreadOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/v1/sessions/\(sessionID.uuidString)/unread")
      XCTAssertEqual(request.httpMethod, "POST")
      let json = """
        {
          "id":"\(sessionID.uuidString)",
          "projectID":"opaque",
          "projectPath":"/Users/example/project",
          "codexSessionID":null,
          "title":"Unread session",
          "createdAt":"2026-07-12T20:00:00Z",
          "updatedAt":"2026-07-12T20:00:01Z",
          "messages":[],
          "isRunning":false,
          "isUnread":true
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.markSessionUnread(id: sessionID)
    XCTAssertTrue(result.isUnread)
  }

  func testRenamesSessionOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/v1/sessions/\(sessionID.uuidString)")
      XCTAssertEqual(request.httpMethod, "PATCH")
      let body = try requestBodyData(request)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
      XCTAssertEqual(object, ["title": "Release readiness"])
      let json = """
        {
          "id":"\(sessionID.uuidString)",
          "projectID":"opaque",
          "projectPath":"/Users/example/project",
          "codexSessionID":null,
          "title":"Release readiness",
          "createdAt":"2026-07-11T20:00:00Z",
          "updatedAt":"2026-07-11T20:00:01Z",
          "messages":[],
          "isRunning":false,
          "isUnread":false
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.renameSession(id: sessionID, title: "Release readiness")

    XCTAssertEqual(result.title, "Release readiness")
  }

  func testPinsSessionOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/v1/sessions/\(sessionID.uuidString)")
      XCTAssertEqual(request.httpMethod, "PATCH")
      let body = try requestBodyData(request)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
      XCTAssertEqual(object, ["isPinned": true])
      let json = """
        {
          "id":"\(sessionID.uuidString)",
          "projectID":"opaque",
          "projectPath":"/Users/example/project",
          "codexSessionID":null,
          "title":"Pinned session",
          "createdAt":"2026-07-11T20:00:00Z",
          "updatedAt":"2026-07-11T20:00:01Z",
          "messages":[],
          "isRunning":false,
          "isUnread":false,
          "isPinned":true
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.setSessionPinned(id: sessionID, isPinned: true)

    XCTAssertTrue(result.isPinned)
  }

  func testDeletesSessionOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/v1/sessions/\(sessionID.uuidString)")
      XCTAssertEqual(request.httpMethod, "DELETE")
      let json = """
        {
          "id":"\(sessionID.uuidString)",
          "projectID":"opaque",
          "projectPath":"/Users/example/project",
          "codexSessionID":null,
          "title":"Deleted session",
          "createdAt":"2026-07-11T20:00:00Z",
          "updatedAt":"2026-07-11T20:00:01Z",
          "messages":[],
          "isRunning":false,
          "isUnread":false,
          "isPinned":false
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.deleteSession(id: sessionID)

    XCTAssertEqual(result.id, sessionID)
  }

  func testCreatesQueuedPromptOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()
    let promptID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, RemoteAgentEndpoint.sessionPromptQueue(sessionID))
      XCTAssertEqual(request.httpMethod, "POST")
      let body = try JSONDecoder().decode(
        QueuedPromptCreateRequest.self,
        from: requestBodyData(request)
      )
      XCTAssertEqual(body, QueuedPromptCreateRequest(text: "Follow up"))
      let json =
        #"{"id":"\#(promptID.uuidString)","text":"Follow up","createdAt":"2026-07-12T20:00:00Z"}"#
      return (
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let queued = try await client.enqueuePrompt("Follow up", sessionID: sessionID)
    XCTAssertEqual(queued.id, promptID)
    XCTAssertEqual(queued.text, "Follow up")
  }

  func testUpdatesQueuedPromptOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()
    let promptID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.url?.path,
        RemoteAgentEndpoint.sessionQueuedPrompt(sessionID, promptID: promptID)
      )
      XCTAssertEqual(request.httpMethod, "PATCH")
      let body = try JSONDecoder().decode(
        QueuedPromptUpdateRequest.self,
        from: requestBodyData(request)
      )
      XCTAssertEqual(body, QueuedPromptUpdateRequest(text: "Edited follow up"))
      let json =
        #"{"id":"\#(promptID.uuidString)","text":"Edited follow up","createdAt":"2026-07-12T20:00:00Z"}"#
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let updated = try await client.updateQueuedPrompt(
      promptID,
      text: "Edited follow up",
      sessionID: sessionID
    )
    XCTAssertEqual(updated.text, "Edited follow up")
  }

  func testDeletesQueuedPromptOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()
    let promptID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.url?.path,
        RemoteAgentEndpoint.sessionQueuedPrompt(sessionID, promptID: promptID)
      )
      XCTAssertEqual(request.httpMethod, "DELETE")
      let json =
        #"{"id":"\#(promptID.uuidString)","text":"Remove me","createdAt":"2026-07-12T20:00:00Z"}"#
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let removed = try await client.deleteQueuedPrompt(promptID, sessionID: sessionID)
    XCTAssertEqual(removed.id, promptID)
  }

  func testSurfacesServerErrorDetail() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "bad"),
      session: URLSession(configuration: configuration)
    )
    MockURLProtocol.requestHandler = { request in
      let data = Data(#"{"error":"Missing or invalid bearer token"}"#.utf8)
      return (
        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
        data
      )
    }

    do {
      _ = try await client.health()
      XCTFail("Expected unauthorized error")
    } catch let error as RemoteAPIError {
      XCTAssertEqual(error, .http(status: 401, detail: "Missing or invalid bearer token"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testLoadsProjectCommandConfiguration() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.url?.path,
        "/v1/sessions/\(sessionID.uuidString)/project-commands"
      )
      let json = """
        {
          "sessionID":"\(sessionID.uuidString)",
          "makeTargets":["build","test"],
          "selectedMakeTarget":"test",
          "isRunning":false
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.projectCommandConfiguration(sessionID: sessionID)
    XCTAssertEqual(result.makeTargets, ["build", "test"])
    XCTAssertEqual(result.selectedMakeTarget, "test")
  }

  func testRunsSelectedMakeCommandOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(
        request.url?.path,
        "/v1/sessions/\(sessionID.uuidString)/project-commands"
      )
      let body = try requestBodyData(request)
      let command = try JSONDecoder().decode(ProjectCommandRequest.self, from: body)
      XCTAssertEqual(command, ProjectCommandRequest(action: .make, target: "phone-deploy"))
      let json = #"{"sessionID":"\#(sessionID.uuidString)","status":"accepted"}"#
      return (
        HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.runProjectCommand(
      .make,
      target: "phone-deploy",
      sessionID: sessionID
    )
    XCTAssertEqual(result.sessionID, sessionID)
    XCTAssertEqual(result.status, "accepted")
  }

  func testRunsCombinedCommitAndPushOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      let body = try requestBodyData(request)
      let command = try JSONDecoder().decode(ProjectCommandRequest.self, from: body)
      XCTAssertEqual(command, ProjectCommandRequest(action: .gitCommitAndPush))
      let json = #"{"sessionID":"\#(sessionID.uuidString)","status":"accepted"}"#
      return (
        HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.runProjectCommand(
      .gitCommitAndPush,
      target: nil,
      sessionID: sessionID
    )
    XCTAssertEqual(result.status, "accepted")
  }

  func testPersistsSelectedMakeTargetOnHost() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.httpMethod, "PATCH")
      let body = try requestBodyData(request)
      let update = try JSONDecoder().decode(SessionUpdateRequest.self, from: body)
      XCTAssertEqual(update.selectedMakeTarget, "test")
      let json = """
        {
          "id":"\(sessionID.uuidString)",
          "projectID":"opaque",
          "projectPath":"/Users/example/project",
          "codexSessionID":null,
          "title":"Test",
          "createdAt":"2026-07-11T20:00:00Z",
          "updatedAt":"2026-07-11T20:00:01Z",
          "messages":[],
          "isRunning":false,
          "selectedMakeTarget":"test"
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.selectMakeTarget("test", sessionID: sessionID)
    XCTAssertEqual(result.selectedMakeTarget, "test")
  }

  func testFetchesProjectCommandOutput() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )
    let sessionID = UUID()
    let resultID = UUID()

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.url?.path,
        "/v1/sessions/\(sessionID.uuidString)/project-commands/\(resultID.uuidString)"
      )
      let json = """
        {
          "id":"\(resultID.uuidString)",
          "sessionID":"\(sessionID.uuidString)",
          "projectPath":"/Users/example/project",
          "kind":"make",
          "title":"Make test",
          "command":"make test",
          "output":"All tests passed",
          "exitCode":0,
          "startedAt":"2026-07-12T20:00:00Z",
          "completedAt":"2026-07-12T20:00:01Z"
        }
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let result = try await client.projectCommandResult(
      sessionID: sessionID,
      resultID: resultID
    )
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.output, "All tests passed")
  }

  func testListsProjectDocumentsWithEncodedProjectID() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = RemoteAPIClient(
      configuration: APIConfiguration(host: "mac.local", port: 8765, token: "token"),
      session: URLSession(configuration: configuration)
    )

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/v1/documents")
      XCTAssertEqual(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
        "opaque project"
      )
      let data = Data(
        #"[{"id":"readme","name":"README.md","relativePath":"README.md","kind":"markdown","byteCount":42,"modifiedAt":"2026-07-14T12:00:00Z"},{"id":"source","name":"App.swift","relativePath":"Sources/App.swift","kind":"code","byteCount":128}]"#
          .utf8
      )
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        data
      )
    }

    let documents = try await client.documents(projectID: "opaque project")
    XCTAssertEqual(documents.first?.name, "README.md")
    XCTAssertEqual(documents.first?.kind, .markdown)
    XCTAssertEqual(documents.first?.modifiedAt, Date(timeIntervalSince1970: 1_784_030_400))
    XCTAssertEqual(documents.last?.relativePath, "Sources/App.swift")
    XCTAssertEqual(documents.last?.kind, .code)
    XCTAssertNil(documents.last?.modifiedAt)
  }
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else {
    throw NSError(domain: "RemoteAPIClientTests", code: 1)
  }
  stream.open()
  defer { stream.close() }
  var body = Data()
  var buffer = [UInt8](repeating: 0, count: 1_024)
  while true {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { throw stream.streamError ?? NSError(domain: "RemoteAPIClientTests", code: 2) }
    if count == 0 { break }
    body.append(contentsOf: buffer.prefix(count))
  }
  return body
}

private final class MockURLProtocol: URLProtocol {
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  func increment() -> Int {
    lock.withLock {
      storage += 1
      return storage
    }
  }
}

private actor AsyncTestGate {
  private var isReleased = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuations.append($0) }
  }

  func release() {
    isReleased = true
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting { continuation.resume() }
  }
}

private actor SchedulerConcurrencyProbe {
  private var activeCount = 0
  private(set) var maximumActiveCount = 0
  private(set) var startedIndexes: [Int] = []

  func enter(index: Int) {
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    startedIndexes.append(index)
  }

  func leave() {
    activeCount -= 1
  }

  func waitUntilStarted(count: Int) async {
    while startedIndexes.count < count { await Task.yield() }
  }
}
