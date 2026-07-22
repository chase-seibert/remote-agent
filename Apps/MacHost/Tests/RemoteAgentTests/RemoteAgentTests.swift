import Darwin
import Foundation
import RemoteAgentProtocol
import Testing

@testable import RemoteAgent

#if canImport(FoundationModels)
  import FoundationModels
#endif

private struct FixedCommitMessageGenerator: CommitMessageGenerating {
  let message: String

  func generate(stagedSummary _: String, stagedDiff _: String) async throws -> String {
    message
  }
}

private actor CapturingCommitMessageGenerator: CommitMessageGenerating {
  private(set) var context: (summary: String, diff: String)?

  func generate(stagedSummary: String, stagedDiff: String) async throws -> String {
    context = (stagedSummary, stagedDiff)
    return "Enable background refresh"
  }
}

private actor ControllableCodexSender: CodexSending {
  private(set) var prompts: [String] = []
  private(set) var models: [String?] = []
  private var firstPromptContinuation: CheckedContinuation<Void, Never>?

  func send(
    prompt: String,
    projectPath _: String,
    existingSessionID _: String?,
    configuredExecutable _: String,
    model: String?,
    onEvent _: CodexEventHandler?
  ) async throws -> CodexTurnResult {
    prompts.append(prompt)
    models.append(model)
    let promptNumber = prompts.count
    if promptNumber == 1 {
      await withCheckedContinuation { continuation in
        firstPromptContinuation = continuation
      }
    }
    return CodexTurnResult(
      sessionID: "host-owned-queue",
      response: "Completed prompt \(promptNumber)"
    )
  }

  func releaseFirstPrompt() {
    firstPromptContinuation?.resume()
    firstPromptContinuation = nil
  }
}

struct RemoteAgentTests {
  @Test func parsesCodexJSONLEvents() {
    var parser = CodexEventAccumulator()
    parser.consume(line: #"{"type":"thread.started","thread_id":"019abc"}"#)
    parser.consume(
      line: #"{"type":"item.completed","item":{"type":"agent_message","text":"Done."}}"#)

    #expect(parser.sessionID == "019abc")
    #expect(parser.assistantMessages == ["Done."])
  }

  @Test func codexArgumentsApplyModelToNewAndResumedTurns() {
    let newTurn = CodexCLIClient.arguments(
      projectPath: "/tmp/example",
      existingSessionID: nil,
      model: "gpt-example"
    )
    let resumedTurn = CodexCLIClient.arguments(
      projectPath: "/tmp/example",
      existingSessionID: "thread-123",
      model: "gpt-example"
    )
    let defaultTurn = CodexCLIClient.arguments(
      projectPath: "/tmp/example",
      existingSessionID: nil,
      model: nil
    )

    #expect(newTurn.joined(separator: " ").contains("--model gpt-example"))
    #expect(resumedTurn.joined(separator: " ").contains("--model gpt-example"))
    #expect(!defaultTurn.contains("--model"))
    #expect(resumedTurn.suffix(2) == ["thread-123", "-"])
  }

  @Test func codexModelCatalogFiltersAndOrdersVisibleModels() throws {
    let data = Data(
      """
      {
        "models": [
          {"slug":"hidden","display_name":"Hidden","description":"No","visibility":"hide","priority":0},
          {"slug":"gpt-b","display_name":"GPT B","description":"Second","visibility":"list","priority":2},
          {"slug":"gpt-a","display_name":"GPT A","description":"First","visibility":"list","priority":1},
          {"slug":"gpt-a","display_name":"Duplicate","description":"No","visibility":"list","priority":3}
        ]
      }
      """.utf8
    )

    let models = try CodexModelCatalogClient.parse(data: data)

    #expect(models.map(\.id) == ["gpt-a", "gpt-b"])
    #expect(models.map(\.displayName) == ["GPT A", "GPT B"])
  }

  @Test func parsesCompletedReasoningEvent() throws {
    let event = try #require(
      CodexJSONLEvent(
        line:
          #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"  Inspecting the session pipeline.  "}}"#
      ))

    #expect(event.reasoningText == "Inspecting the session pipeline.")
  }

  @Test func buffersJSONLLinesAcrossOutputChunks() {
    var buffer = JSONLLineBuffer()
    let secondChunk = #"pleted","item":{"type":"reasoning"}}"# + "\n"

    #expect(buffer.append(Data(#"{"type":"item.com"#.utf8)).isEmpty)
    #expect(
      buffer.append(Data(secondChunk.utf8))
        == [#"{"type":"item.completed","item":{"type":"reasoning"}}"#]
    )
    #expect(buffer.append(Data(#"{"type":"turn.completed"}"#.utf8)).isEmpty)
    #expect(buffer.finish() == #"{"type":"turn.completed"}"#)
  }

  @Test func discoversPhonyMakeTargetsIncludingContinuations() {
    let makefile = """
      .PHONY: setup format lint \\
        test build clean --eval FOO=bar

      build:
      \t@echo build
      """

    #expect(
      MakeTargetDiscovery.targets(makefileContents: makefile)
        == ["setup", "format", "lint", "test", "build", "clean"]
    )
  }

  @Test func discoversDeclaredMakeTargetsWhenPhonyListIsMissing() {
    let makefile = """
      APP := RemoteAgent
      build test: prepare
      .internal:
      %.o: %.c
      """

    #expect(MakeTargetDiscovery.targets(makefileContents: makefile) == ["build", "test"])
  }

  @Test func sanitizesGeneratedCommitMessages() throws {
    #expect(
      try CommitMessageSanitizer.sanitize("Commit message: `Add project command controls`\nExtra")
        == "Add project command controls"
    )

