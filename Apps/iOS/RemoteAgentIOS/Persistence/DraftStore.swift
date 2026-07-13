import Foundation
import RemoteAgentProtocol

struct DraftStore {
  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func draft(serverIdentifier: String, sessionID: UUID) -> String {
    defaults.string(forKey: draftKey(serverIdentifier: serverIdentifier, sessionID: sessionID))
      ?? ""
  }

  func save(_ draft: String, serverIdentifier: String, sessionID: UUID) {
    let key = draftKey(serverIdentifier: serverIdentifier, sessionID: sessionID)
    if draft.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(draft, forKey: key)
    }
  }

  func queuedPrompts(serverIdentifier: String, sessionID: UUID) -> [QueuedPrompt] {
    guard
      let data = defaults.data(
        forKey: queueKey(
          serverIdentifier: serverIdentifier,
          sessionID: sessionID
        ))
    else { return [] }
    return (try? decoder.decode([QueuedPrompt].self, from: data)) ?? []
  }

  func saveQueuedPrompts(
    _ prompts: [QueuedPrompt],
    serverIdentifier: String,
    sessionID: UUID
  ) {
    let key = queueKey(serverIdentifier: serverIdentifier, sessionID: sessionID)
    guard !prompts.isEmpty else {
      defaults.removeObject(forKey: key)
      return
    }
    guard let data = try? encoder.encode(prompts) else { return }
    defaults.set(data, forKey: key)
  }

  private func draftKey(serverIdentifier: String, sessionID: UUID) -> String {
    let identity = Data(serverIdentifier.utf8).base64EncodedString()
    return "draft.\(identity).\(sessionID.uuidString)"
  }

  private func queueKey(serverIdentifier: String, sessionID: UUID) -> String {
    let identity = Data(serverIdentifier.utf8).base64EncodedString()
    return "promptQueue.\(identity).\(sessionID.uuidString)"
  }
}
