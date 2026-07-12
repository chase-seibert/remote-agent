import SwiftUI
import WebKit

struct ProjectDocumentsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let project: AgentProject
  @State private var documents: [ProjectDocument] = []
  @State private var isLoading = true
  @State private var loadError: String?

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView("Loading files…")
        } else if let loadError {
          ContentUnavailableView {
            Label("Couldn’t Load Files", systemImage: "exclamationmark.triangle")
          } description: {
            Text(loadError)
          } actions: {
            Button("Try Again") { Task { await load() } }
          }
        } else if documents.isEmpty {
          ContentUnavailableView(
            "No Documents",
            systemImage: "doc",
            description: Text("This project has no Markdown or HTML files.")
          )
        } else {
          List(documents) { document in
            NavigationLink(value: document) {
              ProjectDocumentRow(document: document)
            }
          }
          .refreshable { await load() }
        }
      }
      .navigationTitle(project.name)
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: ProjectDocument.self) { document in
        ProjectDocumentDetailView(
          projectID: project.id,
          projectPath: project.path,
          document: document
        )
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task { await load() }
    }
  }

  private func load() async {
    isLoading = true
    loadError = nil
    do {
      documents = try await model.documents(projectID: project.id).browsable
    } catch {
      loadError = error.localizedDescription
    }
    isLoading = false
  }
}

private struct ProjectDocumentRow: View {
  let document: ProjectDocument

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(iconColor)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(document.name)
          .font(.body.weight(.medium))
        HStack(spacing: 5) {
          if document.relativePath != document.name {
            Text(document.relativePath)
              .lineLimit(1)
              .truncationMode(.middle)
            Text("•")
          }
          Text(
            ByteCountFormatter.string(fromByteCount: Int64(document.byteCount), countStyle: .file))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
  }

  private var icon: String {
    switch document.kind {
    case .markdown: "doc.text"
    case .html: "safari"
    case .code: "chevron.left.forwardslash.chevron.right"
    }
  }

  private var iconColor: Color {
    switch document.kind {
    case .markdown: Color.accentColor
    case .html: .orange
    case .code: .green
    }
  }
}

#if DEBUG
  struct ProjectDocumentBrowserFixtureView: View {
    private let catalog = [
      ProjectDocument(
        id: "readme",
        name: "README.md",
        relativePath: "README.md",
        kind: .markdown,
        byteCount: 2_048
      ),
      ProjectDocument(
        id: "report",
        name: "status.html",
        relativePath: "docs/status.html",
        kind: .html,
        byteCount: 4_096
      ),
      ProjectDocument(
        id: "swift",
        name: "App.swift",
        relativePath: "Sources/App.swift",
        kind: .code,
        byteCount: 8_192
      ),
      ProjectDocument(
        id: "json",
        name: "package.json",
        relativePath: "package.json",
        kind: .code,
        byteCount: 1_024
      ),
    ]

    var body: some View {
      List(catalog.browsable) { document in
        ProjectDocumentRow(document: document)
      }
      .navigationTitle("Browse Files")
    }
  }
#endif

struct LinkedProjectDocumentView: View {
  @Environment(\.dismiss) private var dismiss
  let projectID: String
  let projectPath: String
  let document: ProjectDocument

  var body: some View {
    NavigationStack {
      ProjectDocumentDetailView(
        projectID: projectID,
        projectPath: projectPath,
        document: document
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

struct ProjectDocumentDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openURL) private var externalOpenURL
  let projectID: String
  let projectPath: String
  let document: ProjectDocument
  @State private var content: String?
  @State private var isLoading = true
  @State private var loadError: String?
  @State private var linkedDocument: ProjectDocument?

  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading \(document.name)…")
      } else if let loadError {
        ContentUnavailableView {
          Label("Couldn’t Open File", systemImage: "exclamationmark.triangle")
        } description: {
          Text(loadError)
        } actions: {
          Button("Try Again") { Task { await load() } }
        }
      } else if let content {
        switch document.kind {
        case .markdown:
          ScrollView {
            MarkdownDocumentPreview(text: content)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
              .textSelection(.enabled)
              .environment(\.openURL, OpenURLAction { handleMarkdownLink($0) })
          }
        case .html:
          HTMLDocumentView(
            html: content,
            documentRelativePath: document.relativePath,
            onOpenURL: handleHTMLLink
          )
        case .code:
          CodeDocumentPreview(text: content)
        }
      }
    }
    .navigationTitle(document.name)
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .sheet(item: $linkedDocument) { linkedDocument in
      LinkedProjectDocumentView(
        projectID: projectID,
        projectPath: projectPath,
        document: linkedDocument
      )
      .environmentObject(model)
    }
  }

  private func load() async {
    isLoading = true
    loadError = nil
    do {
      content = try await model.documentContent(
        projectID: projectID,
        documentID: document.id
      ).content
    } catch {
      loadError = error.localizedDescription
    }
    isLoading = false
  }

  private func handleMarkdownLink(_ url: URL) -> OpenURLAction.Result {
    switch ProjectLinkResolver.destination(
      for: url,
      projectPath: projectPath,
      currentDocumentRelativePath: document.relativePath
    ) {
    case .web:
      return .systemAction
    case .document(let relativePath):
      Task { await openDocument(relativePath: relativePath) }
      return .handled
    case .unsupported:
      return .discarded
    }
  }

  private func handleHTMLLink(_ url: URL) {
    switch ProjectLinkResolver.destination(
      for: url,
      projectPath: projectPath,
      currentDocumentRelativePath: document.relativePath
    ) {
    case .web(let url):
      externalOpenURL(url)
    case .document(let relativePath):
      Task { await openDocument(relativePath: relativePath) }
    case .unsupported:
      break
    }
  }

  private func openDocument(relativePath: String) async {
    do {
      linkedDocument = try await model.document(
        projectID: projectID,
        relativePath: relativePath
      )
    } catch {
      model.presentedError = error.localizedDescription
    }
  }
}

