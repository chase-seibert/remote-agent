# Changelog

## 2026-07-16

- New conversations on macOS and iOS now present a model picker after the project is chosen. The most recently used model is preselected, and changing the host default no longer changes existing sessions.

### Mac Host

- Added a persisted host-wide Codex model setting with a refreshable dropdown sourced from `codex debug models` and a custom-ID fallback, applied it to new and resumed turns, and displayed the configured model in every session row.
- Added logical response payload sizes to Mobile Debug request rows and copied logs, while preserving compatibility with older persisted entries.
- Added a compact watched-session status endpoint backed by persisted monotonic content revisions, keeping transient reasoning updates independent from full transcript serialization.

### iOS

- Refreshed the host model catalog whenever the empty-conversation picker appears, and automatically discard an untouched new session when navigating back from it.
- Added the host-selected Codex model to recent-session rows with backward-compatible “Codex default” labeling for older hosts.
- Replaced one-second full-session-list polling with batched lightweight status polling and targeted authoritative session refreshes only after content changes, including queued turns that start without an idle gap.
- Added automatic full-list polling fallback for older hosts that do not expose the additive status endpoint.

## 2026-07-15

### Mac Host

- Fixed Commit & Push failures caused by truncated Foundation Models structured output by generating a plain-text subject without a response-token cutoff and retaining the existing 72-character sanitizer.

## 2026-07-14

### Mac Host

- Added active IPv4/IPv6 listener addresses and per-address authenticated health checks to the Mobile Debug settings screen.
- Prevented false “Address already in use” failures by waiting for listener cancellation before same-port API restarts and briefly retrying `EADDRINUSE`.
- Prevented large session snapshots from stalling or being truncated by negotiating transparent `deflate` compression with iOS and draining each half-closed HTTP connection until the client closes it, while retaining the existing deadline for clients that stop reading.
- Ordered project-document API results by newest modification time and raised the UTF-8 preview limit from 2 MB to 10 MB.
- Fixed intermittent mobile connection timeouts by serializing response delivery on each Network.framework connection, tracking and closing accepted sockets across listener restarts, closing completed responses gracefully, and batching Mobile Debug publication and persistence outside the response path.
- Prevented slow or abusive clients from starving the mobile API with global and per-source connection and handler limits, reserved health/status capacity, incremental per-connection parsing, and header, body, handler-response, and write deadlines. Accepted agent and command work intentionally continues after its client disconnects while remaining counted against bounded handler capacity.

### iOS

- Fixed intermittent foreground reconnection failures by coalescing connection and refresh work, ignoring canceled or stale responses, waiting for local-network connectivity, and retrying only safe reads after transient transport errors.
- Bounded client networking to four concurrent requests, added exponential retry backoff with jitter and `Retry-After` support for safe reads, consolidated active-session polling into one snapshot request per second, and generation-guarded every asynchronous state mutation across disconnects and host switches.
- Ordered Browse Files by newest modification time while remaining compatible with older hosts that do not provide timestamps, and added a remembered Sort menu for recency, name, or size.
- Expanded completion notifications with the session title, project name, and a concise final-response or failure preview, and grouped related notifications by project.

## 2026-07-13

### Mac Host

- Added native Markdown table parsing and bordered, horizontally scrollable grid rendering with header emphasis, wrapped cells, alternating rows, and declared column alignment in conversations and document previews.

### iOS

- Added formatted Markdown tables to document previews with the same header, alignment, border, wrapping, row shading, and horizontal-scrolling behavior.

### Documentation

- Updated the README hero to describe seamless Mac and phone workflows with optional Tailscale access, and added current Mac and iPhone product screenshots.

## 2026-07-12

- Consolidated the Mac host, iOS client, documentation, and build orchestration into one monorepo with a shared `RemoteAgentProtocol` Swift package.

### Mac Host

- Added persisted Mark as Read/Unread session actions plus an authenticated unread API that preserves activity ordering.
- Added persisted host-owned prompt queues with authenticated create, list, edit, and delete APIs, automatic FIFO execution after agent turns and project commands, and queue recovery after host launch.
- Improved on-device commit subjects by prioritizing behavioral context over filenames and using the General Foundation Model with structured greedy output and an imperative outcome prompt.
- Kept the selected Make target name visible beside the hammer in both the Mac and mobile split buttons.
- Added authenticated mobile API routes for Make target discovery and selection, remote Make and combined Git Commit & Push execution, and session-scoped command-result retrieval.
- Fixed Make target selection so the split menu updates immediately and the selected target persists on its owning session across app launches.
- Added project command controls with a per-session remembered Make target split button, a combined Git Commit & Push action, on-device Apple Foundation Models commit-message generation, and clickable live-status transcript placeholders backed by private scrollable command-output sheets. The Git action stages and commits the entire working tree, then pushes when the current branch has an upstream and silently skips pushing otherwise.
- Added live Codex reasoning-summary display during active turns, replacing the prior summary in place and clearing it when the final response arrives.
- Made the main window and application process single-instance while retaining separate document preview windows.
- Added persisted session pinning with pinned-first ordering and confirmed deletion that protects running sessions in the Mac app, plus authenticated `PATCH` and `DELETE` API support for mobile clients.
- Matched the companion iOS visual language with a green mobile-active checkmark, aligned chat bubbles, icon-bearing unread pills, and the rotating green agent-working treatment.
- Added a persisted System, Light, or Dark appearance setting that applies across app and document windows.
- Replaced the project/session navigation hierarchy with one searchable, globally recent session sidebar capped at 50, including project, activity time, unread state, and status metadata.
- Added persisted session renaming through the authenticated mobile API.
- Hardened the mobile HTTP listener against malformed lengths, duplicate query parameters, oversized headers/bodies, and idle-connection leaks.
- Added automatic API reconfiguration, peer-to-peer networking, and Bonjour `_remoteagent._tcp` advertisement for more reliable mobile discovery.
- Added an enabled-by-default crash watchdog setting that relaunches after unclean exits while respecting normal Quit.
- Added safe read-only source-code discovery to the project document API and native line-numbered code previews for local document windows.

