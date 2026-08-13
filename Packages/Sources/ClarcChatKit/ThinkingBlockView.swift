import SwiftUI
import ClarcCore

enum ThinkingDisclosurePolicy {
    static func isExpanded(
        override: Bool?,
        autoExpandWhileStreaming: Bool,
        isStreaming: Bool
    ) -> Bool {
        override ?? (autoExpandWhileStreaming && isStreaming)
    }
}

/// Renders one presentation-level run of adjacent thinking blocks. The group is
/// collapsed by default; automatic expansion is an explicit global preference,
/// while a user's per-group choice always wins.
struct ThinkingBlockView: View {
    let group: ThinkingBlockGroup
    let isMessageStreaming: Bool
    let autoExpandWhileStreaming: Bool
    @Binding var disclosureOverride: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCopied = false
    @State private var isHovering = false

    private var blocks: [MessageBlock] { group.blocks }

    private var isRedacted: Bool {
        blocks.count == 1 && blocks[0].isThinkingRedacted
    }

    private var isGroupStreaming: Bool {
        guard isMessageStreaming, !isRedacted, let last = blocks.last else { return false }
        return last.thinkingDuration == nil
    }

    private var isExpanded: Bool {
        ThinkingDisclosurePolicy.isExpanded(
            override: disclosureOverride,
            autoExpandWhileStreaming: autoExpandWhileStreaming,
            isStreaming: isGroupStreaming
        )
    }

    private var visibleThinkingBlocks: [MessageBlock] {
        blocks.filter { !($0.thinking ?? "").isEmpty }
    }

    private var thinkingText: String {
        visibleThinkingBlocks.compactMap(\.thinking).joined(separator: "\n\n")
    }

    /// A total is only truthful when every segment has a measured duration.
    private var aggregateDuration: TimeInterval? {
        guard !blocks.isEmpty,
              blocks.allSatisfy({ !$0.isThinkingRedacted && $0.thinkingDuration != nil }) else {
            return nil
        }
        return blocks.compactMap(\.thinkingDuration).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                thinkingBody
            }
        }
        .clarcGlassSurface(.message, cornerRadius: ClaudeTheme.cornerRadiusSmall)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isExpanded)
    }

    private var header: some View {
        Button {
            let toggle = { disclosureOverride = !isExpanded }
            if reduceMotion {
                toggle()
            } else {
                withAnimation(.easeOut(duration: 0.16), toggle)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRedacted ? "lock.fill" : "brain")
                    .font(.system(size: ClaudeTheme.messageSize(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Text(headerText)
                    .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer(minLength: 6)
                if !isRedacted {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: ClaudeTheme.messageSize(9), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRedacted)
    }

    private var headerText: String {
        let base: String
        if isRedacted {
            base = String(localized: "thinking.header.redacted", bundle: .module)
        } else if isGroupStreaming {
            base = String(localized: "thinking.header.streaming", bundle: .module)
        } else if let aggregateDuration {
            base = String(
                format: String(localized: "thinking.header.duration", bundle: .module),
                aggregateDuration.formattedDuration
            )
        } else {
            base = String(localized: "thinking.header.completed", bundle: .module)
        }

        guard blocks.count > 1 else { return base }
        return String(
            format: String(localized: "thinking.header.segmentCount", bundle: .module),
            base,
            blocks.count
        )
    }

    @ViewBuilder
    private var thinkingBody: some View {
        if visibleThinkingBlocks.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                    .overlay(ClaudeTheme.border)
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(ClaudeTheme.border)
                        .frame(width: 2)
                        .padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(visibleThinkingBlocks.enumerated()), id: \.element.id) { index, block in
                            if index > 0 {
                                Divider()
                                    .overlay(ClaudeTheme.borderSubtle)
                            }
                            Text(block.thinking ?? "")
                                .font(.system(size: ClaudeTheme.messageSize(12)))
                                .italic()
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .overlay(alignment: .bottomTrailing) {
                if isHovering && !isMessageStreaming {
                    Button {
                        copyToClipboard(thinkingText, feedback: $isCopied)
                    } label: {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
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
                    .padding(6)
                }
            }
        }
    }
}
