import SwiftUI
import ClarcCore

// MARK: - Parsed document cache

/// Caches only semantic markdown blocks. Typography and theme colors are
/// applied while rendering, so changing message font size cannot revive stale
/// attributed strings from the cache.
private final class MarkdownDocumentCache: @unchecked Sendable {
    static let shared = MarkdownDocumentCache()
    private let cache = NSCache<NSString, CacheEntry>()

    private final class CacheEntry {
        let blocks: [MarkdownRenderBlock]
        init(_ blocks: [MarkdownRenderBlock]) { self.blocks = blocks }
    }

    private init() {
        cache.countLimit = 200
    }

    func get(_ key: String) -> [MarkdownRenderBlock]? {
        cache.object(forKey: key as NSString)?.blocks
    }

    func set(_ key: String, _ blocks: [MarkdownRenderBlock]) {
        cache.setObject(CacheEntry(blocks), forKey: key as NSString)
    }
}

// MARK: - Semantic markdown model

struct MarkdownOrderedListItem: Equatable {
    let number: Int
    let content: String
}

enum MarkdownRenderBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, content: String)
    case unorderedList([String])
    case orderedList([MarkdownOrderedListItem])
    case blockquote([String])
    case codeBlock(language: String, code: String)
    case table(headers: [String], rows: [[String]])
    case horizontalRule
}

enum MarkdownTypography {
    static var bodyFontSize: CGFloat { ClaudeTheme.messageSize(14) }
    static let bodyLineSpacing: CGFloat = 3
    static let paragraphSpacing: CGFloat = 11
    static let listItemSpacing: CGFloat = 5
    static let listSpacing: CGFloat = 9
    static let blockquoteSpacing: CGFloat = 11
    static let headingAfterSpacing: CGFloat = 6
    static let codeSpacing: CGFloat = 11

    static func headingBeforeSpacing(level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 16
        case 3, 4: 13
        default: 10
        }
    }

    static func headingFontSize(level: Int) -> CGFloat {
        let base: CGFloat
        switch level {
        case 1: base = 19
        case 2: base = 17
        case 3: base = 15.5
        default: base = 14
        }
        return ClaudeTheme.messageSize(base)
    }

    static func headingWeight(level: Int) -> Font.Weight {
        switch level {
        case 1, 2, 3, 4: .semibold
        default: .medium
        }
    }

    static func spacingBefore(
        _ block: MarkdownRenderBlock,
        previous: MarkdownRenderBlock?
    ) -> CGFloat {
        guard let previous else { return 0 }

        switch block {
        case .heading(let level, _):
            return headingBeforeSpacing(level: level)
        case .paragraph:
            if case .heading = previous { return headingAfterSpacing }
            return paragraphSpacing
        case .unorderedList, .orderedList:
            if case .heading = previous { return headingAfterSpacing }
            return listSpacing
        case .blockquote:
            if case .heading = previous { return headingAfterSpacing }
            return blockquoteSpacing
        case .codeBlock, .table, .horizontalRule:
            if case .heading = previous { return headingAfterSpacing }
            return codeSpacing
        }
    }
}

