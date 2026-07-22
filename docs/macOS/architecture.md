# Architecture

Remote Agent is a dependency-free Swift package that is packaged as a conventional macOS `.app`. SwiftUI owns the application and windows; Foundation, Speech, AVFoundation, Network, and AppKit provide platform integration.

```mermaid
flowchart LR
    U["macOS SwiftUI UI"] --> M["AppModel"]
    I["iOS client"] -->|"HTTP + bearer token"| H["Network.framework server"]
    H --> M
    M --> P["SessionStore JSON"]
    M --> C["CodexCLIClient"]
    C -->|"codex exec --json"| X["Codex CLI"]
    X --> W["Selected project workspace"]
    X --> G["Existing Codex config and plugins"]
    M --> R["ProjectCommandService"]
    R -->|"make target"| W
    R -->|"git commit, optional git push"| W
    R --> F["Apple Foundation Models"]
    M --> Q["ProjectCommandResultStore JSON"]
```

## Components

- `AppModel` is the main-actor source of truth for projects, local sessions, global recent-session selection, active turns, per-session FIFO prompt queues, errors, and API routing. It persists queue mutations immediately, removes only the item beginning execution, and drains the next item after an agent turn or project command finishes; persisted idle queues resume after host launch without an iOS process. The Mac sidebar derives a deterministic view capped at 50 sessions, with pinned sessions first and activity ordering within each group; persistence and API results retain the full collection.
- Session pin state is persisted metadata and does not alter activity timestamps. Deletion removes the local transcript only after confirmation in the Mac UI and rejects active sessions so in-flight Codex results cannot be orphaned. The authenticated API exposes the same behavior through session `PATCH` and `DELETE`, and returns pinned-first session lists.
- Session renames are validated metadata updates persisted through `SessionStore`; they do not change activity timestamps or interrupt active turns.
- `ProjectScanner` invokes `/usr/bin/find` to list immediate child directories of the configured root. Codex currently has no stable, non-interactive machine-readable project-list command.
- `CodexCLIClient` launches the configured Codex executable with `Process`, applies each session's optional model identifier with `--model`, sends prompts over standard input, line-buffers streamed JSONL events, records the returned thread ID, publishes completed reasoning summaries during a turn, and resumes the thread on future turns. It requests summary reasoning while explicitly keeping raw reasoning hidden. `CodexModelCatalogClient` invokes `codex debug models`, decodes the JSON catalog, removes hidden and duplicate entries, and priority-orders the options for the Settings and new-session pickers; the authenticated `/v1/models` endpoint shares that same catalog with iOS. Discovery failures leave prompt execution and the custom model-ID fallback available.
- `ProjectCommandService` discovers Make targets from `.PHONY` declarations with a conservative target-declaration fallback, invokes `/usr/bin/make` and `/usr/bin/git` directly without a shell, merges stdout and stderr, and caps retained output at 512 KB per run. Commit & Push first invokes `git add --all`. On macOS 26 or later it prioritizes staged changelog and product-requirement hunks as behavioral context, falling back to a compact zero-context source diff that excludes Xcode project metadata. It gives that bounded context and the changed-path summary to Apple's on-device Foundation Models General model and requests a plain-text imperative outcome subject with greedy sampling. Generation has no response-token cutoff because truncating model output can make an otherwise valid subject unusable; the local sanitizer enforces the one-line 72-character limit before passing it to `git commit -m`. After a successful commit, it resolves the current branch's upstream and invokes ordinary `git push` only when that upstream exists; no upstream is treated as a successful commit with no push attempt.
- `ProjectCommandResultStore` keeps the 200 most recent local command results under Application Support. Transcript messages contain only a running, success, or failure placeholder keyed by the same UUID; completion updates the original row in place. Full commands and output are excluded from session snapshots and exposed only through an authenticated, session-scoped result endpoint.
- The active Make target is session metadata persisted by `SessionStore`. Legacy per-session target preferences migrate into the session record at launch, and both toolbar and Project-menu pickers read that same authoritative value.
- `SessionStore` atomically persists Remote Agent's session metadata, including the host-selected Codex model, visible transcripts, queued prompts, and a monotonic content revision under Application Support. Every API-visible session mutation advances that revision; transient reasoning is returned directly by the status endpoint and does not advance it. Codex separately persists its own conversation/tool state.
- `SpeechTranscriber` uses `SFSpeechRecognizer` and `AVAudioEngine`; speech is only an input method and does not change the agent protocol.
- `LocalLinkResolver` recognizes absolute, `file://`, and project-relative filesystem links. Markdown, HTML, and supported source-code files are routed to typed SwiftUI document windows; other local files use Launch Services, and network URLs remain system-handled.
- `RemoteAPIServer` is a small HTTP/1.1 server built on Network.framework. It listens on IPv4/IPv6 with peer-to-peer support, advertises `_remoteagent._tcp` through Bonjour, accepts one request per connection, and delegates state changes to `AppModel`. The listener queue owns only listener and admission state; every accepted socket has its own serial queue for incremental header parsing, body collection, response delivery, and teardown. The parser scans new header bytes once, caches the parsed head while the body arrives, caps headers at 32 KB and bodies at 2 MB, and rejects invalid framing. Global and per-source connection and handler limits reserve capacity for health and session-status reads. Header, body-idle, total-body, handler-response, and response-write deadlines release stalled sockets. For clients that advertise `deflate`, response bodies of at least 32 KB are compressed when doing so reduces their wire size; this keeps growing session snapshots comfortably below constrained mobile receive windows. A successful response half-closes the server's output and keeps the connection alive until the client closes its side, preventing cancellation from discarding large response bytes still queued in Network.framework; the response-write deadline also bounds this drain when a client stops reading. Handler work is intentionally not retained or cancelled by the connection: once admitted it continues after a disconnect or response deadline, while its bounded handler-capacity token remains held until completion. The server retains accepted connections until teardown and closes all sockets when the listener stops or restarts. Restarts are serialized across generations, wait for Network.framework's `.cancelled` listener state before rebinding the same port, and briefly retry `EADDRINUSE` in case the kernel is still releasing the socket.
- `ProjectDocumentService` discovers read-only Markdown, HTML, and common source-code files inside a selected project for mobile viewing. It skips hidden and common generated directories, does not follow content outside the project root, returns newest-modified files first, and limits reads to 10 MB of UTF-8 text.
- `APIActivityStore` keeps the 500 most recent HTTP request summaries under Application Support. It records timestamps, source hosts, client identifiers, routes, response statuses, logical response payload byte counts before transport compression, and routing durations, but never authorization headers or request bodies. Older entries without a payload count remain decodable. An actor batches reconnect bursts into one main-actor publication, and the app coalesces nearby disk writes, so Mobile Debug logging cannot create a SwiftUI backlog that delays later API requests.
- `APIListenerAddressResolver` enumerates every active IPv4 and IPv6 interface address while the listener is ready. Mobile Debug can issue a short authenticated request from the Mac to `/v1/health` through each exact address and bound port, exposing routing, interface, authentication, or listener failures independently of the phone.
- `CrashRelaunchController` arms a small bundled watchdog process while the app is running. A marker removed during normal termination prevents relaunch after Quit; an unclean exit leaves the marker armed so the watchdog reopens the same app bundle.