struct CodeDocumentPreview: View {
  let text: String

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      HStack(alignment: .top, spacing: 12) {
        Text(Self.lineNumbers(for: text))
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.trailing)
          .accessibilityHidden(true)

        Divider()

        Text(text.isEmpty ? " " : text)
          .foregroundStyle(.primary)
          .textSelection(.enabled)
      }
      .font(.system(.callout, design: .monospaced))
      .lineSpacing(3)
      .fixedSize(horizontal: true, vertical: false)
      .padding()
    }
    .defaultScrollAnchor(.topLeading)
    .background(Color(uiColor: .secondarySystemBackground))
  }

  static func lineNumbers(for text: String) -> String {
    (1...max(1, text.components(separatedBy: "\n").count))
      .map(String.init)
      .joined(separator: "\n")
  }
}

#if DEBUG
  struct CodePreviewFixtureView: View {
    private let source = """
      import SwiftUI

      struct ProjectRow: View {
        let name: String
        let isRunning: Bool

        var body: some View {
          Label(name, systemImage: isRunning ? "sparkles" : "folder")
            .foregroundStyle(isRunning ? .green : .primary)
        }
      }
      """

    var body: some View {
      CodeDocumentPreview(text: source)
        .navigationTitle("ProjectRow.swift")
        .navigationBarTitleDisplayMode(.inline)
    }
  }
#endif

