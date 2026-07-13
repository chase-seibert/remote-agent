import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

enum MakeTargetDiscovery {
  static func targets(projectPath: String) -> [String] {
    let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    for name in ["GNUmakefile", "makefile", "Makefile"] {
      let makefileURL = projectURL.appendingPathComponent(name)
      if let contents = try? String(contentsOf: makefileURL, encoding: .utf8) {
        return targets(makefileContents: contents)
      }
    }
    return []
  }

  static func targets(makefileContents: String) -> [String] {
    let logicalLines = joinedContinuationLines(makefileContents)
    let phonyTargets = logicalLines.flatMap { line -> [String] in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(".PHONY:"), let colon = trimmed.firstIndex(of: ":") else {
        return []
      }
      return targetNames(in: String(trimmed[trimmed.index(after: colon)...]))
    }
    if !phonyTargets.isEmpty { return unique(phonyTargets) }

    let declaredTargets = logicalLines.flatMap { line -> [String] in
      guard line.first?.isWhitespace != true, let colon = line.firstIndex(of: ":") else {
        return []
      }
      let declaration = String(line[..<colon])
      let afterColon = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !declaration.contains("="), !declaration.contains("%"), !afterColon.hasPrefix("=")
      else { return [] }
      return targetNames(in: declaration).filter { !$0.hasPrefix(".") }
    }
    return unique(declaredTargets)
  }

  private static func joinedContinuationLines(_ contents: String) -> [String] {
    var result: [String] = []
    var current = ""
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
      let trimmedEnd = line.replacingOccurrences(
        of: #"\s+$"#,
        with: "",
        options: .regularExpression
      )
      if trimmedEnd.hasSuffix("\\") {
        current += String(trimmedEnd.dropLast()) + " "
      } else {
        result.append(current + trimmedEnd)
        current = ""
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  private static func targetNames(in text: String) -> [String] {
    text.split(whereSeparator: \Character.isWhitespace)
      .map(String.init)
      .filter {
        $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/+@-]*$"#, options: .regularExpression) != nil
      }
  }

  private static func unique(_ targets: [String]) -> [String] {
    var seen = Set<String>()
    return targets.filter { seen.insert($0).inserted }
  }
}

struct CapturedProcessResult: Sendable {
  let command: String
  let output: String
  let exitCode: Int32?
  let startedAt: Date
  let completedAt: Date
}

final class CapturedProcessRunner: @unchecked Sendable {
  private static let maximumOutputBytes = 512 * 1_024

  func run(
    executable: String,
    arguments: [String],
    currentDirectory: String,
    displayCommand: String
  ) async -> CapturedProcessResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          returning: self.runSynchronously(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            displayCommand: displayCommand
          ))
      }
    }
  }

  private func runSynchronously(
    executable: String,
    arguments: [String],
    currentDirectory: String,
    displayCommand: String
  ) -> CapturedProcessResult {
    let startedAt = Date()
    let process = Process()
    let pipe = Pipe()
    let collector = LockedCommandOutputCollector(maximumBytes: Self.maximumOutputBytes)
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
    var environment = ProcessInfo.processInfo.environment
    let commonExecutablePaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    let inheritedPaths = environment["PATH", default: ""].split(separator: ":").map(String.init)
    environment["PATH"] = unique(commonExecutablePaths + inheritedPaths).joined(separator: ":")
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GCM_INTERACTIVE"] = "never"
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty { collector.append(data) }
    }

    do {
      try process.run()
      process.waitUntilExit()
      pipe.fileHandleForReading.readabilityHandler = nil
      collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
      return CapturedProcessResult(
        command: displayCommand,
        output: collector.string,
        exitCode: process.terminationStatus,
        startedAt: startedAt,
        completedAt: Date()
      )
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
      let existing = collector.string
      let detail =
        existing.isEmpty ? error.localizedDescription : "\(existing)\n\(error.localizedDescription)"
      return CapturedProcessResult(
        command: displayCommand,
        output: detail,
        exitCode: nil,
        startedAt: startedAt,
        completedAt: Date()
      )
    }
  }

  private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}

