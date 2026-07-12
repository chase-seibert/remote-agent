import SwiftUI

@main
struct RemoteAgentIOSApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model = AppModel()
  @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.system
    .rawValue

  var body: some Scene {
    WindowGroup {
      Group {
        #if DEBUG
          if DebugAppFixture.documentBrowserEnabled {
            NavigationStack {
              ProjectDocumentBrowserFixtureView()
            }
          } else if DebugAppFixture.codePreviewEnabled {
            NavigationStack {
              CodePreviewFixtureView()
            }
          } else if DebugAppFixture.recentSessionDetailEnabled,
            model.selectedSession != nil
          {
            RootView()
              .environmentObject(model)
          } else if DebugAppFixture.renameSessionEnabled {
            NavigationStack {
              RecentSessionsView(
                showingConnectionSettings: .constant(false),
                presentsRenameOnAppear: true
              )
            }
            .environmentObject(model)
          } else if DebugAppFixture.recentSessionsEnabled {
            NavigationStack {
              RecentSessionsView(showingConnectionSettings: .constant(false))
            }
            .environmentObject(model)
          } else if DebugAppFixture.longConversationEnabled {
            RootView()
              .environmentObject(model)
          } else if DebugAppFixture.conversationEnabled, let session = model.selectedSession {
            NavigationStack {
              ConversationView(
                session: session,
                showingConnectionSettings: .constant(false),
                backToSessions: {}
              )
            }
            .environmentObject(model)
          } else {
            appRoot
          }
        #else
          appRoot
        #endif
      }
      .preferredColorScheme(appearance.colorScheme)
    }
  }

  private var appearance: AppAppearance {
    AppAppearance(rawValue: appearanceRawValue) ?? .system
  }

  private var appRoot: some View {
    RootView()
      .environmentObject(model)
      .task { await model.start() }
      .onChange(of: scenePhase) { _, phase in
        model.sceneActivityChanged(isActive: phase == .active)
      }
  }
}

enum AppAppearance: String, CaseIterable, Identifiable {
  static let storageKey = "appAppearance"

  case system
  case light
  case dark

  var id: Self { self }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}
