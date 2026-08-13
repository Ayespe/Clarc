import SwiftUI
import ClarcCore

// MARK: - Bubble Variant

enum BubbleVariant {
    case user
    case assistant
    case error
    case tool
    case toolError
}

// MARK: - Bubble Style Modifier

struct BubbleStyle: ViewModifier {
    let variant: BubbleVariant

    // MARK: - Shared Constants

    static let contentPadding = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    static let toolPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let borderWidth: CGFloat = 0.5

    @ViewBuilder
    func body(content: Content) -> some View {
        switch variant {
        case .assistant:
            // Codex-style assistant prose is part of the reading canvas, not a
            // card. Semantic children such as code, tables and tools keep their
            // own containers where a boundary actually carries meaning.
            content
                .padding(.vertical, 2)
        case .user:
            content
                .padding(padding)
                .clarcGlassSurface(.message, cornerRadius: ClaudeTheme.cornerRadiusLarge)
                .background(ClaudeTheme.userBubble.opacity(0.82), in: shape)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.13), .white.opacity(0.025)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                }
        case .tool:
            content
                .padding(padding)
                .clarcGlassSurface(.message, cornerRadius: ClaudeTheme.cornerRadiusSmall)
        case .error, .toolError:
            content
                .padding(padding)
                .background(background, in: shape)
                .overlay(border)
        }
    }

    // MARK: - Variant Properties

    private var padding: EdgeInsets {
        switch variant {
        case .tool, .toolError:
            return Self.toolPadding
        default:
            return Self.contentPadding
        }
    }

    private var background: some ShapeStyle {
        switch variant {
        case .user:       AnyShapeStyle(ClaudeTheme.userBubble)
        case .assistant:  AnyShapeStyle(Color.clear)
        case .error:      AnyShapeStyle(ClaudeTheme.statusError.opacity(0.08))
        case .tool:       AnyShapeStyle(ClaudeTheme.surfacePrimary)
        case .toolError:  AnyShapeStyle(ClaudeTheme.statusError.opacity(0.06))
        }
    }

    @ViewBuilder
    private var border: some View {
        switch variant {
        case .user:
            EmptyView()
        case .error:
            shape.strokeBorder(ClaudeTheme.statusError.opacity(0.3), lineWidth: Self.borderWidth)
        case .toolError:
            shape.strokeBorder(ClaudeTheme.statusError.opacity(0.3), lineWidth: Self.borderWidth)
        case .assistant:
            EmptyView()
        default:
            shape.strokeBorder(ClaudeTheme.border, lineWidth: Self.borderWidth)
        }
    }

    private var shape: some InsettableShape {
        switch variant {
        case .user:
            AnyInsettableShape(UnevenRoundedRectangle(
                topLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomTrailingRadius: 4,
                topTrailingRadius: ClaudeTheme.cornerRadiusLarge
            ))
        case .assistant:
            AnyInsettableShape(UnevenRoundedRectangle(
                topLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: ClaudeTheme.cornerRadiusLarge,
                topTrailingRadius: ClaudeTheme.cornerRadiusLarge
            ))
        case .error:
            AnyInsettableShape(UnevenRoundedRectangle(
                topLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: ClaudeTheme.cornerRadiusLarge,
                topTrailingRadius: ClaudeTheme.cornerRadiusLarge
            ))
        case .tool, .toolError:
            AnyInsettableShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
    }
}

// MARK: - View Extension

extension View {
    func bubbleStyle(_ variant: BubbleVariant) -> some View {
        modifier(BubbleStyle(variant: variant))
    }
}

// MARK: - AnyInsettableShape

private struct AnyInsettableShape: InsettableShape, @unchecked Sendable {
    private let _path: (CGRect) -> Path
    private let _inset: (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        _path = { shape.path(in: $0) }
        _inset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { _path(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { _inset(amount) }
}