## Turn data flow

1. The app appends and persists the user's message, then marks the session running.
2. A new session runs `codex exec --json --color never --skip-git-repo-check [--model <model>] -C <project> -`.
3. A continued session runs `codex exec resume --json --skip-git-repo-check [--model <model>] <thread-id> -` with the project as its process working directory.
4. The JSONL parser captures `thread.started`, replaces the session's transient `currentReasoning` whenever a completed reasoning summary arrives, and captures the final completed `agent_message`.
5. The app persists the Codex thread ID and assistant response, clears running state and `currentReasoning`, then immediately removes and starts the next queued prompt when present.
6. Clients observe the running turn and remaining host-owned queue through a compact status poll. A changed content revision causes a targeted full-session fetch; `SessionStore` never writes `currentReasoning` to disk.

## Tradeoffs and boundaries

- CLI execution preserves Codex configuration/plugin behavior and avoids coupling to private APIs, at the cost of one process per turn.
- The visible transcript is duplicated locally so the app and iOS API remain fast and stable even if Codex's private storage format changes.
- Version one returns a `202 Accepted` for phone-submitted prompts and uses polling rather than implementing WebSockets or server-sent events.
- Because HTTP connections are short-lived, “mobile active” means a non-loopback request reached the Mac within the last 30 seconds; it does not imply a continuously connected socket.
- The HTTP server has bearer-token authentication but no TLS. It is intended only for a trusted local network. Bonjour provides discovery but not trust; a later release should add key pairing, TLS, and token rotation UX before enabling broader access.
- There is no approval bridge in version one. The effective Codex sandbox and approval behavior comes from the user's Codex CLI configuration; Remote Agent never passes a dangerous bypass flag.
- Project commands require an explicit toolbar or Project-menu action, run one at a time per session, and are disabled while its Codex turn is active. Commit & Push stages all changes and never forces; its push step is silently omitted when the current branch has no upstream. No project action uses a shell. Foundation Models availability depends on macOS 26, Apple Intelligence support, enablement, and model readiness; unavailable generation produces a failed placeholder rather than falling back to a remote model.