    let longMessage = String(repeating: "word ", count: 20) + "tail"
    let truncatedMessage = try CommitMessageSanitizer.sanitize(longMessage)
    #expect(truncatedMessage.count <= 72)
    #expect(truncatedMessage.hasSuffix("word"))
  }

  #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Test func commitMessageGenerationDoesNotTruncateModelOutput() {
      #expect(FoundationCommitMessageGenerator.generationOptions.maximumResponseTokens == nil)
    }
  #endif

  @Test func commitMessageContextPrefersHighSignalIntent() {
    let result = CommitMessageContext.prioritizedDiff(
      highSignalDiff: "  Enable completion notifications for background sessions.  ",
      compactDiff: "Add BackgroundRefreshScheduler.swift"
    )

    #expect(result == "Enable completion notifications for background sessions.")
  }

  @Test func commitMessageContextFallsBackToBoundedCompactDiff() {
    let compactDiff = String(repeating: "x", count: CommitMessageContext.maximumCharacters + 50)
    let result = CommitMessageContext.prioritizedDiff(
      highSignalDiff: "",
      compactDiff: compactDiff
    )

    #expect(result.count == CommitMessageContext.maximumCharacters)
  }

  @Test func capturedProcessRunnerCollectsOutputAndExitStatus() async {
    let result = await CapturedProcessRunner().run(
      executable: "/bin/sh",
      arguments: ["-c", "printf 'standard output'; printf 'standard error' >&2; exit 3"],
      currentDirectory: "/tmp",
      displayCommand: "fixture command"
    )

    #expect(result.command == "fixture command")
    #expect(result.output.contains("standard output"))
    #expect(result.output.contains("standard error"))
    #expect(result.exitCode == 3)
  }

  @Test func projectIDsAreStableAndURLSafe() {
    let first = AgentProject(path: "/Users/example/projects/hello world")
    let second = AgentProject(path: "/Users/example/projects/hello world")

    #expect(first.id == second.id)
    #expect(!first.id.contains("/"))
    #expect(first.name == "hello world")
  }

  @Test func sessionStoreRoundTrips() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
    let project = AgentProject(path: "/tmp/example")
    var session = AgentSession(project: project)
    session.messages.append(AgentMessage(role: .user, text: "Hello"))
    session.isPinned = true
    session.queuedPrompts = [QueuedPrompt(text: "Follow up")]
    session.recordContentChange()

    try await store.save([session])
    let loaded = try await store.load()

    #expect(loaded.count == 1)
    #expect(loaded.first?.messages.first?.text == "Hello")
    #expect(loaded.first?.isPinned == true)
    #expect(loaded.first?.queuedPrompts.map(\.text) == ["Follow up"])
    #expect(loaded.first?.contentRevision == 1)
  }

  @Test func sessionStoreDoesNotPersistCurrentReasoning() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
    var session = AgentSession(project: AgentProject(path: "/tmp/example"))
    session.isRunning = true
    session.currentReasoning = "Checking the build output."

    try await store.save([session])
    let loaded = try await store.load()

    #expect(loaded.first?.isRunning == true)
    #expect(loaded.first?.currentReasoning == nil)
  }

  @Test func projectCommandResultStoreRoundTrips() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProjectCommandResultStore(
      fileURL: directory.appendingPathComponent("command-results.json")
    )
    let result = ProjectCommandResult(
      id: UUID(),
      sessionID: UUID(),
      projectPath: "/tmp/example",
      kind: .make,
      title: "Make test",
      command: "make test",
      output: "All tests passed",
      exitCode: 0,
      startedAt: Date(timeIntervalSince1970: 100),
      completedAt: Date(timeIntervalSince1970: 101)
    )

    try await store.save([result])
    let loaded = try await store.load()

    #expect(loaded == [result])
  }

  @Test func sessionAPIEncodingIncludesCurrentReasoning() throws {
    var session = AgentSession(project: AgentProject(path: "/tmp/example"))
    session.isRunning = true
    session.currentReasoning = "Checking the API response."

    let data = try JSONEncoder().encode(session)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(object["currentReasoning"] as? String == "Checking the API response.")
  }

  @MainActor
  @Test func sessionStatusEndpointAvoidsTranscriptPayloadAndAdvancesRevision() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("Example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    settings.apiToken = "test-token"
    let codex = ControllableCodexSender()
    let model = AppModel(
      settings: settings,
      store: SessionStore(fileURL: directory.appendingPathComponent("sessions.json")),
      activityStore: APIActivityStore(fileURL: directory.appendingPathComponent("activity.json")),
      codex: codex
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let session = try #require(model.createSession(projectID: project.id, select: false))
    let prompt = String(repeating: "Inspect the complete transcript carefully. ", count: 500)
    let turn = Task { await model.sendPrompt(prompt, to: session.id) }
    for _ in 0..<100 {
      if await codex.prompts.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    let runningResponse = await model.handleAPI(
      try apiRequest(
        method: "GET",
        path: RemoteAgentEndpoint.sessionStatus,
        query: ["ids": session.id.uuidString],
        token: settings.apiToken
      ))
    let runningStatuses = try decodeAPI([SessionStatusSnapshot].self, from: runningResponse)
    let runningStatus = try #require(runningStatuses.first)
    let fullResponse = await model.handleAPI(
      try apiRequest(method: "GET", path: RemoteAgentEndpoint.sessions, token: settings.apiToken)
    )

    #expect(runningResponse.status == 200)
    #expect(runningStatuses.count == 1)
    #expect(runningStatus.id == session.id)
    #expect(runningStatus.isRunning)
    #expect(runningStatus.messageCount == 1)
    #expect(runningStatus.contentRevision > session.contentRevision)
    #expect(runningResponse.body.count < 1_024)
    #expect(runningResponse.body.count * 10 < fullResponse.body.count)

    await codex.releaseFirstPrompt()
    await turn.value

    let completedResponse = await model.handleAPI(
      try apiRequest(
        method: "GET",
        path: RemoteAgentEndpoint.sessionStatus,
        query: ["ids": session.id.uuidString],
        token: settings.apiToken
      ))
    let completedStatus = try #require(
      try decodeAPI([SessionStatusSnapshot].self, from: completedResponse).first
    )
    #expect(!completedStatus.isRunning)
    #expect(completedStatus.messageCount == 2)
    #expect(completedStatus.contentRevision > runningStatus.contentRevision)
  }

  @Test func markdownParserPreservesBlockStructure() {
    let source = """
      Smoke test result: **1 of 3 content types passed.**

      ### Critical integrations

      - 🛑 **`dropbox-mcp`** — tools not available.
      - ✅ **Atlassian Rovo** — authenticated successfully.

      **Summary:** Rich text should keep its blocks.
      """

    let blocks = MarkdownBlockParser().parse(source)

    #expect(blocks.count == 4)
    #expect(blocks[0] == .paragraph("Smoke test result: **1 of 3 content types passed.**"))
    #expect(blocks[1] == .heading(level: 3, text: "Critical integrations"))
    #expect(
      blocks[2]
        == .unorderedList([
          "🛑 **`dropbox-mcp`** — tools not available.",
          "✅ **Atlassian Rovo** — authenticated successfully.",
        ]))
    #expect(blocks[3] == .paragraph("**Summary:** Rich text should keep its blocks."))
  }

  @Test func markdownParserHandlesCodeQuotesAndOrderedLists() {
    let source = """
      1. First
      2. Second

      > A quoted line

      ```swift
      print("hello")
      ```
      """

    let blocks = MarkdownBlockParser().parse(source)

    #expect(blocks[0] == .orderedList(["First", "Second"]))
    #expect(blocks[1] == .quote("A quoted line"))
    #expect(blocks[2] == .code(language: "swift", text: "print(\"hello\")"))
  }

  @Test func markdownParserRecognizesTablesAndColumnAlignment() {
    let source = """
      ## Team Review

      | Team | Capacity usage | Readout |
      | :--- | :---: | ---: |
      | Expansion | 99.39% | Monthly \\| weekly |
      | Formation | 69.19% |
      """

    let blocks = MarkdownBlockParser().parse(source)

    #expect(blocks.count == 2)
    #expect(blocks[0] == .heading(level: 2, text: "Team Review"))
    #expect(
      blocks[1]
        == .table(
          headers: ["Team", "Capacity usage", "Readout"],
          alignments: [.leading, .center, .trailing],
          rows: [
            ["Expansion", "99.39%", "Monthly \\| weekly"],
            ["Formation", "69.19%", ""],
          ]
        ))
  }

  @Test func projectsSortByMostRecentSessionThenAlphabetically() {
    let alpha = AgentProject(path: "/tmp/Alpha")
    let beta = AgentProject(path: "/tmp/Beta")
    let gamma = AgentProject(path: "/tmp/Gamma")
    var oldSession = AgentSession(project: alpha)
    oldSession.updatedAt = Date(timeIntervalSince1970: 100)
    var newSession = AgentSession(project: gamma)
    newSession.updatedAt = Date(timeIntervalSince1970: 200)

    let sorted = ProjectSorter.byMostRecentSession(
      [beta, alpha, gamma],
      sessions: [oldSession, newSession]
    )

    #expect(sorted.map(\.name) == ["Gamma", "Alpha", "Beta"])
  }

  @Test func recentSessionsSortGloballyAndCapAtFifty() {
    let projects = [
      AgentProject(path: "/tmp/Alpha"),
      AgentProject(path: "/tmp/Beta"),
    ]
    let sessions = (0..<55).map { index in
      var session = AgentSession(project: projects[index % projects.count])
      session.title = "Session \(index)"
      session.updatedAt = Date(timeIntervalSince1970: TimeInterval(index))
      return session
    }

    let recent = SessionSorter.mostRecent(sessions)

    #expect(recent.count == 50)
    #expect(recent.first?.title == "Session 54")
    #expect(recent.last?.title == "Session 5")
    #expect(Set(recent.map(\.projectName)) == Set(["Alpha", "Beta"]))
  }

  @Test func pinnedSessionsSortBeforeRecentUnpinnedSessions() {
    let project = AgentProject(path: "/tmp/Example")
    var olderPinned = AgentSession(project: project)
    olderPinned.title = "Older pinned"
    olderPinned.updatedAt = Date(timeIntervalSince1970: 100)
    olderPinned.isPinned = true
    var newerPinned = AgentSession(project: project)
    newerPinned.title = "Newer pinned"
    newerPinned.updatedAt = Date(timeIntervalSince1970: 200)
    newerPinned.isPinned = true
    var newestUnpinned = AgentSession(project: project)
    newestUnpinned.title = "Newest unpinned"
    newestUnpinned.updatedAt = Date(timeIntervalSince1970: 300)

    let sorted = SessionSorter.mostRecent([olderPinned, newestUnpinned, newerPinned])

    #expect(sorted.map(\.title) == ["Newer pinned", "Older pinned", "Newest unpinned"])
  }

  @Test func sessionListStatusPrioritizesActiveAndUnreadWork() {
    let project = AgentProject(path: "/tmp/Example")
    var session = AgentSession(project: project)
    #expect(session.listStatus == .newSession)

    session.messages.append(AgentMessage(role: .assistant, text: "Done"))
    #expect(session.listStatus == .ready)

    session.messages.append(
      AgentMessage(role: .system, text: "Failed", state: .failed)
    )
    #expect(session.listStatus == .failed)

    session.isUnread = true
    #expect(session.listStatus == .unread)

    session.isRunning = true
    #expect(session.listStatus == .running)
  }

  @Test func legacySessionsMigrateAsRead() throws {
    let session = AgentSession(project: AgentProject(path: "/tmp/legacy"))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(session)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "isUnread")
    object.removeValue(forKey: "isPinned")
    object.removeValue(forKey: "codexModel")
    object.removeValue(forKey: "contentRevision")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
      AgentSession.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(!decoded.isUnread)
    #expect(!decoded.isPinned)
    #expect(decoded.codexModel == nil)
    #expect(decoded.contentRevision == 0)
  }

  @MainActor
  @Test func codexModelSettingPersists() {
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = AppSettings(defaults: defaults)
    #expect(settings.codexModel.isEmpty)
    settings.codexModel = "gpt-example"

    #expect(AppSettings(defaults: defaults).codexModel == "gpt-example")
  }

  @MainActor
  @Test func codexModelDefaultsFutureSessionsWithoutChangingExistingSessions() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("Example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    let codex = ControllableCodexSender()
    let model = AppModel(
      settings: settings,
      store: SessionStore(fileURL: directory.appendingPathComponent("sessions.json")),
      codex: codex
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let existing = try #require(model.createSession(projectID: project.id, select: false))

    settings.codexModel = "  gpt-example  "
    model.applyCodexModel(settings.codexModel)
    let future = try #require(model.createSession(projectID: project.id, select: false))
    #expect(model.sessions.first(where: { $0.id == existing.id })?.codexModel == nil)
    #expect(future.codexModel == "gpt-example")

    let turn = Task { await model.sendPrompt("Test model", to: existing.id) }
    for _ in 0..<100 {
      if await codex.models.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await codex.models == [nil])
    await codex.releaseFirstPrompt()
    await turn.value
  }

  @MainActor
  @Test func fontScaleCommandsUpdateAndClampTheSetting() {
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)

    settings.increaseFontScale()
    #expect(abs(settings.fontScale - 1.1) < 0.001)
    settings.decreaseFontScale()
    #expect(abs(settings.fontScale - 1.0) < 0.001)
    settings.fontScale = 1.8
    settings.increaseFontScale()
    #expect(settings.fontScale == 1.8)
    settings.resetFontScale()
    #expect(settings.fontScale == 1.0)
  }

  @MainActor
  @Test func appearanceDefaultsToSystemAndPersistsDarkMode() {
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = AppSettings(defaults: defaults)
    #expect(settings.appearance == .system)
    #expect(settings.appearance.colorScheme == nil)

    settings.appearance = .dark
    let reloaded = AppSettings(defaults: defaults)

    #expect(reloaded.appearance == .dark)
    #expect(reloaded.appearance.colorScheme == .dark)
  }

  @Test func selectedMakeTargetPersistsWithItsSession() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
    var firstSession = AgentSession(project: AgentProject(path: "/tmp/example"))
    var secondSession = AgentSession(project: AgentProject(path: "/tmp/example"))
    firstSession.selectedMakeTarget = "test"
    secondSession.selectedMakeTarget = "build"

    try await store.save([firstSession, secondSession])
    let reloaded = try await store.load()

    #expect(reloaded.first(where: { $0.id == firstSession.id })?.selectedMakeTarget == "test")
    #expect(reloaded.first(where: { $0.id == secondSession.id })?.selectedMakeTarget == "build")
  }

  @MainActor
  @Test func makeCommandStoresOutputOutsideTranscriptPlaceholder() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("project", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    try """
    .PHONY: smoke
    smoke:
    \t@/bin/sleep 0.2
    \t@echo PRIVATE COMMAND OUTPUT
    """.write(
      to: projectDirectory.appendingPathComponent("Makefile"),
      atomically: true,
      encoding: .utf8
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    let model = AppModel(
      settings: settings,
      store: SessionStore(fileURL: directory.appendingPathComponent("sessions.json")),
      activityStore: APIActivityStore(fileURL: directory.appendingPathComponent("activity.json")),
      projectCommandResultStore: ProjectCommandResultStore(
        fileURL: directory.appendingPathComponent("command-results.json")
      )
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let session = try #require(model.createSession(projectID: project.id))

    let command = Task { await model.runActiveMakeTarget(sessionID: session.id) }
    try await Task.sleep(for: .milliseconds(50))

    let runningSession = try #require(model.sessions.first(where: { $0.id == session.id }))
    let runningPlaceholder = try #require(runningSession.messages.last)
    let runningResult = try #require(
      model.projectCommandResult(messageID: runningPlaceholder.id)
    )
    #expect(runningPlaceholder.state == .pending)
    #expect(runningPlaceholder.text == "Running make smoke… Click to view output.")
    #expect(runningResult.isRunning)

    await command.value

    let updatedSession = try #require(model.sessions.first(where: { $0.id == session.id }))
    let placeholder = try #require(updatedSession.messages.last)
    let result = try #require(model.projectCommandResult(messageID: placeholder.id))
    #expect(placeholder.id == runningPlaceholder.id)
    #expect(placeholder.state == .complete)
    #expect(placeholder.text == "Make smoke succeeded. Click to view output.")
    #expect(!placeholder.text.contains("PRIVATE COMMAND OUTPUT"))
    #expect(result.output.contains("PRIVATE COMMAND OUTPUT"))
    #expect(!result.isRunning)
  }

  @Test func gitCommitPrioritizesBehavioralContextForMessageGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let runner = CapturedProcessRunner()

    for arguments in [
      ["init"],
      ["config", "user.name", "Remote Agent Tests"],
      ["config", "user.email", "remote-agent-tests@example.invalid"],
    ] {
      let setup = await runner.run(
        executable: "/usr/bin/git",
        arguments: arguments,
        currentDirectory: directory.path,
        displayCommand: "git \(arguments.joined(separator: " "))"
      )
      #expect(setup.exitCode == 0)
    }
    try "- Enable completion notifications for background sessions.\n".write(
      to: directory.appendingPathComponent("CHANGELOG.md"),
      atomically: true,
      encoding: .utf8
    )
    try "struct BackgroundRefreshScheduler {}\n".write(
      to: directory.appendingPathComponent("BackgroundRefreshScheduler.swift"),
      atomically: true,
      encoding: .utf8
    )

    let generator = CapturingCommitMessageGenerator()
    let service = ProjectCommandService(runner: runner, commitMessageGenerator: generator)
    let outcome = await service.runGitCommitAndPush(projectPath: directory.path)
    let context = try #require(await generator.context)

    #expect(outcome.succeeded)
    #expect(context.summary.contains("CHANGELOG.md"))
    #expect(context.summary.contains("BackgroundRefreshScheduler.swift"))
    #expect(context.diff.contains("Enable completion notifications for background sessions"))
    #expect(!context.diff.contains("BackgroundRefreshScheduler"))
  }

  @Test func gitCommitAndPushCommitsAllChangesAndSilentlySkipsMissingUpstream() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let runner = CapturedProcessRunner()

    for arguments in [
      ["init"],
      ["config", "user.name", "Remote Agent Tests"],
      ["config", "user.email", "remote-agent-tests@example.invalid"],
    ] {
      let setup = await runner.run(
        executable: "/usr/bin/git",
        arguments: arguments,
        currentDirectory: directory.path,
        displayCommand: "git \(arguments.joined(separator: " "))"
      )
      #expect(setup.exitCode == 0)
    }
    try "untracked contents\n".write(
      to: directory.appendingPathComponent("untracked.txt"),
      atomically: true,
      encoding: .utf8
    )

    let service = ProjectCommandService(
      runner: runner,
      commitMessageGenerator: FixedCommitMessageGenerator(message: "Add untracked fixture")
    )
    let outcome = await service.runGitCommitAndPush(projectPath: directory.path)
    let subject = await runner.run(
      executable: "/usr/bin/git",
      arguments: ["log", "-1", "--pretty=%s"],
      currentDirectory: directory.path,
      displayCommand: "git log -1 --pretty=%s"
    )

    #expect(outcome.succeeded)
    #expect(outcome.command.hasPrefix("git add --all && git commit"))
    #expect(!outcome.command.contains("git push"))
    #expect(outcome.title == "Git Commit & Push: Add untracked fixture")
    #expect(
      subject.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Add untracked fixture")
  }

  @Test func gitCommitAndPushPushesWhenCurrentBranchHasUpstream() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let project = directory.appendingPathComponent("project", isDirectory: true)
    let remote = directory.appendingPathComponent("remote.git", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let runner = CapturedProcessRunner()

    let bareInit = await runner.run(
      executable: "/usr/bin/git",
      arguments: ["init", "--bare", remote.path],
      currentDirectory: directory.path,
      displayCommand: "git init --bare"
    )
    #expect(bareInit.exitCode == 0)
    for arguments in [
      ["init"],
      ["config", "user.name", "Remote Agent Tests"],
      ["config", "user.email", "remote-agent-tests@example.invalid"],
    ] {
      let setup = await runner.run(
        executable: "/usr/bin/git",
        arguments: arguments,
        currentDirectory: project.path,
        displayCommand: "git \(arguments.joined(separator: " "))"
      )
      #expect(setup.exitCode == 0)
    }
    try "initial\n".write(
      to: project.appendingPathComponent("fixture.txt"),
      atomically: true,
      encoding: .utf8
    )
    for arguments in [
      ["add", "--all"],
      ["commit", "-m", "Initial fixture"],
      ["remote", "add", "origin", remote.path],
      ["push", "--set-upstream", "origin", "HEAD"],
    ] {
      let setup = await runner.run(
        executable: "/usr/bin/git",
        arguments: arguments,
        currentDirectory: project.path,
        displayCommand: "git \(arguments.joined(separator: " "))"
      )
      #expect(setup.exitCode == 0)
    }
    try "updated\n".write(
      to: project.appendingPathComponent("fixture.txt"),
      atomically: true,
      encoding: .utf8
    )

    let service = ProjectCommandService(
      runner: runner,
      commitMessageGenerator: FixedCommitMessageGenerator(message: "Update fixture")
    )
    let outcome = await service.runGitCommitAndPush(projectPath: project.path)
    let remoteSubject = await runner.run(
      executable: "/usr/bin/git",
      arguments: ["--git-dir", remote.path, "log", "-1", "--pretty=%s"],
      currentDirectory: directory.path,
      displayCommand: "git log -1 --pretty=%s"
    )

    #expect(outcome.succeeded)
    #expect(outcome.command.contains("git push"))
    #expect(
      remoteSubject.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Update fixture")
  }

  @MainActor
  @Test func sessionRenamePersistsTitleWithoutChangingActivityTime() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("Example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    let model = AppModel(
      settings: settings,
      store: SessionStore(fileURL: directory.appendingPathComponent("sessions.json")),
      activityStore: APIActivityStore(fileURL: directory.appendingPathComponent("activity.json"))
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let session = try #require(model.createSession(projectID: project.id, select: false))

    let renamed = try model.renameSession(session.id, title: "  Release readiness  ")

    #expect(renamed.title == "Release readiness")
    #expect(renamed.updatedAt == session.updatedAt)
    #expect(model.sessions.first?.title == "Release readiness")

    do {
      _ = try model.renameSession(session.id, title: "   ")
      Issue.record("Expected an empty session title to be rejected")
    } catch {
      #expect(error.localizedDescription.contains("1 and 120"))
    }
  }

  @MainActor
  @Test func sessionPinningOrdersFirstAndDeletionPersists() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("Example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    let sessionFile = directory.appendingPathComponent("sessions.json")
    let store = SessionStore(fileURL: sessionFile)
    let model = AppModel(
      settings: settings,
      store: store,
      activityStore: APIActivityStore(fileURL: directory.appendingPathComponent("activity.json"))
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let first = try #require(model.createSession(projectID: project.id, select: false))
    let second = try #require(model.createSession(projectID: project.id, select: false))
    model.selectSession(first.id)

    let pinned = try model.setSessionPinned(first.id, isPinned: true)

    #expect(pinned.isPinned)
    #expect(model.recentSessions.first?.id == first.id)

    let deleted = try model.deleteSession(first.id)
    #expect(deleted.id == first.id)
    #expect(model.selectedSessionID == second.id)
    var persisted: [AgentSession] = []
    for _ in 0..<100 {
      persisted = try await store.load()
      if persisted.map(\.id) == [second.id] { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(persisted.map(\.id) == [second.id])
  }

  @MainActor
  @Test func sessionPinningAndDeletionAPIsPersistAndReturnUpdatedModels() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("Example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    settings.apiToken = "test-token"
    let model = AppModel(
      settings: settings,
      store: SessionStore(fileURL: directory.appendingPathComponent("sessions.json")),
      activityStore: APIActivityStore(fileURL: directory.appendingPathComponent("activity.json"))
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let older = try #require(model.createSession(projectID: project.id, select: false))
    _ = try #require(model.createSession(projectID: project.id, select: false))

    let pinResponse = await model.handleAPI(
      try apiRequest(
        method: "PATCH",
        path: "/v1/sessions/\(older.id.uuidString)",
        token: settings.apiToken,
        jsonBody: ["isPinned": true]
      ))
    #expect(pinResponse.status == 200)
    let pinned = try decodeAPI(AgentSession.self, from: pinResponse)
    #expect(pinned.id == older.id)
    #expect(pinned.isPinned)

    let listResponse = await model.handleAPI(
      try apiRequest(method: "GET", path: "/v1/sessions", token: settings.apiToken))
    let listed = try decodeAPI([AgentSession].self, from: listResponse)
    #expect(listed.first?.id == older.id)

    let deleteResponse = await model.handleAPI(
      try apiRequest(
        method: "DELETE",
        path: "/v1/sessions/\(older.id.uuidString)",
        token: settings.apiToken
      ))
    #expect(deleteResponse.status == 200)
    #expect(try decodeAPI(AgentSession.self, from: deleteResponse).id == older.id)
    #expect(!model.sessions.contains(where: { $0.id == older.id }))
  }

  @MainActor
  @Test func sessionUnreadAPIPersistsWithoutChangingActivityTime() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("Example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    settings.apiToken = "test-token"
    let store = SessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
    let model = AppModel(
      settings: settings,
      store: store,
      activityStore: APIActivityStore(fileURL: directory.appendingPathComponent("activity.json"))
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let session = try #require(model.createSession(projectID: project.id, select: false))

    let response = await model.handleAPI(
      try apiRequest(
        method: "POST",
        path: RemoteAgentEndpoint.sessionUnread(session.id),
        token: settings.apiToken
      ))

    #expect(response.status == 200)
    let unread = try decodeAPI(AgentSession.self, from: response)
    #expect(unread.isUnread)
    #expect(
      model.sessions.first(where: { $0.id == session.id })?.updatedAt == session.updatedAt
    )

    var persisted: [AgentSession] = []
    for _ in 0..<100 {
      persisted = try await store.load()
      if persisted.first?.isUnread == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(persisted.first?.isUnread == true)

    let readResponse = await model.handleAPI(
      try apiRequest(
        method: "POST",
        path: RemoteAgentEndpoint.sessionRead(session.id),
        token: settings.apiToken
      ))
    #expect(!(try decodeAPI(AgentSession.self, from: readResponse)).isUnread)
  }

  @MainActor
  @Test func hostOwnsEditsAndExecutesQueuedPromptsWithoutIOS() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("Example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    settings.apiToken = "test-token"
    let store = SessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
    let codex = ControllableCodexSender()
    let model = AppModel(
      settings: settings,
      store: store,
      activityStore: APIActivityStore(fileURL: directory.appendingPathComponent("activity.json")),
      codex: codex
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let session = try #require(model.createSession(projectID: project.id, select: false))

    let firstTurn = Task { await model.sendPrompt("Initial work", to: session.id) }
    for _ in 0..<100 {
      if await codex.prompts == ["Initial work"] { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let initialPrompts = await codex.prompts
    #expect(initialPrompts == ["Initial work"])

    let queuePath = RemoteAgentEndpoint.sessionPromptQueue(session.id)
    let firstQueueResponse = await model.handleAPI(
      try apiRequest(
        method: "POST",
        path: queuePath,
        token: settings.apiToken,
        jsonBody: ["text": "Original follow up"]
      ))
    #expect(firstQueueResponse.status == 201)
    let firstQueued = try decodeAPI(QueuedPrompt.self, from: firstQueueResponse)

    let secondQueueResponse = await model.handleAPI(
      try apiRequest(
        method: "POST",
        path: queuePath,
        token: settings.apiToken,
        jsonBody: ["text": "Remove this follow up"]
      ))
    let secondQueued = try decodeAPI(QueuedPrompt.self, from: secondQueueResponse)

    let editResponse = await model.handleAPI(
      try apiRequest(
        method: "PATCH",
        path: RemoteAgentEndpoint.sessionQueuedPrompt(session.id, promptID: firstQueued.id),
        token: settings.apiToken,
        jsonBody: ["text": "Edited follow up"]
      ))
    #expect(editResponse.status == 200)
    #expect(try decodeAPI(QueuedPrompt.self, from: editResponse).text == "Edited follow up")

    let deleteResponse = await model.handleAPI(
      try apiRequest(
        method: "DELETE",
        path: RemoteAgentEndpoint.sessionQueuedPrompt(session.id, promptID: secondQueued.id),
        token: settings.apiToken
      ))
    #expect(deleteResponse.status == 200)

    let sessionResponse = await model.handleAPI(
      try apiRequest(
        method: "GET",
        path: RemoteAgentEndpoint.session(session.id),
        token: settings.apiToken
      ))
    #expect(
      try decodeAPI(AgentSession.self, from: sessionResponse).queuedPrompts.map(\.text)
        == ["Edited follow up"]
    )

    await codex.releaseFirstPrompt()
    await firstTurn.value

    let executedPrompts = await codex.prompts
    #expect(executedPrompts == ["Initial work", "Edited follow up"])
    let completed = try #require(model.sessions.first(where: { $0.id == session.id }))
    #expect(completed.queuedPrompts.isEmpty)
    #expect(
      completed.messages.filter { $0.role == .user }.map(\.text) == [
        "Initial work", "Edited follow up",
      ])

    var persisted: [AgentSession] = []
    for _ in 0..<100 {
      persisted = try await store.load()
      if persisted.first?.queuedPrompts.isEmpty == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(persisted.first?.queuedPrompts.isEmpty == true)
  }

  @MainActor
  @Test func projectCommandAPIRunsMakeAndReturnsCapturedOutput() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDirectory = directory.appendingPathComponent("Example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    try """
    .PHONY: smoke
    smoke:
    \t@echo MOBILE COMMAND OUTPUT
    """.write(
      to: projectDirectory.appendingPathComponent("Makefile"),
      atomically: true,
      encoding: .utf8
    )
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.projectsRoot = directory.path
    settings.apiToken = "test-token"
    let model = AppModel(
      settings: settings,
      store: SessionStore(fileURL: directory.appendingPathComponent("sessions.json")),
      activityStore: APIActivityStore(fileURL: directory.appendingPathComponent("activity.json")),
      projectCommandResultStore: ProjectCommandResultStore(
        fileURL: directory.appendingPathComponent("command-results.json")
      )
    )
    await model.refreshProjects()
    let project = try #require(model.projects.first)
    let session = try #require(model.createSession(projectID: project.id, select: false))
    let commandsPath = RemoteAgentEndpoint.sessionProjectCommands(session.id)

    let configurationResponse = await model.handleAPI(
      try apiRequest(method: "GET", path: commandsPath, token: settings.apiToken))
    let configuration = try decodeAPI(
      ProjectCommandConfigurationResponse.self,
      from: configurationResponse
    )
    #expect(configuration.makeTargets == ["smoke"])
    #expect(configuration.selectedMakeTarget == "smoke")

    let selectionResponse = await model.handleAPI(
      try apiRequest(
        method: "PATCH",
        path: RemoteAgentEndpoint.session(session.id),
        token: settings.apiToken,
        jsonBody: ["selectedMakeTarget": "smoke"]
      ))
    #expect(selectionResponse.status == 200)
    #expect(try decodeAPI(AgentSession.self, from: selectionResponse).selectedMakeTarget == "smoke")

    let runResponse = await model.handleAPI(
      try apiRequest(
        method: "POST",
        path: commandsPath,
        token: settings.apiToken,
        jsonBody: ["action": "make", "target": "smoke"]
      ))
    #expect(runResponse.status == 202)

    var commandMessage: AgentMessage?
    for _ in 0..<100 {
      commandMessage = model.sessions.first(where: { $0.id == session.id })?.messages.last
      if commandMessage?.state == .complete { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let resultID = try #require(commandMessage?.projectCommandResultID)
    let resultResponse = await model.handleAPI(
      try apiRequest(
        method: "GET",
        path: RemoteAgentEndpoint.sessionProjectCommandResult(session.id, resultID: resultID),
        token: settings.apiToken
      ))
    let result = try decodeAPI(RemoteProjectCommandResult.self, from: resultResponse)
    #expect(result.succeeded)
    #expect(result.output.contains("MOBILE COMMAND OUTPUT"))
  }

  @Test func apiClientClassifierDistinguishesLoopbackAndRemoteHosts() {
    #expect(!APIClientClassifier.isRemote(host: "127.0.0.1"))
    #expect(!APIClientClassifier.isRemote(host: "::1"))
    #expect(!APIClientClassifier.isRemote(host: "[::1]"))
    #expect(APIClientClassifier.isRemote(host: "192.168.4.22"))
  }

  @Test func apiActivityStoreRoundTrips() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = APIActivityStore(fileURL: directory.appendingPathComponent("activity.json"))
    let entry = APIActivityEntry(
      timestamp: Date(timeIntervalSince1970: 100),
      remoteHost: "192.168.4.22",
      clientName: "Remote Agent iOS/1",
      method: "GET",
      path: "/v1/projects",
      statusCode: 200,
      responsePayloadByteCount: 4_096,
      durationMilliseconds: 12,
      isRemoteClient: true
    )

    try await store.save([entry])
    let loaded = try await store.load()

    #expect(loaded == [entry])
    #expect(loaded.first?.responsePayloadByteCount == 4_096)
  }

  @Test func apiActivityStoreLoadsEntriesWithoutPayloadSize() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("activity.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(
      """
      [{"id":"00000000-0000-0000-0000-000000000001","timestamp":"1970-01-01T00:01:40Z","remoteHost":"127.0.0.1","clientName":"Legacy","method":"GET","path":"/v1/health","statusCode":200,"durationMilliseconds":1,"isRemoteClient":false}]
      """.utf8
    ).write(to: fileURL)

    let loaded = try await APIActivityStore(fileURL: fileURL).load()

    #expect(loaded.count == 1)
    #expect(loaded.first?.responsePayloadByteCount == nil)
  }

  @Test func projectDocumentsAreRestrictedAndReadable() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let readmeURL = directory.appendingPathComponent("README.md")
    let htmlURL = directory.appendingPathComponent("index.html")
    let sourceURL = directory.appendingPathComponent("Source.swift")
    try Data("# Read me".utf8).write(to: readmeURL)
    try Data("<h1>Hello</h1>".utf8).write(to: htmlURL)
    try Data("let answer = 42".utf8).write(to: sourceURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)],
      ofItemAtPath: readmeURL.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 100)],
      ofItemAtPath: htmlURL.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 300)],
      ofItemAtPath: sourceURL.path)
    try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    let buildDirectory = directory.appendingPathComponent("build", isDirectory: true)
    try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(to: buildDirectory.appendingPathComponent("generated.md"))

    let service = ProjectDocumentService()
    let documents = try await service.list(projectPath: directory.path)

    #expect(documents.map(\.relativePath) == ["Source.swift", "README.md", "index.html"])
    #expect(documents.allSatisfy { $0.modifiedAt != nil })
    let markdown = try #require(documents.first(where: { $0.kind == .markdown }))
    let content = try await service.content(projectPath: directory.path, documentID: markdown.id)
    #expect(content.content == "# Read me")
    let code = try #require(documents.first(where: { $0.kind == .code }))
    let codeContent = try await service.content(projectPath: directory.path, documentID: code.id)
    #expect(codeContent.content == "let answer = 42")
  }

  @Test func projectDocumentsPermitContentAboveLegacyTwoMegabyteLimit() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let byteCount = 3 * 1_024 * 1_024
    try Data(repeating: 97, count: byteCount)
      .write(to: directory.appendingPathComponent("large.md"))

    let service = ProjectDocumentService()
    let document = try #require(await service.list(projectPath: directory.path).first)
    let content = try await service.content(projectPath: directory.path, documentID: document.id)

    #expect(ProjectDocumentService.maximumByteCount == 10 * 1_024 * 1_024)
    #expect(content.content.utf8.count == byteCount)
  }

  @Test func localLinkResolverHandlesAbsoluteAndRelativeDocuments() throws {
    let base = URL(fileURLWithPath: "/Users/example/project", isDirectory: true)
    let absolute = try #require(URL(string: "/Users/example/reports/status.md"))
    let relative = try #require(URL(string: "docs/guide.html"))
    let source = try #require(URL(string: "Sources/App.swift"))

    let absoluteDocument = try #require(
      LocalLinkResolver.document(for: absolute, relativeTo: base))
    let relativeDocument = try #require(
      LocalLinkResolver.document(for: relative, relativeTo: base))
    let sourceDocument = try #require(
      LocalLinkResolver.document(for: source, relativeTo: base))

    #expect(absoluteDocument.path == "/Users/example/reports/status.md")
    #expect(absoluteDocument.kind == .markdown)
    #expect(relativeDocument.path == "/Users/example/project/docs/guide.html")
    #expect(relativeDocument.kind == .html)
    #expect(sourceDocument.path == "/Users/example/project/Sources/App.swift")
    #expect(sourceDocument.kind == .code)
  }

  @Test func localLinkResolverLeavesWebLinksForTheSystem() throws {
    let web = try #require(URL(string: "https://example.com/report.html"))
    let base = URL(fileURLWithPath: "/Users/example/project", isDirectory: true)

    #expect(LocalLinkResolver.fileURL(for: web, relativeTo: base) == nil)
    #expect(LocalLinkResolver.document(for: web, relativeTo: base) == nil)
  }

  @Test func apiListenerAddressesFormatIPv4AndIPv6HealthURLs() throws {
    let ipv4 = APIListenerAddress(
      interfaceName: "en0",
      address: "192.168.1.20",
      family: .ipv4,
      isLoopback: false
    )
    let ipv6 = APIListenerAddress(
      interfaceName: "lo0",
      address: "::1",
      family: .ipv6,
      isLoopback: true
    )

    #expect(ipv4.endpoint(port: 8765) == "192.168.1.20:8765")
    #expect(ipv4.healthURL(port: 8765)?.absoluteString == "http://192.168.1.20:8765/v1/health")
    #expect(ipv6.endpoint(port: 8765) == "[::1]:8765")
    #expect(ipv6.healthURL(port: 8765)?.absoluteString == "http://[::1]:8765/v1/health")
  }

  @Test func apiListenerAddressResolverIncludesActiveLoopbackInterface() {
    let addresses = APIListenerAddressResolver.activeAddresses()

    #expect(
      addresses.contains {
        $0.interfaceName == "lo0" && $0.address == "127.0.0.1" && $0.family == .ipv4
      })
    #expect(Set(addresses).count == addresses.count)
  }

  @Test func apiHealthProbeUsesAuthenticatedHealthEndpoint() async throws {
    let token = "diagnostic-token"
    let server = RemoteAPIServer(advertisesBonjour: false) { request in
      guard request.path == RemoteAgentEndpoint.health,
        request.headers["authorization"] == "Bearer \(token)"
      else {
        return HTTPResponse(status: 401)
      }
      return HTTPResponse(
        status: 200,
        body: Data(#"{"status":"ok","version":"test-version"}"#.utf8)
      )
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer { server.stop() }
    let port = try await waitForBoundPort(server)
    let loopback = APIListenerAddress(
      interfaceName: "lo0",
      address: "127.0.0.1",
      family: .ipv4,
      isLoopback: true
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let success = try await APIHealthProbe.test(
      address: loopback,
      port: port,
      bearerToken: token,
      session: session
    )

    #expect(success.version == "test-version")
    #expect(success.durationMilliseconds >= 0)
  }

  @Test func httpParserAcceptsDuplicateQueryItemsWithoutCrashing() throws {
    let raw = "GET /v1/sessions?project_id=first&project_id=second HTTP/1.1\r\nHost: test\r\n\r\n"

    switch HTTPRequestParser.parse(buffer: Data(raw.utf8), remoteHost: "192.168.4.2") {
    case .request(let request):
      #expect(request.path == "/v1/sessions")
      #expect(request.query["project_id"] == "second")
    default:
      Issue.record("Expected a complete request")
    }
  }

  @Test func httpParserRejectsDangerousContentLengths() {
    let negative = "POST /v1/sessions HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
    let huge = "POST /v1/sessions HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"

    switch HTTPRequestParser.parse(buffer: Data(negative.utf8), remoteHost: "test") {
    case .failure(let response): #expect(response.status == 400)
    default: Issue.record("Expected negative Content-Length to fail")
    }
    switch HTTPRequestParser.parse(buffer: Data(huge.utf8), remoteHost: "test") {
    case .failure(let response): #expect(response.status == 413)
    default: Issue.record("Expected oversized Content-Length to fail")
    }
  }

  @Test func httpParserCapsHeadersAndWaitsForPartialBodies() {
    let oversized =
      "GET / HTTP/1.1\r\nX-Fill: "
      + String(repeating: "a", count: HTTPRequestParser.maximumHeaderByteCount)
    let partial = "POST /v1/sessions HTTP/1.1\r\nContent-Length: 5\r\n\r\n12"

    switch HTTPRequestParser.parse(buffer: Data(oversized.utf8), remoteHost: "test") {
    case .failure(let response): #expect(response.status == 431)
    default: Issue.record("Expected oversized headers to fail")
    }
    switch HTTPRequestParser.parse(buffer: Data(partial.utf8), remoteHost: "test") {
    case .incomplete: break
    default: Issue.record("Expected a partial body to remain incomplete")
    }
  }

  @Test func httpParserParsesHeadersOnceAcrossIncrementalBodyChunks() throws {
    var parser = HTTPRequestParser()
    let header = Data("POST /v1/sessions HTTP/1.1\r\nContent-Length: 5\r\n\r\n".utf8)

    for byte in header {
      switch parser.append(Data([byte]), remoteHost: "test") {
      case .incomplete: break
      default: Issue.record("Expected incremental headers to remain incomplete")
      }
    }
    #expect(parser.isWaitingForBody)
    switch parser.append(Data("12".utf8), remoteHost: "test") {
    case .incomplete: break
    default: Issue.record("Expected an incomplete body")
    }
    switch parser.append(Data("345".utf8), remoteHost: "test") {
    case .request(let request): #expect(request.body == Data("12345".utf8))
    default: Issue.record("Expected the completed incremental request")
    }
  }

  @Test func apiServerDeliversConcurrentAsyncResponsesAndReleasesConnections() async throws {
    let server = RemoteAPIServer(
      advertisesBonjour: false,
      configuration: RemoteAPIServerConfiguration(
        maximumConnections: 128,
        maximumConnectionsPerHost: 128
      )
    ) { request in
      await Task.yield()
      return HTTPResponse(
        status: 200,
        body: Data(request.path.utf8),
        contentType: "text/plain"
      )
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer { server.stop() }

    let port = try await waitForBoundPort(server)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<80 {
        group.addTask {
          let expectedPath = "/request/\(index)"
          let url = try #require(URL(string: "http://127.0.0.1:\(port)\(expectedPath)"))
          let (data, response) = try await session.data(from: url)
          guard let response = response as? HTTPURLResponse,
            response.statusCode == 200,
            data == Data(expectedPath.utf8)
          else { throw RemoteAgentTestFailure.unexpectedResponse }
        }
      }
      try await group.waitForAll()
    }

    try await waitForConnectionCount(server, equalTo: 0)
  }

  @Test func apiServerTimesOutSlowHeadersAndStalledBodies() async throws {
    let server = RemoteAPIServer(
      advertisesBonjour: false,
      configuration: RemoteAPIServerConfiguration(
        headerTimeout: 0.05,
        bodyIdleTimeout: 0.05,
        bodyTimeout: 0.2,
        responseWriteTimeout: 0.2
      )
    ) { _ in
      HTTPResponse(status: 200, body: Data("unexpected".utf8), contentType: "text/plain")
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer { server.stop() }
    let port = try await waitForBoundPort(server)

    let headerSocket = try openRawSocket(port: port)
    try writeRawRequest("GET /v1/health HTTP/1.1\r\nHost: test\r\n", to: headerSocket)
    let headerResponse = try readRawResponse(from: headerSocket)
    Darwin.close(headerSocket)
    #expect(headerResponse.contains("408 Request Timeout"))
    #expect(headerResponse.contains("Request headers timed out"))

    let bodySocket = try openRawSocket(port: port)
    try writeRawRequest(
      "POST /v1/sessions HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\n\r\n1",
      to: bodySocket
    )
    let bodyResponse = try readRawResponse(from: bodySocket)
    Darwin.close(bodySocket)
    #expect(bodyResponse.contains("408 Request Timeout"))
    #expect(bodyResponse.contains("Request body stalled"))
    try await waitForConnectionCount(server, equalTo: 0)
  }

  @Test func apiServerReleasesAClientThatDoesNotReadTheResponse() async throws {
    let handler = ServerHandlerCompletion()
    let server = RemoteAPIServer(
      advertisesBonjour: false,
      configuration: RemoteAPIServerConfiguration(responseWriteTimeout: 0.05)
    ) { _ in
      await handler.markFinished()
      return HTTPResponse(
        status: 200,
        body: Data(repeating: 97, count: 16 * 1_024 * 1_024),
        contentType: "application/octet-stream"
      )
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer { server.stop() }
    let port = try await waitForBoundPort(server)

    let socket = try openRawSocket(port: port)
    defer { Darwin.close(socket) }
    try writeRawRequest("GET /large HTTP/1.1\r\nHost: test\r\n\r\n", to: socket)
    await handler.waitUntilFinished()

    try await waitForConnectionCount(server, equalTo: 0)
  }

  @Test func apiServerDrainsLargeResponseBeforeClosingSlowClient() async throws {
    let payload = Data(repeating: 97, count: 4 * 1_024 * 1_024)
    let handler = ServerHandlerCompletion()
    let server = RemoteAPIServer(
      advertisesBonjour: false,
      configuration: RemoteAPIServerConfiguration(responseWriteTimeout: 5)
    ) { _ in
      await handler.markFinished()
      return HTTPResponse(
        status: 200,
        body: payload,
        contentType: "application/octet-stream"
      )
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer { server.stop() }
    let port = try await waitForBoundPort(server)

    let socket = try openRawSocket(port: port, receiveBufferSize: 4_096)
    try writeRawRequest("GET /large HTTP/1.1\r\nHost: test\r\n\r\n", to: socket)
    await handler.waitUntilFinished()
    try await Task.sleep(for: .milliseconds(100))

    let response = try await Task.detached { try readRawResponseData(from: socket) }.value
    Darwin.close(socket)
    let separator = Data("\r\n\r\n".utf8)
    let headerRange = try #require(response.range(of: separator))
    let headers = String(decoding: response[..<headerRange.lowerBound], as: UTF8.self)
    #expect(headers.contains("HTTP/1.1 200 OK"))
    #expect(headers.contains("Content-Length: \(payload.count)"))
    #expect(response[headerRange.upperBound...] == payload)
    try await waitForConnectionCount(server, equalTo: 0)
  }

  @Test func apiServerCompressesNegotiatedLargeResponseForURLSession() async throws {
    let payload = Data(repeating: 97, count: 512 * 1_024)
    let server = RemoteAPIServer(advertisesBonjour: false) { _ in
      HTTPResponse(
        status: 200,
        body: payload,
        contentType: "application/octet-stream"
      )
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer { server.stop() }
    let port = try await waitForBoundPort(server)

    let url = try #require(URL(string: "http://127.0.0.1:\(port)/large"))
    var request = URLRequest(url: url)
    request.setValue("deflate", forHTTPHeaderField: "Accept-Encoding")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let (data, response) = try await session.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(
      (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Encoding") == "deflate")
    #expect(data == payload)
    try await waitForConnectionCount(server, equalTo: 0)
  }

  @Test func apiServerReservesCapacityForHealthAndSessionStatusRequests() async throws {
    let gate = ServerHandlerGate()
    let server = RemoteAPIServer(
      advertisesBonjour: false,
      configuration: RemoteAPIServerConfiguration(
        maximumConnections: 3,
        priorityConnectionReserve: 2,
        maximumConnectionsPerHost: 3,
        priorityConnectionReservePerHost: 2,
        handlerTimeout: 5
      )
    ) { request in
      if request.path == "/slow" { await gate.wait() }
      return HTTPResponse(status: 200, body: Data(request.path.utf8), contentType: "text/plain")
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer {
      Task { await gate.release() }
      server.stop()
    }

    let port = try await waitForBoundPort(server)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let slowURL = try #require(URL(string: "http://127.0.0.1:\(port)/slow"))
    let slowRequest = Task { try await session.data(from: slowURL) }
    await gate.waitUntilStarted()

    let healthURL = try #require(URL(string: "http://127.0.0.1:\(port)/v1/health"))
    let (healthData, healthResponse) = try await session.data(from: healthURL)
    #expect((healthResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(healthData == Data("/v1/health".utf8))
    try await waitForConnectionCount(server, equalTo: 1)

    let statusURL = try #require(
      URL(
        string:
          "http://127.0.0.1:\(port)/v1/session-status?ids=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    )
    let (statusData, statusResponse) = try await session.data(from: statusURL)
    #expect((statusResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(statusData == Data("/v1/session-status".utf8))
    try await waitForConnectionCount(server, equalTo: 1)

    let ordinaryURL = try #require(URL(string: "http://127.0.0.1:\(port)/ordinary"))
    let (_, ordinaryResponse) = try await session.data(from: ordinaryURL)
    #expect((ordinaryResponse as? HTTPURLResponse)?.statusCode == 503)
    #expect((ordinaryResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") == "1")

    slowRequest.cancel()
    await gate.release()
    _ = try? await slowRequest.value
  }

  @Test func apiHandlerDeadlineClosesResponseButLetsAcceptedWorkFinish() async throws {
    let completion = ServerHandlerCompletion()
    let server = RemoteAPIServer(
      advertisesBonjour: false,
      configuration: RemoteAPIServerConfiguration(
        handlerTimeout: 0.05,
        responseWriteTimeout: 0.2
      )
    ) { _ in
      try? await Task.sleep(for: .milliseconds(150))
      await completion.markFinished()
      return HTTPResponse(status: 200, body: Data("finished".utf8), contentType: "text/plain")
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer { server.stop() }

    let port = try await waitForBoundPort(server)
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/slow"))
    let (data, response) = try await URLSession.shared.data(from: url)

    #expect((response as? HTTPURLResponse)?.statusCode == 504)
    #expect(String(decoding: data, as: UTF8.self).contains("still running"))
    await completion.waitUntilFinished()
    #expect(await completion.isFinished)
  }

  @Test func closingClientConnectionDoesNotCancelAcceptedHandlerWork() async throws {
    let gate = ServerHandlerGate()
    let completion = ServerHandlerCompletion()
    let server = RemoteAPIServer(advertisesBonjour: false) { _ in
      await gate.wait()
      await completion.markFinished()
      return HTTPResponse(status: 200, body: Data("finished".utf8), contentType: "text/plain")
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer {
      Task { await gate.release() }
      server.stop()
    }

    let port = try await waitForBoundPort(server)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 1
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/disconnect"))
    let request = Task { try await session.data(from: url) }
    await gate.waitUntilStarted()
    request.cancel()
    _ = try? await request.value

    await gate.release()
    await completion.waitUntilFinished()
    #expect(await completion.isFinished)
  }

  @Test func disconnectedWorkStillConsumesBoundedHandlerCapacity() async throws {
    let gate = ServerHandlerGate()
    let server = RemoteAPIServer(
      advertisesBonjour: false,
      configuration: RemoteAPIServerConfiguration(
        maximumHandlers: 2,
        priorityHandlerReserve: 1,
        maximumHandlersPerHost: 2,
        priorityHandlerReservePerHost: 1,
        handlerTimeout: 0.05,
        responseWriteTimeout: 0.1
      )
    ) { request in
      if request.path == "/slow" { await gate.wait() }
      return HTTPResponse(status: 200, body: Data(request.path.utf8), contentType: "text/plain")
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer {
      Task { await gate.release() }
      server.stop()
    }

    let port = try await waitForBoundPort(server)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let slowSocket = try openRawSocket(port: port)
    try writeRawRequest("GET /slow HTTP/1.1\r\nHost: test\r\n\r\n", to: slowSocket)
    await gate.waitUntilStarted()
    Darwin.close(slowSocket)
    try await waitForConnectionCount(server, equalTo: 0)

    let ordinaryURL = try #require(URL(string: "http://127.0.0.1:\(port)/ordinary"))
    let (_, ordinaryResponse) = try await session.data(from: ordinaryURL)
    #expect((ordinaryResponse as? HTTPURLResponse)?.statusCode == 503)

    let healthURL = try #require(URL(string: "http://127.0.0.1:\(port)/v1/health"))
    let (healthData, healthResponse) = try await session.data(from: healthURL)
    #expect((healthResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(healthData == Data("/v1/health".utf8))

    await gate.release()
  }

  @Test func stoppingAPIClosesActiveConnectionsAndAllowsImmediateRestart() async throws {
    let server = RemoteAPIServer(advertisesBonjour: false) { request in
      if request.path == "/slow" {
        try? await Task.sleep(for: .milliseconds(500))
      }
      return HTTPResponse(status: 200, body: Data("ok".utf8), contentType: "text/plain")
    } stateChanged: { _ in
    }
    try server.start(port: 0)
    defer { server.stop() }

    let initialPort = try await waitForBoundPort(server)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let slowURL = try #require(URL(string: "http://127.0.0.1:\(initialPort)/slow"))
    let slowRequest = Task { try await session.data(from: slowURL) }
    try await waitForConnectionCount(server, equalTo: 1)

    await server.stopAndWait()
    #expect(server.activeConnectionCount == 0)
    do {
      _ = try await slowRequest.value
      Issue.record("Expected stopping the listener to close the active request")
    } catch {}

    try await server.startAndWait(port: initialPort)
    let restartedPort = try await waitForBoundPort(server)
    #expect(restartedPort == initialPort)
    let healthURL = try #require(URL(string: "http://127.0.0.1:\(restartedPort)/health"))
    let (data, response) = try await session.data(from: healthURL)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data == Data("ok".utf8))
  }

  @Test func apiActivityBatcherPublishesReconnectBurstsAsOneUpdate() async {
    let capture = APIActivityBatchCapture()
    let batcher = APIActivityBatcher(flushDelay: .seconds(10)) { entries in
      await capture.append(entries)
    }

    for index in 0..<100 {
      await batcher.record(
        APIActivityEntry(
          remoteHost: "192.168.1.\(index % 10)",
          clientName: "Reconnect test",
          method: "GET",
          path: "/v1/health",
          statusCode: 200,
          durationMilliseconds: index,
          isRemoteClient: true
        ))
    }
    #expect(await capture.batches.isEmpty)

    await batcher.flushNow()

    let batches = await capture.batches
    #expect(batches.count == 1)
    #expect(batches.first?.count == 100)
  }

  @Test func apiAuthenticationRequiresAnExactBearerToken() {
    #expect(APIAuthentication.matches(authorizationHeader: "Bearer secret", token: "secret"))
    #expect(!APIAuthentication.matches(authorizationHeader: "Bearer secrets", token: "secret"))
    #expect(!APIAuthentication.matches(authorizationHeader: "bearer secret", token: "secret"))
    #expect(!APIAuthentication.matches(authorizationHeader: nil, token: "secret"))
  }

  @MainActor
  @Test func crashRelaunchDefaultsToEnabledAndPersists() {
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initial = AppSettings(defaults: defaults)
    #expect(initial.autoRelaunchAfterCrash)
    initial.autoRelaunchAfterCrash = false

    let restored = AppSettings(defaults: defaults)
    #expect(!restored.autoRelaunchAfterCrash)
  }

  @MainActor
  @Test func invalidAPIPortsAreRejectedInsteadOfClamped() {
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.apiPort = 70_000
    let model = AppModel(settings: settings)

    model.restartAPI()

    #expect(model.apiStatus == "API failed: port must be between 1 and 65535")
  }

  @MainActor
  @Test func appModelRetriesAddressInUseUntilFixedPortIsReleased() async throws {
    let suiteName = "RemoteAgentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let blocker = RemoteAPIServer(advertisesBonjour: false) { _ in
      HTTPResponse(status: 200)
    } stateChanged: { _ in
    }
    try await blocker.startAndWait(port: 0)
    defer { blocker.stop() }
    let port = try #require(blocker.boundPort)
    let settings = AppSettings(defaults: defaults)
    settings.apiPort = Int(port)
    let model = AppModel(settings: settings, advertisesAPIWithBonjour: false)

    model.restartAPI()
    for _ in 0..<100 {
      if model.apiStatus.contains("still releasing") { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.apiStatus.contains("still releasing"))

    await blocker.stopAndWait()
    for _ in 0..<200 {
      if model.apiListeningPort == port { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.apiListeningPort == port)
    #expect(model.apiStatus == "Listening on all interfaces · port \(port)")

    let healthURL = try #require(URL(string: "http://127.0.0.1:\(port)/v1/health"))
    var healthRequest = URLRequest(url: healthURL)
    healthRequest.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
    let (healthData, healthResponse) = try await URLSession.shared.data(for: healthRequest)
    #expect((healthResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: healthData, as: UTF8.self).contains(#""status":"ok""#))

    settings.apiEnabled = false
    model.restartAPI()
    for _ in 0..<100 {
      if model.apiStatus == "API disabled" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.apiStatus == "API disabled")
  }
}

private func apiRequest(
  method: String,
  path: String,
  query: [String: String] = [:],
  token: String,
  jsonBody: [String: Any]? = nil
) throws -> HTTPRequest {
  HTTPRequest(
    method: method,
    path: path,
    query: query,
    headers: ["authorization": "Bearer \(token)"],
    body: try jsonBody.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data(),
    remoteHost: "192.168.4.2"
  )
}

private func decodeAPI<Value: Decodable>(
  _ type: Value.Type,
  from response: HTTPResponse
) throws -> Value {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(type, from: response.body)
}

private actor APIActivityBatchCapture {
  private(set) var batches: [[APIActivityEntry]] = []

  func append(_ entries: [APIActivityEntry]) {
    batches.append(entries)
  }
}

private actor ServerHandlerGate {
  private var started = false
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    started = true
    guard !released else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func waitUntilStarted() async {
    while !started { await Task.yield() }
  }

  func release() {
    released = true
    let continuations = waiters
    waiters.removeAll()
    for continuation in continuations { continuation.resume() }
  }
}

private actor ServerHandlerCompletion {
  private(set) var isFinished = false

  func markFinished() {
    isFinished = true
  }

  func waitUntilFinished() async {
    while !isFinished { await Task.yield() }
  }
}

private enum RemoteAgentTestFailure: Error {
  case timeout
  case unexpectedResponse
  case socketFailure(String)
}

private func openRawSocket(port: UInt16, receiveBufferSize: Int32? = nil) throws -> Int32 {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw RemoteAgentTestFailure.socketFailure("socket") }
  var noSignal: Int32 = 1
  setsockopt(
    descriptor,
    SOL_SOCKET,
    SO_NOSIGPIPE,
    &noSignal,
    socklen_t(MemoryLayout.size(ofValue: noSignal))
  )
  var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
  setsockopt(
    descriptor,
    SOL_SOCKET,
    SO_RCVTIMEO,
    &receiveTimeout,
    socklen_t(MemoryLayout.size(ofValue: receiveTimeout))
  )
  if var receiveBufferSize {
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVBUF,
      &receiveBufferSize,
      socklen_t(MemoryLayout.size(ofValue: receiveBufferSize))
    )
  }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
    Darwin.close(descriptor)
    throw RemoteAgentTestFailure.socketFailure("inet_pton")
  }
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
      Darwin.connect(
        descriptor,
        addressPointer,
        socklen_t(MemoryLayout<sockaddr_in>.size)
      )
    }
  }
  guard result == 0 else {
    Darwin.close(descriptor)
    throw RemoteAgentTestFailure.socketFailure("connect")
  }
  return descriptor
}

private func writeRawRequest(_ request: String, to descriptor: Int32) throws {
  let data = Data(request.utf8)
  let sent = data.withUnsafeBytes { bytes in
    Darwin.send(descriptor, bytes.baseAddress, bytes.count, 0)
  }
  guard sent == data.count else { throw RemoteAgentTestFailure.socketFailure("send") }
}

private func readRawResponse(from descriptor: Int32) throws -> String {
  String(decoding: try readRawResponseData(from: descriptor), as: UTF8.self)
}

private func readRawResponseData(from descriptor: Int32) throws -> Data {
  var response = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while true {
    let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
    if count == 0 { break }
    guard count > 0 else {
      if errno == EAGAIN || errno == EWOULDBLOCK { break }
      throw RemoteAgentTestFailure.socketFailure("recv")
    }
    response.append(contentsOf: buffer.prefix(count))
  }
  return response
}

private func waitForBoundPort(_ server: RemoteAPIServer) async throws -> UInt16 {
  for _ in 0..<200 {
    if let port = server.boundPort, port != 0 { return port }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RemoteAgentTestFailure.timeout
}

private func waitForConnectionCount(
  _ server: RemoteAPIServer,
  equalTo expectedCount: Int
) async throws {
  for _ in 0..<200 {
    if server.activeConnectionCount == expectedCount { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RemoteAgentTestFailure.timeout
}
