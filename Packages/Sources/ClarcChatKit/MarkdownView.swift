import Foundation
import SwiftUI
import ClarcCore

// MARK: - Markdown render repository

/// Process-wide, cost-bounded cache for the expensive, appearance-independent
/// stages of Markdown rendering.
///
/// The repository deliberately does not cache final fonts or colors. Semantic
/// blocks and inline presentation intents survive an appearance change, while
/// typography and theme attributes are reapplied by the views on every render.
/// Together with SyntaxHighlighter's 16 MiB token cache, these limits keep the
/// complete Markdown render pipeline near a 48 MiB upper bound.
nonisolated final class MarkdownRenderRepository: @unchecked Sendable {
    static let shared = MarkdownRenderRepository()

    static let semanticCostLimitBytes = 20 * 1024 * 1024
    static let inlineCostLimitBytes = 12 * 1024 * 1024

    struct Statistics: Sendable, Equatable {
        var semanticHits = 0
        var semanticMisses = 0
        var inlineHits = 0
        var inlineMisses = 0
    }

    private let semanticCache = NSCache<NSString, SemanticEntry>()
    private let inlineCache = NSCache<NSString, InlineEntry>()
    private let statisticsLock = NSLock()
    private var statisticsStorage = Statistics()

    private final class SemanticEntry {
        let blocks: [MarkdownRenderBlock]
        init(_ blocks: [MarkdownRenderBlock]) { self.blocks = blocks }
    }

    private final class InlineEntry {
        let value: AttributedString?
        init(_ value: AttributedString?) { self.value = value }
    }

    private init() {
        semanticCache.countLimit = 400
        semanticCache.totalCostLimit = Self.semanticCostLimitBytes
        inlineCache.countLimit = 2_000
        inlineCache.totalCostLimit = Self.inlineCostLimitBytes
    }

    var statistics: Statistics {
        statisticsLock.lock()
        defer { statisticsLock.unlock() }
        return statisticsStorage
    }

    func cachedBlocks(for text: String) -> [MarkdownRenderBlock]? {
        guard let entry = semanticCache.object(forKey: text as NSString) else {
            record { $0.semanticMisses += 1 }
            return nil
        }
        record { $0.semanticHits += 1 }
        return entry.blocks
    }

    func blocks(for text: String) -> [MarkdownRenderBlock] {
        if let cached = cachedBlocks(for: text) { return cached }
        let blocks = MarkdownDocumentParser.parse(text)
        store(blocks: blocks, for: text)
        prewarmInlineDocuments(in: blocks)
        return blocks
    }

    func blocksAsync(for text: String) async -> [MarkdownRenderBlock] {
        if let cached = cachedBlocks(for: text) { return cached }

        let parsingTask = Task.detached(priority: .userInitiated) { () -> [MarkdownRenderBlock]? in
            guard let parsed = MarkdownDocumentParser.parseCancellable(text),
                  !Task.isCancelled else {
                return nil
            }
            MarkdownRenderRepository.shared.prewarmInlineDocuments(in: parsed)
            return Task.isCancelled ? nil : parsed
        }
        let parsed = await withTaskCancellationHandler {
            await parsingTask.value
        } onCancel: {
            parsingTask.cancel()
        }

        guard let blocks = parsed, !Task.isCancelled else { return [] }
        store(blocks: blocks, for: text)
        return blocks
    }

    func inlineDocument(for content: String) -> AttributedString? {
        if let cached = inlineCache.object(forKey: content as NSString) {
            record { $0.inlineHits += 1 }
            return cached.value
        }

        record { $0.inlineMisses += 1 }
        let normalized = autoLinkURLs(sanitizeMarkdownLinkURLs(content))
        let parsed = try? AttributedString(
            markdown: normalized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        inlineCache.setObject(
            InlineEntry(parsed),
            forKey: content as NSString,
            cost: inlineCost(content: content, parsed: parsed)
        )
        return parsed
    }

    func resetForTesting() {
        semanticCache.removeAllObjects()
        inlineCache.removeAllObjects()
        statisticsLock.lock()
        statisticsStorage = Statistics()
        statisticsLock.unlock()
    }

    private func store(blocks: [MarkdownRenderBlock], for text: String) {
        semanticCache.setObject(
            SemanticEntry(blocks),
            forKey: text as NSString,
            cost: semanticCost(text: text, blocks: blocks)
        )
    }

    private func prewarmInlineDocuments(in blocks: [MarkdownRenderBlock]) {
        for (index, block) in blocks.enumerated() {
            if index.isMultiple(of: 32), Task<Never, Never>.isCancelled { return }
            switch block {
            case .paragraph(let content), .heading(_, let content):
                _ = inlineDocument(for: content)
            case .unorderedList(let items):
                items.forEach { _ = inlineDocument(for: $0) }
            case .orderedList(let items):
                items.forEach { _ = inlineDocument(for: $0.content) }
            case .blockquote(let lines):
                _ = inlineDocument(for: lines.joined(separator: "\n"))
            case .table(let headers, let rows):
                headers.forEach { _ = inlineDocument(for: $0) }
                rows.lazy.joined().forEach { _ = inlineDocument(for: $0) }
            case .codeBlock, .horizontalRule:
                break
            }
        }
    }

    private func semanticCost(text: String, blocks: [MarkdownRenderBlock]) -> Int {
        // NSString keys and block strings both retain the source. Three bytes
        // per UTF-8 byte plus modest block overhead is a conservative estimate.
        max(1, text.utf8.count * 3 + blocks.count * 96)
    }

    private func inlineCost(content: String, parsed: AttributedString?) -> Int {
        let runCount = parsed.map { Array($0.runs).count } ?? 0
        return max(1, content.utf8.count * 4 + runCount * 80)
    }

    private func record(_ update: (inout Statistics) -> Void) {
        statisticsLock.lock()
        update(&statisticsStorage)
        statisticsLock.unlock()
    }
}

// MARK: - Semantic markdown model

nonisolated struct MarkdownOrderedListItem: Equatable, Sendable {
    let number: Int
    let content: String
}

nonisolated enum MarkdownRenderBlock: Equatable, Sendable {
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

nonisolated enum MarkdownDocumentParser {
    static func parse(_ text: String) -> [MarkdownRenderBlock] {
        parse(text, cancellationCheck: { false }) ?? []
    }

    static func parseCancellable(_ text: String) -> [MarkdownRenderBlock]? {
        parse(text, cancellationCheck: { Task<Never, Never>.isCancelled })
    }

    private static func parse(
        _ text: String,
        cancellationCheck: () -> Bool
    ) -> [MarkdownRenderBlock]? {
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
            if index.isMultiple(of: 128), cancellationCheck() { return nil }
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushAll()
                let language = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].hasPrefix("```") {
                    if index.isMultiple(of: 128), cancellationCheck() { return nil }
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
    @State private var cachedBlocks: [MarkdownRenderBlock]?
    @State private var cachedText: String

    init(text: String) {
        self.text = text
        let repository = MarkdownRenderRepository.shared
        let blocks: [MarkdownRenderBlock]?
        if text.utf8.count <= 4_096 {
            // Small messages are cheaper to parse than to schedule and never
            // show a transient raw-Markdown state.
            blocks = repository.blocks(for: text)
        } else {
            // Large responses are parsed and prewarmed off the main actor.
            blocks = repository.cachedBlocks(for: text)
        }
        _cachedBlocks = State(initialValue: blocks)
        _cachedText = State(initialValue: blocks == nil ? "" : text)
    }

    var body: some View {
        Group {
            if cachedText == text, let cachedBlocks {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(cachedBlocks.enumerated()), id: \.offset) { index, block in
                        render(block)
                            .padding(.top, MarkdownTypography.spacingBefore(
                                block,
                                previous: index > 0 ? cachedBlocks[index - 1] : nil
                            ))
                    }
                }
            } else {
                // Keep long uncached content readable while its pure semantic
                // parse runs away from the main actor. The final and fallback
                // paths deliberately share typography to minimize reflow.
                Text(text)
                    .font(.system(size: MarkdownTypography.bodyFontSize))
                    .lineSpacing(MarkdownTypography.bodyLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: text) {
            guard cachedText != text || cachedBlocks == nil else { return }
            let parsed = await MarkdownRenderRepository.shared.blocksAsync(for: text)
            guard !Task.isCancelled else { return }
            cachedBlocks = parsed
            cachedText = text
        }
    }

    @ViewBuilder
    private func render(_ block: MarkdownRenderBlock) -> some View {
        switch block {
        case .paragraph(let content):
            MarkdownTextView(content: content)
        case .heading(let level, let content):
            Text(renderInlineMarkdown(
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
        Text(renderInlineMarkdown(
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
        Text(renderInlineMarkdown(
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

func renderInlineMarkdown(
    _ content: String,
    fontSize: CGFloat,
    baseWeight: Font.Weight = .regular
) -> AttributedString {
    guard var result = MarkdownRenderRepository.shared.inlineDocument(for: content) else {
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

nonisolated private enum MarkdownRegularExpressions {
    static let malformedLink = try? NSRegularExpression(
        pattern: #"\[([^\]]*)\]\(([^)]*\x60[^)]*)\)"#
    )
    static let bareURL = try? NSRegularExpression(
        pattern: #"(?<!\]\()(?<!\()https?://[^\s\)<>\[\]\x60]+"#
    )
}

/// Removes incorrectly included backticks from URLs inside markdown links.
nonisolated func sanitizeMarkdownLinkURLs(_ text: String) -> String {
    guard let regex = MarkdownRegularExpressions.malformedLink else { return text }
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
nonisolated func autoLinkURLs(_ text: String) -> String {
    guard let regex = MarkdownRegularExpressions.bareURL else { return text }
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
        Text(renderInlineMarkdown(
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
    @State private var highlightedCode: HighlightedCode?

    var body: some View {
        let request = HighlightRequest(
            code: code,
            language: language,
            fontSize: ClaudeTheme.messageSize(14)
        )

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
                Group {
                    if let highlightedCode, highlightedCode.request == request {
                        Text(highlightedCode.value)
                    } else {
                        Text(code)
                            .font(.system(
                                size: request.fontSize,
                                weight: .regular,
                                design: .monospaced
                            ))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                    }
                }
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
        .task(id: request) {
            guard let rendered = await SyntaxHighlighter.highlightAsync(
                request.code,
                language: request.language,
                fontSize: request.fontSize
            ), !Task.isCancelled else { return }
            highlightedCode = HighlightedCode(request: request, value: rendered)
        }
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

private struct HighlightRequest: Hashable, Sendable {
    let code: String
    let language: String
    let fontSize: CGFloat
}

private struct HighlightedCode: Sendable {
    let request: HighlightRequest
    let value: AttributedString
}

private extension String {
    nonisolated func trimmingTrailingNewlines() -> String {
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
