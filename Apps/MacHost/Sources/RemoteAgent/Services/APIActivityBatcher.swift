import Foundation

actor APIActivityBatcher {
  typealias Sink = @Sendable ([APIActivityEntry]) async -> Void

  private let flushDelay: Duration
  private let sink: Sink
  private var pendingEntries: [APIActivityEntry] = []
  private var scheduledFlush: Task<Void, Never>?

  init(
    flushDelay: Duration = .milliseconds(100),
    sink: @escaping Sink
  ) {
    self.flushDelay = flushDelay
    self.sink = sink
  }

  func record(_ entry: APIActivityEntry) {
    pendingEntries.append(entry)
    guard scheduledFlush == nil else { return }
    let delay = flushDelay
    scheduledFlush = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      await self?.flush()
    }
  }

  func flush() async {
    scheduledFlush = nil
    let entries = pendingEntries
    pendingEntries.removeAll(keepingCapacity: true)
    guard !entries.isEmpty else { return }
    await sink(entries)
  }

  func flushNow() async {
    scheduledFlush?.cancel()
    scheduledFlush = nil
    await flush()
  }

  func discardPending() {
    scheduledFlush?.cancel()
    scheduledFlush = nil
    pendingEntries.removeAll(keepingCapacity: true)
  }
}
