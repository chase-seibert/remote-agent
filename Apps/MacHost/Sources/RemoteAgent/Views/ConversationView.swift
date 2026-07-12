import AppKit
import SwiftUI

struct ConversationView: View {
  @ObservedObject var model: AppModel
  let fontScale: Double
  @State private var prompt = ""
  @State private var selectedProjectCommandResult: ProjectCommandResultSelection?

  var body: some View {
    if let session = model.selectedSession {
      VStack(spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 12) {
              if session.messages.isEmpty {
                ContentUnavailableView(
                  "Start the Conversation",
                  systemImage: "terminal",
                  description: Text(
                    "Your first prompt starts a persisted Codex CLI session in \(URL(fileURLWithPath: session.projectPath).lastPathComponent)."
                  )
                )
                .padding(.top, 50)
              }
              ForEach(session.messages) { message in
                let commandResult = model.projectCommandResult(messageID: message.id)
                MessageRowView(
                  message: message,
                  fontScale: fontScale,
                  onOpenDetails: commandResult.map { result in
                    { selectedProjectCommandResult = ProjectCommandResultSelection(id: result.id) }
                  }
                )
                .id(message.id)
              }
              if session.isRunning {
                CurrentReasoningView(
                  reasoning: session.currentReasoning,
                  fontScale: fontScale
                )
                .id("running")
              }
            }
          }
          .onChange(of: session.messages.count) { _, _ in
            if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
          }
          .onChange(of: session.isRunning) { _, running in
            if running { proxy.scrollTo("running", anchor: .bottom) }
          }
          .onChange(of: session.currentReasoning) { _, _ in
            proxy.scrollTo("running", anchor: .bottom)
          }
        }

        Divider()
        ComposerView(
          text: $prompt,
          isRunning: session.isRunning || model.isProjectCommandRunning(sessionID: session.id),
          fontScale: fontScale
        ) {
          let outgoing = prompt
          prompt = ""
          Task { await model.sendPrompt(outgoing, to: session.id) }
        }
      }
      .navigationTitle(session.title)
      .navigationSubtitle(URL(fileURLWithPath: session.projectPath).path)
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          ProjectCommandToolbar(model: model, session: session)
        }
      }
      .sheet(item: $selectedProjectCommandResult) { selection in
        ProjectCommandResultView(model: model, resultID: selection.id)
      }
    } else {
      ContentUnavailableView(
        "Select a Session",
        systemImage: "sidebar.right",
        description: Text("Choose an existing session or create a new one.")
      )
    }
  }
}

private struct ProjectCommandResultSelection: Identifiable {
  let id: UUID
}

private struct ProjectCommandToolbar: View {
  @ObservedObject var model: AppModel
  let session: AgentSession

  var body: some View {
    Menu {
      if targets.isEmpty {
        Text("No Makefile targets")
      } else {
        Picker("Make Target", selection: activeTargetBinding) {
          ForEach(targets, id: \.self) { target in
            Text(target).tag(target)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "hammer")
        Text(activeTarget ?? "Make")
          .lineLimit(1)
      }
      .fixedSize(horizontal: true, vertical: false)
    } primaryAction: {
      Task { await model.runActiveMakeTarget(sessionID: session.id) }
    }
    .disabled(commandsDisabled || activeTarget == nil)
    .help(activeTarget.map { "Run make \($0)" } ?? "No Makefile targets available")

    Button {
      Task { await model.runGitCommitAndPush(sessionID: session.id) }
    } label: {
      Label("Commit & Push", systemImage: "arrow.up.circle")
    }
    .disabled(commandsDisabled)
    .help(
      "Add and commit all changes using an Apple Foundation Models message, then push when an upstream is configured"
    )
  }

  private var targets: [String] { model.makeTargets(for: session) }
  private var activeTarget: String? { model.activeMakeTarget(for: session) }
  private var activeTargetBinding: Binding<String> {
    Binding(
      get: { activeTarget ?? targets.first ?? "" },
      set: { model.selectMakeTarget($0, for: session) }
    )
  }
  private var commandsDisabled: Bool {
    session.isRunning || model.isProjectCommandRunning(sessionID: session.id)
  }
}

private struct ProjectCommandResultView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: AppModel
  let resultID: UUID

  var body: some View {
    if let result = model.projectCommandResult(messageID: resultID) {
      resultContent(result)
    } else {
      ContentUnavailableView("Output Unavailable", systemImage: "terminal")
        .frame(minWidth: 720, minHeight: 480)
    }
  }

  private func resultContent(_ result: ProjectCommandResult) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        HStack(spacing: 8) {
          if result.isRunning {
            ProgressView().controlSize(.small)
          } else {
            Image(
              systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
          }
          Text(result.title)
        }
        .font(.title2.weight(.semibold))
        .foregroundStyle(result.isRunning || result.succeeded ? .green : .red)
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        GridRow {
          Text("Command").foregroundStyle(.secondary)
          Text(result.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
        GridRow {
          Text("Project").foregroundStyle(.secondary)
          Text(result.projectPath).textSelection(.enabled)
        }
        GridRow {
          Text("Exit Status").foregroundStyle(.secondary)
          Text(result.isRunning ? "Running" : result.exitCode.map(String.init) ?? "Failed")
        }
        GridRow {
          Text("Duration").foregroundStyle(.secondary)
          Text(result.duration.formatted(.number.precision(.fractionLength(2))) + " seconds")
        }
      }

      Divider()

      ScrollView([.horizontal, .vertical]) {
        Text(
          result.output.isEmpty
            ? (result.isRunning ? "Command is running…" : "Command completed without output.")
            : result.output
        )
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
      }
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

      HStack {
        Spacer()
        Button("Copy Output", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(result.output, forType: .string)
        }
        .disabled(result.isRunning)
      }
    }
    .padding(20)
    .frame(minWidth: 720, minHeight: 480)
  }
}

private struct CurrentReasoningView: View {
  let reasoning: String?
  let fontScale: Double

  var body: some View {
    HStack(alignment: .top) {
      HStack(alignment: .top, spacing: 8) {
        RunningAgentIcon(size: 18)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 4) {
          Text("Working")
            .font(.system(size: 12 * fontScale, weight: .semibold))
          Text(reasoning ?? "Agent is working…")
            .font(.system(size: 12 * fontScale))
            .foregroundStyle(reasoning == nil ? .green : .secondary)
            .textSelection(.enabled)
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
      Spacer(minLength: 72)
    }
    .foregroundStyle(.green)
    .padding(.horizontal, 18)
    .padding(.bottom, 8)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Agent working: \(reasoning ?? "Waiting for an update")")
  }
}
