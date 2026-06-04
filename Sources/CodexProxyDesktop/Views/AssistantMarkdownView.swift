#if os(macOS)
import SwiftUI

struct AssistantMarkdownView: View {
    let text: String
    let palette: AppearancePalette
    let colorScheme: ColorScheme

    private var blocks: [AssistantMarkdownBlock] {
        AssistantMarkdownParser.parse(self.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(self.blocks.enumerated()), id: \.offset) { _, block in
                self.blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let content):
            self.inlineText(content, font: .system(size: 13, weight: .regular))
        case .heading(let level, let content):
            self.inlineText(content, font: .system(size: level == 1 ? 16 : 14, weight: .bold))
                .padding(.top, level == 1 ? 2 : 0)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                        self.inlineText(item, font: .system(size: 13, weight: .regular))
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1).")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        self.inlineText(item, font: .system(size: 13, weight: .regular))
                    }
                }
            }
        case .codeBlock(let content), .preformatted(let content):
            self.preformattedBlock(content)
        }
    }

    private func inlineText(_ content: String, font: Font) -> some View {
        Text(Self.attributedMarkdown(content))
            .font(font)
            .foregroundStyle(palette.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func preformattedBlock(_ content: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(content)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.consoleBackground.opacity(colorScheme == .dark ? 0.72 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.border.opacity(0.7), lineWidth: 1)
        )
    }

    private static func attributedMarkdown(_ content: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(content)
        }
    }
}

private enum AssistantMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, String)
    case unorderedList([String])
    case orderedList([String])
    case codeBlock(String)
    case preformatted(String)
}

private enum AssistantMarkdownParser {
    static func parse(_ text: String) -> [AssistantMarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [AssistantMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = Self.codeFence(from: trimmed) {
                let result = Self.consumeCodeBlock(lines: lines, startIndex: index, fence: fence)
                blocks.append(.codeBlock(result.content))
                index = result.nextIndex
                continue
            }

            if Self.isTableLine(line) {
                let result = Self.consumeTable(lines: lines, startIndex: index)
                blocks.append(.preformatted(Self.alignedTable(result.lines)))
                index = result.nextIndex
                continue
            }

            if let heading = Self.heading(from: line) {
                blocks.append(.heading(level: heading.level, heading.text))
                index += 1
                continue
            }

            if let firstItem = Self.unorderedListItem(from: line) {
                let result = Self.consumeUnorderedList(lines: lines, startIndex: index, firstItem: firstItem)
                blocks.append(.unorderedList(result.items))
                index = result.nextIndex
                continue
            }

            if let firstItem = Self.orderedListItem(from: line) {
                let result = Self.consumeOrderedList(lines: lines, startIndex: index, firstItem: firstItem)
                blocks.append(.orderedList(result.items))
                index = result.nextIndex
                continue
            }

            let result = Self.consumeParagraph(lines: lines, startIndex: index)
            blocks.append(.paragraph(result.content))
            index = result.nextIndex
        }

        return blocks.isEmpty ? [.paragraph(text)] : blocks
    }

    private static func codeFence(from trimmedLine: String) -> String? {
        if trimmedLine.hasPrefix("```") { return "```" }
        if trimmedLine.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func consumeCodeBlock(lines: [String], startIndex: Int, fence: String) -> (content: String, nextIndex: Int) {
        var content: [String] = []
        var index = startIndex + 1

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(fence) {
                return (content.joined(separator: "\n"), index + 1)
            }
            content.append(lines[index])
            index += 1
        }

        return (content.joined(separator: "\n"), index)
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        for character in trimmed {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...3).contains(level), trimmed.dropFirst(level).first == " " else {
            return nil
        }
        return (level, String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedListItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ ", "• "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func orderedListItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard digits.isEmpty == false else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return nil }
        let content = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func consumeUnorderedList(lines: [String], startIndex: Int, firstItem: String) -> (items: [String], nextIndex: Int) {
        var items = [firstItem]
        var index = startIndex + 1
        while index < lines.count, let item = Self.unorderedListItem(from: lines[index]) {
            items.append(item)
            index += 1
        }
        return (items, index)
    }

    private static func consumeOrderedList(lines: [String], startIndex: Int, firstItem: String) -> (items: [String], nextIndex: Int) {
        var items = [firstItem]
        var index = startIndex + 1
        while index < lines.count, let item = Self.orderedListItem(from: lines[index]) {
            items.append(item)
            index += 1
        }
        return (items, index)
    }

    private static func consumeParagraph(lines: [String], startIndex: Int) -> (content: String, nextIndex: Int) {
        var paragraph: [String] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty
                || Self.codeFence(from: trimmed) != nil
                || Self.isTableLine(line)
                || Self.heading(from: line) != nil
                || Self.unorderedListItem(from: line) != nil
                || Self.orderedListItem(from: line) != nil
            {
                break
            }
            paragraph.append(line)
            index += 1
        }

        return (paragraph.joined(separator: "\n"), index)
    }

    private static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count >= 3
    }

    private static func consumeTable(lines: [String], startIndex: Int) -> (lines: [String], nextIndex: Int) {
        var tableLines: [String] = []
        var index = startIndex
        while index < lines.count, Self.isTableLine(lines[index]) {
            tableLines.append(lines[index])
            index += 1
        }
        return (tableLines, index)
    }

    private static func alignedTable(_ lines: [String]) -> String {
        let rows = lines
            .map(Self.tableColumns)
            .filter { columns in
                columns.isEmpty == false && Self.isTableSeparator(columns) == false
            }
        guard rows.isEmpty == false else {
            return lines.joined(separator: "\n")
        }

        let columnCount = rows.map(\.count).max() ?? 0
        let widths = (0..<columnCount).map { column in
            rows.map { row in column < row.count ? row[column].count : 0 }.max() ?? 0
        }

        return rows.map { row in
            (0..<columnCount).map { column in
                let value = column < row.count ? row[column] : ""
                return value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    private static func tableColumns(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ columns: [String]) -> Bool {
        columns.allSatisfy { column in
            let normalized = column.replacingOccurrences(of: ":", with: "")
            return normalized.isEmpty == false && normalized.allSatisfy { $0 == "-" }
        }
    }
}
#endif