private final class LockedCommandOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumBytes: Int
  private var data = Data()
  private var didTruncate = false

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  func append(_ newData: Data) {
    guard !newData.isEmpty else { return }
    lock.lock()
    data.append(newData)
    if data.count > maximumBytes {
      data = Data(data.suffix(maximumBytes))
      didTruncate = true
    }
    lock.unlock()
  }

  var string: String {
    lock.lock()
    let value = String(decoding: data, as: UTF8.self)
    let truncated = didTruncate
    lock.unlock()
    return truncated ? "[Earlier output truncated]\n\(value)" : value
  }
}

protocol CommitMessageGenerating: Sendable {
  func generate(stagedSummary: String, stagedDiff: String) async throws -> String
}

enum CommitMessageContext {
  static let maximumCharacters = 4_000

  static func prioritizedDiff(highSignalDiff: String, compactDiff: String) -> String {
    let highSignal = highSignalDiff.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = highSignal.isEmpty ? compactDiff : highSignal
    return String(source.prefix(maximumCharacters))
  }
}

#if canImport(FoundationModels)
  @available(macOS 26.0, *)
  @Generable
  private struct GeneratedCommitSubject {
    @Guide(description: "A single natural imperative Git subject under 72 characters")
    var subject: String
  }
#endif

struct FoundationCommitMessageGenerator: CommitMessageGenerating {
  func generate(stagedSummary: String, stagedDiff: String) async throws -> String {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return try await generateWithFoundationModels(
          stagedSummary: stagedSummary,
          stagedDiff: stagedDiff
        )
      }
    #endif
    throw ProjectCommandError.foundationModelsUnavailable(
      "Commit message generation requires macOS 26 or later."
    )
  }

  #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateWithFoundationModels(
      stagedSummary: String,
      stagedDiff: String
    ) async throws -> String {
      let model = SystemLanguageModel(useCase: .general)
      guard model.isAvailable else {
        throw ProjectCommandError.foundationModelsUnavailable(
          Self.unavailableDescription(model.availability)
        )
      }
      let session = LanguageModelSession(
        model: model,
        instructions: """
          Write one natural Git subject under 72 characters. The first word must be an imperative \
          verb such as Enable, Keep, Notify, Improve, Prevent, Support, or Fix. Describe the primary \
          behavior or user outcome, not files, tests, types, frameworks, or implementation work. \
          Return only the subject and never use past tense or a trailing period.
          """
      )
      let response = try await session.respond(
        to: """
          Silently determine what behavior this compact diff makes possible and when that behavior \
          matters. Express that result as the subject. Paths are context only.

          Compact diff:
          \(stagedDiff)

          Changed paths:
          \(stagedSummary)
          """,
        generating: GeneratedCommitSubject.self,
        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 20)
      )
      return try CommitMessageSanitizer.sanitize(response.content.subject)
    }

    @available(macOS 26.0, *)
    private static func unavailableDescription(
      _ availability: SystemLanguageModel.Availability
    ) -> String {
      switch availability {
      case .available:
        return "Apple Foundation Models is unavailable."
      case .unavailable(.deviceNotEligible):
        return "This Mac does not support Apple Intelligence."
      case .unavailable(.appleIntelligenceNotEnabled):
        return "Apple Intelligence is not enabled."
      case .unavailable(.modelNotReady):
        return "The Apple Intelligence model is not ready."
      case .unavailable:
        return "Apple Foundation Models is unavailable for an unknown reason."
      }
    }
  #endif
}

