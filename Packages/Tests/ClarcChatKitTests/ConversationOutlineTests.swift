import Foundation
import Testing
@testable import ClarcChatKit
import ClarcCore

@Suite("Conversation outline")
struct ConversationOutlineTests {
    @Test("User message preview flattens whitespace without changing content order")
    func previewFlattensWhitespace() {
        let message = ChatMessage(
            role: .user,
            content: "  第一段\n\n第二段   with English  "
        )

        #expect(ConversationOutlineItem.previewText(for: message) == "第一段 第二段 with English")
    }

    @Test("Attachment-only message uses its first attachment name")
    func attachmentFallback() {
        var message = ChatMessage(role: .user)
        message.attachmentPaths = [
            AttachmentInfo(name: "design.png", path: "/tmp/design.png", type: "image")
        ]

        #expect(ConversationOutlineItem.previewText(for: message) == "design.png")
    }

    @Test("Snapshot assigns stable sequence numbers to every user turn")
    func snapshotSequenceNumbers() {
        let messages = (1...105).map { index in
            ChatMessage(role: .user, content: "Prompt \(index)")
        }

        let first = ConversationSnapshot(messages: messages)
        let rebuilt = ConversationSnapshot(messages: messages)

        #expect(first.rows.map(\.id) == rebuilt.rows.map(\.id))
        #expect(first.outlineItems.map(\.sequence) == Array(1...105))
        #expect(first.outlineItems[0].formattedSequence == "01")
        #expect(first.outlineItems[8].formattedSequence == "09")
        #expect(first.outlineItems[9].formattedSequence == "10")
        #expect(first.outlineItems[104].formattedSequence == "105")
    }

    @Test("Visible assistant rows keep their preceding user turn active")
    func activeTurnFollowsAssistantRows() {
        let firstUser = ChatMessage(role: .user, content: "First")
        let firstAssistant = ChatMessage(role: .assistant, content: "First response")
        let secondUser = ChatMessage(role: .user, content: "Second")
        let secondAssistant = ChatMessage(role: .assistant, content: "Second response")
        let snapshot = ConversationSnapshot(
            messages: [firstUser, firstAssistant, secondUser, secondAssistant]
        )

        #expect(snapshot.activeOutlineMessageID(visibleRowIDs: [firstAssistant.id]) == firstUser.id)
        #expect(snapshot.activeOutlineMessageID(visibleRowIDs: [secondAssistant.id]) == secondUser.id)
        // Input order is deliberately reversed; the snapshot resolves visual row order.
        #expect(
            snapshot.activeOutlineMessageID(visibleRowIDs: [secondUser.id, firstAssistant.id])
                == firstUser.id
        )
    }

    @Test("Consecutive transient tools become one stable lazy-list row")
    func transientRowsAreGrouped() {
        let user = ChatMessage(role: .user, content: "Inspect")
        let firstTool = ChatMessage(
            role: .assistant,
            blocks: [.toolCall(ToolCall(id: "tool-1", name: "Read"))]
        )
        let secondTool = ChatMessage(
            role: .assistant,
            blocks: [.toolCall(ToolCall(id: "tool-2", name: "Bash"))]
        )
        let answer = ChatMessage(role: .assistant, content: "Done")

        let snapshot = ConversationSnapshot(messages: [user, firstTool, secondTool, answer])

        #expect(snapshot.rows.count == 3)
        #expect(snapshot.rows[1].id == firstTool.id)
        if case .transientGroup(_, let messages) = snapshot.rows[1] {
            #expect(messages.map(\.id) == [firstTool.id, secondTool.id])
        } else {
            Issue.record("Expected a grouped transient row")
        }
        #expect(snapshot.activeOutlineMessageID(visibleRowIDs: [firstTool.id]) == user.id)
    }

    @Test("Jump style is distance aware and honors Reduce Motion")
    func jumpStyleResolution() {
        #expect(ConversationJumpKind.resolve(distance: 1, reduceMotion: false) == .nearby)
        #expect(ConversationJumpKind.resolve(distance: 2, reduceMotion: false) == .nearby)
        #expect(ConversationJumpKind.resolve(distance: 3, reduceMotion: false) == .distant)
        #expect(ConversationJumpKind.resolve(distance: nil, reduceMotion: false) == .distant)
        #expect(ConversationJumpKind.resolve(distance: 30, reduceMotion: true) == .immediate)
    }

    @Test("User scrolling away disables output following until returning to bottom")
    func outputFollowingRespectsUserScroll() {
        let coordinator = ConversationScrollCoordinator()

        coordinator.updateScrollPhase(.interacting)
        coordinator.updateNearBottom(false)
        #expect(!coordinator.followsOutput)

        coordinator.streamingDidStart()
        #expect(!coordinator.followsOutput)

        coordinator.updateNearBottom(true)
        #expect(coordinator.followsOutput)
    }

    @Test("Snapshot identity detects settled tail revisions without deep history equality")
    func snapshotIdentityTracksSettledTail() {
        let first = ChatMessage(role: .user, content: "Prompt")
        var response = ChatMessage(role: .assistant, content: "Answer")
        let original = ConversationSnapshotIdentity(messages: [first, response])

        response.appendText(" updated")
        let revised = ConversationSnapshotIdentity(messages: [first, response])

        #expect(original != revised)
        #expect(revised == ConversationSnapshotIdentity(messages: [first, response]))
    }
}
