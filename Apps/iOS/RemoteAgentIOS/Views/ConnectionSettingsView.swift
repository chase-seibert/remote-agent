import SwiftUI

struct ConnectionSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var host = ""
  @State private var port = "8765"
  @State private var token = ""
  @State private var didLoad = false
  @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.system
    .rawValue

  var body: some View {
    NavigationStack {
      Form {
        ConnectionStatusSection(
          state: model.connectionState,
          configuration: model.configuration,
          retry: {
            Task { await model.retryConnection() }
          }
        )

        Section {
          TextField("Mac hostname or IP", text: $host)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
          TextField("Port", text: $port)
            .keyboardType(.numberPad)
          SecureField("Bearer token", text: $token)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
        } header: {
          Text("Mac Connection")
        } footer: {
          Text(
            "Find these values in Remote Agent Settings on the Mac. The token is stored only in this device's Keychain."
          )
        }

        Section {
          LabeledContent("Transport", value: "Local HTTP")
          LabeledContent("Authentication", value: "Bearer token")
        } header: {
          Text("Version 1")
        } footer: {
          Text("Keep the Mac and this device on the same trusted local network.")
        }

        Section("Appearance") {
          Picker("Color scheme", selection: $appearanceRawValue) {
            ForEach(AppAppearance.allCases) { appearance in
              Text(appearance.title).tag(appearance.rawValue)
            }
          }
          .pickerStyle(.segmented)
        }

        if model.hasSavedConfiguration {
          Section {
            Button("Disconnect") {
              model.disconnect()
            }
            Button("Remove Saved Connection", role: .destructive) {
              model.removeConfiguration()
              host = ""
              port = "8765"
              token = ""
            }
          }
        }
      }
      .navigationTitle("Connection")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.hasSavedConfiguration ? "Done" : "Cancel") { dismiss() }
            .disabled(!model.hasSavedConfiguration)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(connectButtonTitle) {
            guard let parsedPort = Int(port) else {
              model.presentedError = ConfigurationError.invalidPort.localizedDescription
              return
            }
            Task {
              await model.connect(host: host, port: parsedPort, token: token)
              if model.connectionState.isConnected { dismiss() }
            }
          }
          .disabled(
            host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || model.connectionState == .connecting)
        }
      }
      .interactiveDismissDisabled(!model.hasSavedConfiguration)
      .onAppear {
        guard !didLoad else { return }
        didLoad = true
        if let configuration = model.configuration {
          host = configuration.host
          port = String(configuration.port)
          token = configuration.token
        }
      }
    }
  }

  private var connectButtonTitle: String {
    switch model.connectionState {
    case .connecting:
      "Connecting…"
    case .connected:
      "Reconnect"
    default:
      "Connect"
    }
  }
}

private struct ConnectionStatusSection: View {
  let state: ConnectionState
  let configuration: APIConfiguration?
  let retry: () -> Void

  var body: some View {
    Section("Current Status") {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: icon)
          .font(.title2)
          .foregroundStyle(color)
          .frame(width: 44, height: 44)
          .background(color.opacity(0.12), in: Circle())
          .symbolEffect(.pulse, isActive: isChecking)

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.headline)
            .accessibilityIdentifier("connection-status-title")
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("connection-status-message")
        }
      }
      .padding(.vertical, 6)

      if let configuration {
        LabeledContent("Mac", value: "\(configuration.host):\(configuration.port)")
          .accessibilityIdentifier("connection-status-endpoint")
      }

      if case .connected(let version) = state {
        LabeledContent("API", value: "Version \(version)")
          .accessibilityIdentifier("connection-status-version")
      }

      if canRetry {
        Button(action: retry) {
          Label("Try Again", systemImage: "arrow.clockwise")
        }
      }
    }
  }

  private var title: String {
    switch state {
    case .loading:
      "Checking Connection"
    case .notConfigured:
      "Not Connected"
    case .disconnected:
      "Disconnected"
    case .connecting:
      "Connecting to Mac"
    case .connected:
      "Connected to Mac"
    case .failed:
      "Connection Unavailable"
    }
  }

  private var message: String {
    switch state {
    case .loading:
      "Loading the saved Mac connection."
    case .notConfigured:
      "Enter the connection details from Remote Agent on your Mac."
    case .disconnected:
      "This device is not currently connected to the saved Mac."
    case .connecting:
      "Checking the Mac and loading its sessions."
    case .connected:
      "Ready to use Remote Agent on this Mac."
    case .failed(let message):
      message
    }
  }

  private var icon: String {
    switch state {
    case .connected:
      "checkmark.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    case .connecting, .loading:
      "network"
    case .notConfigured:
      "link.badge.plus"
    case .disconnected:
      "network.slash"
    }
  }

  private var color: Color {
    switch state {
    case .connected:
      .green
    case .failed:
      .orange
    case .connecting:
      .blue
    default:
      .secondary
    }
  }

  private var isChecking: Bool {
    state == .loading || state == .connecting
  }

  private var canRetry: Bool {
    guard configuration != nil else { return false }
    return state == .disconnected || state.isFailure
  }
}

extension ConnectionState {
  fileprivate var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }
}