private struct MarkdownDocumentPreview: View {
  let text: String

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 14) {
      ForEach(Array(MarkdownDocumentParser.parse(text).enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownDocumentBlock) -> some View {
    switch block {
    case .heading(let level, let content):
      Text(inlineMarkdown(content))
        .font(headingFont(level))
        .fontWeight(.bold)
        .padding(.top, level <= 2 ? 6 : 2)
        .accessibilityAddTraits(.isHeader)
    case .paragraph(let content):
      Text(inlineMarkdown(content))
        .font(.body)
        .lineSpacing(3)
    case .unorderedListItem(let depth, let content):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let isComplete = taskState(content) {
          Image(systemName: isComplete ? "checkmark.square.fill" : "square")
            .foregroundStyle(isComplete ? Color.accentColor : .secondary)
            .accessibilityLabel(isComplete ? "Completed" : "Not completed")
        } else {
          Text("•")
            .font(.body.weight(.bold))
            .accessibilityHidden(true)
        }
        Text(inlineMarkdown(taskContent(content)))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(depth) * 18)
    case .orderedListItem(let depth, let number, let content):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(number).")
          .font(.body.monospacedDigit())
          .foregroundStyle(.secondary)
        Text(inlineMarkdown(content))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(depth) * 18)
    case .quote(let content):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.accentColor.opacity(0.55))
          .frame(width: 4)
        Text(inlineMarkdown(content))
          .foregroundStyle(.secondary)
          .italic()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 2)
    case .code(let language, let content):
      VStack(alignment: .leading, spacing: 6) {
        if let language, !language.isEmpty {
          Text(language)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        ScrollView(.horizontal) {
          Text(content)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(12)
      .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    case .rule:
      Divider()
    }
  }

  private func inlineMarkdown(_ content: String) -> AttributedString {
    (try? AttributedString(
      markdown: content,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(content)
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .largeTitle
    case 2: .title
    case 3: .title2
    case 4: .headline
    case 5: .subheadline
    default: .footnote
    }
  }

  private func taskState(_ content: String) -> Bool? {
    let prefix = content.prefix(4).lowercased()
    if prefix == "[x] " { return true }
    if prefix == "[ ] " { return false }
    return nil
  }

  private func taskContent(_ content: String) -> String {
    taskState(content) == nil ? content : String(content.dropFirst(4))
  }
}

enum MarkdownDocumentBlock: Equatable {
  case heading(level: Int, content: String)
  case paragraph(String)
  case unorderedListItem(depth: Int, content: String)
  case orderedListItem(depth: Int, number: String, content: String)
  case quote(String)
  case code(language: String?, content: String)
  case rule
}

enum MarkdownDocumentParser {
  static func parse(_ text: String) -> [MarkdownDocumentBlock] {
    var result: [MarkdownDocumentBlock] = []
    var paragraphLines: [String] = []
    var quoteLines: [String] = []
    var codeLines: [String] = []
    var codeLanguage: String?
    var inCodeBlock = false

    func flushParagraph() {
      guard !paragraphLines.isEmpty else { return }
      result.append(.paragraph(paragraphLines.joined(separator: " ")))
      paragraphLines.removeAll()
    }

    func flushQuote() {
      guard !quoteLines.isEmpty else { return }
      result.append(.quote(quoteLines.joined(separator: " ")))
      quoteLines.removeAll()
    }

    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        if inCodeBlock {
          result.append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
          codeLines.removeAll()
          codeLanguage = nil
        } else {
          flushParagraph()
          flushQuote()
          let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
          codeLanguage = language.isEmpty ? nil : language
        }
        inCodeBlock.toggle()
        continue
      }

      if inCodeBlock {
        codeLines.append(line)
        continue
      }

      if trimmed.isEmpty {
        flushParagraph()
        flushQuote()
        continue
      }

      if trimmed.hasPrefix(">") {
        flushParagraph()
        quoteLines.append(
          String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
        continue
      }
      flushQuote()

      if let heading = heading(from: trimmed) {
        flushParagraph()
        result.append(heading)
      } else if isRule(trimmed) {
        flushParagraph()
        result.append(.rule)
      } else if let listItem = listItem(from: line) {
        flushParagraph()
        result.append(listItem)
      } else {
        paragraphLines.append(trimmed)
      }
    }

    if inCodeBlock {
      result.append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
    }
    flushParagraph()
    flushQuote()
    return result.isEmpty ? [.paragraph("")] : result
  }

  private static func heading(from line: String) -> MarkdownDocumentBlock? {
    let level = line.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
    return .heading(
      level: level,
      content: String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
    )
  }

  private static func listItem(from line: String) -> MarkdownDocumentBlock? {
    let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
    let indentationWidth = indentation.reduce(0) { width, character in
      width + (character == "\t" ? 2 : 1)
    }
    let depth = indentationWidth / 2
    let content = line.dropFirst(indentation.count)

    for prefix in ["- ", "* ", "+ "] where content.hasPrefix(prefix) {
      return .unorderedListItem(depth: depth, content: String(content.dropFirst(2)))
    }

    let digits = content.prefix(while: { $0.isNumber })
    guard !digits.isEmpty else { return nil }
    let suffix = content.dropFirst(digits.count)
    guard suffix.hasPrefix(". ") || suffix.hasPrefix(") ") else { return nil }
    return .orderedListItem(
      depth: depth,
      number: String(digits),
      content: String(suffix.dropFirst(2))
    )
  }

  private static func isRule(_ line: String) -> Bool {
    let compact = line.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 3, let marker = compact.first, ["-", "*", "_"].contains(marker) else {
      return false
    }
    return compact.allSatisfy { $0 == marker }
  }
}

private struct HTMLDocumentView: UIViewRepresentable {
  let html: String
  let documentRelativePath: String
  let onOpenURL: (URL) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(documentRelativePath: documentRelativePath, onOpenURL: onOpenURL)
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsLinkPreview = false
    webView.isInspectable = false
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    context.coordinator.documentRelativePath = documentRelativePath
    context.coordinator.onOpenURL = onOpenURL
    guard context.coordinator.loadedHTML != html else { return }
    context.coordinator.loadedHTML = html
    webView.loadHTMLString(
      Self.restrictedHTML(html),
      baseURL: ProjectLinkResolver.baseURL(for: documentRelativePath)
    )
  }

  private static func restrictedHTML(_ html: String) -> String {
    let restrictions = """
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
      <meta name="color-scheme" content="light dark">
      <style>
        :root { color-scheme: light dark; }
        html, body { background-color: Canvas; color: CanvasText; }
        a { color: LinkText; }
      </style>
      """
    if let headStart = html.range(of: "<head", options: .caseInsensitive),
      let headEnd = html.range(of: ">", range: headStart.lowerBound..<html.endIndex)
    {
      var result = html
      result.insert(contentsOf: restrictions, at: headEnd.upperBound)
      return result
    }
    return "<head>\(restrictions)</head>\(html)"
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loadedHTML: String?
    var documentRelativePath: String
    var onOpenURL: (URL) -> Void

    init(documentRelativePath: String, onOpenURL: @escaping (URL) -> Void) {
      self.documentRelativePath = documentRelativePath
      self.onOpenURL = onOpenURL
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

      let internalPath = String(url.path.drop(while: { $0 == "/" }))
      if url.scheme == ProjectLinkResolver.internalScheme,
        url.fragment != nil,
        internalPath == documentRelativePath
      {
        decisionHandler(.allow)
        return
      }

      onOpenURL(url)
      decisionHandler(.cancel)
    }
  }
}
