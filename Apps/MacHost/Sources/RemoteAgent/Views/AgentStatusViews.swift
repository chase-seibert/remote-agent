import SwiftUI

struct RunningAgentIcon: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var size: CGFloat = 20

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
      Image(systemName: "sparkles")
        .font(.system(size: size * 0.75, weight: .semibold))
        .foregroundStyle(.green)
        .rotationEffect(reduceMotion ? .zero : rotation(at: context.date))
        .symbolEffect(.pulse, isActive: reduceMotion)
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Agent running")
  }

  private func rotation(at date: Date) -> Angle {
    let duration = 1.2
    let progress =
      date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)
      / duration
    return .degrees(progress * 360)
  }
}

struct SessionStatusBadge: View {
  let title: String
  let color: Color
  let fontScale: Double
  var systemImage: String? = nil

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      Text(title)
    }
    .font(.system(size: 10 * fontScale, weight: .semibold))
    .foregroundStyle(color)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(color.opacity(0.12), in: Capsule())
  }
}