enum MarkdownDocumentParser {
    static func parse(_ text: String) -> [MarkdownRenderBlock] {
        let lines = text.components(separatedBy: "\n")
        var result: [MarkdownRenderBlock] = []
        var paragraphLines: [String] = []
        var unorderedItems: [String] = []
        var orderedItems: [MarkdownOrderedListItem] = []
        var quoteLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            result.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushUnorderedList() {
            guard !unorderedItems.isEmpty else { return }
            result.append(.unorderedList(unorderedItems))
            unorderedItems.removeAll(keepingCapacity: true)
        }

        func flushOrderedList() {
            guard !orderedItems.isEmpty else { return }
            result.append(.orderedList(orderedItems))
            orderedItems.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            result.append(.blockquote(quoteLines))
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushAll() {
            flushParagraph()
            flushUnorderedList()
            flushOrderedList()
            flushQuote()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushAll()
                let language = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                result.append(.codeBlock(
                    language: language,
                    code: codeLines.joined(separator: "\n").trimmingTrailingNewlines()
                ))
                continue
            }

            if let table = parseTable(lines: lines, startIndex: index) {
                flushAll()
                result.append(.table(headers: table.headers, rows: table.rows))
                index = table.endIndex
                continue
            }

            if let heading = parseHeading(line) {
                flushAll()
                result.append(.heading(level: heading.level, content: heading.content))
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushAll()
                result.append(.horizontalRule)
                index += 1
                continue
            }

            if let item = parseUnorderedListItem(line) {
                flushParagraph()
                flushOrderedList()
                flushQuote()
                unorderedItems.append(item)
                index += 1
                continue
            }

            if let item = parseOrderedListItem(line) {
                flushParagraph()
                flushUnorderedList()
                flushQuote()
                orderedItems.append(.init(number: item.number, content: item.content))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                var quote = String(trimmed.dropFirst())
                if quote.hasPrefix(" ") { quote.removeFirst() }
                quoteLines.append(quote)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            flushUnorderedList()
            flushOrderedList()
            flushQuote()
            paragraphLines.append(line)
            index += 1
        }

        flushAll()
        return result
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let marker = compact.first else { return false }
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func parseTable(
        lines: [String],
        startIndex: Int
    ) -> (headers: [String], rows: [[String]], endIndex: Int)? {
        guard startIndex + 1 < lines.count else { return nil }
        let headerLine = lines[startIndex]
        let separatorLine = lines[startIndex + 1]
        guard headerLine.contains("|"),
              isTableSeparator(separatorLine.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        let headers = parseTableRow(headerLine)
        guard !headers.isEmpty else { return nil }

        var rows: [[String]] = []
        var currentIndex = startIndex + 2
        while currentIndex < lines.count {
            let row = lines[currentIndex]
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            guard !isTableSeparator(trimmed) else {
                currentIndex += 1
                continue
            }
            rows.append(parseTableRow(row))
            currentIndex += 1
        }
        return (headers, rows, currentIndex)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.contains("--") else { return false }
        return compact.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseHeading(_ line: String) -> (level: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level), trimmed.count > level else { return nil }
        let remainder = trimmed.dropFirst(level)
        guard remainder.first == " " else { return nil }
        let content = String(remainder.dropFirst())
            .trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : (level, content)
    }

    private static func parseUnorderedListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("+ ") else {
            return nil
        }
        return String(trimmed.dropFirst(2))
    }

    private static func parseOrderedListItem(_ line: String) -> (number: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: "."),
              let number = Int(trimmed[..<dotIndex]),
              number >= 0 else {
            return nil
        }
        let afterDot = trimmed[trimmed.index(after: dotIndex)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        return (number, String(afterDot.dropFirst()))
    }
}

// MARK: - Markdown content view

struct MarkdownContentView: View {
    let text: String
    @State private var cachedBlocks: [MarkdownRenderBlock]
    @State private var cachedText: String

    init(text: String) {
        self.text = text
        let blocks: [MarkdownRenderBlock]
        if let cached = MarkdownDocumentCache.shared.get(text) {
            blocks = cached
        } else {
            blocks = MarkdownDocumentParser.parse(text)
            MarkdownDocumentCache.shared.set(text, blocks)
        }
        _cachedBlocks = State(initialValue: blocks)
        _cachedText = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cachedBlocks.enumerated()), id: \.offset) { index, block in
                render(block)
                    .padding(.top, MarkdownTypography.spacingBefore(
                        block,
                        previous: index > 0 ? cachedBlocks[index - 1] : nil
                    ))
            }
        }
        .onChange(of: text) { _, newText in
            guard newText != cachedText else { return }
            cachedText = newText
            if let cached = MarkdownDocumentCache.shared.get(newText) {
                cachedBlocks = cached
            } else {
                let parsed = MarkdownDocumentParser.parse(newText)
                MarkdownDocumentCache.shared.set(newText, parsed)
                cachedBlocks = parsed
            }
        }
    }

    @ViewBuilder
    private func render(_ block: MarkdownRenderBlock) -> some View {
        switch block {
        case .paragraph(let content):
            MarkdownTextView(content: content)
        case .heading(let level, let content):
            Text(parseInlineMarkdown(
                content,
                fontSize: MarkdownTypography.headingFontSize(level: level),
                baseWeight: MarkdownTypography.headingWeight(level: level)
            ))
            .lineSpacing(MarkdownTypography.bodyLineSpacing)
            .foregroundStyle(ClaudeTheme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .unorderedList(let items):
            MarkdownUnorderedListView(items: items)
        case .orderedList(let items):
            MarkdownOrderedListView(items: items)
        case .blockquote(let lines):
            BlockquoteView(lines: lines)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
        case .horizontalRule:
            ClaudeThemeDivider()
        }
    }
}

