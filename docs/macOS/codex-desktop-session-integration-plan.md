# Codex Desktop Session Integration Plan

## Status

Optional future work. No implementation has been approved.

The prospects are good for listing and reading sessions created by other Codex desktop surfaces. Directly sharing a live session between two apps introduces meaningful synchronization complexity. The recommended stopping point is an opt-in, read-only catalog with **Fork into Remote Agent** as the initial interaction model.

## Verified feasibility

On 2026-07-11, the installed Codex CLI and app-server were inspected without changing any sessions.

- `thread/list` returned persisted sessions with thread ID, project path, title, preview, timestamps, source, and runtime status.
- The list included the active Remote Agent macOS development task and other desktop-created tasks.
- `thread/read` returned the full stored history for the Remote Agent development task: 10 turns and 112 items.
- The supported app-server surface includes `thread/list`, `thread/read`, `thread/resume`, and `thread/fork`.
- `codex exec resume <thread-id>` can continue a known saved session, but the ordinary CLI has no suitable machine-readable session-list command.

The app-server is still launched through the Codex CLI, so this approach keeps the CLI as Remote Agent's interoperability boundary and avoids parsing private files under `~/.codex`.

Reference: [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server).

## Important caveats

- Desktop sessions currently appeared with source `vscode`, not a dedicated `desktop` source value. The product should call them **Other Codex Sessions** and identify them by excluding thread IDs already owned by Remote Agent.
- The installed CLI labels the app-server command experimental, even though the protocol documentation distinguishes stable methods from explicitly experimental methods and fields.
- Generated protocol schemas are specific to the installed Codex version. Compatibility must be checked after CLI upgrades.
- Runtime status is scoped to an app-server process. It may not reliably show that the same thread is active in another Codex surface.
- External sessions can contain reasoning, tool calls, images, file changes, approvals, and other item types that Remote Agent does not currently render.
- Interactive approvals would require a deeper app-server integration. The existing one-shot `codex exec` path is intentionally non-interactive.

## Recommended phases

| Phase | Capability | Complexity |
| --- | --- | --- |
| 1 | Technical spike only | Small |
| 2 | Opt-in read-only session catalog | Small–medium |
| 3 | Fork desktop session into Remote Agent | Medium |
| 4 | Continue the exact same session | Medium–high |
| 5 | Full live synchronization and approvals | High |

## Phase 1: bounded technical spike

Build a small `CodexSessionCatalog` prototype that launches `codex app-server` over stdio and performs:

1. `initialize`
2. `thread/list`
3. `thread/read`
4. `thread/fork`
5. Resume the fork through the existing `codex exec resume` implementation

Keep this out of the UI. Verify that:

- Pagination and project filtering work.
- User and agent text can be mapped into the existing transcript model.
- A fork preserves useful conversation context.
- The original desktop thread remains unchanged.
- Unsupported or changed protocol versions fail with a clear compatibility error.
- The implementation never reads private Codex session files directly.

Stop after this phase if the adapter is brittle or requires a persistent process.

## Phase 2: opt-in read-only catalog

Add a Settings toggle that defaults off:

> Show Other Codex Sessions

When enabled:

- Refresh only when requested by the user; do not poll in the background.
- Use a short-lived stdio app-server process for discovery and reads.
- Group sessions into projects using the exact `cwd` returned by Codex.
- Deduplicate sessions whose thread IDs Remote Agent already owns.
- Display an **External** badge.
- Load the transcript lazily with `thread/read` when selected.
- Render user and agent messages only.
- Omit reasoning, tool calls, file changes, images, and other unsupported items.
- Store only the external thread ID, local read state, and last-seen update timestamp. Treat Codex as the transcript source of truth.

This phase should remain useful even if interaction is never implemented.

## Phase 3: safe interaction through forking

Give an external session one primary action:

> Fork into Remote Agent

The action should:

1. Call `thread/fork` for the external thread.
2. Create a Remote Agent session using the returned thread ID.
3. Refresh the forked transcript.
4. Continue through the existing CLI turn implementation.

Forking preserves context while keeping the original desktop conversation unchanged. It avoids simultaneous writers and fits Remote Agent's current ownership and persistence model. This is the recommended shipping boundary.

## Phase 4: direct continuation

Only add **Continue Original Session** if users clearly need it. Keep it behind an advanced setting or explicit warning.

Before and after every prompt:

1. Refresh the complete thread.
2. Reconcile turns added by another surface.
3. Detect changes since the transcript was opened.
4. Refuse to send when concurrent activity is suspected.
5. Send the prompt.
6. Refresh and reconcile again after completion.

This phase requires an explicit concurrency policy. Cross-process runtime status alone should not be treated as a reliable lock.

## Phase 5: full app-server integration

Pursue this only if shared-session operation becomes a core product requirement. Replace one-shot `codex exec` calls with a persistent app-server connection and implement:

- Streamed agent and tool events
- Approval and user-input requests
- Turn interruption and steering
- Reconnection and process recovery
- Protocol-version compatibility handling
- Tool, command, file-change, reasoning, and image items
- Cross-surface conflict resolution

This would be a substantial architectural change and is not recommended for the current product scope.

## Complexity guardrails

- Use the official app-server through the Codex CLI.
- Never parse `~/.codex/sessions` directly.
- Keep discovery disabled by default.
- Use manual refresh rather than polling.
- Load transcripts lazily.
- Support text messages only at first.
- Prefer forking over direct shared-thread mutation.
- Do not implement approval or tool-event UI in the initial version.
- Generate protocol schemas from the installed CLI rather than copying private structures.
- Keep the existing `CodexCLIClient` as the turn-execution path unless a later phase explicitly replaces it.

## Decision gates

Proceed from the spike only if all of the following are true:

- List and read operations remain stable across at least one Codex CLI upgrade.
- Desktop sessions can be mapped to projects without source-specific heuristics beyond `cwd` and deduplication.
- Forked sessions can continue through the existing CLI implementation.
- Errors are recoverable without corrupting or hiding the user's existing Codex sessions.
- The implementation remains isolated behind a small catalog adapter.

Do not proceed to direct continuation unless concurrent access can be detected or prevented safely.

## Recommendation

Approve only Phase 1 initially. If the spike stays small and reliable, Phases 2 and 3 provide most of the value without turning Remote Agent into another full Codex desktop client.
