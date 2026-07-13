import Foundation
import SwiftUI

enum MarkdownTableAlignment: Equatable, Sendable {
  case leading
  case center
  case trailing
}

enum MarkdownBlock: Equatable, Sendable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case unorderedList([String])
  case orderedList([String])
  case code(language: String?, text: String)
  case quote(String)
  case table(
    headers: [String],
    alignments: [MarkdownTableAlignment],
    rows: [[String]]
  )
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

      if let table = table(in: lines, at: index) {
        blocks.append(
          .table(
            headers: table.headers,
            alignments: table.alignments,
            rows: table.rows
          ))
        index = table.nextIndex
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
        !isBlockStart(lines: lines, index: index, allowParagraphText: paragraphLines.isEmpty)
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

  private func isBlockStart(lines: [String], index: Int, allowParagraphText: Bool) -> Bool {
    if allowParagraphText { return false }
    let line = lines[index]
    return codeFence(in: line) != nil
      || heading(in: line) != nil
      || isDivider(line)
      || unorderedItem(in: line) != nil
      || orderedItem(in: line) != nil
      || quoteLine(in: line) != nil
      || table(in: lines, at: index) != nil
  }

  private func table(
    in lines: [String],
    at index: Int
  ) -> (
    headers: [String],
    alignments: [MarkdownTableAlignment],
    rows: [[String]],
    nextIndex: Int
  )? {
    guard index + 1 < lines.count,
      let headers = tableCells(in: lines[index]),
      let delimiterCells = tableCells(in: lines[index + 1]),
      !headers.isEmpty,
      headers.count == delimiterCells.count
    else { return nil }

    let alignments = delimiterCells.compactMap(tableAlignment)
    guard alignments.count == headers.count else { return nil }

    var rows: [[String]] = []
    var nextIndex = index + 2
    while nextIndex < lines.count,
      !lines[nextIndex].trimmingCharacters(in: .whitespaces).isEmpty,
      let cells = tableCells(in: lines[nextIndex])
    {
      rows.append(normalizedTableRow(cells, columnCount: headers.count))
      nextIndex += 1
    }
    return (headers, alignments, rows, nextIndex)
  }

  private func tableCells(in line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|") else { return nil }

    var cells: [String] = []
    var current = ""
    var isEscaped = false
    var isInsideCode = false
    var foundSeparator = false

    for character in trimmed {
      if isEscaped {
        current.append(character)
        isEscaped = false
      } else if character == "\\" {
        current.append(character)
        isEscaped = true
      } else if character == "`" {
        current.append(character)
        isInsideCode.toggle()
      } else if character == "|", !isInsideCode {
        cells.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
        foundSeparator = true
      } else {
        current.append(character)
      }
    }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    guard foundSeparator else { return nil }

    if trimmed.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
    if hasUnescapedTrailingPipe(trimmed), cells.last?.isEmpty == true { cells.removeLast() }
    return cells
  }

  private func hasUnescapedTrailingPipe(_ line: String) -> Bool {
    guard line.last == "|" else { return false }
    let slashCount = line.dropLast().reversed().prefix(while: { $0 == "\\" }).count
    return slashCount.isMultiple(of: 2)
  }

  private func tableAlignment(_ cell: String) -> MarkdownTableAlignment? {
    var delimiter = cell.trimmingCharacters(in: .whitespaces)
    let hasLeadingColon = delimiter.hasPrefix(":")
    let hasTrailingColon = delimiter.hasSuffix(":")
    if hasLeadingColon { delimiter.removeFirst() }
    if hasTrailingColon, !delimiter.isEmpty { delimiter.removeLast() }
    delimiter = delimiter.trimmingCharacters(in: .whitespaces)
    guard delimiter.count >= 3, delimiter.allSatisfy({ $0 == "-" }) else { return nil }
    if hasLeadingColon, hasTrailingColon { return .center }
    if hasTrailingColon { return .trailing }
    return .leading
  }

  private func normalizedTableRow(_ cells: [String], columnCount: Int) -> [String] {
    var normalized = Array(cells.prefix(columnCount))
    normalized.append(contentsOf: repeatElement("", count: max(0, columnCount - normalized.count)))
    return normalized
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

    case .table(let headers, let alignments, let rows):
      markdownTable(headers: headers, alignments: alignments, rows: rows)

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

  private func markdownTable(
    headers: [String],
    alignments: [MarkdownTableAlignment],
    rows: [[String]]
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: 7)
    return ScrollView(.horizontal) {
      Grid(horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(headers.indices, id: \.self) { column in
            tableCell(
              headers[column],
              width: tableColumnWidth(headers: headers, rows: rows, column: column),
              alignment: alignments[column],
              isHeader: true,
              isAlternating: false
            )
          }
        }
        ForEach(rows.indices, id: \.self) { row in
          GridRow {
            ForEach(headers.indices, id: \.self) { column in
              tableCell(
                rows[row][column],
                width: tableColumnWidth(headers: headers, rows: rows, column: column),
                alignment: alignments[column],
                isHeader: false,
                isAlternating: row.isMultiple(of: 2) == false
              )
            }
          }
        }
      }
      .clipShape(shape)
      .overlay(shape.stroke(.tertiary, lineWidth: 1))
    }
  }

  private func tableCell(
    _ text: String,
    width: CGFloat,
    alignment: MarkdownTableAlignment,
    isHeader: Bool,
    isAlternating: Bool
  ) -> some View {
    Text(inlineMarkdown(text))
      .font(.system(size: 13 * fontScale, weight: isHeader ? .semibold : .regular))
      .multilineTextAlignment(textAlignment(alignment))
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: width, alignment: viewAlignment(alignment))
      .frame(maxHeight: .infinity, alignment: viewAlignment(alignment))
      .padding(.horizontal, 10 * fontScale)
      .padding(.vertical, 8 * fontScale)
      .background(
        isHeader
          ? Color.primary.opacity(0.1)
          : Color.primary.opacity(isAlternating ? 0.035 : 0)
      )
      .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
  }

  private func tableColumnWidth(headers: [String], rows: [[String]], column: Int) -> CGFloat {
    let values = [headers[column]] + rows.map { $0[column] }
    let longest = values.map(\.count).max() ?? 0
    return min(max(CGFloat(longest) * 7 * fontScale, 88 * fontScale), 280 * fontScale)
  }

  private func viewAlignment(_ alignment: MarkdownTableAlignment) -> Alignment {
    switch alignment {
    case .leading: .topLeading
    case .center: .top
    case .trailing: .topTrailing
    }
  }

  private func textAlignment(_ alignment: MarkdownTableAlignment) -> TextAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
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
