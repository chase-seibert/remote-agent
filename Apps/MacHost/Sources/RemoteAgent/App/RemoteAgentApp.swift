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