// MARK: - Text styles

private struct MarkdownTextView: View {
    let content: String

    var body: some View {
        Text(parseInlineMarkdown(
            content,
            fontSize: MarkdownTypography.bodyFontSize
        ))
        .lineSpacing(MarkdownTypography.bodyLineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownUnorderedListView: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownTypography.listItemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•")
                        .font(.system(size: MarkdownTypography.bodyFontSize, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(width: 10, alignment: .trailing)
                    MarkdownTextView(content: item)
                }
            }
        }
    }
}

private struct MarkdownOrderedListView: View {
    let items: [MarkdownOrderedListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownTypography.listItemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(item.number).")
                        .font(.system(
                            size: MarkdownTypography.bodyFontSize,
                            weight: .medium,
                            design: .monospaced
                        ))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(minWidth: 20, alignment: .trailing)
                    MarkdownTextView(content: item.content)
                }
            }
        }
    }
}

private struct BlockquoteView: View {
    let lines: [String]

    var body: some View {
        Text(parseInlineMarkdown(
            lines.joined(separator: "\n"),
            fontSize: MarkdownTypography.bodyFontSize
        ))
        .foregroundStyle(ClaudeTheme.textSecondary)
        .lineSpacing(MarkdownTypography.bodyLineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(ClaudeTheme.border)
                .frame(width: 2)
        }
    }
}

// MARK: - Inline markdown

private func parseInlineMarkdown(
    _ content: String,
    fontSize: CGFloat,
    baseWeight: Font.Weight = .regular
) -> AttributedString {
    let autoLinked = autoLinkURLs(sanitizeMarkdownLinkURLs(content))
    guard var result = try? AttributedString(
        markdown: autoLinked,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) else {
        var fallback = AttributedString(content)
        fallback.font = .system(size: fontSize, weight: baseWeight)
        return fallback
    }

    var codeRanges: [Range<AttributedString.Index>] = []
    for run in result.runs {
        guard let intent = run.inlinePresentationIntent else {
            result[run.range].font = .system(size: fontSize, weight: baseWeight)
            continue
        }
        if intent.contains(.code) {
            codeRanges.append(run.range)
            continue
        }

        let isBold = intent.contains(.stronglyEmphasized)
        let isItalic = intent.contains(.emphasized)
        switch (isBold, isItalic) {
        case (true, true):
            result[run.range].font = .system(size: fontSize, weight: .semibold).italic()
        case (true, false):
            result[run.range].font = .system(size: fontSize, weight: .semibold)
        case (false, true):
            result[run.range].font = .system(size: fontSize, weight: baseWeight).italic()
        default:
            result[run.range].font = .system(size: fontSize, weight: baseWeight)
        }
    }

    for range in codeRanges.reversed() {
        result[range].font = .system(
            size: max(11, fontSize - 1),
            design: .monospaced
        )
        result[range].foregroundColor = ClaudeTheme.textPrimary
        result[range].backgroundColor = ClaudeTheme.surfaceTertiary
        result[range].baselineOffset = 0.5
    }
    return result
}

