import SwiftUI

struct ConversationView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let session: AgentSession
  @Binding var showingConnectionSettings: Bool
  let backToSessions: () -> Void
  var scrollRequestID: UUID? = nil
  @State private var linkedDocument: ProjectDocument?
  @State private var showingDocuments = false

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 18) {
          if session.messages.isEmpty {
            ContentUnavailableView(
              "Ready for a Prompt",
              systemImage: "sparkles",
              description: Text("Ask the agent to inspect, explain, or change this project.")
            )
            .padding(.top, 72)
          } else {
            ForEach(session.messages) { message in
              MessageRow(message: message)
                .id(message.id)
                .accessibilityIdentifier(accessibilityIdentifier(for: message))
            }
          }

          if session.isRunning {
            HStack(spacing: 10) {
              ProgressView()
              Text("Agent is working…")
                .foregroundStyle(.secondary)
              Spacer()
            }
            .padding(.horizontal)
            .id("running")
          }

          let queuedPrompts = model.queuedPrompts(sessionID: session.id)
          if !queuedPrompts.isEmpty {
            QueuedPromptsView(sessionID: session.id, prompts: queuedPrompts)
              .id("queued-prompts")
          }

          Color.clear
            .frame(height: 1)
            .id("conversation-bottom")
        }
        .padding(.vertical)
      }
      .scrollDismissesKeyboard(.interactively)
      .onChange(of: session.messages.count) { _, _ in
        withAnimation { scrollToBottom(proxy) }
      }
      .onChange(of: session.isRunning) { _, _ in
        withAnimation { scrollToBottom(proxy) }
      }
      .onChange(of: model.queuedPrompts(sessionID: session.id).count) { _, _ in
        withAnimation { scrollToBottom(proxy) }
      }
      .task(id: session.id) {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        guard !Task.isCancelled else { return }
        scrollToBottom(proxy)
        markSessionReadIfVisible()
      }
      .onChange(of: scrollRequestID) { _, requestID in
        guard requestID != nil else { return }
        scrollToBottom(proxy)
      }
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 20)
        .onEnded { value in
          guard horizontalSizeClass == .compact,
            SessionListSwipeGesture.shouldNavigate(
              translation: value.translation,
              predictedEndTranslation: value.predictedEndTranslation
            )
          else { return }
          backToSessions()
        }
    )
    .navigationTitle(session.title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(horizontalSizeClass == .compact)
    .toolbar {
      if horizontalSizeClass == .compact {
        ToolbarItem(placement: .topBarLeading) {
          SessionsBackButton(action: backToSessions)
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("New Session", systemImage: "square.and.pencil") {
          Task { await model.createSession(projectID: session.projectID) }
        }
        .labelStyle(.iconOnly)
        .disabled(!model.connectionState.isConnected)
        .accessibilityHint("Starts a new session in \(project.name)")
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Browse Files", systemImage: "doc.text.magnifyingglass") {
          showingDocuments = true
        }
        .labelStyle(.iconOnly)
        .disabled(!model.connectionState.isConnected)
      }
      ToolbarItem(placement: .topBarTrailing) {
        ConnectionStatusButton {
          showingConnectionSettings = true
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ComposerView(sessionID: session.id, isRunning: session.isRunning)
    }
    .environment(\.openURL, OpenURLAction { handleLink($0) })
    .sheet(item: $linkedDocument) { document in
      LinkedProjectDocumentView(
        projectID: session.projectID,
        projectPath: session.projectPath,
        document: document
      )
      .environmentObject(model)
    }
    .sheet(isPresented: $showingDocuments) {
      ProjectDocumentsView(project: project)
        .environmentObject(model)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { markSessionReadIfVisible() }
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    proxy.scrollTo("conversation-bottom", anchor: .bottom)
  }

  private func accessibilityIdentifier(for message: AgentMessage) -> String {
    if message.id == session.messages.first?.id { return "conversation-first-message" }
    if message.id == session.messages.last?.id { return "conversation-last-message" }
    return "conversation-message-\(message.id.uuidString)"
  }

  private func markSessionReadIfVisible() {
    guard scenePhase == .active else { return }
    Task { await model.markSessionRead(session.id) }
  }

  private func handleLink(_ url: URL) -> OpenURLAction.Result {
    switch ProjectLinkResolver.destination(for: url, projectPath: session.projectPath) {
    case .web:
      return .systemAction
    case .document(let relativePath):
      Task { await openDocument(relativePath: relativePath) }
      return .handled
    case .unsupported:
      return .discarded
    }
  }

  private func openDocument(relativePath: String) async {
    do {
      linkedDocument = try await model.document(
        projectID: session.projectID,
        relativePath: relativePath
      )
    } catch {
      model.presentedError = error.localizedDescription
    }
  }

  private var project: AgentProject {
    model.projects.first(where: { $0.id == session.projectID })
      ?? AgentProject(
        id: session.projectID,
        name: URL(fileURLWithPath: session.projectPath).lastPathComponent,
        path: session.projectPath
      )
  }
}

enum SessionListSwipeGesture {
  private static let minimumDistance: CGFloat = 80
  private static let horizontalDominance: CGFloat = 1.25

  static func shouldNavigate(
    translation: CGSize,
    predictedEndTranslation: CGSize
  ) -> Bool {
    let rightwardDistance = max(translation.width, predictedEndTranslation.width)
    let verticalDistance = max(
      abs(translation.height),
      abs(predictedEndTranslation.height)
    )
    return rightwardDistance >= minimumDistance
      && rightwardDistance >= verticalDistance * horizontalDominance
  }
}

private struct SessionsBackButton: View {
  @EnvironmentObject private var model: AppModel
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.left")
          .font(.body.weight(.semibold))
        if model.hasUnreadSessions {
          Circle()
            .fill(.blue)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
        }
      }
    }
    .accessibilityLabel("Back to sessions")
    .accessibilityValue(model.hasUnreadSessions ? "Unread sessions" : "")
  }
}

