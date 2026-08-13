import SwiftUI
import Combine
import ClarcCore

/// Message scroll area — extracted from ChatView to isolate @Observable dependencies on `messages`.
struct MessageListView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot = ConversationSnapshot.empty
    @State private var scrollCoordinator = ConversationScrollCoordinator()
    @State private var isSessionReady = false

    private static let bottomAnchorID = "conversation-bottom-anchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(snapshot.rows) { row in
                        CenteredChatTrack {
                            messageRow(row)
                        }
                        .id(row.id)
                    }
                }
                .padding(.top, 16)
                .scrollTargetLayout()
                .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.12) { visibleRowIDs in
                    scrollCoordinator.updateVisibleRows(visibleRowIDs, in: snapshot)
                }

                // Streaming view is outside VStack — text deltas don't affect settled layout
                CenteredChatTrack {
                    VStack(spacing: 16) {
                        if !windowState.focusMode {
                            StreamingMessageView {
                                // The active assistant tail is deliberately outside the
                                // settled snapshot, so a new streaming block only changes
                                // its isolated view and never rescans conversation history.
                                scrollToBottomDebounced(using: proxy)
                            }
                        }

                        if chatBridge.isStreaming {
                            HStack(alignment: .top, spacing: 0) {
                                StreamingIndicatorView(
                                    isThinking: chatBridge.isThinking,
                                    startDate: chatBridge.streamingStartDate
                                )
                                Spacer(minLength: 40)
                            }
                        }

                        if !chatBridge.isStreaming && !snapshot.messages.isEmpty {
                            WebPreviewButton(messages: snapshot.messages)
                                .id("web-preview")
                        }
                    }
                    // Suppress layout animations when switching sessions so the pulse indicator
                    // doesn't visually jump as StreamingMessageView changes height.
                    .animation(.none, value: windowState.currentSessionId)
                }

                Color.clear.frame(height: 1)
                    .padding(.bottom, 16)
                    .id(Self.bottomAnchorID)
            }
            .opacity(isSessionReady ? 1 : 0)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geo in
                let distanceFromBottom = geo.contentSize.height - geo.visibleRect.maxY
                return distanceFromBottom < 120
            } action: { _, nearBottom in
                scrollCoordinator.updateNearBottom(nearBottom)
            }
            .onScrollPhaseChange { _, newPhase in
                scrollCoordinator.updateScrollPhase(newPhase)
            }
            .task(id: windowState.currentSessionId) {
                isSessionReady = false
                scrollCoordinator.reset()
                rebuildSnapshot()
                // Skip scroll/fade delay for empty sessions — appear instantly
                guard !snapshot.messages.isEmpty else {
                    isSessionReady = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))  // 1 frame: scroll after VStack layout is committed
                guard !Task.isCancelled else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                // Pre-set isNearBottom so streaming messages that arrive before onScrollGeometryChange
                // fires still trigger scrollToBottomDebounced(), keeping the pulse pinned to the bottom.
                scrollCoordinator.updateNearBottom(true)
                try? await Task.sleep(for: .milliseconds(32))  // 2 frames: fade-in after scroll settles
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.15)) { isSessionReady = true }
            }
            .onChange(of: chatBridge.isStreaming) { old, new in
                if !old && new {
                    scrollCoordinator.streamingDidStart()
                }
                // Only rebuild when streaming ends — settled list doesn't change at start.
                if old && !new {
                    rebuildSnapshot()
                    scrollToBottomDebounced(using: proxy)
                }
            }
            .overlay {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(scrollCoordinator.navigationVeilOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                if !snapshot.outlineItems.isEmpty {
                    GeometryReader { geometry in
                        let resolvedTrackWidth = ChatLayout.resolvedWidth(
                            availableWidth: geometry.size.width,
                            trackWidth: ChatLayout.readingMaxWidth
                        )
                        let contentLeading = (geometry.size.width - resolvedTrackWidth) / 2
                        let railLeading = max(8, contentLeading - 36)

                        ConversationOutlineRail(
                            items: snapshot.outlineItems,
                            activeMessageID: scrollCoordinator.activeOutlineMessageID,
                            targetMessageID: scrollCoordinator.targetOutlineMessageID,
                            availableHeight: max(220, geometry.size.height - 48),
                            onSelect: { messageID in
                                jumpToMessage(messageID, using: proxy)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .offset(x: railLeading)
                    }
                }
            }
            .overlay {
                if snapshot.messages.isEmpty && !chatBridge.isStreaming && windowState.currentSessionId == nil {
                    EmptySessionView()
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func messageRow(_ row: ConversationRow) -> some View {
        Group {
            switch row {
            case .message(let message):
                MessageBubble(message: message)
            case .transientGroup(_, let messages):
                TransientGroupSummaryView(messages: messages)
            }
        }
        .background {
            if scrollCoordinator.highlightedMessageID == row.id {
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                    .fill(ClaudeTheme.accent.opacity(0.08))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -6)
            }
        }
    }

    // MARK: - Message Grouping

    // MARK: - Settled Items

    private func rebuildSnapshot() {
        let messages = settledOnlyMessages(from: chatBridge.messages)
        let identity = ConversationSnapshotIdentity(messages: messages)
        guard identity != snapshot.identity else { return }
        let updatedSnapshot = ConversationSnapshot(messages: messages)
        var t = Transaction()
        t.animation = nil
        withTransaction(t) { snapshot = updatedSnapshot }
    }

    /// If streaming, returns only completed messages excluding the last consecutive (non-error) assistant sequence.
    /// If not streaming, returns all messages without the streaming flag.
    /// In focus mode, further filters to only user messages and completed assistant responses.
    private func settledOnlyMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        var settled: [ChatMessage]
        if messages.last?.isStreaming == true {
            let boundary = streamingBoundaryIndex(in: messages)
            settled = Array(messages[..<boundary]).filter { !$0.isStreaming }
        } else {
            settled = messages.filter { !$0.isStreaming }
        }
        if windowState.focusMode {
            settled = settled.filter { $0.role == .user || $0.isResponseComplete || $0.isCompactBoundary }
        }
        return settled
    }

    private func scrollToBottomDebounced(using proxy: ScrollViewProxy) {
        scrollCoordinator.requestBottomScroll {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private func jumpToMessage(_ messageId: UUID, using proxy: ScrollViewProxy) {
        scrollCoordinator.jump(
            to: messageId,
            in: snapshot,
            reduceMotion: reduceMotion
        ) { targetID in
            proxy.scrollTo(targetID, anchor: .top)
        }
    }
}

private struct ConversationOutlineRail: View {
    let items: [ConversationOutlineItem]
    let activeMessageID: UUID?
    let targetMessageID: UUID?
    let availableHeight: CGFloat
    let onSelect: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            rail
                .onHover { hovering in
                    guard hovering else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        isHovered = true
                    }
                }
            if isHovered {
                outlinePanel
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(maxHeight: availableHeight, alignment: .center)
        .onHover { hovering in
            guard !hovering else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                isHovered = false
            }
        }
        .zIndex(20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Conversation outline", bundle: .module))
    }

    private var rail: some View {
        Canvas { context, size in
            guard !items.isEmpty else { return }

            let step = size.height / CGFloat(items.count)
            let tickHeight = min(2, max(0.75, step * 0.42))

            for (index, item) in items.enumerated() {
                let isTarget = item.id == targetMessageID
                let isActive = item.id == activeMessageID
                let color: Color
                if isTarget {
                    color = ClaudeTheme.accent
                } else if isActive {
                    color = ClaudeTheme.accent.opacity(0.78)
                } else {
                    color = ClaudeTheme.textTertiary.opacity(0.48)
                }

                let y = min(size.height - tickHeight, CGFloat(index) * step + (step - tickHeight) / 2)
                let rect = CGRect(
                    x: 0,
                    y: max(0, y),
                    width: railWidth(at: index),
                    height: tickHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: tickHeight / 2),
                    with: .color(color)
                )
            }
        }
        .frame(width: 28, alignment: .leading)
        .frame(height: railHeight)
        .contentShape(Rectangle())
    }

    private var outlinePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversation outline", bundle: .module)
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(item.formattedSequence)
                                    .font(.system(size: ClaudeTheme.size(11), weight: .medium, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(sequenceColor(for: item))
                                    .frame(minWidth: 22, alignment: .trailing)

                                Text(item.preview)
                                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                                    .foregroundStyle(labelColor(for: item))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background {
                                if item.id == targetMessageID || item.id == activeMessageID {
                                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                                        .fill(ClaudeTheme.accent.opacity(item.id == targetMessageID ? 0.13 : 0.08))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.sequence). \(item.preview)")
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: availableHeight)
        .clarcGlassSurface(.popover, cornerRadius: ClaudeTheme.cornerRadiusMedium)
    }

    private var railHeight: CGFloat {
        min(360, max(24, CGFloat(items.count) * 7))
    }

    private func labelColor(for item: ConversationOutlineItem) -> Color {
        item.id == targetMessageID || item.id == activeMessageID
            ? ClaudeTheme.textPrimary
            : ClaudeTheme.textSecondary
    }

    private func sequenceColor(for item: ConversationOutlineItem) -> Color {
        item.id == targetMessageID || item.id == activeMessageID
            ? ClaudeTheme.accent
            : ClaudeTheme.textTertiary
    }

    private func railWidth(at index: Int) -> CGFloat {
        switch index % 4 {
        case 0: 20
        case 1: 12
        case 2: 17
        default: 9
        }
    }
}

// MARK: - Message Grouping Helpers

/// Single-pass partition of messages into (settled, streaming) without scanning the array twice.
fileprivate func partitionByStreaming(_ messages: [ChatMessage]) -> (settled: [ChatMessage], streaming: [ChatMessage]) {
    var settled: [ChatMessage] = []
    var streaming: [ChatMessage] = []
    for m in messages { if m.isStreaming { streaming.append(m) } else { settled.append(m) } }
    return (settled, streaming)
}

// MARK: - Shared Helper

/// Returns the start index of the last consecutive non-error assistant sequence.
/// Used to distinguish the settled (previous) / active (streaming) boundary.
private func streamingBoundaryIndex(in messages: [ChatMessage]) -> Int {
    var idx = messages.count - 1
    while idx >= 0 && messages[idx].role == .assistant && !messages[idx].isError {
        idx -= 1
    }
    return idx + 1
}

// MARK: - Streaming Message (isolated view — chatBridge.messages dependency confined to this view)

struct StreamingMessageView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(WindowState.self) private var windowState
    var onStructureChanged: () -> Void

    var body: some View {
        let messages = chatBridge.messages
        let activeMessages = activeResponseMessages(from: messages)
        let (settledActive, streamingActive) = partitionByStreaming(activeMessages)
        Group {
            if !activeMessages.isEmpty {

                if !streamingActive.isEmpty {
                    // Collapse completed transient tool calls (even a single one) the moment
                    // the next streaming message begins, so only the current message stays visible.
                    let groups = groupMessages(settledActive, minGroupSize: 1)
                    ForEach(groups) { group in
                        if group.isTransientGroup {
                            TransientGroupSummaryView(messages: group.messages)
                                .id(group.id)
                        } else if let message = group.messages.first {
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                } else {
                    // Nothing streaming yet — show each settled message individually.
                    ForEach(settledActive, id: \.id) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }

                ForEach(streamingActive, id: \.id) { message in
                    MessageBubble(message: message)
                        .id(message.id)
                }
            }
        }
        .onChange(of: messages.count) { _, _ in
            onStructureChanged()
        }
    }

    /// Returns the last consecutive assistant sequence (including streaming turn) while streaming.
    /// Returns an empty array when not streaming so StreamingMessageView renders nothing.
    private func activeResponseMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.last?.isStreaming == true else { return [] }
        return Array(messages[streamingBoundaryIndex(in: messages)...])
    }
}

// MARK: - Transient Group Summary

struct TransientGroupSummaryView: View {
    let messages: [ChatMessage]
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allToolCalls: [ToolCall] {
        messages.flatMap { $0.blocks.compactMap(\.toolCall) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Text(String(format: String(localized: "%lld tools executed", bundle: .module), allToolCalls.count))
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.size(9)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(allToolCalls, id: \.id) { toolCall in
                        ToolResultView(toolCall: toolCall, isMessageStreaming: false)
                    }
                }
            }
            Spacer(minLength: 40)
        }
    }
}

// MARK: - Empty Session

struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: ClaudeTheme.size(36)))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Text("How can I help you?", bundle: .module)
                .font(.system(size: ClaudeTheme.size(18), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Streaming Indicator

struct StreamingIndicatorView: View {
    let isThinking: Bool
    var startDate: Date?

    var body: some View {
        HStack(spacing: 8) {
            PulseRingView()
                .id("pulse")

            Group {
                if isThinking {
                    Text("Thinking...", bundle: .module)
                } else {
                    Text("Generating response...", bundle: .module)
                }
            }
            .font(.system(size: ClaudeTheme.size(13)))
            .foregroundStyle(ClaudeTheme.textSecondary)

            Spacer()

            if let startDate {
                ElapsedTimeView(startDate: startDate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
    }
}

// MARK: - Elapsed Time

struct ElapsedTimeView: View {
    let startDate: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(elapsed.formattedDuration)
            .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .onAppear {
                elapsed = Date().timeIntervalSince(startDate)
            }
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startDate)
            }
    }
}
