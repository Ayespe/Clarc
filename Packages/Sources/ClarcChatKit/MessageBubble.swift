import SwiftUI
import AppKit
import ClarcCore

/// A UI-only run of adjacent, visible thinking content. The original
/// `MessageBlock` values remain untouched so Claude JSONL stays authoritative.
struct ThinkingBlockGroup: Identifiable, Equatable {
    let blocks: [MessageBlock]

    var id: String { blocks.first?.id ?? "thinking-empty" }
}

/// Presentation items retain hard boundaries from the original block stream.
/// In particular, a hidden tool remains a boundary while runs are formed, so
/// thinking is never merged across Tool/Text content merely because that content
/// is filtered out later.
enum MessagePresentationItem: Identifiable, Equatable {
    case block(MessageBlock)
    case thinkingGroup(ThinkingBlockGroup)

    var id: String {
        switch self {
        case .block(let block): block.id
        case .thinkingGroup(let group): group.id
        }
    }
}

enum MessagePresentationBuilder {
    /// Groups only consecutive, ordinary thinking blocks. Text, tools, mixed
    /// blocks, and redacted thinking are all hard boundaries.
    static func groupAdjacentThinking(in blocks: [MessageBlock]) -> [MessagePresentationItem] {
        var result: [MessagePresentationItem] = []
        var thinkingRun: [MessageBlock] = []

        func flushThinkingRun() {
            guard !thinkingRun.isEmpty else { return }
            result.append(.thinkingGroup(ThinkingBlockGroup(blocks: thinkingRun)))
            thinkingRun.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            let isOrdinaryThinking = block.thinking != nil
                && !block.isThinkingRedacted
                && block.text == nil
                && block.toolCall == nil
            if isOrdinaryThinking {
                thinkingRun.append(block)
            } else {
                flushThinkingRun()
                result.append(.block(block))
            }
        }
        flushThinkingRun()
        return result
    }
}

struct MessageBubble: View {
    @Environment(ChatBridge.self) private var chatBridge
    let message: ChatMessage
    @State private var isCopied = false
    @State private var cursorVisible = true
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isEditFocused: Bool
    @State private var hoveredBlockId: String? = nil
    @State private var isHoveringUserBubble = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                // Show attachments
                if !message.attachmentPaths.isEmpty {
                    attachmentPreview
                }

                if message.role == .user {
                    // User message: single text bubble
                    if !message.content.isEmpty {
                        textBubble
                    }
                } else if message.isCompactBoundary {
                    compactBoundaryBubble
                } else if message.isError {
                    // Error message: warning-style bubble
                    errorBubble
                } else {
                    // Assistant message: render blocks in order
                    let hidden = message.isStreaming ? [] : message.blocks.compactMap(\.toolCall).filter { isTransientTool($0) && $0.hasNonEmptyResult }
                    let visibleItems = presentationItems

                    // Hidden tool summary — shown before text (reflects tool execution → text response order)
                    if !hidden.isEmpty {
                        transientToolSummary(hidden: hidden)
                    }

                    ForEach(visibleItems) { item in
                        switch item {
                        case .block(let block):
                            if let text = block.text, !text.isEmpty {
                                assistantTextBubble(text: text, blockId: block.id, hasHiddenTools: !hidden.isEmpty)
                            }
                            if let toolCall = block.toolCall {
                                if toolCall.name == "AskUserQuestion" {
                                    AskUserQuestionView(toolCall: toolCall)
                                } else {
                                    ToolResultView(toolCall: toolCall, isMessageStreaming: message.isStreaming)
                                }
                            }
                            if block.isThinking {
                                thinkingBlock(group: ThinkingBlockGroup(blocks: [block]))
                            }
                        case .thinkingGroup(let group):
                            thinkingBlock(group: group)
                        }
                    }
                }

