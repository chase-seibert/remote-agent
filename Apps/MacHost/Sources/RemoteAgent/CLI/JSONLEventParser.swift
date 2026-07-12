import Foundation

struct CodexJSONLEvent: Equatable, Sendable {
  let type: String
  let threadID: String?
  let itemType: String?
  let text: String?
  let errorMessage: String?

  var reasoningText: String? {
    guard type == "item.completed", itemType == "reasoning" else { return nil }
    return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  init?(line: String) {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else { return nil }

    let item = object["item"] as? [String: Any]
    self.type = type
    threadID = object["thread_id"] as? String ?? object["threadId"] as? String
    itemType = item?["type"] as? String
    text = item?["text"] as? String
    errorMessage = object["message"] as? String ?? object["error"] as? String
  }
}

struct JSONLLineBuffer: Sendable {
  private var pending = Data()

  mutating func append(_ data: Data) -> [String] {
    pending.append(data)
    var lines: [String] = []
    while let newlineIndex = pending.firstIndex(of: 0x0A) {
      let lineData = pending[pending.startIndex..<newlineIndex]
      pending.removeSubrange(pending.startIndex...newlineIndex)
      guard var line = String(data: lineData, encoding: .utf8) else { continue }
      if line.last == "\r" { line.removeLast() }
      if !line.isEmpty { lines.append(line) }
    }
    return lines
  }

  mutating func finish() -> String? {
    guard !pending.isEmpty, var line = String(data: pending, encoding: .utf8) else {
      pending.removeAll()
      return nil
    }
    pending.removeAll()
    if line.last == "\r" { line.removeLast() }
    return line.isEmpty ? nil : line
  }
}

struct CodexEventAccumulator: Sendable {
  private(set) var sessionID: String?
  private(set) var assistantMessages: [String] = []
  private(set) var lastError: String?

  mutating func consume(line: String) {
    guard let event = CodexJSONLEvent(line: line) else { return }

    if event.type == "thread.started" {
      sessionID = event.threadID
    }

    if event.type == "item.completed",
      event.itemType == "agent_message",
      let text = event.text,
      !text.isEmpty
    {
      assistantMessages.append(text)
    }

    if event.type == "error" {
      lastError = event.errorMessage
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
