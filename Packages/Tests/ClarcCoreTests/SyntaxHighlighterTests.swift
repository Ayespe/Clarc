import AppKit
import Testing
@testable import ClarcCore

@Suite("Syntax highlighter performance", .serialized)
struct SyntaxHighlighterTests {
    @Test("Token cache is shared across SwiftUI and AppKit renderers")
    func cacheHitsAcrossRenderers() {
        SyntaxHighlighter.resetCacheForTesting()
        let code = "let answer: Int = 42 // cached"

        let swiftUI = SyntaxHighlighter.highlight(code, language: "swift", fontSize: 12)
        let afterFirst = SyntaxHighlighter.cacheStatistics
        let appKit = SyntaxHighlighter.highlightNS(code, language: "swift", fontSize: 14)
        let afterSecond = SyntaxHighlighter.cacheStatistics

        #expect(String(swiftUI.characters) == code)
        #expect(appKit.string == code)
        #expect(afterFirst.misses == 1)
        #expect(afterSecond.hits == 1)
    }

    @Test("Font changes reuse tokens but rebuild final attributes")
    func fontSizeInvalidation() throws {
        SyntaxHighlighter.resetCacheForTesting()
        let code = "let value = 1"

        let small = SyntaxHighlighter.highlightNS(code, language: "swift", fontSize: 11)
        let large = SyntaxHighlighter.highlightNS(code, language: "swift", fontSize: 17)
        let smallFont = try #require(small.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let largeFont = try #require(large.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        #expect(smallFont.pointSize == 11)
        #expect(largeFont.pointSize == 17)
        #expect(SyntaxHighlighter.cacheStatistics.misses == 1)
        #expect(SyntaxHighlighter.cacheStatistics.hits == 1)
    }

    @Test("Source and language are part of the token cache key")
    func sourceAndLanguageInvalidation() {
        SyntaxHighlighter.resetCacheForTesting()

        _ = SyntaxHighlighter.highlight("let value = 1", language: "swift")
        _ = SyntaxHighlighter.highlight("let value = 2", language: "swift")
        _ = SyntaxHighlighter.highlight("let value = 2", language: "javascript")

        #expect(SyntaxHighlighter.cacheStatistics.misses == 3)
        #expect(SyntaxHighlighter.cacheStatistics.hits == 0)
    }

    @Test("Normalized aliases share the same cache entry")
    func languageAliasCacheKey() {
        SyntaxHighlighter.resetCacheForTesting()
        let code = "const value = true"

        _ = SyntaxHighlighter.highlight(code, language: "javascript")
        _ = SyntaxHighlighter.highlight(code, language: "js")

        #expect(SyntaxHighlighter.cacheStatistics.misses == 1)
        #expect(SyntaxHighlighter.cacheStatistics.hits == 1)
    }

    @Test("Long Unicode source is scanned without losing content")
    func longUnicodeSource() {
        SyntaxHighlighter.resetCacheForTesting()
        let line = "let greeting = \"你好 👋\" // 保留 Unicode\n"
        let code = String(repeating: line, count: 20_000)

        let highlighted = SyntaxHighlighter.highlight(code, language: "swift")

        #expect(String(highlighted.characters) == code)
        #expect(SyntaxHighlighter.cacheStatistics.misses == 1)
    }

    @Test("Async highlighting cooperates with cancellation")
    func asyncCancellation() async {
        SyntaxHighlighter.resetCacheForTesting()
        let code = String(repeating: "let value = 42 // cancellable\n", count: 50_000)
        let task = Task {
            await SyntaxHighlighter.highlightAsync(code, language: "swift")
        }
        task.cancel()

        let value = await task.value

        #expect(value == nil)
    }

    @Test("Highlighter cache has its assigned share of the render budget")
    func cacheBudget() {
        #expect(SyntaxHighlighter.cacheCostLimitBytes == 16 * 1024 * 1024)
    }
}
