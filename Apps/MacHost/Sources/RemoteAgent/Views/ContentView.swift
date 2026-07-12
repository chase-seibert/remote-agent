import AppKit
import SwiftUI

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var model: AppModel
  @ObservedObject var settings: AppSettings
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      AllSessionsSidebarView(model: model, fontScale: settings.fontScale)
        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
    } detail: {
      ConversationView(model: model, fontScale: settings.fontScale)
    }
    .frame(minWidth: 760, minHeight: 560)
    .environment(
      \.openURL,
      OpenURLAction { url in
        openLink(url)
      }
    )
    .toolbar {
      ToolbarItem(placement: .automatic) {
        MobileActivityIndicatorView(model: model)
      }
    }
    .task { await model.start() }
    .onChange(of: scenePhase) { _, phase in
      model.appActivationChanged(isActive: phase == .active)
    }
    .sheet(isPresented: $model.isShowingNewSessionPicker) {
      NewSessionProjectPickerView(model: model)
    }
    .alert(
      "Remote Agent",
      isPresented: Binding(
        get: { model.presentedError != nil },
        set: { if !$0 { model.presentedError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { model.presentedError = nil }
    } message: {
      Text(model.presentedError ?? "Unknown error")
    }
  }

  private func openLink(_ link: URL) -> OpenURLAction.Result {
    let projectPath = model.selectedSession?.projectPath ?? model.selectedProject?.path
    let baseDirectory = projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let document = LocalLinkResolver.document(for: link, relativeTo: baseDirectory) {
      openWindow(value: document)
      return .handled
    }
    if let localFile = LocalLinkResolver.fileURL(for: link, relativeTo: baseDirectory) {
      NSWorkspace.shared.open(localFile)
      return .handled
    }
    return .systemAction(link)
  }
}
