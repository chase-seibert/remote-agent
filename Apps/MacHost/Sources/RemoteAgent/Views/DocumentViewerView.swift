import AppKit
import SwiftUI
import WebKit

struct DocumentViewerView: View {
  let reference: LocalDocumentReference
  @ObservedObject var settings: AppSettings

  @Environment(\.openWindow) private var openWindow
  @State private var textSource: String?
  @State private var loadError: String?
  @State private var reloadID = UUID()

  var body: some View {
    NavigationStack {
      Group {
        switch reference.kind {
        case .markdown:
          markdownView
        case .code:
          codeView
        case .html:
          LocalHTMLView(
            fileURL: reference.fileURL,
            reloadID: reloadID,
            openLink: openLink,
            onError: { loadError = $0 }
          )
          .overlay { errorOverlay }
        case nil:
          ContentUnavailableView(
            "Unsupported Document",
            systemImage: "doc.badge.ellipsis",
            description: Text(reference.path)
          )
        }
      }
      .navigationTitle(reference.name)
      .navigationSubtitle(reference.path)
      .toolbar {
        ToolbarItemGroup {
          Button {
            reload()
          } label: {
            Label("Reload", systemImage: "arrow.clockwise")
          }
          .help("Reload Document")

          Button {
            NSWorkspace.shared.activateFileViewerSelecting([reference.fileURL])
          } label: {
            Label("Show in Finder", systemImage: "folder")
          }
          .help("Show in Finder")

          Button {
            NSWorkspace.shared.open(reference.fileURL)
          } label: {
            Label("Open in Default App", systemImage: "arrow.up.forward.app")
          }
          .help("Open in Default App")
        }
      }
    }
    .frame(minWidth: 600, minHeight: 450)
    .task(id: reloadID) {
      if reference.kind == .markdown || reference.kind == .code {
        await loadText()
      }
    }
  }

  @ViewBuilder
  private var markdownView: some View {
    if let textSource {
      ScrollView {
        MarkdownContentView(source: textSource, fontScale: settings.fontScale)
          .padding(24)
      }
      .environment(
        \.openURL,
        OpenURLAction { url in
          openLink(url)
          return .handled
        }
      )
    } else if loadError != nil {
      errorOverlay
    } else {
      ProgressView("Loading \(reference.name)…")
    }
  }

  @ViewBuilder
  private var codeView: some View {
    if let textSource {
      ScrollView([.horizontal, .vertical]) {
        HStack(alignment: .top, spacing: 12) {
          Text(lineNumbers(for: textSource))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.trailing)
            .accessibilityHidden(true)
          Divider()
          Text(textSource.isEmpty ? " " : textSource)
            .textSelection(.enabled)
        }
        .font(.system(size: 13 * settings.fontScale, design: .monospaced))
        .lineSpacing(3)
        .fixedSize(horizontal: true, vertical: false)
        .padding(24)
      }
      .defaultScrollAnchor(.topLeading)
      .background(Color(nsColor: .textBackgroundColor))
    } else if loadError != nil {
      errorOverlay
    } else {
      ProgressView("Loading \(reference.name)…")
    }
  }

  @ViewBuilder
  private var errorOverlay: some View {
    if let loadError {
      ContentUnavailableView {
        Label("Document Couldn’t Be Opened", systemImage: "exclamationmark.triangle")
      } description: {
        Text(loadError)
      } actions: {
        Button("Try Again", action: reload)
      }
    }
  }

  private func reload() {
    loadError = nil
    textSource = nil
    reloadID = UUID()
  }

  private func loadText() async {
    do {
      let fileURL = reference.fileURL
      let content = try await Task.detached {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= ProjectDocumentService.maximumByteCount else {
          throw RemoteAgentError.invalidRequest(
            "Document is larger than \(ProjectDocumentService.maximumSizeDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
          throw RemoteAgentError.invalidRequest("Document is not UTF-8 text")
        }
        return text
      }.value
      textSource = content
      loadError = nil
    } catch {
      textSource = nil
      loadError = error.localizedDescription
    }
  }

  private func lineNumbers(for text: String) -> String {
    (1...max(1, text.components(separatedBy: "\n").count))
      .map(String.init)
      .joined(separator: "\n")
  }

  private func openLink(_ link: URL) {
    let baseDirectory = reference.fileURL.deletingLastPathComponent()
    if let document = LocalLinkResolver.document(for: link, relativeTo: baseDirectory) {
      openWindow(value: document)
      return
    }
    if let localFile = LocalLinkResolver.fileURL(for: link, relativeTo: baseDirectory) {
      NSWorkspace.shared.open(localFile)
      return
    }
    NSWorkspace.shared.open(link)
  }
}

private struct LocalHTMLView: NSViewRepresentable {
  let fileURL: URL
  let reloadID: UUID
  let openLink: (URL) -> Void
  let onError: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(openLink: openLink, onError: onError)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    context.coordinator.load(fileURL: fileURL, reloadID: reloadID, in: webView)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.openLink = openLink
    context.coordinator.onError = onError
    context.coordinator.load(fileURL: fileURL, reloadID: reloadID, in: webView)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var openLink: (URL) -> Void
    var onError: (String) -> Void
    private var loadedFileURL: URL?
    private var loadedReloadID: UUID?

    init(openLink: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
      self.openLink = openLink
      self.onError = onError
    }

    func load(fileURL: URL, reloadID: UUID, in webView: WKWebView) {
      guard loadedFileURL != fileURL || loadedReloadID != reloadID else { return }
      loadedFileURL = fileURL
      loadedReloadID = reloadID
      webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url
      else {
        decisionHandler(.allow)
        return
      }

      if url.isFileURL,
        url.standardizedFileURL.path == loadedFileURL?.standardizedFileURL.path,
        url.fragment != nil
      {
        decisionHandler(.allow)
        return
      }
      openLink(url)
      decisionHandler(.cancel)
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation!,
      withError error: Error
    ) {
      onError(error.localizedDescription)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      onError(error.localizedDescription)
    }
  }
}
