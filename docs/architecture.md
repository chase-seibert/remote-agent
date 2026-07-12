# Monorepo Architecture

Remote Agent has three independently buildable components:

1. `Apps/MacHost` owns local project discovery, durable session storage, Codex process execution, the native Mac UI, and the authenticated HTTP server.
2. `Apps/iOS` owns mobile connection configuration, recent-session presentation, prompt queues, notifications, and native conversation and document views.
3. `Packages/RemoteAgentProtocol` owns API details that must remain identical on both sides, currently the protocol version, endpoint construction, and partial session-update request contract.

The Mac host remains the authority for projects, sessions, transcripts, unread state, and pin state. The iOS app caches server snapshots and persists only mobile-local drafts and queued prompts. Each app retains its own build definition and release workflow; the root Makefile coordinates compatible builds and tests without merging their runtime responsibilities.

Protocol changes should update the shared package first, then the Mac route behavior, iOS client behavior, interoperability tests, and both product documentation sets in one commit.
