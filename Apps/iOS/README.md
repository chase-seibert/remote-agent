# Remote Agent for iOS

Remote Agent is a native iPhone and iPad client for the Remote Agent macOS host. It securely connects over the local network, browses projects and Codex sessions, creates sessions, submits prompts, and follows active turns to completion.

## Quick start

1. Open Remote Agent on the Mac and enable its local API in Settings.
2. Copy the Mac hostname or IP address, port, and bearer token.
3. Run `make sim-launch` or `make phone-deploy`.
4. Enter the host details in the iOS connection screen and tap **Connect**.

The bearer token is stored in Keychain. The hostname and port are stored in app preferences. Version one intentionally supports local-network HTTP only.

See [the iOS setup guide](../../docs/iOS/setup-install.md) for full setup and troubleshooting.

## Development

- `make sim-build` — compile without code signing.
- `make test` — run the unit test suite on the default simulator.
- `make sim-launch` — launch in an iPhone 17 Pro simulator.
- `make phone-deploy` — sign, install, and launch on Chase's iPhone 17 Pro.
- `make format` / `make lint` — format and validate Swift source.