### iOS

- Fixed prompt submission ordering so the outgoing blue message appears before the green agent-working state, with optimistic messages removed if submission fails.
- Added Mark as Read/Unread to session-row swipe and long-press actions, with immediate unread-dot and app-icon badge synchronization.
- Moved queued prompts from device storage into Mac session snapshots, added native editing and host-backed removal, and added migration of queues saved by older iOS builds on connection.
- Made the connection sheet lead with a clear live-status summary showing the Mac endpoint, API version or failure detail, and an inline retry action for unavailable saved connections.
- Added conditional background app refresh for active sessions: iOS requests the earliest system-managed refresh opportunity, persists watched session IDs across process termination, waits for the Mac health check before reading session status, schedules the existing completion notification before yielding, and stops requesting background work when all agents are idle.
- Added host-backed Make target and combined Git Commit & Push controls to conversations, with live command chat rows and a dismissible full-output screen.
- Shortened the session deletion confirmation button to “Delete,” keeping long session titles in the dialog message instead of the action label.
- Fixed foreground restoration so an already-visible session is marked read after its refreshed unread state arrives, without requiring the user to leave and reopen it.
- Added the host's current reasoning summary to running conversations through the existing active-turn polling flow; the transient summary is replaced in place and removed at completion.
- Added pinned-first session ordering plus Pin/Unpin and confirmed Delete actions backed by the Mac host API; running sessions remain protected from deletion.
- Added production-navigation fixtures and XCUITest integration coverage proving 120-message sessions open at the bottom after direct restoration, global-list navigation, and switching from another session; fixed the switch-path race by scrolling again when the system navigation animation completes.
- Added a conversation-toolbar compose button that creates and opens a new session in the current project.
- Added an iPhone right-swipe gesture from conversations back to the global session list using the same animated transition as Back, with horizontal-intent filtering to preserve transcript scrolling.
- Added persisted session renaming from recent-session row actions.
- Replaced project-first navigation with a global, status-rich list of the 50 most recently active sessions and moved the rolled-up unread marker beside the conversation Back control.
- Limited Browse Files to Markdown and HTML while retaining source-code previews for links opened from conversations and documents.
- Added persistent System, Light, and Dark appearance choices with adaptive conversation and file-preview surfaces.
- Added read-only source-code link previews with native monospaced text, line numbers, horizontal scrolling, and in-app source links.
- Fixed session navigation so long, variable-height transcripts scroll to the final activity without overscrolling into a blank region.

## 2026-07-11

### Mac Host

- Added native in-app windows for local Markdown and HTML links, with relative-link resolution, reload, Finder, and default-app actions.
- Documented an optional, staged plan for listing, reading, and safely forking sessions created by other Codex desktop surfaces.
- Added read-only Markdown and HTML project document API endpoints for the iOS client.
- Added a toolbar mobile-activity indicator and a persistent Mobile Debug settings screen with safe HTTP request metadata and timing logs.
- Added the selected desktop-and-phone app icon, a shared 1024px Mac/iOS source asset, and reproducible macOS `.icns` generation.
- Fixed the text-size commands so changes immediately apply across project rows, session rows, transcripts, progress text, and the prompt composer.
- Ordered projects by their most recent session activity and added persisted unread indicators for sessions and projects.
- Fixed response rendering so Markdown paragraphs, headings, lists, quotes, dividers, and fenced code blocks retain their block layout.
- Created the first native macOS Remote Agent application.
- Added command-line project discovery and Codex JSONL session execution/resumption.
- Added persisted project sessions and conversation transcripts.
- Added typed prompts, macOS speech-to-text dictation, progress feedback, Markdown rendering, and text scaling.
- Added a token-authenticated local-network HTTP API for project, session, and message access.
- Added app bundling, signing, tests, documentation, and Makefile workflows.

### iOS

- Added the initial native iOS app with secure host configuration.
- Added project and session browsing, session creation, prompt submission, and one-second active-turn polling.
- Added Keychain token storage, per-session draft persistence, local-network transport configuration, safe Markdown rendering, adaptive iPhone/iPad navigation, tests, and simulator/device workflows.
- Matched the iOS app icon to the Remote Agent macOS app's canonical icon.
- Ordered projects and sessions by most recent session activity.
- Added read-only Markdown and HTML browsing for project files.
- Made transcript and document links actionable on iOS, including translation of absolute Mac project paths and relative document links.
- Added local completion notifications and limited background polling for active agent turns.
- Added connection status to each main navigation toolbar and made it open connection settings from project, session, and conversation screens.
- Added an activity-ordered project switcher to every main toolbar that opens each project's newest session while preserving Back navigation to its session list.
- Added host-synchronized unread markers to the project dropdown, project rows, and session rows, with conversations marked read when presented.
- Added rich native Markdown document previews with headings, emphasis, lists, tasks, quotes, rules, and fenced code blocks.
- Added spinning green agent icons in the project menu and list when that project has a running agent.
- Replaced the system project menu with a compact popover so every affected project reliably shows its blue unread badge and running animation.
- Added a reusable simulator fixture for visually testing running, unread, and read project states.
- Added persisted per-session prompt queues with visible FIFO ordering, removal, and automatic one-at-a-time delivery after active turns complete.
- Added an iOS app icon badge that tracks the total number of unread sessions and clears as sessions are read.
- Made conversations open at the latest message or queued prompt when navigating into a session.
