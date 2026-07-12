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
              dismiss()
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
          Button("Cancel") { dismiss() }
            .disabled(!model.hasSavedConfiguration)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(model.connectionState == .connecting ? "Connecting…" : "Connect") {
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
}
