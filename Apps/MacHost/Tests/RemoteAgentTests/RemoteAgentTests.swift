import Foundation
import RemoteAgentProtocol
import Testing

@testable import RemoteAgent

private struct FixedCommitMessageGenerator: CommitMessageGenerating {
  let message: String

  func generate(stagedSummary _: String, stagedDiff _: String) async throws -> String {
    message
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

    try await store.save([session])
    let loaded = try await store.load()

    #expect(loaded.count == 1)
    #expect(loaded.first?.messages.first?.text == "Hello")
    #expect(loaded.first?.isPinned == true)
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

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
      AgentSession.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(!decoded.isUnread)
    #expect(!decoded.isPinned)
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
      durationMilliseconds: 12,
      isRemoteClient: true
    )

    try await store.save([entry])
    let loaded = try await store.load()

    #expect(loaded == [entry])
  }

  @Test func projectDocumentsAreRestrictedAndReadable() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("# Read me".utf8).write(to: directory.appendingPathComponent("README.md"))
    try Data("<h1>Hello</h1>".utf8).write(to: directory.appendingPathComponent("index.html"))
    try Data("let answer = 42".utf8).write(to: directory.appendingPathComponent("Source.swift"))
    try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    let buildDirectory = directory.appendingPathComponent("build", isDirectory: true)
    try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
    try Data("ignored".utf8).write(to: buildDirectory.appendingPathComponent("generated.md"))

    let service = ProjectDocumentService()
    let documents = try await service.list(projectPath: directory.path)

    #expect(documents.map(\.relativePath) == ["index.html", "README.md", "Source.swift"])
    let markdown = try #require(documents.first(where: { $0.kind == .markdown }))
    let content = try await service.content(projectPath: directory.path, documentID: markdown.id)
    #expect(content.content == "# Read me")
    let code = try #require(documents.first(where: { $0.kind == .code }))
    let codeContent = try await service.content(projectPath: directory.path, documentID: code.id)
    #expect(codeContent.content == "let answer = 42")
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
}

private func apiRequest(
  method: String,
  path: String,
  token: String,
  jsonBody: [String: Any]? = nil
) throws -> HTTPRequest {
  HTTPRequest(
    method: method,
    path: path,
    query: [:],
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
