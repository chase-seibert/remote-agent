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

      GroupBox {
        if let port = model.apiListeningPort, !model.apiListenerAddresses.isEmpty {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(model.apiListenerAddresses) { address in
                listenerAddressRow(address, port: port)
                if address.id != model.apiListenerAddresses.last?.id {
                  Divider()
                }
              }
            }
          }
          .frame(maxHeight: 130)
        } else {
          Text(
            model.apiListeningPort == nil
              ? "The local API is not currently listening."
              : "No active network-interface addresses were found."
          )
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } label: {
        HStack {
          Label("Listening Addresses", systemImage: "network")
          Spacer()
          Button("Refresh") { model.refreshAPIListenerAddresses() }
            .controlSize(.small)
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

        TableColumn("Payload") { entry in
          Text(payloadSize(entry.responsePayloadByteCount))
            .monospacedDigit()
            .help(payloadSizeHelp(entry.responsePayloadByteCount))
        }
        .width(min: 65, ideal: 75)

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
        "Stores the 500 most recent HTTP requests and logical response payload sizes. Request bodies and authorization tokens are never logged. Remote means a non-loopback source address."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding()
    .onAppear { model.refreshAPIListenerAddresses() }
    .confirmationDialog(
      "Clear all API activity?",
      isPresented: $showingClearConfirmation
    ) {
      Button("Clear Log", role: .destructive) { model.clearAPIActivityLog() }
      Button("Cancel", role: .cancel) {}
    }
  }

  @ViewBuilder
  private func listenerAddressRow(_ address: APIListenerAddress, port: UInt16) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(address.endpoint(port: port))
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
        Text("\(address.interfaceName) · \(address.family.rawValue)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      healthTestStatus(model.apiHealthTestStates[address.id])
      Button("Test") {
        Task { await model.testAPIListenerAddress(address) }
      }
      .disabled(model.apiHealthTestStates[address.id]?.isTesting == true)
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private func healthTestStatus(_ state: APIHealthTestState?) -> some View {
    switch state {
    case .testing:
      HStack(spacing: 5) {
        ProgressView().controlSize(.small)
        Text("Testing…")
      }
      .foregroundStyle(.secondary)
    case .succeeded(let success):
      Label(
        "OK · v\(success.version) · \(success.durationMilliseconds) ms",
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
    case .failed(let message):
      Label("Failed · \(message)", systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
        .lineLimit(1)
        .frame(maxWidth: 260, alignment: .trailing)
        .help(message)
    case nil:
      EmptyView()
    }
  }

  private func statusColor(_ status: Int) -> Color {
    switch status {
    case 200..<400: return .green
    case 400..<500: return .orange
    default: return .red
    }
  }

  private func payloadSize(_ byteCount: Int?) -> String {
    guard let byteCount else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
  }

  private func payloadSizeHelp(_ byteCount: Int?) -> String {
    guard let byteCount else { return "Payload size was not recorded for this older entry." }
    return "\(byteCount.formatted()) response body bytes before transport compression."
  }

  private func copyLog() {
    let text = newestFirst.map { entry in
      let timestamp = entry.timestamp.formatted(.iso8601)
      let source = entry.isRemoteClient ? "remote" : "local"
      let payload = entry.responsePayloadByteCount.map { "\($0)B" } ?? "unknown"
      return
        "\(timestamp)\t\(source)\t\(entry.remoteHost)\t\(entry.clientName)\t\(entry.method) \(entry.path)\t\(entry.statusCode)\t\(payload)\t\(entry.durationMilliseconds)ms"
    }.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
