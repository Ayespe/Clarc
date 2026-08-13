import Foundation
import Observation
import SwiftUI
import ClarcCore

/// Immutable presentation data for the settled portion of a conversation.
///
/// Building this once when the message structure changes keeps grouping,
/// outline previews and row-to-turn ownership out of the scroll hot path.
struct ConversationSnapshot {
    static let empty = ConversationSnapshot(messages: [])

    let identity: ConversationSnapshotIdentity
    let messages: [ChatMessage]
    let rows: [ConversationRow]
    let outlineItems: [ConversationOutlineItem]

    private let rowOrder: [UUID: Int]
    private let outlineOrder: [UUID: Int]
    private let rowOwner: [UUID: UUID]

    init(messages: [ChatMessage]) {
        identity = ConversationSnapshotIdentity(messages: messages)
        self.messages = messages

        let groups = groupMessages(messages)
        rows = groups.map(ConversationRow.init(group:))

        var nextOutlineItems: [ConversationOutlineItem] = []
        var nextRowOwner: [UUID: UUID] = [:]
        var currentUserMessageID: UUID?

        for row in rows {
            if let userMessage = row.messages.first(where: { $0.role == .user }) {
                currentUserMessageID = userMessage.id
                nextOutlineItems.append(
                    ConversationOutlineItem(
                        message: userMessage,
                        sequence: nextOutlineItems.count + 1
                    )
                )
            }
            if let currentUserMessageID {
                nextRowOwner[row.id] = currentUserMessageID
            }
        }

        outlineItems = nextOutlineItems
        rowOwner = nextRowOwner
        rowOrder = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        outlineOrder = Dictionary(
            uniqueKeysWithValues: nextOutlineItems.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    /// Resolves the turn represented by the top-most visible settled row.
    /// Assistant and transient rows inherit ownership from their preceding user
    /// message so the outline remains selected throughout the full turn.
    func activeOutlineMessageID(visibleRowIDs: [UUID]) -> UUID? {
        visibleRowIDs
            .compactMap { id -> (row: Int, owner: UUID)? in
                guard let order = rowOrder[id], let owner = rowOwner[id] else { return nil }
                return (order, owner)
            }
            .min(by: { $0.row < $1.row })?
            .owner
    }

    func outlineDistance(from sourceID: UUID?, to destinationID: UUID) -> Int? {
        guard let sourceID,
              let source = outlineOrder[sourceID],
              let destination = outlineOrder[destinationID] else { return nil }
        return abs(destination - source)
    }
}

/// Constant-size equality key for deciding whether the settled presentation
/// changed. Stream deltas belong to the isolated streaming tail and therefore
/// do not compare every historical block on each callback.
struct ConversationSnapshotIdentity: Equatable {
    let count: Int
    let lastMessageID: UUID?
    let lastBlockCount: Int
    let tailRevision: Int
    let lastMessageIsComplete: Bool

    init(messages: [ChatMessage]) {
        count = messages.count
        lastMessageID = messages.last?.id
        lastBlockCount = messages.last?.blocks.count ?? 0
        lastMessageIsComplete = messages.last?.isResponseComplete ?? false

        var hasher = Hasher()
        if let tail = messages.last {
            hasher.combine(tail.id)
            hasher.combine(tail.role.rawValue)
            hasher.combine(tail.isError)
            hasher.combine(tail.isCompactBoundary)
            hasher.combine(tail.attachmentPaths.count)
            for block in tail.blocks {
                hasher.combine(block.id)
                hasher.combine(block.text)
                hasher.combine(block.thinking)
                hasher.combine(block.isThinkingRedacted)
                hasher.combine(block.toolCall?.id)
                hasher.combine(block.toolCall?.name)
                hasher.combine(block.toolCall?.result)
                hasher.combine(block.toolCall?.isError)
            }
        }
        tailRevision = hasher.finalize()
    }
}

enum ConversationRow: Identifiable {
    case message(ChatMessage)
    case transientGroup(id: UUID, messages: [ChatMessage])

    init(group: MessageGroup) {
        if group.isTransientGroup {
            self = .transientGroup(id: group.id, messages: group.messages)
        } else if let message = group.messages.first {
            self = .message(message)
        } else {
            preconditionFailure("A message group must contain at least one message")
        }
    }

    var id: UUID {
        switch self {
        case .message(let message): message.id
        case .transientGroup(let id, _): id
        }
    }

    var messages: [ChatMessage] {
        switch self {
        case .message(let message): [message]
        case .transientGroup(_, let messages): messages
        }
    }
}

struct ConversationOutlineItem: Identifiable, Equatable {
    let id: UUID
    let sequence: Int
    let preview: String
    let timestamp: Date

    var formattedSequence: String {
        String(format: "%02d", sequence)
    }

    init(message: ChatMessage, sequence: Int = 1) {
        id = message.id
        self.sequence = sequence
        timestamp = message.timestamp
        preview = Self.previewText(for: message)
    }

    static func previewText(for message: ChatMessage) -> String {
        let normalized = message.content
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty { return normalized }
        if let attachment = message.attachmentPaths.first { return attachment.name }
        return String(localized: "Attachment", bundle: .module)
    }
}

enum ConversationJumpKind: Equatable {
    case immediate
    case nearby
    case distant

    static func resolve(distance: Int?, reduceMotion: Bool) -> Self {
        if reduceMotion { return .immediate }
        guard let distance, distance <= 2 else { return .distant }
        return .nearby
    }
}

/// Owns every programmatic scroll decision for the conversation. The view only
/// supplies the `ScrollViewProxy` operation, preventing independent scroll
/// bindings and animations from competing with one another.
@MainActor
@Observable
final class ConversationScrollCoordinator {
    private(set) var activeOutlineMessageID: UUID?
    private(set) var targetOutlineMessageID: UUID?
    private(set) var highlightedMessageID: UUID?
    private(set) var navigationVeilOpacity: Double = 0
    private(set) var isNearBottom = true
    private(set) var followsOutput = true

    @ObservationIgnored private var jumpTask: Task<Void, Never>?
    @ObservationIgnored private var bottomTask: Task<Void, Never>?
    @ObservationIgnored private var userIsScrolling = false

    func reset() {
        jumpTask?.cancel()
        bottomTask?.cancel()
        jumpTask = nil
        bottomTask = nil
        activeOutlineMessageID = nil
        targetOutlineMessageID = nil
        highlightedMessageID = nil
        navigationVeilOpacity = 0
        isNearBottom = true
        followsOutput = true
        userIsScrolling = false
    }

    func updateVisibleRows(_ rowIDs: [UUID], in snapshot: ConversationSnapshot) {
        if let activeID = snapshot.activeOutlineMessageID(visibleRowIDs: rowIDs) {
            activeOutlineMessageID = activeID
        }
    }

    func updateNearBottom(_ nearBottom: Bool) {
        isNearBottom = nearBottom
        if nearBottom {
            followsOutput = true
        } else if userIsScrolling {
            followsOutput = false
        }
    }

    func updateScrollPhase(_ phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting:
            userIsScrolling = true
            if !isNearBottom { followsOutput = false }
        case .idle:
            userIsScrolling = false
        case .decelerating:
            // Keep the interaction armed until momentum finishes so geometry
            // updates can disable output following as the user moves upward.
            break
        case .animating:
            break
        @unknown default:
            break
        }
    }

    func streamingDidStart() {
        followsOutput = isNearBottom
    }

    func requestBottomScroll(
        delay: Duration = .milliseconds(50),
        onlyWhenFollowing: Bool = true,
        perform: @escaping @MainActor () -> Void
    ) {
        guard !onlyWhenFollowing || followsOutput else { return }
        bottomTask?.cancel()
        bottomTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            guard !onlyWhenFollowing || self.followsOutput else { return }
            perform()
        }
    }