                // Response complete indicator + elapsed time
                if message.role == .assistant && !message.isStreaming,
                   let duration = message.duration {
                    HStack(spacing: 4) {
                        if message.isResponseComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: ClaudeTheme.messageSize(11)))
                                .foregroundStyle(ClaudeTheme.statusSuccess)
                        }
                        Text(duration.formattedDuration)
                            .font(.system(size: ClaudeTheme.messageSize(11), design: .monospaced))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
            }
            .frame(
                maxWidth: message.role == .assistant
                    ? ChatLayout.readingMaxWidth
                    : ChatLayout.userBubbleMaxWidth,
                alignment: message.role == .user ? .trailing : .leading
            )

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - Compact Boundary Bubble

    private var compactBoundaryBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(message.content)
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .clarcGlassSurface(.message, cornerRadius: ClaudeTheme.cornerRadiusSmall)
    }

    // MARK: - Error Bubble

    private var errorBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: ClaudeTheme.messageSize(13)))
                .foregroundStyle(ClaudeTheme.statusWarning)
            Text(message.content)
                .font(.system(size: ClaudeTheme.messageSize(14)))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .textSelection(.enabled)
        }
        .bubbleStyle(.error)
    }

    // MARK: - User Text Bubble

    @ViewBuilder
    private var textBubble: some View {
        if isEditing {
            VStack(alignment: .trailing, spacing: 8) {
                TextField(String(localized: "Edit message...", bundle: .module), text: $editText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.messageSize(14)))
                    .foregroundStyle(ClaudeTheme.userBubbleText)
                    .focused($isEditFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(ClaudeTheme.userBubble, in: bubbleShape)
                    .overlay(
                        bubbleShape
                            .strokeBorder(ClaudeTheme.accent, lineWidth: 1.5)
                    )
                    .onKeyPress(.return, phases: .down) { keyPress in
                        guard !keyPress.modifiers.contains(.shift) else { return .ignored }
                        submitEdit()
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        isEditing = false
                        return .handled
                    }

                HStack(spacing: 8) {
                    Button(String(localized: "Cancel", bundle: .module)) {
                        isEditing = false
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: ClaudeTheme.messageSize(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)

                    Button(String(localized: "Send", bundle: .module)) {
                        submitEdit()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.accent)
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                Text(message.content)
                    .font(.system(size: ClaudeTheme.messageSize(14)))
                    .foregroundStyle(ClaudeTheme.userBubbleText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .bubbleStyle(.user)
            .overlay(alignment: .bottomTrailing) {
                if isHoveringUserBubble {
                    HStack(spacing: 3) {
                        userActionButton(systemName: isCopied ? "checkmark" : "doc.on.doc") {
                            copyToClipboard(message.content, feedback: $isCopied)
                        }
                        userActionButton(systemName: "pencil") {
                            editText = message.content
                            isEditing = true
                        }
                    }
                    .padding(5)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
            .onHover { isHoveringUserBubble = $0 }
            .onChange(of: isEditing) { _, editing in
                if editing { isEditFocused = true }
            }
        }
    }

    // MARK: - Assistant Text Bubble

    private func assistantTextBubble(text: String, blockId: String, hasHiddenTools: Bool = false) -> some View {
        // Raw-text (un-rendered) streaming + cursor applies ONLY while this text block is
        // the genuinely last block still receiving deltas. The moment any block (a tool
        // such as AskUserQuestion, a thinking block, or another text block) follows it, the
        // text is settled and switches to full markdown — so e.g. a table sitting above an
        // AskUserQuestion prompt renders immediately instead of staying as raw source.
        let isStreamingTail = message.isStreaming && message.blocks.last?.id == blockId

        return HStack(alignment: .bottom, spacing: 0) {
            if isStreamingTail {
                Text(text)
                    .font(.system(size: MarkdownTypography.bodyFontSize))
                    .lineSpacing(MarkdownTypography.bodyLineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownContentView(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isStreamingTail {
                Text("|")
                    .font(.system(size: MarkdownTypography.bodyFontSize, weight: .light))
                    .foregroundStyle(ClaudeTheme.accent)
                    .opacity(cursorVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: cursorVisible)
                    .onAppear { cursorVisible = false }
            }
        }
        .foregroundStyle(ClaudeTheme.textPrimary)
        .bubbleStyle(.assistant)
        .overlay(alignment: .bottomTrailing) {
            if hoveredBlockId == blockId && !message.isStreaming {
                HStack(spacing: 4) {
                    copyButton(for: text)
                    forkButton()
                }
                .padding(6)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .onHover { hoveredBlockId = $0 ? blockId : nil }
        .onTapGesture {
            if hasHiddenTools {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTransientTools.toggle()
                }
            }
        }
        .accessibilityLabel("Assistant: \(text)")
    }

    @ViewBuilder
    private func thinkingBlock(group: ThinkingBlockGroup) -> some View {
        ThinkingBlockView(
            group: group,
            isMessageStreaming: message.isStreaming,
            autoExpandWhileStreaming: chatBridge.autoExpandThinking,
            disclosureOverride: Binding(
                get: { chatBridge.thinkingDisclosureOverrides[group.id] },
                set: { newValue in
                    if let newValue {
                        chatBridge.thinkingDisclosureOverrides[group.id] = newValue
                    } else {
                        chatBridge.thinkingDisclosureOverrides.removeValue(forKey: group.id)
                    }
                }
            )
        )
    }

    // MARK: - Copy Button

    @ViewBuilder
    private func copyButton(for text: String) -> some View {
        Button {
            copyToClipboard(text, feedback: $isCopied)
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func forkButton() -> some View {
        Button {
            Task { await chatBridge.forkFromHere(messageId: message.id) }
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(String(localized: "Fork from here", bundle: .module))
    }

    @ViewBuilder
    private func userActionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .opacity(0.8)
    }

    // MARK: - Transient Tool Helpers

    /// Read, Grep, Glob, Bash etc. are collapsed into a summary after streaming completes
    private func isTransientTool(_ toolCall: ToolCall) -> Bool {
        let cat = ToolCategory(toolName: toolCall.name)
        return cat == .readOnly || cat == .execution
    }

    /// Presentation items are built from the original block order before hidden
    /// tools are removed. This preserves Tool/Text as hard thinking boundaries,
    /// while still retaining Clarc's existing behavior of joining text made
    /// visually contiguous by a hidden transient tool.
    private var presentationItems: [MessagePresentationItem] {
        let grouped = MessagePresentationBuilder.groupAdjacentThinking(in: message.blocks)
        let visible = grouped.filter { item in
            switch item {
            case .thinkingGroup:
                return true
            case .block(let block):
                return isRenderable(block)
            }
        }
        return Self.mergeAdjacentTextItems(in: visible)
    }

    private func isRenderable(_ block: MessageBlock) -> Bool {
        if let text = block.text { return !text.isEmpty }
        if let toolCall = block.toolCall {
            if message.isStreaming { return true }
            if isTransientTool(toolCall) { return false }
            if toolCall.isKeepAlways { return true }
            return toolCall.result != nil || toolCall.isError
        }
        return block.isThinking
    }

    /// Join rule matches the previous implementation: preserve explicit
    /// whitespace and add one space only when neither side supplies it.
    private static func mergeAdjacentTextItems(in items: [MessagePresentationItem]) -> [MessagePresentationItem] {
        var result: [MessagePresentationItem] = []
        for item in items {
            if case .block(let block) = item,
               block.isText,
               let lastIndex = result.indices.last,
               case .block(let previousBlock) = result[lastIndex],
               previousBlock.isText {
                let previous = previousBlock.text ?? ""
                let current = block.text ?? ""
                let needsSpace = !(previous.last?.isWhitespace ?? true)
                    && !(current.first?.isWhitespace ?? true)
                let joined = needsSpace ? previous + " " + current : previous + current
                result[lastIndex] = .block(.text(joined, id: previousBlock.id))
            } else {
                result.append(item)
            }
        }
        return result
    }

    @State private var showTransientTools = false

    private func transientToolSummary(hidden: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTransientTools.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: ClaudeTheme.messageSize(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text(String(format: String(localized: "%lld tools executed", bundle: .module), hidden.count))
                        .font(.system(size: ClaudeTheme.messageSize(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Image(systemName: showTransientTools ? "chevron.up" : "chevron.down")
                        .font(.system(size: ClaudeTheme.messageSize(9)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTransientTools {
                ForEach(hidden, id: \.id) { toolCall in
                    ToolResultView(toolCall: toolCall, isMessageStreaming: false)
                }
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if message.role == .user {
            return UnevenRoundedRectangle(
                topLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomTrailingRadius: 4,
                topTrailingRadius: ClaudeTheme.cornerRadiusLarge
            )
        } else {
            return UnevenRoundedRectangle(
                topLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: ClaudeTheme.cornerRadiusLarge,
                topTrailingRadius: ClaudeTheme.cornerRadiusLarge
            )
        }
    }

    private func submitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isEditing = false
        Task { await chatBridge.editAndResend(messageId: message.id, newContent: trimmed) }
    }

    // MARK: - Attachment Preview

    private var attachmentPreview: some View {
        HStack(spacing: 6) {
            ForEach(message.attachmentPaths, id: \.path) { info in
                HStack(spacing: 4) {
                    if info.isImage {
                        AsyncAttachmentThumbnail(path: info.path)
                    } else {
                        Image(systemName: info.isImage ? "photo" : "doc")
                            .font(.system(size: ClaudeTheme.messageSize(14)))
                            .foregroundStyle(ClaudeTheme.accent)
                    }
                    Text(info.name)
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                }
                .padding(6)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            }
        }
    }

    /// Converts bare URLs to clickable links (without full markdown rendering)
    private func linkifiedAttributedString(_ text: String) -> AttributedString {
        let autoLinked = autoLinkURLs(text)
        return (try? AttributedString(
            markdown: autoLinked,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
