import Foundation

typealias CodexEventHandler = @Sendable (CodexJSONLEvent) -> Void

protocol CodexSending: Sendable {
  func send(
    prompt: String,
    projectPath: String,
    existingSessionID: String?,
    configuredExecutable: String,
    onEvent: CodexEventHandler?
  ) async throws -> CodexTurnResult
}

final class CodexCLIClient: CodexSending, @unchecked Sendable {
  typealias EventHandler = CodexEventHandler

  func send(
    prompt: String,
    projectPath: String,
    existingSessionID: String?,
    configuredExecutable: String,
    onEvent: EventHandler? = nil
  ) async throws -> CodexTurnResult {
    let executable = try resolveExecutable(configuredExecutable)
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let result = try self.run(
            executable: executable,
            prompt: prompt,
            projectPath: projectPath,
            existingSessionID: existingSessionID,
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
    onEvent: EventHandler?
  ) throws -> CodexTurnResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = Pipe()

    process.executableURL = URL(fileURLWithPath: executable)
    process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
    if let existingSessionID {
      process.arguments = [
        "exec", "resume", "--json", "--skip-git-repo-check",
        "-c", "hide_agent_reasoning=false",
        "-c", "show_raw_agent_reasoning=false",
        "-c", "model_reasoning_summary=auto",
        existingSessionID, "-",
      ]
    } else {
      process.arguments = [
        "exec", "--json", "--color", "never", "--skip-git-repo-check",
        "-c", "hide_agent_reasoning=false",
        "-c", "show_raw_agent_reasoning=false",
        "-c", "model_reasoning_summary=auto",
        "-C", projectPath, "-",
      ]
    }
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

  private func resolveExecutable(_ configuredPath: String) throws -> String {
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
