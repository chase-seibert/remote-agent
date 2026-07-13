# Setup and Installation

## Mac host

1. Build and open the Remote Agent macOS app from `Apps/MacHost`.
2. In its Settings, enable the API server and confirm port `8765` (or note the configured port).
3. Copy the API token and find the Mac's local hostname, such as `chases-mac.local`, or its LAN IP address.
4. Keep the Mac awake and ensure both devices are on the same local network.

## iOS app

Open `Apps/iOS/RemoteAgentIOS.xcodeproj` in Xcode, or use the root Makefile:

```sh
make sim-launch
```

For Chase's configured iPhone 17 Pro and Apple Personal Team:

```sh
make phone-deploy
```

To inspect the global recent-sessions list with pinned, running, unread, failed, and read states:

```sh
make sim-recent-sessions-fixture
```

To inspect a conversation with the unread marker beside its Back control:

```sh
make sim-recent-session-detail-fixture
```

To inspect the session rename editor with mixed recent-session fixture data:

```sh
make sim-rename-session-fixture
```

To inspect a running conversation with multiple queued prompts:

```sh
make sim-prompt-queue-fixture
```

To verify that a restored multi-screen conversation opens at its latest message:

```sh
make sim-long-conversation-fixture
```

Equivalent fixtures start from the global session list or from another active conversation:

```sh
make sim-long-conversation-from-list-fixture
make sim-long-conversation-from-session-fixture
```

Run the XCUITest journeys for all three entry paths with:

```sh
make integration-test
```

To inspect the native source-code preview with line numbers and long-line scrolling:

```sh
make sim-code-preview-fixture
```

To verify that Browse Files lists Markdown and HTML while omitting source code:

```sh
make sim-document-browser-fixture
```

On first connection, iOS asks for Local Network access. Allow it, then enter the Mac hostname/IP, port, and 64-character token. The host field accepts a bare hostname, an IPv4/IPv6 address, or an `http://` URL; version one rejects HTTPS and non-local transport assumptions.

Keep Background App Refresh enabled for Remote Agent in iOS Settings to permit opportunistic active-session checks after the app is suspended. These checks are requested only while the Mac reports active work; iOS chooses the actual execution time, so completion notifications may be delayed.

## Troubleshooting

- **Unauthorized:** copy the current token from the Mac app again.
- **Cannot connect:** verify the API is enabled, the Mac is awake, the port matches, and both devices are on the same Wi-Fi/VLAN.
- **Local Network denied:** enable Local Network for Remote Agent in iOS Settings.
- **Mac hostname fails:** use the Mac's current LAN IP address.
- **Session remains active after reconnecting:** pull to refresh or reopen the session; the server remains authoritative.
- **No background completion notification:** confirm notification permission and Background App Refresh are enabled for Remote Agent. iOS may defer or skip an individual background refresh request.
