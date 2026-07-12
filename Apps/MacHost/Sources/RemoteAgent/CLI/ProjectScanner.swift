import Foundation

struct ProjectScanner: Sendable {
  func scan(rootPath: String) async throws -> [AgentProject] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let process = Process()
          let pipe = Pipe()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
          process.arguments = [
            rootPath, "-mindepth", "1", "-maxdepth", "1", "-type", "d",
            "-not", "-name", ".*", "-print",
          ]
          process.standardOutput = pipe
          process.standardError = Pipe()
          try process.run()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          guard process.terminationStatus == 0 else {
            throw RemoteAgentError.commandFailed("Could not scan \(rootPath).")
          }
          let output = String(data: data, encoding: .utf8) ?? ""
          let projects = output.split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .map(AgentProject.init(path:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
          continuation.resume(returning: projects)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