    func jump(
        to messageID: UUID,
        in snapshot: ConversationSnapshot,
        reduceMotion: Bool,
        perform: @escaping @MainActor (UUID) -> Void
    ) {
        jumpTask?.cancel()
        bottomTask?.cancel()

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            navigationVeilOpacity = 0
            targetOutlineMessageID = messageID
            highlightedMessageID = nil
            followsOutput = false
        }

        let distance = snapshot.outlineDistance(
            from: activeOutlineMessageID,
            to: messageID
        )
        let kind = ConversationJumpKind.resolve(distance: distance, reduceMotion: reduceMotion)

        jumpTask = Task { @MainActor [weak self] in
            guard let self else { return }

            switch kind {
            case .immediate:
                perform(messageID)
                self.highlightedMessageID = messageID

            case .nearby:
                self.highlightedMessageID = messageID
                withAnimation(.easeInOut(duration: 0.28)) {
                    perform(messageID)
                }

            case .distant:
                withAnimation(.easeOut(duration: 0.08)) {
                    self.navigationVeilOpacity = 1
                }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }

                var noAnimation = Transaction()
                noAnimation.disablesAnimations = true
                withTransaction(noAnimation) {
                    perform(messageID)
                }
                self.highlightedMessageID = messageID

                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.16)) {
                    self.navigationVeilOpacity = 0
                }
            }

            try? await Task.sleep(for: .milliseconds(kind == .immediate ? 450 : 800))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                self.highlightedMessageID = nil
                self.targetOutlineMessageID = nil
            }
        }
    }
}

// MARK: - Message Grouping

struct MessageGroup: Identifiable {
    let id: UUID
    let messages: [ChatMessage]
    let isTransientGroup: Bool
}

/// Returns true if the message would render only a transient tool summary (no visible text or non-transient tools).
private func isPureTransientMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary else { return false }
    let hasVisibleText = message.blocks.contains {
        guard let text = $0.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if hasVisibleText { return false }
    let toolCalls = message.blocks.compactMap(\.toolCall)
    guard !toolCalls.isEmpty else { return false }
    return !toolCalls.contains { !ToolCategory(toolName: $0.name).isTransient }
}

/// Returns true if the message has no renderable content.
private func isInvisibleMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant,
          !message.isError,
          !message.isCompactBoundary,
          !message.isStreaming else { return false }
    return message.blocks.isEmpty
}

/// Groups consecutive pure-transient assistant messages into combined groups.
func groupMessages(_ messages: [ChatMessage], minGroupSize: Int = 2) -> [MessageGroup] {
    var result: [MessageGroup] = []
    var accumulator: [ChatMessage] = []

    func flushAccumulator() {
        guard !accumulator.isEmpty else { return }
        if accumulator.count >= minGroupSize {
            result.append(MessageGroup(id: accumulator[0].id, messages: accumulator, isTransientGroup: true))
        } else {
            result.append(contentsOf: accumulator.map {
                MessageGroup(id: $0.id, messages: [$0], isTransientGroup: false)
            })
        }
        accumulator.removeAll(keepingCapacity: true)
    }

    for message in messages {
        if isPureTransientMessage(message) {
            accumulator.append(message)
        } else if isInvisibleMessage(message) {
            continue
        } else {
            flushAccumulator()
            result.append(MessageGroup(id: message.id, messages: [message], isTransientGroup: false))
        }
    }
    flushAccumulator()
    return result
}
