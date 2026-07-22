import AppKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settings: AppSettings

  var body: some View {
    TabView {
      generalSettings
        .tabItem { Label("General", systemImage: "gear") }
      MobileActivityLogView(model: model)
        .tabItem { Label("Mobile Debug", systemImage: "network") }
    }
    .frame(width: 780, height: 570)
  }

  private var generalSettings: some View {
    Form {
      Section("Projects") {
        LabeledContent("Projects folder") {
          HStack {
            TextField("Path", text: $settings.projectsRoot)
              .frame(width: 300)
            Button("Choose…", action: chooseProjectsFolder)
          }
        }
        LabeledContent("Codex CLI") {
          TextField("Executable path", text: $settings.codexPath)
            .frame(width: 380)
        }
        LabeledContent("Model") {
          HStack {
            Picker("Model", selection: $settings.codexModel) {
              Text("Codex default").tag("")
              ForEach(model.codexModels) { option in
                Text(option.displayName).tag(option.id)
              }
              if !settings.codexModel.isEmpty,
                !model.codexModels.contains(where: { $0.id == settings.codexModel })
              {
                Text("\(settings.codexModel) (Custom)").tag(settings.codexModel)
              }
            }
            .labelsHidden()
            .frame(width: 240)
            if model.isRefreshingCodexModels {
              ProgressView()
                .controlSize(.small)
            } else {
              Button {
                Task { await model.refreshCodexModels() }
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .help("Refresh models from Codex CLI")
            }
          }
        }
        LabeledContent("Custom model ID") {
          TextField("Optional model identifier", text: $settings.codexModel)
            .frame(width: 240)
        }
        Text(modelCatalogDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Refresh Projects") { Task { await model.refreshProjects() } }
      }

      Section("Local Network API") {
        Toggle("Allow local network clients", isOn: $settings.apiEnabled)
        LabeledContent("Port") {
          TextField("Port", value: $settings.apiPort, format: .number)
            .frame(width: 90)
        }
        LabeledContent("Bearer token") {
          HStack {
            SecureField("Token", text: $settings.apiToken)
              .textFieldStyle(.roundedBorder)
              .frame(width: 300)
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(settings.apiToken, forType: .string)
            }
            Button("Regenerate") { settings.regenerateToken() }
          }
        }
        LabeledContent("Status") { Text(model.apiStatus).foregroundStyle(.secondary) }
        Text(
          "Enabled and port changes apply automatically. Remote Agent also advertises _remoteagent._tcp with Bonjour."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Button("Restart API Now") { model.restartAPI() }
      }

      Section("Reliability") {
        Toggle("Automatically relaunch after a crash", isOn: $settings.autoRelaunchAfterCrash)
        LabeledContent("Crash watchdog") {
          Text(model.crashRelaunchStatus)
            .foregroundStyle(.secondary)
        }
        Text("Remote Agent relaunches after an unclean exit, but stays closed after a normal Quit.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Appearance") {
        LabeledContent("App appearance") {
          Picker("App appearance", selection: $settings.appearance) {
            ForEach(AppAppearance.allCases) { appearance in
              Text(appearance.label).tag(appearance)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 240)
        }
        LabeledContent("Conversation text") {
          HStack {
            Slider(value: $settings.fontScale, in: 0.7...1.8, step: 0.1)
              .frame(width: 220)
            Text("\(Int(settings.fontScale * 100))%")
              .monospacedDigit()
              .frame(width: 45, alignment: .trailing)
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .onChange(of: settings.apiEnabled) { _, _ in model.restartAPI() }
    .onChange(of: settings.codexModel) { _, value in model.applyCodexModel(value) }
    .onChange(of: settings.apiPort) { _, _ in model.scheduleAPIRestart() }
    .onChange(of: settings.autoRelaunchAfterCrash) { _, _ in
      model.configureCrashRelaunch()
    }
    .task { await model.refreshCodexModels() }
  }

  private var modelCatalogDescription: String {
    if let error = model.codexModelCatalogError {
      return
        "Could not load models from Codex CLI: \(error) You can still enter a model ID manually."
    }
    if model.codexModels.isEmpty {
      return
        "Leave the model blank to use Codex configuration, or enter a model ID manually. The choice applies to every session."
    }
    return
      "Models are loaded from the Codex CLI. Leave the model blank to use Codex configuration. The choice applies to every session."
  }

  private func chooseProjectsFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: settings.projectsRoot)
    if panel.runModal() == .OK, let url = panel.url {
      settings.projectsRoot = url.path
      Task { await model.refreshProjects() }
    }
  }
}
