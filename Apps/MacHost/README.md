# Remote Agent

Remote Agent is a native macOS SwiftUI client for running Codex CLI sessions inside local projects. It discovers projects under a configurable folder, starts and resumes persisted Codex sessions, keeps a local conversation index, accepts typed or dictated prompts, runs Make and Git project commands, and exposes an authenticated local-network API for a future iOS client.

The Codex CLI remains the agent interoperability boundary. Remote Agent invokes `codex exec --json` for the first turn and `codex exec resume --json` for every later turn, so existing Codex configuration and installed plugins remain available to the session.

## Quick start

Requirements: macOS 14 or later, Xcode/Swift 6, and a logged-in Codex CLI.

The Git Commit control requires macOS 26 or later with Apple Intelligence enabled because it generates its one-line subject with Apple's on-device Foundation Models framework. Make and Git Push remain available on the app's macOS 14 minimum deployment target.

```sh
make test
make run
```

The packaged app is created at `build/Remote Agent.app`. By default, project discovery scans `~/projects`, the app looks for the Codex executable bundled with ChatGPT, and the local API listens on port `8765` with a generated bearer token shown in Settings. The shared 1024px Mac/iOS icon source is at `Resources/AppIcon/RemoteAgentIcon-1024.png`; `make icons` derives the macOS `.icns` from it.

See [setup and installation](../../docs/macOS/setup-install.md), [architecture](../../docs/macOS/architecture.md), the [iOS client interoperability plan](../../docs/macOS/ios-client-interop.md), and the optional [Codex desktop session integration plan](../../docs/macOS/codex-desktop-session-integration-plan.md).
