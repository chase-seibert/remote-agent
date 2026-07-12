import SwiftUI

struct ComposerView: View {
  @Binding var text: String
  let isRunning: Bool
  let fontScale: Double
  let onSend: () -> Void

  @StateObject private var speech = SpeechTranscriber()
  @FocusState private var isFocused: Bool
  @State private var speechPrefix = ""

  var body: some View {
    VStack(spacing: 8) {
      if speech.authorizationDenied {
        Text(
          "Speech recognition permission is disabled. You can enable it in System Settings → Privacy & Security."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(alignment: .bottom, spacing: 8) {
        TextEditor(text: $text)
          .font(.system(size: 14 * fontScale))
          .scrollContentBackground(.hidden)
          .padding(6)
          .frame(minHeight: 54, maxHeight: 150)
          .background(.background, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(.separator, lineWidth: 1)
          }
          .focused($isFocused)
          .accessibilityLabel("Prompt")

        Button {
          if !speech.isRecording {
            speechPrefix = text.isEmpty ? "" : text + " "
          }
          speech.toggle { transcript in text = speechPrefix + transcript }
        } label: {
          Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.fill")
            .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .foregroundStyle(speech.isRecording ? .red : .secondary)
        .help(speech.isRecording ? "Stop Dictation" : "Dictate Prompt")

        Button(action: onSend) {
          if isRunning {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.up.circle.fill")
          }
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send Prompt (⌘↩)")
      }
      Text("⌘↩ to send")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(12)
    .background(.bar)
    .onAppear { isFocused = true }
    .onDisappear { speech.stop() }
  }
}
