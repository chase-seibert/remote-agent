import AppKit
import SwiftUI

struct MessageRowView: View {
  let message: AgentMessage
  let fontScale: Double
  let onOpenDetails: (() -> Void)?

  init(
    message: AgentMessage,
    fontScale: Double,
    onOpenDetails: (() -> Void)? = nil
  ) {
    self.message = message
    self.fontScale = fontScale
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
    .contextMenu {
      if let onOpenDetails {
        Button("View Output", systemImage: "terminal") { onOpenDetails() }
        Divider()
      }
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(roleName): \(message.text)\(onOpenDetails == nil ? "" : ", click to view output")"
    )
  }

  private var rowContent: some View {
    HStack(alignment: .top, spacing: 10) {
      if message.role == .user { Spacer(minLength: 72) }

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
          if message.state == .pending {
            ProgressView()
              .controlSize(.small)
              .accessibilityHidden(true)
          } else {
            Image(systemName: iconName)
              .accessibilityHidden(true)
          }
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

        if onOpenDetails != nil {
          Label("View Output", systemImage: "chevron.right")
            .font(.system(size: 10 * fontScale, weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(12)
      .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14))

      if message.role != .user { Spacer(minLength: 72) }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 4)
  }

  private var roleName: String {
    switch message.role {
    case .user: return "You"
    case .assistant: return "Agent"
    case .system:
      if message.state == .pending { return "Running" }
      return message.state == .failed ? "Failed" : "System"
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
    if message.state == .pending { return .green }
    return message.state == .failed
      ? .red : (message.role == .user ? .white.opacity(0.9) : .secondary)
  }

  private var contentColor: Color {
    message.role == .user ? .white : .primary
  }

  private var backgroundColor: Color {
    if message.state == .pending { return .green.opacity(0.1) }
    if message.state == .failed { return .red.opacity(0.12) }
    return message.role == .user ? .accentColor : .secondary.opacity(0.12)
  }
}
