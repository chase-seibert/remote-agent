import SwiftUI

struct ConversationView: View {
  @ObservedObject var model: AppModel
  let fontScale: Double
  @State private var prompt = ""

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
                MessageRowView(message: message, fontScale: fontScale)
                  .id(message.id)
              }
              if session.isRunning {
                HStack {
                  HStack(spacing: 7) {
                    RunningAgentIcon(size: 18)
                    Text("Agent is working…")
                      .font(.system(size: 12 * fontScale, weight: .semibold))
                  }
                  .foregroundStyle(.green)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 6)
                  .background(Color.green.opacity(0.12), in: Capsule())
                  Spacer(minLength: 72)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
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
        }

        Divider()
        ComposerView(
          text: $prompt,
          isRunning: session.isRunning,
          fontScale: fontScale
        ) {
          let outgoing = prompt
          prompt = ""
          Task { await model.sendPrompt(outgoing, to: session.id) }
        }
      }
      .navigationTitle(session.title)
      .navigationSubtitle(URL(fileURLWithPath: session.projectPath).path)
    } else {
      ContentUnavailableView(
        "Select a Session",
        systemImage: "sidebar.right",
        description: Text("Choose an existing session or create a new one.")
      )
    }
  }
}