private struct QueuedPromptsView: View {
  @EnvironmentObject private var model: AppModel
  let sessionID: UUID
  let prompts: [QueuedPrompt]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(
        prompts.count == 1 ? "1 queued prompt" : "\(prompts.count) queued prompts",
        systemImage: "tray.full.fill"
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)

      ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
        HStack(alignment: .top, spacing: 10) {
          Text("\(index + 1)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 24)

          Text(prompt.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)

          if model.deliveringQueuedPromptIDs.contains(prompt.id) {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Sending queued prompt")
          } else {
            Button("Remove queued prompt", systemImage: "xmark.circle.fill") {
              withAnimation {
                model.removeQueuedPrompt(prompt.id, sessionID: sessionID)
              }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
          }
        }
        .font(.callout)

        if index < prompts.count - 1 {
          Divider()
            .padding(.leading, 30)
        }
      }
    }
    .padding(12)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    .padding(.horizontal)
    .accessibilityElement(children: .contain)
  }
}

private struct ComposerView: View {
  @EnvironmentObject private var model: AppModel
  let sessionID: UUID
  let isRunning: Bool
  @State private var draft = ""
  @FocusState private var isFocused: Bool

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && model.canAcceptPrompt(sessionID: sessionID)
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(alignment: .bottom, spacing: 10) {
        TextField(isRunning ? "Queue a prompt" : "Message the agent", text: $draft, axis: .vertical)
          .lineLimit(1...7)
          .textFieldStyle(.plain)
          .focused($isFocused)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .background(.background, in: RoundedRectangle(cornerRadius: 18))
          .overlay {
            RoundedRectangle(cornerRadius: 18)
              .stroke(.quaternary, lineWidth: 1)
          }
        Button {
          let submitted = draft
          Task {
            if await model.sendPrompt(submitted, to: sessionID) {
              draft = ""
            }
          }
        } label: {
          Image(systemName: isRunning ? "plus.circle.fill" : "arrow.up.circle.fill")
            .font(.system(size: 32))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(isRunning ? "Queue prompt" : "Send prompt")
      }
      .padding(.horizontal)
      .padding(.vertical, 10)
      .background(.bar)
    }
    .task(id: sessionID) { draft = model.draft(sessionID: sessionID) }
    .onChange(of: draft) { _, value in model.saveDraft(value, sessionID: sessionID) }
  }
}
