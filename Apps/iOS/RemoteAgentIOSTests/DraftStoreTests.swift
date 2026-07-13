import RemoteAgentProtocol
import XCTest

@testable import RemoteAgentIOS

final class DraftStoreTests: XCTestCase {
  func testDraftsAreScopedToServerAndSession() {
    let suite = "DraftStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DraftStore(defaults: defaults)
    let sessionID = UUID()

    store.save("First", serverIdentifier: "mac-a.local:8765", sessionID: sessionID)
    store.save("Second", serverIdentifier: "mac-b.local:8765", sessionID: sessionID)

    XCTAssertEqual(store.draft(serverIdentifier: "mac-a.local:8765", sessionID: sessionID), "First")
    XCTAssertEqual(
      store.draft(serverIdentifier: "mac-b.local:8765", sessionID: sessionID), "Second")
  }

  func testEmptyDraftRemovesStoredValue() {
    let suite = "DraftStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DraftStore(defaults: defaults)
    let sessionID = UUID()

    store.save("Temporary", serverIdentifier: "mac.local:8765", sessionID: sessionID)
    store.save("", serverIdentifier: "mac.local:8765", sessionID: sessionID)

    XCTAssertEqual(store.draft(serverIdentifier: "mac.local:8765", sessionID: sessionID), "")
  }

  func testQueuedPromptsRoundTripInOrderAndAreScopedToServer() {
    let suite = "DraftStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DraftStore(defaults: defaults)
    let sessionID = UUID()
    let prompts = [
      QueuedPrompt(text: "First", createdAt: Date(timeIntervalSince1970: 100)),
      QueuedPrompt(text: "Second", createdAt: Date(timeIntervalSince1970: 200)),
    ]

    store.saveQueuedPrompts(
      prompts,
      serverIdentifier: "mac-a.local:8765",
      sessionID: sessionID
    )

    XCTAssertEqual(
      store.queuedPrompts(serverIdentifier: "mac-a.local:8765", sessionID: sessionID),
      prompts
    )
    XCTAssertTrue(
      store.queuedPrompts(serverIdentifier: "mac-b.local:8765", sessionID: sessionID).isEmpty
    )
  }

  func testSavingEmptyQueueRemovesPersistedPrompts() {
    let suite = "DraftStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DraftStore(defaults: defaults)
    let sessionID = UUID()

    store.saveQueuedPrompts(
      [QueuedPrompt(text: "Temporary")],
      serverIdentifier: "mac.local:8765",
      sessionID: sessionID
    )
    store.saveQueuedPrompts(
      [],
      serverIdentifier: "mac.local:8765",
      sessionID: sessionID
    )

    XCTAssertTrue(
      store.queuedPrompts(serverIdentifier: "mac.local:8765", sessionID: sessionID).isEmpty
    )
  }
}
