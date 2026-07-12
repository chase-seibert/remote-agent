# Setup and Installation

## Requirements

- macOS 14 or newer.
- Xcode 26 / Swift 6 toolchain (earlier Swift 6 toolchains may also work).
- A working, authenticated Codex CLI. By default the app uses `/Applications/ChatGPT.app/Contents/Resources/codex`; `/opt/homebrew/bin/codex` and `/usr/local/bin/codex` are fallbacks.

## Build and launch

```sh
make setup
make mac-test
make mac-run
```

`make mac-run` compiles the package, creates and ad-hoc signs `Apps/MacHost/build/Remote Agent.app`, terminates an older debug instance, and opens the new app. `make mac-build` compiles without relaunching the application. No third-party dependencies are installed.

## First launch

1. Open Settings and confirm the projects root and Codex CLI path.
2. Select a project, create a session, and submit a prompt.
3. The first dictation request prompts for Speech Recognition and Microphone access.
4. The first API connection may prompt for Local Network access.
5. Leave “Automatically relaunch after a crash” enabled unless another process manager owns the app lifecycle.

Session metadata and transcripts are stored at `~/Library/Application Support/Remote Agent/sessions.json`. Safe API request summaries are stored at `~/Library/Application Support/Remote Agent/api-activity.json`. The API bearer token and preferences are stored in the app's user defaults. Codex session data remains owned by Codex.

## Troubleshooting

- If Codex is not found, run `command -v codex` and paste the absolute result into Settings.
- If a session fails, verify `codex login status` and try an equivalent `codex exec` command in Terminal.
- If dictation is denied, enable Remote Agent under System Settings → Privacy & Security → Microphone and Speech Recognition.
- If the iOS client cannot connect, verify both devices are on the same trusted network, Local Network access is enabled, the Mac firewall permits Remote Agent, and the configured port is not in use.
- The Mac advertises a Bonjour service named `Remote Agent` with type `_remoteagent._tcp`. If discovery fails, use the Mac's current LAN IP and configured port directly.
- The crash watchdog exists only while Remote Agent is running. It relaunches the current bundle after a crash or force-kill, but does not launch at login and does not reopen after a normal Quit.
