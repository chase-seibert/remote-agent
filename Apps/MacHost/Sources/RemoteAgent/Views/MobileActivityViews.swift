import AppKit
import SwiftUI

struct MobileActivityIndicatorView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let isActive = model.isRemoteClientActive(at: context.date)
      SettingsLink {
        HStack(spacing: 6) {
          Image(systemName: isActive ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(isActive ? Color.green : Color.secondary)
          Text(isActive ? "Mobile active" : "Mobile idle")
        }
      }
      .help(helpText(now: context.date))
      .accessibilityLabel(isActive ? "Mobile client active" : "Mobile client idle")
    }
  }

  private func helpText(now: Date) -> String {
    guard let date = model.lastRemoteClientActivityAt else {
      return "No remote client requests recorded. Open Settings for connection logs."
    }
    let relative = date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    return "Last remote client request \(relative). Open Settings for connection logs."
  }
}

struct MobileActivityLogView: View {
  @ObservedObject var model: AppModel
  @State private var showingClearConfirmation = false

  private var newestFirst: [APIActivityEntry] {
    Array(model.apiActivityLog.reversed())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      GroupBox {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          HStack(spacing: 10) {
            Image(
              systemName: model.isRemoteClientActive(at: context.date)
                ? "checkmark.circle.fill" : "circle.dashed"
            )
            .foregroundStyle(
              model.isRemoteClientActive(at: context.date) ? Color.green : Color.secondary
            )
            VStack(alignment: .leading, spacing: 2) {
              Text(
                model.isRemoteClientActive(at: context.date)
                  ? "Mobile client active" : "Mobile client idle"
              )
              .font(.headline)
              if let lastActivity = model.lastRemoteClientActivityAt {
                Text(
                  "Last remote request \(lastActivity.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              } else {
                Text("No remote requests have reached this Mac yet.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            Text(model.apiStatus)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      HStack {
        Text("Request Log")
          .font(.headline)
        Text("\(model.apiActivityLog.count) entries")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Copy Log") { copyLog() }
          .disabled(model.apiActivityLog.isEmpty)
        Button("Clear Log", role: .destructive) { showingClearConfirmation = true }
          .disabled(model.apiActivityLog.isEmpty)
      }

      Table(newestFirst) {
        TableColumn("Duration") { entry in
          Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
            .monospacedDigit()
        }
        .width(min: 135, ideal: 155)

        TableColumn("Source") { entry in
          VStack(alignment: .leading, spacing: 1) {
            Text(entry.isRemoteClient ? "Remote" : "This Mac")
            Text(entry.remoteHost)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .width(min: 90, ideal: 110)

        TableColumn("Client") { entry in
          Text(entry.clientName)
            .lineLimit(1)
            .help(entry.clientName)
        }
        .width(min: 90, ideal: 130)

        TableColumn("Request") { entry in
          Text("\(entry.method) \(entry.path)")
            .lineLimit(1)
            .help("\(entry.method) \(entry.path)")
        }
        .width(min: 150, ideal: 240)

        TableColumn("Status") { entry in
          Text("\(entry.statusCode)")
            .monospacedDigit()
            .foregroundStyle(statusColor(entry.statusCode))
        }
        .width(55)

        TableColumn("Time") { entry in
          Text("\(entry.durationMilliseconds) ms")
            .monospacedDigit()
        }
        .width(65)
      }
      .overlay {
        if model.apiActivityLog.isEmpty {
          ContentUnavailableView(
            "No Connection Activity",
            systemImage: "network.slash",
            description: Text("Requests to the local API will appear here.")
          )
        }
      }

      Text(
        "Stores the 500 most recent HTTP requests. Request bodies and authorization tokens are never logged. Remote means a non-loopback source address."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding()
    .confirmationDialog(
      "Clear all API activity?",
      isPresented: $showingClearConfirmation
    ) {
      Button("Clear Log", role: .destructive) { model.clearAPIActivityLog() }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func statusColor(_ status: Int) -> Color {
    switch status {
    case 200..<400: return .green
    case 400..<500: return .orange
    default: return .red
    }
  }

  private func copyLog() {
    let text = newestFirst.map { entry in
      let timestamp = entry.timestamp.formatted(.iso8601)
      let source = entry.isRemoteClient ? "remote" : "local"
      return
        "\(timestamp)\t\(source)\t\(entry.remoteHost)\t\(entry.clientName)\t\(entry.method) \(entry.path)\t\(entry.statusCode)\t\(entry.durationMilliseconds)ms"
    }.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
