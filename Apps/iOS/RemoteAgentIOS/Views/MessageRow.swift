import SwiftUI

struct MessageRow: View {
  let message: AgentMessage
  let onOpenDetails: (() -> Void)?

  init(message: AgentMessage, onOpenDetails: (() -> Void)? = nil) {
    self.message = message
    self.onOpenDetails = onOpenDetails
  }

  var body: some View {
    Group {
      if let onOpenDetails {
        Button(action: onOpenDetails) { rowContent }
          .buttonStyle(.plain)
      } else {
        rowContent
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityHint(onOpenDetails == nil ? "" : "Opens command output")
  }

  private var rowContent: some View {
    HStack(alignment: .top) {
      if message.role == .user { Spacer(minLength: 48) }

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
          if message.state == .pending {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: roleIcon)
          }
          Text(roleTitle)
          if message.state == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          Spacer(minLength: 4)
          Text(message.createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(headerColor)

        SafeMarkdownView(text: message.text)
          .foregroundStyle(message.role == .user ? Color.white : Color.primary)
          .textSelection(.enabled)

        if onOpenDetails != nil {
          Label("View Output", systemImage: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .background(backgroundColor, in: RoundedRectangle(cornerRadius: 16))

      if message.role != .user { Spacer(minLength: 24) }
    }
    .padding(.horizontal)
  }

  private var roleTitle: String {
    switch message.role {
    case .user: return "You"
    case .assistant: return "Agent"
    case .system:
      if message.state == .pending { return "Running" }
      return message.state == .failed ? "Failed" : "System"
    }
  }

  private var roleIcon: String {
    switch message.role {
    case .user: "person.fill"
    case .assistant: "sparkles"
    case .system: "gearshape.fill"
    }
  }

  private var headerColor: Color {
    if message.state == .pending { return .green }
    return message.state == .failed
      ? .red : (message.role == .user ? .white.opacity(0.9) : .secondary)
  }

  private var backgroundColor: Color {
    if message.state == .pending { return .green.opacity(0.1) }
    if message.state == .failed { return .red.opacity(0.12) }
    return message.role == .user ? .accentColor : Color(uiColor: .secondarySystemBackground)
  }
}

struct SafeMarkdownView: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .text(let content):
          Text(safeAttributedString(content))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let content):
          ScrollView(.horizontal) {
            Text(content)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .padding(10)
          }
          .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }

  private var blocks: [MarkdownBlock] {
    var result: [MarkdownBlock] = []
    var textLines: [String] = []
    var codeLines: [String] = []
    var inCodeBlock = false

    func flushText() {
      guard !textLines.isEmpty else { return }
      result.append(.text(textLines.joined(separator: "\n")))
      textLines.removeAll()
    }

    for line in text.components(separatedBy: .newlines) {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        if inCodeBlock {
          result.append(.code(codeLines.joined(separator: "\n")))
          codeLines.removeAll()
        } else {
          flushText()
        }
        inCodeBlock.toggle()
      } else if inCodeBlock {
        codeLines.append(line)
      } else {
        textLines.append(line)
      }
    }

    if inCodeBlock {
      textLines.append("```")
      textLines.append(contentsOf: codeLines)
    }
    flushText()
    return result.isEmpty ? [.text("")] : result
  }

  private func safeAttributedString(_ content: String) -> AttributedString {
    (try? AttributedString(
      markdown: content,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(content)
  }

  private enum MarkdownBlock {
    case text(String)
    case code(String)
  }
}
