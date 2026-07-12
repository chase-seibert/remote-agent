import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingConnectionSettings = false
  @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
  @State private var conversationScrollRequestID = UUID()

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
      RecentSessionsView(showingConnectionSettings: $showingConnectionSettings)
    } detail: {
      if let session = model.selectedSession {
        ConversationView(
          session: session,
          showingConnectionSettings: $showingConnectionSettings,
          backToSessions: showSessions,
          scrollRequestID: conversationScrollRequestID
        )
        .id(session.id)
      } else {
        ContentUnavailableView(
          "Choose a Session",
          systemImage: "bubble.left.and.bubble.right",
          description: Text("Open a recent session or create a new one to start working.")
        )
      }
    }
    .onChange(of: model.selectedSessionID) { _, sessionID in
      guard sessionID != nil else { return }
      withAnimation {
        preferredCompactColumn = .detail
      } completion: {
        conversationScrollRequestID = UUID()
      }
    }
    .sheet(isPresented: $showingConnectionSettings) {
      ConnectionSettingsView()
        .environmentObject(model)
    }
    .onChange(of: model.connectionState) { _, state in
      if state == .notConfigured { showingConnectionSettings = true }
    }
    .alert(
      "Remote Agent",
      isPresented: Binding(
        get: { model.presentedError != nil },
        set: { if !$0 { model.presentedError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { model.presentedError = nil }
    } message: {
      Text(model.presentedError ?? "An unexpected error occurred.")
    }
  }

  private func showSessions() {
    withAnimation {
      model.selectSession(nil)
      preferredCompactColumn = .sidebar
    }
  }
}

struct ConnectionStatusButton: View {
  @EnvironmentObject private var model: AppModel
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .foregroundStyle(color)
        .symbolEffect(.pulse, isActive: model.connectionState == .connecting)
    }
    .accessibilityLabel("Connection")
    .accessibilityValue(accessibilityValue)
    .accessibilityHint("Opens connection settings")
  }

  private var title: String {
    switch model.connectionState {
    case .loading: "Loading…"
    case .notConfigured: "Not configured"
    case .disconnected: "Disconnected"
    case .connecting: "Connecting…"
    case .connected: "Connected"
    case .failed: "Connection lost"
    }
  }

  private var detail: String? {
    switch model.connectionState {
    case .connected(let version):
      return model.configuration.map { "\($0.host):\($0.port) • API v\(version)" }
    case .failed(let message):
      return message
    case .notConfigured:
      return "Add the Mac host and token."
    case .disconnected:
      return model.configuration.map { "\($0.host):\($0.port)" }
    case .loading, .connecting:
      return model.configuration.map { "\($0.host):\($0.port)" }
    }
  }

  private var icon: String {
    switch model.connectionState {
    case .connected: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .connecting, .loading: "network"
    case .notConfigured, .disconnected: "network.slash"
    }
  }

  private var color: Color {
    switch model.connectionState {
    case .connected: .green
    case .failed: .orange
    default: .secondary
    }
  }

  private var accessibilityValue: String {
    [title, detail].compactMap { $0 }.joined(separator: ", ")
  }
}

struct RunningAgentIcon: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
      Image(systemName: "sparkles")
        .foregroundStyle(.green)
        .rotationEffect(reduceMotion ? .zero : rotation(at: context.date))
        .symbolEffect(.pulse, isActive: reduceMotion)
    }
    .frame(width: 20, height: 20)
    .accessibilityLabel("Agent running")
  }

  private func rotation(at date: Date) -> Angle {
    let duration = 1.2
    let progress =
      date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)
      / duration
    return .degrees(progress * 360)
  }
}
