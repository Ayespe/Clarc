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
}
