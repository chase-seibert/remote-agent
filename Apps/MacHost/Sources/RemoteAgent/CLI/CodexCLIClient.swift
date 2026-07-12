import Foundation

final class CodexCLIClient: @unchecked Sendable {
  typealias EventHandler = @Sendable (String) -> Void

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
        existingSessionID, "-",
      ]
    } else {
      process.arguments = [
        "exec", "--json", "--color", "never", "--skip-git-repo-check",
        "-C", projectPath, "-",
      ]
    }
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = stdin

    let outputLock = NSLock()
    var outputData = Data()
    var errorData = Data()

    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      outputLock.lock()
      outputData.append(data)
      outputLock.unlock()
      if let chunk = String(data: data, encoding: .utf8) {
        for line in chunk.split(separator: "\n") {
          onEvent?(String(line))
        }
      }
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      outputLock.lock()
      errorData.append(data)
      outputLock.unlock()
    }

    try process.run()
    stdin.fileHandleForWriting.write(Data(prompt.utf8))
    stdin.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil

    outputLock.lock()
    outputData.append(stdout.fileHandleForReading.readDataToEndOfFile())
    errorData.append(stderr.fileHandleForReading.readDataToEndOfFile())
    outputLock.unlock()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
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
