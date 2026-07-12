import AppKit
import SwiftUI

struct MessageRowView: View {
  let message: AgentMessage
  let fontScale: Double

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      if message.role == .user { Spacer(minLength: 72) }

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
          Image(systemName: iconName)
            .accessibilityHidden(true)
          Text(roleName)
          if message.state == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
              .accessibilityHidden(true)
          }
          Spacer(minLength: 6)
          Text(message.createdAt, style: .time)
            .font(.system(size: 10 * fontScale))
            .foregroundStyle(headerColor.opacity(0.72))
        }
        .font(.system(size: 11 * fontScale, weight: .semibold))
        .foregroundStyle(headerColor)

        MarkdownContentView(source: message.text, fontScale: fontScale)
          .foregroundStyle(contentColor)
          .tint(message.role == .user ? .white : .accentColor)
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(12)
      .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14))

      if message.role != .user { Spacer(minLength: 72) }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 4)
    .contextMenu {
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(roleName): \(message.text)")
  }

  private var roleName: String {
    switch message.role {
    case .user: return "You"
    case .assistant: return "Agent"
    case .system: return message.state == .failed ? "Failed" : "System"
    }
  }

  private var iconName: String {
    switch message.role {
    case .user: return "person.fill"
    case .assistant: return "sparkles"
    case .system: return "gearshape.fill"
    }
  }

  private var headerColor: Color {
    message.state == .failed ? .red : (message.role == .user ? .white.opacity(0.9) : .secondary)
  }

  private var contentColor: Color {
    message.role == .user ? .white : .primary
  }

  private var backgroundColor: Color {
    if message.state == .failed { return .red.opacity(0.12) }
    return message.role == .user ? .accentColor : .secondary.opacity(0.12)
  }
}