enum CommitMessageSanitizer {
  static func sanitize(_ rawMessage: String) throws -> String {
    let firstLine = rawMessage.components(separatedBy: .newlines).first ?? ""
    var message = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    if message.hasPrefix("Commit message:") {
      message = String(message.dropFirst("Commit message:".count))
        .trimmingCharacters(in: .whitespaces)
    }
    let wrappers = CharacterSet(charactersIn: "\"'`")
    message = message.trimmingCharacters(in: wrappers)
    if message.count > 72 {
      let prefix = String(message.prefix(72))
      if let wordBoundary = prefix.lastIndex(where: \Character.isWhitespace) {
        message = String(prefix[..<wordBoundary])
      } else {
        message = prefix
      }
    }
    message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { throw ProjectCommandError.emptyCommitMessage }
    return message
  }
}

enum ProjectCommandError: LocalizedError {
  case noStagedChanges
  case emptyCommitMessage
  case foundationModelsUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .noStagedChanges:
      return "There are no working tree changes to commit."
    case .emptyCommitMessage:
      return "Apple Foundation Models returned an empty commit message."
    case .foundationModelsUnavailable(let reason):
      return reason
    }
  }
}

struct ProjectCommandService: Sendable {
  private let runner: CapturedProcessRunner
  private let commitMessageGenerator: any CommitMessageGenerating

  init(
    runner: CapturedProcessRunner = CapturedProcessRunner(),
    commitMessageGenerator: any CommitMessageGenerating = FoundationCommitMessageGenerator()
  ) {
    self.runner = runner
    self.commitMessageGenerator = commitMessageGenerator
  }

  func runMake(target: String, projectPath: String) async -> ProjectCommandOutcome {
    let result = await runner.run(
      executable: "/usr/bin/make",
      arguments: [target],
      currentDirectory: projectPath,
      displayCommand: "make \(target)"
    )
    return ProjectCommandOutcome(
      kind: .make,
      title: "Make \(target)",
      command: result.command,
      output: result.output,
      exitCode: result.exitCode,
      startedAt: result.startedAt,
      completedAt: result.completedAt
    )
  }

  func runGitPush(projectPath: String) async -> ProjectCommandOutcome {
    let result = await runner.run(
      executable: "/usr/bin/git",
      arguments: ["push"],
      currentDirectory: projectPath,
      displayCommand: "git push"
    )
    return ProjectCommandOutcome(
      kind: .gitPush,
      title: "Git Push",
      command: result.command,
      output: result.output,
      exitCode: result.exitCode,
      startedAt: result.startedAt,
      completedAt: result.completedAt
    )
  }

  func runGitCommitAndPush(projectPath: String) async -> ProjectCommandOutcome {
    let commit = await runGitCommit(projectPath: projectPath)
    let title = commit.title.replacingOccurrences(
      of: "Git Commit",
      with: "Git Commit & Push"
    )
    guard commit.succeeded else {
      return ProjectCommandOutcome(
        kind: .gitCommit,
        title: title,
        command: commit.command,
        output: commit.output,
        exitCode: commit.exitCode,
        startedAt: commit.startedAt,
        completedAt: commit.completedAt
      )
    }

    let upstream = await runner.run(
      executable: "/usr/bin/git",
      arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      currentDirectory: projectPath,
      displayCommand: "git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'"
    )
    guard upstream.exitCode == 0 else {
      return ProjectCommandOutcome(
        kind: .gitCommit,
        title: title,
        command: commit.command,
        output: commit.output,
        exitCode: commit.exitCode,
        startedAt: commit.startedAt,
        completedAt: upstream.completedAt
      )
    }

    let push = await runner.run(
      executable: "/usr/bin/git",
      arguments: ["push"],
      currentDirectory: projectPath,
      displayCommand: "git push"
    )
    return ProjectCommandOutcome(
      kind: .gitCommit,
      title: title,
      command: "\(commit.command) && \(push.command)",
      output: combinedOutput(commit.output, push.output),
      exitCode: push.exitCode,
      startedAt: commit.startedAt,
      completedAt: push.completedAt
    )
  }

