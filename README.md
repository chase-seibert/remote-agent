# Remote Agent

Remote Agent is a local macOS host and companion iOS client for working with Codex sessions away from the Mac. Both apps live in this monorepo so host UI, API, protocol, and mobile changes can ship atomically.

## Repository layout

- `Apps/MacHost`: SwiftPM macOS menu/window app and authenticated local-network API.
- `Apps/iOS`: SwiftUI iPhone/iPad client and its Xcode tests.
- `Packages/RemoteAgentProtocol`: shared endpoint definitions and API request contracts.
- `docs/macOS`: Mac host product and implementation documentation.
- `docs/iOS`: mobile product and implementation documentation.

## Common commands

```sh
make setup
make build
make test
make lint
```

App-specific commands are namespaced, including `make mac-build`, `make mac-test`, `make ios-build`, and `make ios-test`. `make mac-bundle` packages the Mac app without launching it; `make mac-run` explicitly rebuilds and restarts it.

See [docs/architecture.md](docs/architecture.md) for the product boundary and [docs/setup-install.md](docs/setup-install.md) for development setup.
