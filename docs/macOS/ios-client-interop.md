# iOS Client Interoperability Plan

## Scope and transport

The Mac is the host and the only machine that launches Codex. The iOS app is a thin client over HTTP/JSON on the same local network. Version one of the Mac host listens on all interfaces at the configurable TCP port `8765` and requires a bearer token on every request, including health checks.

The Mac advertises a Bonjour service named `Remote Agent` with type `_remoteagent._tcp`. Prefer `NWBrowser` discovery and use the discovered endpoint directly. Manual hostname/IP and port entry remains a fallback. Do not advertise or store the bearer token in Bonjour metadata.

Example base URL:

```text
http://chases-mac.local:8765
```

Every request includes:

```http
Authorization: Bearer <64-character-token>
Content-Type: application/json
```

The iOS app should also identify itself for the Mac debug log:

```http
X-Remote-Agent-Client: Remote Agent iOS/1.0
```

This header is optional for protocol compatibility. Without it, the Mac falls back to the standard `User-Agent` header. Any non-loopback request updates the Mac toolbar’s mobile-activity indicator for 30 seconds and appears in Settings → Mobile Debug.

## API

### Health

`GET /v1/health`

```json
{"status":"ok","version":"1"}
```

### Projects

`GET /v1/projects`

Returns an array of `{ "id", "name", "path" }`. Treat `id` as opaque. The path is informational and must never be used as an iOS filesystem path.

### Sessions

`GET /v1/sessions` returns all locally indexed sessions with pinned sessions first, then most-recent activity within the pinned and unpinned groups.

`GET /v1/sessions?project_id=<opaque-project-id>` filters by project.

`POST /v1/sessions` creates an empty local session:

```json
{"projectID":"<opaque-project-id>"}
```

The response is `201 Created` with the full session. A session has a Remote Agent UUID `id`, an optional `codexSessionID`, project fields, title and timestamps, a `messages` array, `isRunning`, optional `currentReasoning`, `isUnread`, and `isPinned`. Dates use ISO 8601. Enum values are lowercase strings. `currentReasoning` contains only the latest concise reasoning summary while a turn is running; the host replaces it in place, clears it at completion, and never persists it.

`GET /v1/sessions/<session-uuid>` fetches one current session.

`PATCH /v1/sessions/<session-uuid>` updates session metadata without changing its activity timestamp. Rename with:

```json
{ "title": "A clearer session name" }
```

Titles are trimmed and must contain 1–120 characters. The response is `200 OK` with the full updated session.

Pin or unpin with:

```json
{ "isPinned": true }
```

The patch may include either or both fields. Pinning affects list ordering but not activity timestamps.

`DELETE /v1/sessions/<session-uuid>` permanently removes an idle session and its locally persisted transcript. The response is `200 OK` with the deleted session. Deleting a running session returns `409 Conflict`.

`POST /v1/sessions/<session-uuid>/read` marks a displayed session read and returns the updated session. The iOS client should call this only after presenting the newest result to the user; fetching a session does not implicitly mark it read.

### Submit a prompt

`POST /v1/sessions/<session-uuid>/messages`

```json
{"text":"Summarize this project and suggest the next task."}
```

The Mac validates that the session is idle, queues the Codex CLI turn, and responds immediately:

```http
HTTP/1.1 202 Accepted

{"sessionID":"<session-uuid>","status":"accepted"}
```

Poll `GET /v1/sessions/<session-uuid>` about once per second while `isRunning` is true. Replace the visible working summary with a non-empty `currentReasoning` value from each snapshot. Stop polling when `isRunning` becomes false, remove the working summary, then render the newly appended assistant or failed system message. Back off or stop polling when the app is backgrounded. Only one turn may run per session; a concurrent submission receives `409 Conflict`.

### Project documents

`GET /v1/documents?project_id=<opaque-project-id>` returns Markdown, HTML, and source-code metadata as `{ "id", "name", "relativePath", "kind", "byteCount" }`. Supported kinds are `markdown` for `.md` and `.markdown`, `html` for `.html` and `.htm`, and `code` for common programming, shell, data, configuration, and build-file extensions plus extensionless files such as `Dockerfile` and `Makefile`.

`GET /v1/documents/<document-id>?project_id=<opaque-project-id>` returns `{ "document": <metadata>, "content": "<UTF-8 text>" }`. Document IDs are opaque. The host only returns files discovered inside the selected project, skips hidden and common generated directories, and rejects content larger than 2 MB.

## Errors

Errors use an HTTP status and `{ "error": "human-readable detail" }`:

- `400`: malformed JSON, missing text, or unknown project.
- `401`: absent/incorrect bearer token.
- `404`: route or session not found.
- `409`: the session is already processing a turn and cannot accept the requested operation.
- `500`: host-side failure.

Codex execution failures are appended to the session as a `system` message whose state is `failed`; therefore a successfully accepted request can still result in a later agent failure.

## iOS implementation notes

- Use `URLSession` with Codable request/response types and Swift concurrency.
- Add `NSLocalNetworkUsageDescription` and `_remoteagent._tcp` under `NSBonjourServices` to the iOS app. Because version one is plain HTTP to a local host, add the narrow local-network App Transport Security allowance needed by the deployment target; do not add an arbitrary-loads exception for internet traffic.
- Store the token in Keychain, never `UserDefaults`, logs, analytics, crash fields, or screenshots.
- Model connection state separately from agent running state. The Mac can sleep, change IP addresses, close, or restart while a Codex turn is running.
- Use server-provided IDs and timestamps. Do not invent or parse Codex IDs on iOS.
- Preserve unsent draft text locally. Disable Send while the chosen session is running.
- Treat message text as untrusted display content. Render a safe Markdown subset and never execute links or code automatically.

## Recommended protocol evolution

1. Add an in-person pairing flow that exchanges a short-lived secret and stores a per-device credential.
2. Add TLS with a pinned pairing identity or move to Network.framework peer-to-peer encrypted parameters.
3. Add an event stream (WebSocket or server-sent events) with event IDs and reconnect support.
4. Add cancellation, transcript pagination, model/provider metadata, and capability negotiation.
5. Keep the public API provider-neutral: the Mac may later expose `provider: "codex" | "claude"`, while each provider adapter continues to use its own CLI internally.
