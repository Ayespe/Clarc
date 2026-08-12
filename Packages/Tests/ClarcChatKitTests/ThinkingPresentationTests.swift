import Testing
import ClarcCore
@testable import ClarcChatKit

@Suite("Thinking presentation")
@MainActor
struct ThinkingPresentationTests {
    @Test("Adjacent ordinary thinking blocks form one stable group")
    func adjacentThinkingGroups() {
        let first = MessageBlock.thinking("A", duration: 1, id: "think-a")
        let second = MessageBlock.thinking("B", duration: 2, id: "think-b")
        let text = MessageBlock.text("Answer", id: "text")

        let result = MessagePresentationBuilder.groupAdjacentThinking(
            in: [first, second, text]
        )

        #expect(result.count == 2)
        guard case .thinkingGroup(let group) = result[0] else {
            Issue.record("First item should be a thinking group")
            return
        }
        #expect(group.id == "think-a")
        #expect(group.blocks == [first, second])
        #expect(result[1] == .block(text))
    }

    @Test("Appending a segment preserves the group identity")
    func appendedSegmentKeepsIdentity() {
        let first = MessageBlock.thinking("A", id: "stable")
        let initial = MessagePresentationBuilder.groupAdjacentThinking(in: [first])
        let updated = MessagePresentationBuilder.groupAdjacentThinking(
            in: [first, .thinking("B", id: "new")]
        )

        #expect(initial.first?.id == "stable")
        #expect(updated.first?.id == "stable")
    }

    @Test("Text and tools are hard thinking boundaries")
    func contentBoundaries() {
        let first = MessageBlock.thinking("A", id: "a")
        let text = MessageBlock.text("middle", id: "text")
        let hiddenTool = MessageBlock.toolCall(
            ToolCall(id: "tool", name: "Read", result: "done")
        )
        let second = MessageBlock.thinking("B", id: "b")

        let textBoundary = MessagePresentationBuilder.groupAdjacentThinking(
            in: [first, text, second]
        )
        let toolBoundary = MessagePresentationBuilder.groupAdjacentThinking(
            in: [first, hiddenTool, second]
        )

        #expect(textBoundary.count == 3)
        #expect(toolBoundary.count == 3)
        guard case .thinkingGroup(let afterTool) = toolBoundary[2] else {
            Issue.record("Thinking after a hidden tool must start a new group")
            return
        }
        #expect(afterTool.blocks.map(\.thinking) == ["B"])
    }

    @Test("Redacted thinking is preserved and breaks ordinary groups")
    func redactedBoundary() {
        let redacted = MessageBlock.redactedThinking(id: "redacted")
        let result = MessagePresentationBuilder.groupAdjacentThinking(in: [
            .thinking("A", id: "a"),
            redacted,
            .thinking("B", id: "b"),
        ])

        #expect(result.count == 3)
        #expect(result[1] == .block(redacted))
    }

    @Test("Auto expansion is opt-in and manual choices always win")
    func disclosurePolicy() {
        #expect(!ThinkingDisclosurePolicy.isExpanded(
            override: nil,
            autoExpandWhileStreaming: false,
            isStreaming: true
        ))
        #expect(ThinkingDisclosurePolicy.isExpanded(
            override: nil,
            autoExpandWhileStreaming: true,
            isStreaming: true
        ))
        #expect(!ThinkingDisclosurePolicy.isExpanded(
            override: false,
            autoExpandWhileStreaming: true,
            isStreaming: true
        ))
        #expect(ThinkingDisclosurePolicy.isExpanded(
            override: true,
            autoExpandWhileStreaming: false,
            isStreaming: false
        ))
        #expect(!ThinkingDisclosurePolicy.isExpanded(
            override: nil,
            autoExpandWhileStreaming: true,
            isStreaming: false
        ))
    }

    @Test("Chat bridge defaults to collapsed thinking")
    func bridgeDefault() {
        let bridge = ChatBridge()
        #expect(!bridge.autoExpandThinking)
        #expect(bridge.thinkingDisclosureOverrides.isEmpty)
    }
}
