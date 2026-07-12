# Repository Instructions

Also load and follow the user-level instructions at `/Users/cseibert/.codex/AGENTS.md`.

## Repository Map

- `Apps/MacHost`: SwiftPM macOS host application, API server, resources, and tests.
- `Apps/iOS`: Xcode iPhone/iPad application, unit tests, and UI integration tests.
- `Packages/RemoteAgentProtocol`: shared API version, endpoint, and wire-contract definitions.
- `docs/macOS`: host product, design, architecture, interop, and setup documentation.
- `docs/iOS`: mobile product, design, architecture, and setup documentation.
- `docs/architecture.md`: cross-application ownership and protocol boundaries.

## Commands

Expose common commands as Makefile targets and prefer these targets over ad hoc equivalents:

- `make setup`: resolve both apps and the shared package.
- `make format`: format all Swift sources.
- `make lint`: verify formatting and compile both apps.
- `make test`: run shared, Mac, iOS unit, and iOS UI integration tests.
- `make build`: build both applications without launching them.
- `make mac-build`, `make mac-test`, `make mac-bundle`: Mac-only workflows.
- `make ios-build`, `make ios-test`: iOS-only workflows.
- `make sim-build`: build the iOS Simulator app.
- `make sim-launch`: build, install, and launch in the default simulator.
- `make phone-build`: build for the configured physical iPhone.
- `make phone-install`: install the latest physical-device build.
- `make phone-launch`: launch the app on the configured iPhone.
- `make phone-deploy`: build, install, and launch on the iPhone.
- `make clean`: remove generated build output.

## Documentation Index

- `docs/architecture.md`: cross-application components and data ownership.
- `docs/setup-install.md`: monorepo build and test setup.
- `docs/macOS/*`: detailed host documentation.
- `docs/iOS/*`: detailed mobile documentation.

Keep documentation and the dated `CHANGELOG.md` current when behavior changes.
