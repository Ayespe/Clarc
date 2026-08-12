import Testing
@testable import ClarcChatKit

@Suite("Markdown document typography")
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
        #expect(MarkdownTypography.bodyLineSpacing == 4)
        #expect(MarkdownTypography.listItemSpacing == 4)
        #expect(MarkdownTypography.paragraphSpacing == 10)
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
}
