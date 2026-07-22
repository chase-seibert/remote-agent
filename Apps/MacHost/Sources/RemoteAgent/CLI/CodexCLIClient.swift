import Foundation
import RemoteAgentProtocol

typealias CodexEventHandler = @Sendable (CodexJSONLEvent) -> Void

protocol CodexSending: Sendable {
  func send(
    prompt: String,
    projectPath: String,
    existingSessionID: String?,
    configuredExecutable: String,
    model: String?,
    onEvent: CodexEventHandler?
  ) async throws -> CodexTurnResult
}

protocol CodexModelListing: Sendable {
  func listModels(configuredExecutable: String) async throws -> [CodexModelOption]
}

enum CodexModelCatalogError: LocalizedError {
  case invalidOutput

  var errorDescription: String? {
    "Codex returned an unreadable model catalog."
  }
}

final class CodexModelCatalogClient: CodexModelListing, @unchecked Sendable {
  func listModels(configuredExecutable: String) async throws -> [CodexModelOption] {
    let executable = try CodexCLIClient.resolveExecutable(configuredExecutable)
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          continuation.resume(returning: try self.run(executable: executable))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func run(executable: String) throws -> [CodexModelOption] {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let collector = CodexProcessOutputCollector()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["debug", "models"]
    process.standardOutput = stdout
    process.standardError = stderr

    stdout.fileHandleForReading.readabilityHandler = { handle in
      _ = collector.appendStdout(handle.availableData)
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
      collector.appendStderr(handle.availableData)
    }

    try process.run()
    process.waitUntilExit()
    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil
    _ = collector.appendStdout(stdout.fileHandleForReading.readDataToEndOfFile())
    collector.appendStderr(stderr.fileHandleForReading.readDataToEndOfFile())

    let (output, errorOutput) = collector.strings()
    guard process.terminationStatus == 0 else {
      let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      throw RemoteAgentError.commandFailed(
        detail.isEmpty ? "Codex model discovery failed." : detail
      )
    }
    return try Self.parse(data: Data(output.utf8))
  }

  static func parse(data: Data) throws -> [CodexModelOption] {
    struct Catalog: Decodable { let models: [Model] }
    struct Model: Decodable {
      let slug: String
      let displayName: String
      let description: String
      let visibility: String
      let priority: Int

      private enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case description
        case visibility
        case priority
      }
    }

    guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
      throw CodexModelCatalogError.invalidOutput
    }
    var seen = Set<String>()
    return catalog.models
      .filter { $0.visibility == "list" && seen.insert($0.slug).inserted }
      .sorted {
        $0.priority == $1.priority
          ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
          : $0.priority < $1.priority
      }
      .map {
        CodexModelOption(id: $0.slug, displayName: $0.displayName, description: $0.description)
      }
  }
}

final class CodexCLIClient: CodexSending, @unchecked Sendable {
  typealias EventHandler = CodexEventHandler

  func send(
    prompt: String,
    projectPath: String,
    existingSessionID: String?,
    configuredExecutable: String,
    model: String?,
    onEvent: EventHandler? = nil
  ) async throws -> CodexTurnResult {
    let executable = try Self.resolveExecutable(configuredExecutable)
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let result = try self.run(
            executable: executable,
            prompt: prompt,
            projectPath: projectPath,
            existingSessionID: existingSessionID,
            model: model,
            onEvent: onEvent
          )
          continuation.resume(returning: result)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func run(
    executable: String,
    prompt: String,
    projectPath: String,
    existingSessionID: String?,
    model: String?,
    onEvent: EventHandler?
  ) throws -> CodexTurnResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = Pipe()

    process.executableURL = URL(fileURLWithPath: executable)
    process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
    process.arguments = Self.arguments(
      projectPath: projectPath,
      existingSessionID: existingSessionID,
      model: model
    )
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = stdin

    let collector = CodexProcessOutputCollector()

    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      for line in collector.appendStdout(data) {
        if let event = CodexJSONLEvent(line: line) { onEvent?(event) }
      }
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      collector.appendStderr(data)
    }

    try process.run()
    stdin.fileHandleForWriting.write(Data(prompt.utf8))
    stdin.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil

    for line in collector.appendStdout(stdout.fileHandleForReading.readDataToEndOfFile()) {
      if let event = CodexJSONLEvent(line: line) { onEvent?(event) }
    }
    collector.appendStderr(stderr.fileHandleForReading.readDataToEndOfFile())
    if let line = collector.finishLine(), let event = CodexJSONLEvent(line: line) {
      onEvent?(event)
    }

    let (output, errorOutput) = collector.strings()
    guard process.terminationStatus == 0 else {
      let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      throw RemoteAgentError.commandFailed(
        detail.isEmpty ? "Codex exited with status \(process.terminationStatus)." : detail
      )
    }

    var accumulator = CodexEventAccumulator()
    for line in output.split(whereSeparator: \Character.isNewline) {
      accumulator.consume(line: String(line))
    }
    if let error = accumulator.lastError {
      throw RemoteAgentError.commandFailed(error)
    }
    guard let sessionID = accumulator.sessionID ?? existingSessionID,
      let response = accumulator.assistantMessages.last,
      !response.isEmpty
    else { throw RemoteAgentError.invalidCodexOutput }

    return CodexTurnResult(sessionID: sessionID, response: response)
  }

  static func arguments(
    projectPath: String,
    existingSessionID: String?,
    model: String?
  ) -> [String] {
    let modelArguments = model.map { ["--model", $0] } ?? []
    if let existingSessionID {
      return [
        "exec", "resume", "--json", "--skip-git-repo-check",
        "-c", "hide_agent_reasoning=false",
        "-c", "show_raw_agent_reasoning=false",
        "-c", "model_reasoning_summary=auto",
      ] + modelArguments + [existingSessionID, "-"]
    }
    return [
      "exec", "--json", "--color", "never", "--skip-git-repo-check",
      "-c", "hide_agent_reasoning=false",
      "-c", "show_raw_agent_reasoning=false",
      "-c", "model_reasoning_summary=auto",
    ] + modelArguments + ["-C", projectPath, "-"]
  }

  static func resolveExecutable(_ configuredPath: String) throws -> String {
    let manager = FileManager.default
    let candidates = [
      configuredPath,
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
    ].filter { !$0.isEmpty }

    guard let path = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) else {
      throw RemoteAgentError.codexNotFound
    }
    return path
  }
}

private final class CodexProcessOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var outputData = Data()
  private var errorData = Data()
  private var lineBuffer = JSONLLineBuffer()

  func appendStdout(_ data: Data) -> [String] {
    guard !data.isEmpty else { return [] }
    lock.lock()
    outputData.append(data)
    let lines = lineBuffer.append(data)
    lock.unlock()
    return lines
  }

  func appendStderr(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    errorData.append(data)
    lock.unlock()
  }

  func finishLine() -> String? {
    lock.lock()
    let line = lineBuffer.finish()
    lock.unlock()
    return line
  }

  func strings() -> (output: String, error: String) {
    lock.lock()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    let error = String(data: errorData, encoding: .utf8) ?? ""
    lock.unlock()
    return (output, error)
  }
}
