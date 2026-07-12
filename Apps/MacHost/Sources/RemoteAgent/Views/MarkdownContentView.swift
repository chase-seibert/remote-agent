import Foundation
import SwiftUI

enum MarkdownBlock: Equatable, Sendable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case unorderedList([String])
  case orderedList([String])
  case code(language: String?, text: String)
  case quote(String)
  case divider
}

struct MarkdownBlockParser: Sendable {
  func parse(_ source: String) -> [MarkdownBlock] {
    let normalized =
      source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [MarkdownBlock] = []
    var index = 0

    while index < lines.count {
      if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
        index += 1
        continue
      }

      if let fence = codeFence(in: lines[index]) {
        let language = String(
          lines[index].trimmingCharacters(in: .whitespaces).dropFirst(fence.count)
        )
        .trimmingCharacters(in: .whitespaces)
        index += 1
        var codeLines: [String] = []
        while index < lines.count,
          !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence)
        {
          codeLines.append(lines[index])
          index += 1
        }
        if index < lines.count { index += 1 }
        blocks.append(
          .code(
            language: language.isEmpty ? nil : language, text: codeLines.joined(separator: "\n")))
        continue
      }

      if let heading = heading(in: lines[index]) {
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if isDivider(lines[index]) {
        blocks.append(.divider)
        index += 1
        continue
      }

      if unorderedItem(in: lines[index]) != nil {
        var items: [String] = []
        while index < lines.count, let item = unorderedItem(in: lines[index]) {
          var text = item
          index += 1
          text = consumeIndentedContinuation(lines: lines, index: &index, initialText: text)
          items.append(text)
        }
        blocks.append(.unorderedList(items))
        continue
      }

      if orderedItem(in: lines[index]) != nil {
        var items: [String] = []
        while index < lines.count, let item = orderedItem(in: lines[index]) {
          var text = item
          index += 1
          text = consumeIndentedContinuation(lines: lines, index: &index, initialText: text)
          items.append(text)
        }
        blocks.append(.orderedList(items))
        continue
      }

      if quoteLine(in: lines[index]) != nil {
        var quoteLines: [String] = []
        while index < lines.count, let quote = quoteLine(in: lines[index]) {
          quoteLines.append(quote)
          index += 1
        }
        blocks.append(.quote(quoteLines.joined(separator: "\n")))
        continue
      }

      var paragraphLines: [String] = []
      while index < lines.count,
        !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
        !isBlockStart(lines[index], allowParagraphText: paragraphLines.isEmpty)
      {
        paragraphLines.append(lines[index])
        index += 1
      }
      if paragraphLines.isEmpty {
        paragraphLines.append(lines[index])
        index += 1
      }
      blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
    }

    return blocks
  }

  private func consumeIndentedContinuation(
    lines: [String],
    index: inout Int,
    initialText: String
  ) -> String {
    var text = initialText
    while index < lines.count {
      let line = lines[index]
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
        line.first?.isWhitespace == true,
        unorderedItem(in: line) == nil,
        orderedItem(in: line) == nil
      else { break }
      text += "\n" + line.trimmingCharacters(in: .whitespaces)
      index += 1
    }
    return text
  }

  private func isBlockStart(_ line: String, allowParagraphText: Bool) -> Bool {
    if allowParagraphText { return false }
    return codeFence(in: line) != nil
      || heading(in: line) != nil
      || isDivider(line)
      || unorderedItem(in: line) != nil
      || orderedItem(in: line) != nil
      || quoteLine(in: line) != nil
  }

  private func heading(in line: String) -> (level: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let level = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level) else { return nil }
    let remainder = trimmed.dropFirst(level)
    guard remainder.first == " " else { return nil }
    return (level, remainder.trimmingCharacters(in: .whitespaces))
  }

  private func unorderedItem(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2,
      ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) })
    else { return nil }
    return String(trimmed.dropFirst(2))
  }

  private func orderedItem(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.prefix(while: \Character.isNumber)
    guard !digits.isEmpty else { return nil }
    let remainder = trimmed.dropFirst(digits.count)
    guard remainder.hasPrefix(". ") || remainder.hasPrefix(") ") else { return nil }
    return String(remainder.dropFirst(2))
  }

  private func quoteLine(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed == ">" || trimmed.hasPrefix("> ") else { return nil }
    return trimmed == ">" ? "" : String(trimmed.dropFirst(2))
  }

  private func codeFence(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("```") { return "```" }
    if trimmed.hasPrefix("~~~") { return "~~~" }
    return nil
  }

  private func isDivider(_ line: String) -> Bool {
    let compact = line.filter { !$0.isWhitespace }
    return compact.count >= 3
      && (Set(compact) == ["-"] || Set(compact) == ["*"] || Set(compact) == ["_"])
  }
}

struct MarkdownContentView: View {
  let source: String
  let fontScale: Double

  private let parser = MarkdownBlockParser()

  var body: some View {
    let blocks = parser.parse(source)
    VStack(alignment: .leading, spacing: 10 * fontScale) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
    case .paragraph(let text):
      Text(inlineMarkdown(text))
        .font(bodyFont)
        .fixedSize(horizontal: false, vertical: true)

    case .heading(let level, let text):
      Text(inlineMarkdown(text))
        .font(headingFont(level: level))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, level <= 2 ? 4 : 1)

    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: 5 * fontScale) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          listRow(marker: "•", text: item)
        }
      }

    case .orderedList(let items):
      VStack(alignment: .leading, spacing: 5 * fontScale) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          listRow(marker: "\(index + 1).", text: item)
        }
      }

    case .code(let language, let code):
      VStack(alignment: .leading, spacing: 5) {
        if let language {
          Text(language.uppercased())
            .font(.system(size: 10 * fontScale, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        ScrollView(.horizontal) {
          Text(code)
            .font(.system(size: 13 * fontScale, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
            .padding(10)
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      }

    case .quote(let text):
      HStack(alignment: .top, spacing: 9) {
        RoundedRectangle(cornerRadius: 1)
          .fill(.tertiary)
          .frame(width: 3)
        Text(inlineMarkdown(text))
          .font(bodyFont)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

    case .divider:
      Divider()
    }
  }

  private func listRow(marker: String, text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(marker)
        .font(bodyFont)
        .frame(width: 18 * fontScale, alignment: .trailing)
        .accessibilityHidden(true)
      Text(inlineMarkdown(text))
        .font(bodyFont)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  }

  private var bodyFont: Font {
    .system(size: 14 * fontScale)
  }

  private func headingFont(level: Int) -> Font {
    switch level {
    case 1: return .system(size: 22 * fontScale, weight: .bold)
    case 2: return .system(size: 19 * fontScale, weight: .bold)
    case 3: return .system(size: 16 * fontScale, weight: .semibold)
    default: return .system(size: 14 * fontScale, weight: .semibold)
    }
  }
}
