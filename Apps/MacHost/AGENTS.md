# Repository Instructions

Also load and follow the user-level instructions at `/Users/cseibert/.codex/AGENTS.md`.

## Repository Map

- `Sources/RemoteAgent/App`: app lifecycle, settings, and shared application model.
- `Sources/RemoteAgent/CLI`: Codex CLI execution, JSONL parsing, and project discovery.
- `Sources/RemoteAgent/Models`: persisted domain models.
- `Sources/RemoteAgent/Persistence`: local session metadata and transcript persistence.
- `Sources/RemoteAgent/Services`: speech transcription and local HTTP server.
- `Sources/RemoteAgent/Views`: native SwiftUI views.
- `Tests/RemoteAgentTests`: unit tests.
- `Resources`: macOS bundle metadata.
- `scripts`: app packaging scripts.
- `../../docs/macOS`: product, design, architecture, setup, and client interoperability docs.

## Commands

Expose common commands as Makefile targets and prefer these targets over ad hoc equivalents:

- `make setup`: resolve the Swift package.
- `make format`: format Swift sources.
- `make lint`: check Swift formatting.
- `make test`: run unit tests.
- `make build`: compile the app executable.
- `make icons`: generate the macOS `.icns` from the shared 1024px Mac/iOS source icon.
- `make bundle`: create and ad-hoc sign `build/Remote Agent.app`.
- `make run`: rebuild, relaunch, and open the app.
- `make clean`: remove generated build output.

## Documentation Index

- `../../docs/macOS/initial-brainstorm.md`: original product request and initial scope.
- `../../docs/macOS/product-requirements.md`: user-centered requirements.
- `../../docs/macOS/architecture.md`: components, data flow, and tradeoffs.
- `../../docs/macOS/design.md`: macOS interaction and visual design.
- `../../docs/macOS/setup-install.md`: local build, launch, and permissions.
- `../../docs/macOS/ios-client-interop.md`: local-network protocol for the iOS app.
- `../../docs/macOS/codex-desktop-session-integration-plan.md`: optional staged plan for discovering, reading, and safely forking sessions created by other Codex surfaces.

Keep these documents and the dated `CHANGELOG.md` current when behavior changes.
