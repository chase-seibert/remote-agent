# Architecture

## Components

- `RemoteAPIClient` is the only HTTP boundary. It applies bearer authentication, Codable encoding/decoding, ISO-8601 dates, URL construction, and typed HTTP errors.
- `AppModel` owns connection state, server snapshots, navigation selection, project-command configuration, request tasks, foreground refresh, active-work polling, and conditional background-refresh scheduling.
- `ConnectionSettings` persists only the host and port in `UserDefaults`; `KeychainStore` persists the token as a generic password.
- `DraftStore` persists unsent composer text and FIFO prompt queues by server/session identity in `UserDefaults`.
- `CompletionNotificationService` requests notification permission when notifications or unread badges are first needed, synchronizes the app icon badge with the unread-session count, and schedules a local success or failure notification when a running session becomes idle.
- SwiftUI views form a two-level recent sessions → conversation hierarchy. The session list merges activity from every project, while the conversation retains its project context for prompts and file browsing. On compact layouts, a horizontal-dominant right swipe invokes the same animated column transition as the conversation's Back control; short and vertical drags remain available to the transcript.
- The project document catalog includes Markdown, HTML, and supported source-code metadata so links can resolve, but the Browse Files UI filters its list to Markdown and HTML. Markdown is parsed into safe native SwiftUI blocks for headings, paragraphs, lists, quotes, rules, and fenced code, with inline Markdown handled by `AttributedString`. HTML uses a `WKWebView` with JavaScript disabled and network subresources blocked. Source code is reachable only through explicit conversation or document links and uses a native selectable monospaced view with line numbers and two-axis scrolling. Explicit taps route web links to the system and translate Mac-absolute or document-relative project links back to host document IDs.

## Data flow

On connection, the app authenticates `/v1/health`, then fetches projects and sessions. The client places sessions with the host-persisted `isPinned` flag first, sorts each group by server activity time, and presents the first 50. Creating a session from the global list asks for a project; creating one from a conversation reuses that conversation's project. Both paths post the opaque project ID, insert the returned server model, and select the new session. Rename and Pin/Unpin send partial `PATCH /v1/sessions/{id}` updates and replace the local session with the persisted response. Delete sends `DELETE /v1/sessions/{id}`, then removes the confirmed session plus its local draft and queued prompts; the host returns `409 Conflict` rather than deleting a running session. Sending a prompt waits for `202 Accepted`, marks the local session running, then polls its detail endpoint about once per second while active work remains. Each running-session snapshot may include one transient `currentReasoning` summary; the conversation replaces its prior working text with that value and removes the working surface once the host reports completion. Additional prompts entered while the session is running are persisted locally in FIFO order. When the host reports that a turn has completed, the app submits exactly one next queued prompt; it removes that item only after the host returns `202 Accepted`. Failed or interrupted submissions remain queued for a later reconnect or foreground refresh.

Opening a conversation fetches its Make target configuration. Target selection uses the existing session `PATCH`; starting Make or Commit & Push posts a typed command request and then follows the same session polling path. A pending command is identified by the message's `projectCommandResultID`, so it counts as active work without pretending that Codex itself is running. Full output is never returned in the session snapshot. Tapping the row fetches `/v1/sessions/{session-id}/project-commands/{result-id}` and refreshes that result while it remains active.

While an agent turn or project command is running, leaving the foreground persists the active session IDs and submits a `BGAppRefreshTaskRequest` with an earliest begin date five minutes later. No request is submitted when every session is idle. Each system-granted wake first waits for the Mac health endpoint, then performs one session-list request, schedules the existing local completion notification before yielding its background time, and submits another request only if work remains active. A failed health check never reads session status and leaves another refresh requested for the still-watched work. Persisted watched IDs allow a completion to be recognized even if iOS terminated and relaunched the app between checks. Returning to the foreground cancels pending background requests, resumes one-second active polling, refreshes the server snapshot, and then marks the selected conversation read. Background refresh timing remains entirely system-managed and may occur later than the requested earliest date.

Debug fixtures provide the same 120-message conversation through direct restoration, global-list selection, and switching from another conversation. The UI integration suite launches each fixture, performs the real navigation actions, and asserts that the last transcript row is hittable while the first row remains above the viewport.

Every full or per-session server snapshot recomputes the total unread-session count and sends it to iOS as the app icon badge. Marking a session read therefore decrements or clears the badge immediately after the host confirms the change. Badge display still respects the user's system notification settings.

The UI treats connectivity and agent execution as independent states: losing the host does not rewrite a server-provided `isRunning` value.

## Security and trust boundaries

- The token is never written to logs, errors, analytics, or app preferences. Its input uses a privacy-sensitive secure field.
- App Transport Security allows local networking but does not enable arbitrary internet loads.
- Server IDs and timestamps are authoritative. Desktop paths are display-only.
- Make and Git executables are never launched on iOS. Command names, output, exit status, and session ownership come from the authenticated Mac host.
- Message Markdown is parsed as presentation text. Links have their destinations removed and code is never executed.
- This release relies on physical local-network access plus a bearer token. TLS and paired device credentials are recommended follow-up work.
