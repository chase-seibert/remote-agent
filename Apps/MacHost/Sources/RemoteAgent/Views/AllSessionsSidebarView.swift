import SwiftUI

struct AllSessionsSidebarView: View {
  @ObservedObject var model: AppModel
  let fontScale: Double
  @State private var searchText = ""
  @State private var sessionPendingDeletion: AgentSession?

  private var visibleSessions: [AgentSession] {
    guard !searchText.isEmpty else { return model.recentSessions }
    return model.recentSessions.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.projectName.localizedCaseInsensitiveContains(searchText)
        || $0.projectPath.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    List(
      visibleSessions,
      selection: Binding(
        get: { model.selectedSessionID },
        set: { model.selectSession($0) }
      )
    ) { session in
      SessionSidebarRow(
        session: session,
        isProjectCommandRunning: model.isProjectCommandRunning(sessionID: session.id),
        fontScale: fontScale
      )
      .tag(session.id)
      .contextMenu {
        Button(session.isUnread ? "Mark as Read" : "Mark as Unread") {
          if session.isUnread {
            model.markSessionRead(session.id)
          } else {
            model.markSessionUnread(session.id)
          }
        }
        Button(session.isPinned ? "Unpin Session" : "Pin Session") {
          do {
            try model.setSessionPinned(session.id, isPinned: !session.isPinned)
          } catch {
            model.presentedError = error.localizedDescription
          }
        }
        Button("New Session in This Project") {
          model.requestNewSession(projectID: session.projectID)
        }
        if let project = model.projects.first(where: { $0.id == session.projectID }) {
          Button("Show Project in Finder") { model.showProjectInFinder(project) }
        }
        Divider()
        Button("Delete Session", role: .destructive) {
          sessionPendingDeletion = session
        }
        .disabled(
          session.isRunning || model.isProjectCommandRunning(sessionID: session.id)
        )
      }
    }
    .navigationTitle("Sessions")
    .searchable(text: $searchText, placement: .sidebar, prompt: "Filter Sessions")
    .alert(
      "Delete Session?",
      isPresented: isConfirmingDeletion,
      presenting: sessionPendingDeletion
    ) { session in
      Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
      Button("Delete", role: .destructive) {
        sessionPendingDeletion = nil
        do {
          try model.deleteSession(session.id)
        } catch {
          model.presentedError = error.localizedDescription
        }
      }
    } message: { session in
      Text("“\(session.title)” and its transcript will be permanently deleted.")
    }
    .overlay {
      if model.recentSessions.isEmpty {
        ContentUnavailableView {
          Label("No Sessions", systemImage: "bubble.left.and.bubble.right")
        } description: {
          Text("Start a session to send a prompt to Codex in one of your projects.")
        } actions: {
          Button("New Session") { model.requestNewSession() }
            .disabled(model.projects.isEmpty)
        }
      } else if visibleSessions.isEmpty {
        ContentUnavailableView.search(text: searchText)
      }
    }
    .toolbar {
      ToolbarItem {
        Button {
          model.requestNewSession()
        } label: {
          Label("New Session", systemImage: "square.and.pencil")
        }
        .disabled(model.projects.isEmpty)
        .help("New Session (⌘N)")
      }
    }
  }

  private var isConfirmingDeletion: Binding<Bool> {
    Binding(
      get: { sessionPendingDeletion != nil },
      set: { if !$0 { sessionPendingDeletion = nil } }
    )
  }
}

private struct SessionSidebarRow: View {
  let session: AgentSession
  let isProjectCommandRunning: Bool
  let fontScale: Double

  private var isRunning: Bool { session.isRunning || isProjectCommandRunning }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      if isRunning {
        RunningAgentIcon()
      } else {
        Image(systemName: "bubble.left.fill")
          .foregroundStyle(.secondary)
          .frame(width: 20, height: 20)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(session.title)
          .font(.system(size: 13 * fontScale, weight: .semibold))
          .lineLimit(2)

        if session.isPinned {
          Label("Pinned", systemImage: "pin.fill")
            .font(.system(size: 10 * fontScale, weight: .semibold))
            .foregroundStyle(.orange)
        }

        HStack(spacing: 5) {
          Text(session.projectName)
            .lineLimit(1)
          Text("•")
          Text(session.codexModel ?? "Codex default")
            .lineLimit(1)
          Text("•")
          Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
            .lineLimit(1)
        }
        .font(.system(size: 11 * fontScale))
        .foregroundStyle(.secondary)

        HStack(spacing: 6) {
          if isRunning {
            SessionStatusBadge(title: "Running", color: .green, fontScale: fontScale)
          }
          if session.messages.last?.state == .failed {
            SessionStatusBadge(title: "Failed", color: .red, fontScale: fontScale)
          }
          if session.isUnread {
            SessionStatusBadge(
              title: "Unread",
              color: .blue,
              fontScale: fontScale,
              systemImage: "bubble.left.fill"
            )
          }
          if !isRunning, session.messages.last?.state != .failed, !session.isUnread {
            SessionStatusBadge(
              title: session.messages.isEmpty ? "New" : "Read",
              color: .secondary,
              fontScale: fontScale
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .combine)
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    var values = [
      session.projectName,
      session.codexModel ?? "Codex default",
      session.updatedAt.formatted(date: .abbreviated, time: .shortened),
    ]
    if isRunning { values.append("Running") }
    if session.isPinned { values.append("Pinned") }
    if session.messages.last?.state == .failed { values.append("Failed") }
    values.append(session.isUnread ? "Unread" : "Read")
    return values.joined(separator: ", ")
  }
}

struct NewSessionProjectPickerView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: AppModel
  @State private var projectID: String?
  @State private var codexModel = ""

  var body: some View {
    NavigationStack {
      Form {
        Picker("Project", selection: $projectID) {
          Text("Choose a project").tag(nil as String?)
          ForEach(ProjectSorter.byMostRecentSession(model.projects, sessions: model.sessions)) {
            project in
            Text(project.name).tag(project.id as String?)
          }
        }
        Picker("Model", selection: $codexModel) {
          Text("Codex default").tag("")
          ForEach(model.codexModels) { option in
            Text(option.displayName).tag(option.id)
          }
        }
        if let option = model.codexModels.first(where: { $0.id == codexModel }) {
          Text(option.description).font(.caption).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("New Session")
      .onAppear {
        projectID = model.pendingNewSessionProjectID ?? model.selectedProjectID
        codexModel = model.mostRecentlyUsedCodexModel ?? ""
      }
      .task { await model.refreshCodexModels() }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Start Session") {
            if model.createSession(projectID: projectID, codexModel: codexModel) != nil {
              dismiss()
            }
          }
          .disabled(projectID == nil)
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .frame(width: 440, height: 240)
  }
}
