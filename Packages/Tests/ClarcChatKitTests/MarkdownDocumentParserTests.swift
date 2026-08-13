import Testing
@testable import ClarcChatKit

@Suite("Markdown document typography", .serialized)
@MainActor
struct MarkdownDocumentParserTests {
    @Test("Paragraphs retain Chinese, English, and mixed content")
    func paragraphs() {
        let blocks = MarkdownDocumentParser.parse("""
        第一段中文，包含较长的正文内容。
        同一段的第二行 mixed with English.

        Second paragraph with **bold** and `code`.
        """)

        #expect(blocks == [
            .paragraph("第一段中文，包含较长的正文内容。\n同一段的第二行 mixed with English."),
            .paragraph("Second paragraph with **bold** and `code`."),
        ])
    }

    @Test("Lists are semantic groups with original order")
    func lists() {
        let blocks = MarkdownDocumentParser.parse("""
        Intro

        - One
        - 二

        3. Third
        4. Fourth
        """)

        #expect(blocks == [
            .paragraph("Intro"),
            .unorderedList(["One", "二"]),
            .orderedList([
                .init(number: 3, content: "Third"),
                .init(number: 4, content: "Fourth"),
            ]),
        ])
    }

    @Test("Headings, quotes, code, tables, and rules remain distinct")
    func blockTypes() {
        let fence = String(repeating: "`", count: 3)
        let source = """
        ## Heading

        > Quote one
        > 引用二

        \(fence)swift
        let value = 1
        \(fence)

        | Name | Value |
        |------|-------|
        | A | 1 |

        ---
        """
        let blocks = MarkdownDocumentParser.parse(source)

        #expect(blocks == [
            .heading(level: 2, content: "Heading"),
            .blockquote(["Quote one", "引用二"]),
            .codeBlock(language: "swift", code: "let value = 1"),
            .table(headers: ["Name", "Value"], rows: [["A", "1"]]),
            .horizontalRule,
        ])
    }

    @Test("Body, list, and quote use the streaming line spacing")
    func typographyMetrics() {
        #expect(MarkdownTypography.bodyLineSpacing == 3)
        #expect(MarkdownTypography.listItemSpacing == 5)
        #expect(MarkdownTypography.paragraphSpacing == 11)
        #expect(MarkdownTypography.headingAfterSpacing == 6)
        #expect(MarkdownTypography.spacingBefore(
            .paragraph("body"),
            previous: .heading(level: 2, content: "title")
        ) == 6)
    }

    @Test("Existing URL sanitizing behavior is retained")
    func urlHelpers() {
        let tick = "`"
        let broken = "[link](https://example.com/\(tick)path\(tick))"
        #expect(sanitizeMarkdownLinkURLs(broken) == "[link](https://example.com/path)")
        #expect(autoLinkURLs("See https://example.com now")
            == "See [https://example.com](https://example.com) now")
    }

    @Test("Semantic and inline caches reuse appearance-independent work")
    func renderRepositoryHits() {
        let repository = MarkdownRenderRepository.shared
        repository.resetForTesting()
        let source = "A **bold** paragraph with `inline code`."

        let first = repository.blocks(for: source)
        let afterFirst = repository.statistics
        let second = repository.blocks(for: source)
        let afterSecond = repository.statistics

        #expect(first == second)
        #expect(afterFirst.semanticMisses == 1)
        #expect(afterSecond.semanticHits == 1)
        // The first semantic parse prewarms inline Markdown. Rendering with a
        // different font size reuses semantics, not final style attributes.
        let small = renderInlineMarkdown(source, fontSize: 12)
        let beforeLarge = repository.statistics
        let large = renderInlineMarkdown(source, fontSize: 17)
        let afterLarge = repository.statistics
        #expect(small != large)
        #expect(afterLarge.inlineHits == beforeLarge.inlineHits + 1)
    }

    @Test("Changed source invalidates semantic and inline cache keys")
    func renderRepositoryInvalidation() {
        let repository = MarkdownRenderRepository.shared
        repository.resetForTesting()

        _ = repository.blocks(for: "First **version**")
        let firstStatistics = repository.statistics
        _ = repository.blocks(for: "Second **version**")
        let secondStatistics = repository.statistics

        #expect(firstStatistics.semanticMisses == 1)
        #expect(secondStatistics.semanticMisses == 2)
        #expect(secondStatistics.inlineMisses == firstStatistics.inlineMisses + 1)
    }

    @Test("Large documents parse off actor without changing semantics")
    func backgroundDocumentParsing() async {
        let repository = MarkdownRenderRepository.shared
        repository.resetForTesting()
        let source = (0..<2_000)
            .map { "- item \($0) with **emphasis** and `code`" }
            .joined(separator: "\n")

        let blocks = await repository.blocksAsync(for: source)
        let cached = repository.blocks(for: source)

        #expect(blocks == cached)
        #expect(blocks.count == 1)
        guard case .unorderedList(let items) = blocks.first else {
            Issue.record("Expected one semantic unordered-list block")
            return
        }
        #expect(items.count == 2_000)
        #expect(repository.statistics.semanticHits == 1)
    }

    @Test("Markdown repository stays inside its assigned cache budget")
    func renderRepositoryBudget() {
        #expect(MarkdownRenderRepository.semanticCostLimitBytes == 20 * 1024 * 1024)
        #expect(MarkdownRenderRepository.inlineCostLimitBytes == 12 * 1024 * 1024)
    }
}
