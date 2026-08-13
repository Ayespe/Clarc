import Testing
@testable import ClarcChatKit

@Suite("Centered chat layout")
@MainActor
struct ChatLayoutTests {
    @Test("Wide windows preserve the exact 730 point composer")
    func wideComposerWidth() {
        #expect(ChatLayout.resolvedWidth(
            availableWidth: 1_200,
            trackWidth: ChatLayout.composerMaxWidth
        ) == 730)
        #expect(ChatLayout.gutter(
            for: 1_200,
            trackWidth: ChatLayout.composerMaxWidth
        ) == 24)
    }

    @Test("Narrow windows keep compact safety gutters")
    func narrowComposerWidth() {
        #expect(ChatLayout.resolvedWidth(
            availableWidth: 700,
            trackWidth: ChatLayout.composerMaxWidth
        ) == 668)
        #expect(ChatLayout.gutter(
            for: 700,
            trackWidth: ChatLayout.composerMaxWidth
        ) == 16)
    }

    @Test("Reading and composer tracks share one axis")
    func sharedTrackWidth() {
        #expect(ChatLayout.readingMaxWidth == ChatLayout.composerMaxWidth)
        #expect(ChatLayout.userBubbleMaxWidth == 540)
        #expect(ChatLayout.semanticMaxWidth == 780)
    }
}
