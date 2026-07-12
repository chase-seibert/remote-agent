import Foundation

struct CodexEventAccumulator: Sendable {
  private(set) var sessionID: String?
  private(set) var assistantMessages: [String] = []
  private(set) var lastError: String?

  mutating func consume(line: String) {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    let type = object["type"] as? String
    if type == "thread.started" {
      sessionID = object["thread_id"] as? String ?? object["threadId"] as? String
    }

    if type == "item.completed",
      let item = object["item"] as? [String: Any],
      item["type"] as? String == "agent_message",
      let text = item["text"] as? String,
      !text.isEmpty
    {
      assistantMessages.append(text)
    }

    if type == "error" {
      lastError = object["message"] as? String ?? object["error"] as? String
    }
  }
}
