import SwiftUI

/// Shared geometry for the centered conversation workspace.
///
/// Keeping these values in one place prevents the composer, settled messages,
/// streaming response and outline from drifting onto different horizontal axes.
nonisolated enum ChatLayout {
    static let composerMaxWidth: CGFloat = 730
    static let readingMaxWidth: CGFloat = 730
    static let semanticMaxWidth: CGFloat = 780
    static let userBubbleMaxWidth: CGFloat = 540
    static let regularGutter: CGFloat = 24
    static let compactGutter: CGFloat = 16

    static func gutter(for availableWidth: CGFloat, trackWidth: CGFloat) -> CGFloat {
        availableWidth >= trackWidth + regularGutter * 2
            ? regularGutter
            : compactGutter
    }

    static func resolvedWidth(
        availableWidth: CGFloat,
        trackWidth: CGFloat
    ) -> CGFloat {
        let gutter = gutter(for: availableWidth, trackWidth: trackWidth)
        return min(trackWidth, max(0, availableWidth - gutter * 2))
    }
}

/// A single-child layout that keeps chat content on the window's horizontal
/// center line while preserving responsive safety gutters in narrow windows.
struct CenteredChatTrack<Content: View>: View {
    let maxWidth: CGFloat
    let content: Content

    init(
        maxWidth: CGFloat = ChatLayout.readingMaxWidth,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        CenteredChatTrackLayout(maxWidth: maxWidth) {
            content
        }
    }
}

private struct CenteredChatTrackLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let proposedWidth = proposal.width ?? maxWidth + ChatLayout.regularGutter * 2
        let contentWidth = ChatLayout.resolvedWidth(
            availableWidth: proposedWidth,
            trackWidth: maxWidth
        )
        let measured = subview.sizeThatFits(
            ProposedViewSize(width: contentWidth, height: proposal.height)
        )
        return CGSize(width: proposedWidth, height: measured.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let contentWidth = ChatLayout.resolvedWidth(
            availableWidth: bounds.width,
            trackWidth: maxWidth
        )
        let measured = subview.sizeThatFits(
            ProposedViewSize(width: contentWidth, height: proposal.height)
        )
        subview.place(
            at: CGPoint(x: bounds.midX - measured.width / 2, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: contentWidth, height: measured.height)
        )
    }
}
