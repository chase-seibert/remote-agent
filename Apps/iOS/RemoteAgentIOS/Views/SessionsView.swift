import SwiftUI

struct RecentSessionsView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var showingConnectionSettings: Bool
  var presentsRenameOnAppear = false
  @State private var sessionToRename: AgentSession?
  @State private var sessionToDelete: AgentSession?
  @State private var renameTitle = ""

  private var selection: Binding<UUID?> {
    Binding(get: { model.selectedSessionID }, set: { model.selectSession($0) })
  }

  var body: some View {
    List(selection: selection) {
      Section {
        ForEach(model.recentSessions) { session in
          RecentSessionRow(session: session, projectName: model.projectName(for: session))
            .tag(session.id)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
              pinButton(for: session)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              deleteButton(for: session)
              renameButton(for: session)
            }
            .contextMenu {
              pinButton(for: session)
              renameButton(for: session)
              Divider()
              deleteButton(for: session)
            }
        }
      } header: {
        Text("Pinned & Recent")
      } footer: {
        if model.sessions.count > model.recentSessions.count {
          Text("Showing up to 50 sessions, with pinned sessions first.")
        }
      }
    }
    .alert("Rename Session", isPresented: isPresentingRename) {
      TextField("Session title", text: $renameTitle)
      Button("Cancel", role: .cancel) { sessionToRename = nil }
      Button("Save") {
        guard let sessionID = sessionToRename?.id else { return }
        let title = renameTitle
        sessionToRename = nil
        Task { await model.renameSession(sessionID, title: title) }
      }
      .disabled(!renameIsValid)
    } message: {
      Text("Enter a title between 1 and 120 characters.")
    }
    .confirmationDialog(
      "Delete Session?",
      isPresented: isPresentingDelete,
      titleVisibility: .visible,
      presenting: sessionToDelete
    ) { session in
      Button("Delete “\(session.title)”", role: .destructive) {
        sessionToDelete = nil
        Task { await model.deleteSession(session.id) }
      }
      Button("Cancel", role: .cancel) { sessionToDelete = nil }
    } message: { _ in
      Text("This permanently deletes the session and its transcript from the Mac.")
    }
    .overlay {
      if model.sessions.isEmpty, model.connectionState.isConnected {
        ContentUnavailableView(
          "No Sessions",
          systemImage: "bubble.left.and.bubble.right",
          description: Text("Create a session to start working from your phone.")
        )
      }
    }
    .navigationTitle("Sessions")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        NewSessionMenu()
      }
      ToolbarItem(placement: .topBarTrailing) {
        ConnectionStatusButton {
          showingConnectionSettings = true
        }
      }
    }
    .refreshable { await model.refresh() }
    .task {
      guard presentsRenameOnAppear, sessionToRename == nil, let session = model.recentSessions.first
      else { return }
      beginRenaming(session)
    }
  }

  private var isPresentingRename: Binding<Bool> {
    Binding(
      get: { sessionToRename != nil },
      set: { if !$0 { sessionToRename = nil } }
    )
  }

  private var isPresentingDelete: Binding<Bool> {
    Binding(
      get: { sessionToDelete != nil },
      set: { if !$0 { sessionToDelete = nil } }
    )
  }

  private var renameIsValid: Bool {
    let trimmed = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.count <= 120
  }

  private func beginRenaming(_ session: AgentSession) {
    renameTitle = session.title
    sessionToRename = session
  }

  private func renameButton(for session: AgentSession) -> some View {
    Button("Rename", systemImage: "pencil") {
      beginRenaming(session)
    }
    .tint(.blue)
  }

  private func pinButton(for session: AgentSession) -> some View {
    Button(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin")
    {
      Task { await model.setSessionPinned(session.id, isPinned: !session.isPinned) }
    }
    .tint(.orange)
  }

  private func deleteButton(for session: AgentSession) -> some View {
    Button("Delete", systemImage: "trash", role: .destructive) {
      sessionToDelete = session
    }
    .disabled(session.isRunning)
  }
}

private struct NewSessionMenu: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Menu("New Session", systemImage: "square.and.pencil") {
      ForEach(model.visibleProjects) { project in
        Button(project.name, systemImage: "folder") {
          Task { await model.createSession(projectID: project.id) }
        }
      }
    }
    .disabled(model.visibleProjects.isEmpty || !model.connectionState.isConnected)
    .accessibilityHint("Choose a project for the new session")
  }
}

private struct RecentSessionRow: View {
  let session: AgentSession
  let projectName: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if session.isRunning {
        RunningAgentIcon()
      } else {
        Image(systemName: "bubble.left.fill")
          .foregroundStyle(.secondary)
          .frame(width: 20, height: 20)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(session.title)
            .font(.body.weight(.semibold))
            .lineLimit(2)
          if session.isPinned {
            Image(systemName: "pin.fill")
              .font(.caption)
              .foregroundStyle(.orange)
              .accessibilityHidden(true)
          }
        }

        HStack(spacing: 5) {
          Text(projectName)
            .lineLimit(1)
          Text("•")
          Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
            .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        HStack(spacing: 6) {
          if session.isRunning {
            SessionStatusBadge(title: "Running", color: .green)
          }
          if session.messages.last?.state == .failed {
            SessionStatusBadge(title: "Failed", color: .red)
          }
          if session.isUnread {
            SessionStatusBadge(title: "Unread", color: .blue, showsDot: true)
          }
          if !session.isRunning, session.messages.last?.state != .failed, !session.isUnread {
            SessionStatusBadge(title: "Read", color: .secondary)
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
    var values = [projectName, session.updatedAt.formatted(date: .abbreviated, time: .shortened)]
    if session.isRunning { values.append("Running") }
    if session.messages.last?.state == .failed { values.append("Failed") }
    if session.isPinned { values.append("Pinned") }
    values.append(session.isUnread ? "Unread" : "Read")
    return values.joined(separator: ", ")
  }
}

private struct SessionStatusBadge: View {
  let title: String
  let color: Color
  var showsDot = false

  var body: some View {
    HStack(spacing: 4) {
      if showsDot {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)
      }
      Text(title)
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(color)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(color.opacity(0.12), in: Capsule())
  }
}
