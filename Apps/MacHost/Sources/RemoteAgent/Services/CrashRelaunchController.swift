import AppKit
import Foundation

@MainActor
final class CrashRelaunchController {
  static let shared = CrashRelaunchController()

  private var watchdog: Process?
  private let markerURL: URL

  private init() {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    markerURL =
      support
      .appendingPathComponent("Remote Agent", isDirectory: true)
      .appendingPathComponent("crash-relaunch-armed")
  }

  @discardableResult
  func configure(enabled: Bool) -> String {
    if enabled {
      return startIfNeeded()
    }
    disarm()
    return "Disabled"
  }

  func prepareForCleanTermination() {
    disarm()
  }

  private func startIfNeeded() -> String {
    if watchdog?.isRunning == true {
      return "Armed"
    }
    guard let scriptURL = Bundle.main.url(forResource: "crash-watchdog", withExtension: "sh")
    else {
      return "Unavailable in this build"
    }

    do {
      try FileManager.default.createDirectory(
        at: markerURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("armed".utf8).write(to: markerURL, options: .atomic)

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [
        scriptURL.path,
        String(ProcessInfo.processInfo.processIdentifier),
        Bundle.main.bundleURL.path,
        markerURL.path,
      ]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      watchdog = process
      return "Armed"
    } catch {
      try? FileManager.default.removeItem(at: markerURL)
      watchdog = nil
      return "Could not arm: \(error.localizedDescription)"
    }
  }

  private func disarm() {
    try? FileManager.default.removeItem(at: markerURL)
    if watchdog?.isRunning == true {
      watchdog?.terminate()
    }
    watchdog = nil
  }
}

final class RemoteAgentApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      CrashRelaunchController.shared.prepareForCleanTermination()
    }
  }
}
