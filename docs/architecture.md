# Monorepo Architecture

Remote Agent has three independently buildable components:

1. `Apps/MacHost` owns local project discovery, durable session storage, Codex process execution, the native Mac UI, and the authenticated HTTP server.
2. `Apps/iOS` owns mobile connection configuration, recent-session and prompt-queue presentation, notifications, and native conversation and document views.
3. `Packages/RemoteAgentProtocol` owns API details that must remain identical on both sides, including the protocol version, endpoint construction, lightweight session-status snapshots, queued-prompt wire models, and mutation request contracts.

The Mac host remains the authority for projects, sessions, transcripts, unread state, pin state, prompt queues, Make target selection, project-command execution, and captured output. The iOS app caches server snapshots and command configuration while persisting only mobile-local composer drafts. Foreground active-work polling reads compact status records and treats their content revisions as invalidation signals; full session snapshots remain the recovery and transcript authority. Each app retains its own build definition and release workflow; the root Makefile coordinates compatible builds and tests without merging their runtime responsibilities.

Protocol changes should update the shared package first, then the Mac route behavior, iOS client behavior, interoperability tests, and both product documentation sets in one commit.
