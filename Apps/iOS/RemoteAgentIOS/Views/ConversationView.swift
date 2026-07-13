import RemoteAgentProtocol
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
  @State private var selectedCommandResult: ProjectCommandResultSelection?

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
              MessageRow(
                message: message,
                onOpenDetails: message.projectCommandResultID.map { resultID in
                  {
                    selectedCommandResult = ProjectCommandResultSelection(
                      sessionID: session.id,
                      resultID: resultID
                    )
                  }
                }
              )
              .id(message.id)
              .accessibilityIdentifier(accessibilityIdentifier(for: message))
            }
          }

          if session.isRunning {
            CurrentReasoningView(reasoning: session.currentReasoning)
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
      .onChange(of: session.currentReasoning) { _, _ in
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
        await model.loadProjectCommandConfiguration(sessionID: session.id)
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
      VStack(spacing: 0) {
        ProjectCommandBar(session: session)
        ComposerView(
          sessionID: session.id,
          isRunning: session.hasActiveWork
            || model.isProjectCommandRunning(sessionID: session.id)
        )
      }
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
    .sheet(item: $selectedCommandResult) { selection in
      ProjectCommandOutputView(
        sessionID: selection.sessionID,
        resultID: selection.resultID
      )
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

private struct ProjectCommandResultSelection: Identifiable {
  let sessionID: UUID
  let resultID: UUID
  var id: UUID { resultID }
}

private struct ProjectCommandBar: View {
  @EnvironmentObject private var model: AppModel
  let session: AgentSession

  var body: some View {
    HStack(spacing: 10) {
      Menu {
        if targets.isEmpty {
          Text("No Makefile targets")
        } else {
          Picker("Make Target", selection: targetBinding) {
            ForEach(targets, id: \.self) { target in
              Text(target).tag(target)
            }
          }
        }
      } label: {
        Label(activeTarget ?? "Make", systemImage: "hammer")
      } primaryAction: {
        Task { await model.runProjectCommand(.make, sessionID: session.id) }
      }
      .disabled(commandsDisabled || activeTarget == nil)
      .accessibilityLabel(activeTarget.map { "Run make \($0)" } ?? "Make")

      Spacer(minLength: 0)

      Button("Commit & Push", systemImage: "arrow.up.circle") {
        Task { await model.runProjectCommand(.gitCommitAndPush, sessionID: session.id) }
      }
      .disabled(commandsDisabled)
    }
    .font(.subheadline.weight(.semibold))
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var configuration: ProjectCommandConfigurationResponse? {
    model.projectCommandConfiguration(sessionID: session.id)
  }

  private var targets: [String] { configuration?.makeTargets ?? [] }
  private var activeTarget: String? {
    configuration?.selectedMakeTarget ?? session.selectedMakeTarget
  }
  private var commandsDisabled: Bool {
    !model.connectionState.isConnected || session.hasActiveWork
      || model.isProjectCommandRunning(sessionID: session.id)
  }
  private var targetBinding: Binding<String> {
    Binding(
      get: { activeTarget ?? targets.first ?? "" },
      set: { target in
        Task { await model.selectMakeTarget(target, sessionID: session.id) }
      }
    )
  }
}

private struct ProjectCommandOutputView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let sessionID: UUID
  let resultID: UUID
  @State private var result: RemoteProjectCommandResult?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Group {
        if let result {
          resultView(result)
        } else if let errorMessage {
          ContentUnavailableView(
            "Output Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(errorMessage)
          )
        } else {
          ProgressView("Loading output…")
        }
      }
      .navigationTitle(result?.title ?? "Command Output")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .task { await loadResultUntilComplete() }
  }

  private func resultView(_ result: RemoteProjectCommandResult) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Label {
          Text(result.isRunning ? "Running" : result.succeeded ? "Succeeded" : "Failed")
        } icon: {
          if result.isRunning {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
          }
        }
        .font(.headline)
        .foregroundStyle(result.isRunning || result.succeeded ? .green : .red)

        LabeledContent("Command") {
          Text(result.command).font(.system(.subheadline, design: .monospaced))
        }
        LabeledContent("Project") { Text(result.projectPath) }
        LabeledContent("Exit Status") {
          Text(result.isRunning ? "Running" : result.exitCode.map(String.init) ?? "Failed")
        }

        Divider()

        Text(result.output.isEmpty ? "Command completed without output." : result.output)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(
            Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
      }
      .padding()
    }
  }

  private func loadResultUntilComplete() async {
    while !Task.isCancelled {
      do {
        let loaded = try await model.projectCommandResult(
          sessionID: sessionID,
          resultID: resultID
        )
        result = loaded
        errorMessage = nil
        guard loaded.isRunning else { return }
        try await Task.sleep(for: .seconds(1))
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
        return
      }
    }
  }
}

private struct CurrentReasoningView: View {
  let reasoning: String?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ProgressView()
        .tint(.green)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        Text("Working")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
        Text(reasoning ?? "Agent is working…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: 24)
    }
    .padding(12)
    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    .padding(.horizontal)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Agent working: \(reasoning ?? "Waiting for an update")")
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
  @State private var editingPrompt: QueuedPrompt?

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

          HStack(spacing: 8) {
            Button("Edit queued prompt", systemImage: "pencil.circle.fill") {
              editingPrompt = prompt
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)

            Button("Remove queued prompt", systemImage: "xmark.circle.fill") {
              Task {
                _ = await model.removeQueuedPrompt(prompt.id, sessionID: sessionID)
              }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
          }
          .disabled(!model.connectionState.isConnected)
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
    .sheet(item: $editingPrompt) { prompt in
      QueuedPromptEditor(sessionID: sessionID, prompt: prompt)
        .environmentObject(model)
    }
  }
}

private struct QueuedPromptEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let sessionID: UUID
  let prompt: QueuedPrompt
  @State private var text: String
  @State private var isSaving = false

  init(sessionID: UUID, prompt: QueuedPrompt) {
    self.sessionID = sessionID
    self.prompt = prompt
    _text = State(initialValue: prompt.text)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Prompt") {
          TextEditor(text: $text)
            .frame(minHeight: 160)
            .accessibilityLabel("Queued prompt text")
        }
      }
      .navigationTitle("Edit Queued Prompt")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "Saving…" : "Save") {
            isSaving = true
            Task {
              if await model.updateQueuedPrompt(prompt.id, text: text, sessionID: sessionID) {
                dismiss()
              } else {
                isSaving = false
              }
            }
          }
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
        }
      }
      .interactiveDismissDisabled(isSaving)
    }
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