/// Removes incorrectly included backticks from URLs inside markdown links.
func sanitizeMarkdownLinkURLs(_ text: String) -> String {
    let pattern = #"\[([^\]]*)\]\(([^)]*\x60[^)]*)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    for match in regex.matches(in: text, range: range).reversed() {
        guard let fullRange = Range(match.range, in: result),
              let labelRange = Range(match.range(at: 1), in: result),
              let urlRange = Range(match.range(at: 2), in: result) else {
            continue
        }
        let label = String(result[labelRange])
        let url = String(result[urlRange])
            .replacingOccurrences(of: "\u{0060}", with: "")
        result.replaceSubrange(fullRange, with: "[\(label)](\(url))")
    }
    return result
}

/// Converts bare URLs not already inside a markdown link into link syntax.
func autoLinkURLs(_ text: String) -> String {
    let pattern = #"(?<!\]\()(?<!\()https?://[^\s\)<>\[\]\x60]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    for match in regex.matches(in: text, range: range).reversed() {
        guard let swiftRange = Range(match.range, in: result) else { continue }
        let url = String(result[swiftRange])
        result.replaceSubrange(swiftRange, with: "[\(url)](\(url))")
    }
    return result
}

// MARK: - Table

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { column, header in
                        cellView(text: header, isHeader: true, column: column)
                    }
                }
                .background(ClaudeTheme.surfaceSecondary)

                GridRow {
                    Rectangle()
                        .fill(ClaudeTheme.border)
                        .frame(height: 1)
                        .gridCellColumns(headers.count)
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(headers.indices), id: \.self) { column in
                            cellView(
                                text: column < row.count ? row[column] : "",
                                isHeader: false,
                                column: column
                            )
                        }
                    }
                    .background(
                        rowIndex.isMultiple(of: 2)
                            ? Color.clear
                            : ClaudeTheme.surfacePrimary.opacity(0.5)
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
            )
        }
        .textSelection(.enabled)
    }

    private func cellView(
        text: String,
        isHeader: Bool,
        column: Int
    ) -> some View {
        Text(parseInlineMarkdown(
            text,
            fontSize: ClaudeTheme.messageSize(13),
            baseWeight: isHeader ? .semibold : .regular
        ))
        .foregroundStyle(ClaudeTheme.textPrimary)
        .lineSpacing(MarkdownTypography.bodyLineSpacing)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(
            minWidth: 80,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .leading
        )
        .overlay(alignment: .leading) {
            if column > 0 {
                Rectangle()
                    .fill(ClaudeTheme.borderSubtle)
                    .frame(width: 0.5)
            }
        }
    }
}

// MARK: - Code block

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(
                            size: ClaudeTheme.messageSize(11),
                            weight: .medium,
                            design: .monospaced
                        ))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }

                Spacer()
                copyButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ClaudeTheme.codeHeaderBackground)

            Rectangle()
                .fill(ClaudeTheme.border)
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(
                    code,
                    language: language,
                    fontSize: ClaudeTheme.messageSize(14)
                ))
                .textSelection(.enabled)
                .fixedSize()
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ClaudeTheme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
        )
    }

    private var copyButton: some View {
        Button {
            copyToClipboard(code, feedback: $isCopied)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                Text(isCopied
                     ? String(localized: "Copied", bundle: .module)
                     : String(localized: "Copy", bundle: .module))
                    .font(.caption2)
            }
            .foregroundStyle(
                isCopied ? ClaudeTheme.statusSuccess : ClaudeTheme.textTertiary
            )
        }
        .buttonStyle(.plain)
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var result = self
        while result.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }
}

#Preview("Markdown") {
    ScrollView {
        MarkdownContentView(text: """
        # H1 Heading

        This is a **markdown** paragraph with inline code.

        > A blockquote keeps the same comfortable line height.

        - First list item
        - Second list item

        1. Ordered item
        2. Another ordered item

        Regular text continues here.
        """)
        .padding()
    }
    .frame(width: 500, height: 600)
    .background(ClaudeTheme.background)
}