  func runGitCommit(projectPath: String) async -> ProjectCommandOutcome {
    let startedAt = Date()
    let add = await runner.run(
      executable: "/usr/bin/git",
      arguments: ["add", "--all"],
      currentDirectory: projectPath,
      displayCommand: "git add --all"
    )
    guard add.exitCode == 0 else {
      return failureOutcome(
        title: "Git Commit",
        command: add.command,
        message: add.output,
        startedAt: startedAt
      )
    }

    let summary = await runner.run(
      executable: "/usr/bin/git",
      arguments: ["diff", "--cached", "--name-status"],
      currentDirectory: projectPath,
      displayCommand: "git diff --cached --name-status"
    )
    guard summary.exitCode == 0 else {
      return failureOutcome(
        title: "Git Commit",
        command: "git add --all && git commit",
        message: combinedOutput(add.output, summary.output),
        startedAt: startedAt
      )
    }
    let stagedSummary = summary.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stagedSummary.isEmpty else {
      return failureOutcome(
        title: "Git Commit",
        command: "git add --all && git commit",
        message: combinedOutput(
          add.output,
          ProjectCommandError.noStagedChanges.localizedDescription
        ),
        startedAt: startedAt
      )
    }

    let compactDiff = await runner.run(
      executable: "/usr/bin/git",
      arguments: [
        "diff", "--cached", "--no-ext-diff", "--no-color", "--unified=0", "--", ".",
        ":(exclude)**/*.xcodeproj/project.pbxproj",
      ],
      currentDirectory: projectPath,
      displayCommand: "git diff --cached --no-ext-diff --no-color --unified=0"
    )
    guard compactDiff.exitCode == 0 else {
      return failureOutcome(
        title: "Git Commit",
        command: "git add --all && git commit",
        message: combinedOutput(add.output, compactDiff.output),
        startedAt: startedAt
      )
    }

    let highSignalDiff = await runner.run(
      executable: "/usr/bin/git",
      arguments: [
        "diff", "--cached", "--no-ext-diff", "--no-color", "--unified=0", "--",
        "CHANGELOG.md", "docs/iOS/product-requirements.md",
        "docs/macOS/product-requirements.md",
      ],
      currentDirectory: projectPath,
      displayCommand: "git diff --cached --no-ext-diff --no-color --unified=0 -- product context"
    )

    do {
      let stagedDiff = CommitMessageContext.prioritizedDiff(
        highSignalDiff: highSignalDiff.exitCode == 0 ? highSignalDiff.output : "",
        compactDiff: compactDiff.output
      )
      let message = try await commitMessageGenerator.generate(
        stagedSummary: stagedSummary,
        stagedDiff: stagedDiff
      )
      let result = await runner.run(
        executable: "/usr/bin/git",
        arguments: ["commit", "-m", message],
        currentDirectory: projectPath,
        displayCommand: "git commit -m \(shellQuoted(message))"
      )
      return ProjectCommandOutcome(
        kind: .gitCommit,
        title: "Git Commit: \(message)",
        command: "git add --all && \(result.command)",
        output: combinedOutput(add.output, result.output),
        exitCode: result.exitCode,
        startedAt: startedAt,
        completedAt: result.completedAt
      )
    } catch {
      return failureOutcome(
        title: "Git Commit",
        command: "git add --all && git commit",
        message: combinedOutput(add.output, error.localizedDescription),
        startedAt: startedAt
      )
    }
  }

  private func failureOutcome(
    title: String,
    command: String,
    message: String,
    startedAt: Date
  ) -> ProjectCommandOutcome {
    ProjectCommandOutcome(
      kind: .gitCommit,
      title: title,
      command: command,
      output: message,
      exitCode: nil,
      startedAt: startedAt,
      completedAt: Date()
    )
  }

  private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func combinedOutput(_ parts: String...) -> String {
    parts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }
}
