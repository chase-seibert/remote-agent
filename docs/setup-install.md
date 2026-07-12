# Development Setup

Run `make setup` from the repository root to resolve both applications and the shared local package. Use `make build` to compile the Mac executable and iOS simulator app without launching either application, or `make test` to run shared-package, Mac, iOS unit, and iOS integration tests.

The app-specific setup and deployment guides remain in:

- `docs/macOS/setup-install.md`
- `docs/iOS/setup-install.md`

The root targets delegate to each app directory, so existing device overrides continue to work, for example `make phone-build DEVICE_ID=… DEVELOPMENT_TEAM=…`.
