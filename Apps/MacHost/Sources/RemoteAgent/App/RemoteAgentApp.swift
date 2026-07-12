import SwiftUI

@main
struct RemoteAgentApp: App {
  @NSApplicationDelegateAdaptor(RemoteAgentApplicationDelegate.self) private var appDelegate
  @StateObject private var settings: AppSettings
  @StateObject private var model: AppModel

  init() {
    let settings = AppSettings()
    _settings = StateObject(wrappedValue: settings)
    _model = StateObject(wrappedValue: AppModel(settings: settings))
  }

  var body: some Scene {
    Window("Remote Agent", id: "main") {
      ContentView(model: model, settings: settings)
        .preferredColorScheme(settings.appearance.colorScheme)
    }
    .defaultSize(width: 1_180, height: 760)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Session") { model.requestNewSession() }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(model.projects.isEmpty)
      }
      CommandGroup(after: .sidebar) {
        Button("Refresh Projects") { Task { await model.refreshProjects() } }
          .keyboardShortcut("r", modifiers: .command)
      }
      CommandMenu("Project") {
        if let session = model.selectedSession {
          let targets = model.makeTargets(for: session)
          let activeTarget = model.activeMakeTarget(for: session)
          let disabled =
            session.isRunning || model.isProjectCommandRunning(sessionID: session.id)

          Button(activeTarget.map { "Run make \($0)" } ?? "Run Make Target") {
            Task { await model.runActiveMakeTarget(sessionID: session.id) }
          }
          .disabled(disabled || activeTarget == nil)

          Menu("Make Target") {
            Picker(
              "Make Target",
              selection: Binding(
                get: { model.activeMakeTarget(for: session) ?? targets.first ?? "" },
                set: { model.selectMakeTarget($0, for: session) }
              )
            ) {
              ForEach(targets, id: \.self) { target in
                Text(target).tag(target)
              }
            }
            .pickerStyle(.inline)
            .labelsHidden()
          }
          .disabled(disabled || targets.isEmpty)

          Divider()

          Button("Commit and Push All Changes") {
            Task { await model.runGitCommitAndPush(sessionID: session.id) }
          }
          .disabled(disabled)
        } else {
          Text("Select a session to run project commands")
        }
      }
      CommandGroup(after: .toolbar) {
        Divider()
        Button("Make Text Bigger") { settings.increaseFontScale() }
          .keyboardShortcut("+", modifiers: .command)
        Button("Make Text Smaller") { settings.decreaseFontScale() }
          .keyboardShortcut("-", modifiers: .command)
        Button("Actual Text Size") { settings.resetFontScale() }
          .keyboardShortcut("0", modifiers: .command)
      }
    }

    WindowGroup("Document", for: LocalDocumentReference.self) { $reference in
      if let reference {
        DocumentViewerView(reference: reference, settings: settings)
          .preferredColorScheme(settings.appearance.colorScheme)
      }
    }
    .defaultSize(width: 820, height: 720)

    Settings {
      SettingsView(model: model, settings: settings)
        .preferredColorScheme(settings.appearance.colorScheme)
    }
  }
}
