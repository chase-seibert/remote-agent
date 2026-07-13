import BackgroundTasks
import Foundation

protocol BackgroundRefreshScheduling: AnyObject {
  func schedule()
  func cancel()
}

final class BackgroundRefreshScheduler: BackgroundRefreshScheduling {
  static let identifier = "com.cseibert.RemoteAgentIOS.active-session-refresh"
  static let minimumInterval: TimeInterval = 5 * 60

  func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumInterval)
    try? BGTaskScheduler.shared.submit(request)
  }

  func cancel() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
  }
}

struct BackgroundSessionWatchStore {
  private let defaults: UserDefaults
  private let keyPrefix = "backgroundActiveSessionIDs."

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func sessionIDs(serverIdentifier: String) -> Set<UUID> {
    let values = defaults.stringArray(forKey: key(serverIdentifier: serverIdentifier)) ?? []
    return Set(values.compactMap(UUID.init(uuidString:)))
  }

  func save(_ sessionIDs: Set<UUID>, serverIdentifier: String) {
    let key = key(serverIdentifier: serverIdentifier)
    guard !sessionIDs.isEmpty else {
      defaults.removeObject(forKey: key)
      return
    }
    defaults.set(sessionIDs.map(\.uuidString).sorted(), forKey: key)
  }

  func clear(serverIdentifier: String) {
    defaults.removeObject(forKey: key(serverIdentifier: serverIdentifier))
  }

  private func key(serverIdentifier: String) -> String {
    keyPrefix + serverIdentifier
  }
}
