import AppKit
import Observation
import SwiftUI

// MARK: - Appearance

/// Clarc has one visual identity and three ways to resolve its light/dark appearance.
/// The legacy palette preference is intentionally not consulted.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var detail: LocalizedStringKey {
        switch self {
        case .system: "Use the Mac appearance setting."
        case .light: "Always use light appearance."
        case .dark: "Always use dark appearance."
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Claude Color System

public struct ThemeColors: @unchecked Sendable {
    public let accent: Color
    public let accentSubtle: Color
    public let background: Color
    public let surfacePrimary: Color
    public let surfaceSecondary: Color
    public let surfaceTertiary: Color
    public let surfaceElevated: Color
    public let sidebarBackground: Color
    public let sidebarItemHover: Color
    public let sidebarItemSelected: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let border: Color
    public let borderSubtle: Color
    public let codeBackground: Color
    public let codeHeaderBackground: Color
    public let userBubble: Color
    public let userBubbleText: Color
    public let assistantBubble: Color
    public let statusSuccess: Color
    public let statusError: Color
    public let statusWarning: Color
    public let inputBackground: Color
    public let inputBorder: Color

    public init(
        accent: Color, accentSubtle: Color,
        background: Color, surfacePrimary: Color, surfaceSecondary: Color,
        surfaceTertiary: Color, surfaceElevated: Color,
        sidebarBackground: Color, sidebarItemHover: Color, sidebarItemSelected: Color,
        textPrimary: Color, textSecondary: Color, textTertiary: Color,
        border: Color, borderSubtle: Color,
        codeBackground: Color, codeHeaderBackground: Color,
        userBubble: Color, userBubbleText: Color, assistantBubble: Color,
        statusSuccess: Color, statusError: Color, statusWarning: Color,
        inputBackground: Color, inputBorder: Color
    ) {
        self.accent = accent
        self.accentSubtle = accentSubtle
        self.background = background
        self.surfacePrimary = surfacePrimary
        self.surfaceSecondary = surfaceSecondary
        self.surfaceTertiary = surfaceTertiary
        self.surfaceElevated = surfaceElevated
        self.sidebarBackground = sidebarBackground
        self.sidebarItemHover = sidebarItemHover
        self.sidebarItemSelected = sidebarItemSelected
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.border = border
        self.borderSubtle = borderSubtle
        self.codeBackground = codeBackground
        self.codeHeaderBackground = codeHeaderBackground
        self.userBubble = userBubble
        self.userBubbleText = userBubbleText
        self.assistantBubble = assistantBubble
        self.statusSuccess = statusSuccess
        self.statusError = statusError
        self.statusWarning = statusWarning
        self.inputBackground = inputBackground
        self.inputBorder = inputBorder
    }

    public var textOnAccent: Color { .white }
    public var inputPlaceholder: Color { textTertiary }
    public var statusRunning: Color { accent }
}

extension ThemeColors {
    /// Warm pearl by day, obsidian and graphite by night. Terracotta remains the
    /// only accent so project identity never changes when appearance changes.
    public static let claude = ThemeColors(
        accent:               Color(light: .hex(0xC96345), dark: .hex(0xE07A5F)),
        accentSubtle:         Color(light: .hex(0xC96345).opacity(0.11), dark: .hex(0xE07A5F).opacity(0.14)),
        background:           Color(light: .hex(0xF5F2EA), dark: .hex(0x141411)),
        surfacePrimary:       Color(light: .hex(0xF0ECE3), dark: .hex(0x211F1B)),
        surfaceSecondary:     Color(light: .hex(0xE8E3D9), dark: .hex(0x292722)),
        surfaceTertiary:      Color(light: .hex(0xDDD7CC), dark: .hex(0x34312B)),
        surfaceElevated:      Color(light: .hex(0xFCFAF5), dark: .hex(0x292722)),
        sidebarBackground:    Color(light: .hex(0xECE7DE).opacity(0.88), dark: .hex(0x181713).opacity(0.90)),
        sidebarItemHover:     Color(light: .white.opacity(0.52), dark: .white.opacity(0.055)),
        sidebarItemSelected:  Color(light: .hex(0xC96345).opacity(0.12), dark: .hex(0xE07A5F).opacity(0.15)),
        textPrimary:          Color(light: .hex(0x302D28), dark: .hex(0xF0ECE3)),
        textSecondary:        Color(light: .hex(0x666158), dark: .hex(0xBBB5AA)),
        textTertiary:         Color(light: .hex(0x918A7F), dark: .hex(0x817B72)),
        border:               Color(light: .hex(0xCFC8BB).opacity(0.90), dark: .white.opacity(0.12)),
        borderSubtle:         Color(light: .hex(0xDCD5C9).opacity(0.76), dark: .white.opacity(0.07)),
        codeBackground:       Color(light: .hex(0xE9E4DB), dark: .hex(0x11110F)),
        codeHeaderBackground: Color(light: .hex(0xDDD7CC), dark: .hex(0x1C1B18)),
        userBubble:           Color(light: .hex(0xEEE8DE).opacity(0.96), dark: .hex(0x2A2823).opacity(0.96)),
        userBubbleText:       Color(light: .hex(0x302D28), dark: .hex(0xF0ECE3)),
        assistantBubble:      Color(light: .clear, dark: .clear),
        statusSuccess:        Color(light: .hex(0x4F8A68), dark: .hex(0x76B18F)),
        statusError:          Color(light: .hex(0xB6544B), dark: .hex(0xD9776A)),
        statusWarning:        Color(light: .hex(0xB9792D), dark: .hex(0xD9A557)),
        inputBackground:      Color(light: .white.opacity(0.72), dark: .hex(0x24221E).opacity(0.86)),
        inputBorder:          Color(light: .white.opacity(0.88), dark: .white.opacity(0.13))
    )
}

// MARK: - Design Tokens

/// Shared visual vocabulary for every Clarc surface. Values are deliberately
/// semantic so a view declares intent instead of recreating glass recipes.
@MainActor
public enum ClarcDesignTokens {
    public static var canvas: Color { ThemeStore.shared.colors.background }
    public static var canvasRaised: Color {
        Color(light: .hex(0xFBF8F1), dark: .hex(0x1A1A17))
    }
    public static var ambientGlow: Color {
        Color(light: .hex(0xD97757).opacity(0.10), dark: .hex(0xD97757).opacity(0.085))
    }
    public static var glassTint: Color {
        Color(light: .white.opacity(0.52), dark: .hex(0x24231F).opacity(0.68))
    }
    public static var glassTintStrong: Color {
        Color(light: .hex(0xFAF7EF).opacity(0.88), dark: .hex(0x24231F).opacity(0.90))
    }
    public static var glassTintOpaque: Color {
        Color(light: .hex(0xF2EEE5), dark: .hex(0x24231F))
    }
    public static var edgeHighlight: Color {
        Color(light: .white.opacity(0.82), dark: .white.opacity(0.12))
    }
    public static var edgeLowlight: Color {
        Color(light: .black.opacity(0.08), dark: .black.opacity(0.34))
    }
    public static var accentEdge: Color { ThemeStore.shared.colors.accent.opacity(0.34) }
    public static var shadow: Color { Color.black.opacity(0.18) }

    public static let cornerSmall: CGFloat = 8
    public static let cornerMedium: CGFloat = 12
    public static let cornerLarge: CGFloat = 18
    public static let cornerExtraLarge: CGFloat = 24
    public static let cornerPill: CGFloat = 999

    public static let hoverDuration = 0.11
    public static let selectionDuration = 0.16
    public static let presentationDuration = 0.20

    public static var windowGradient: LinearGradient {
        LinearGradient(
            colors: [canvasRaised, canvas],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

@MainActor
public enum GlassSurfaceRole: Sendable, Equatable {
    case sidebar
    case composer
    case popover
    case inspector
    case floating
    case control
    case selection
    case message

    fileprivate var defaultCornerRadius: CGFloat {
        switch self {
        case .sidebar, .inspector: 0
        case .composer: ClarcDesignTokens.cornerExtraLarge
        case .popover, .floating: ClarcDesignTokens.cornerLarge
        case .control, .selection: ClarcDesignTokens.cornerMedium
        case .message: ClarcDesignTokens.cornerLarge
        }
    }

    fileprivate var usesLiveMaterial: Bool {
        switch self {
        case .sidebar, .composer, .popover, .inspector, .floating: true
        case .control, .selection, .message: false
        }
    }

    fileprivate var material: Material {
        switch self {
        case .sidebar, .inspector: .ultraThinMaterial
        case .composer, .popover, .floating: .thinMaterial
        case .control, .selection, .message: .regularMaterial
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .composer, .popover, .floating: ClarcDesignTokens.glassTintStrong
        case .selection: ThemeStore.shared.colors.accentSubtle
        case .sidebar, .inspector, .control, .message: ClarcDesignTokens.glassTint
        }
    }

    fileprivate var shadowRadius: CGFloat {
        switch self {
        case .popover, .floating: 20
        case .composer: 14
        case .control, .message: 7
        case .sidebar, .inspector, .selection: 0
        }
    }
}

// MARK: - Theme Store

public extension Notification.Name {
    /// AppKit-backed renderers use this to refresh attributed colors.
    static let clarcThemeDidChange = Notification.Name("com.clarc.themeDidChange")
}

@Observable
@MainActor
public final class ThemeStore {
    public static let shared = ThemeStore()
    private init() {}

    public var appearanceMode: AppearanceMode = .system {
        didSet {
            guard oldValue != appearanceMode else { return }
            NotificationCenter.default.post(name: .clarcThemeDidChange, object: nil)
        }
    }

    public let colors: ThemeColors = .claude

    public static let minFontSizeAdjustment = -5
    public static let maxFontSizeAdjustment = 8
    public var fontSizeAdjustment = 0
    public var messageFontSizeAdjustment = 0
}

// MARK: - Glass Surfaces

private struct ClarcGlassSurfaceModifier: ViewModifier {
    let role: GlassSurfaceRole
    let cornerRadius: CGFloat?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.defaultCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if reduceTransparency {
                legacySurface(content: content, shape: shape, radius: radius, useMaterial: false)
            } else {
                content
                    .background(role.tint.opacity(0.34), in: shape)
                    .glassEffect(.regular, in: shape)
                    .overlay(edge(for: shape))
                    .shadow(color: ClarcDesignTokens.shadow, radius: role.shadowRadius, y: role.shadowRadius * 0.35)
            }
        } else {
            legacySurface(content: content, shape: shape, radius: radius, useMaterial: role.usesLiveMaterial)
        }
        #else
        legacySurface(content: content, shape: shape, radius: radius, useMaterial: role.usesLiveMaterial)
        #endif
    }

    private func legacySurface(
        content: Content,
        shape: RoundedRectangle,
        radius: CGFloat,
        useMaterial: Bool
    ) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(ClarcDesignTokens.glassTintOpaque)
                } else if useMaterial {
                    shape.fill(role.material)
                        .overlay(shape.fill(role.tint.opacity(0.42)))
                } else {
                    shape.fill(role.tint)
                }
            }
            .overlay(edge(for: shape))
            .shadow(
                color: reduceTransparency ? .clear : ClarcDesignTokens.shadow,
                radius: role.shadowRadius,
                y: role.shadowRadius * 0.35
            )
    }

    @ViewBuilder
    private func edge(for shape: RoundedRectangle) -> some View {
        shape
            .strokeBorder(
                contrast == .increased
                    ? ThemeStore.shared.colors.border
                    : ClarcDesignTokens.edgeHighlight,
                lineWidth: contrast == .increased ? 1 : 0.7
            )
            .overlay(alignment: .bottom) {
                if role == .popover || role == .floating || role == .composer || role == .message {
                    shape
                        .trim(from: 0.08, to: 0.48)
                        .stroke(ClarcDesignTokens.edgeLowlight, lineWidth: 0.5)
                }
            }
    }
}

private struct ClarcWindowCanvasModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            ZStack(alignment: .topTrailing) {
                ClarcDesignTokens.windowGradient
                if !reduceTransparency {
                    RadialGradient(
                        colors: [ClarcDesignTokens.ambientGlow, .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 440
                    )
                    .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
    }
}

public extension View {
    /// Applies Clarc's semantic glass treatment. Scrolling message content uses
    /// a static tint while fixed chrome receives native material blur.
    func clarcGlassSurface(
        _ role: GlassSurfaceRole,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(ClarcGlassSurfaceModifier(role: role, cornerRadius: cornerRadius))
    }

    /// Installs the warm pearl / obsidian canvas and its restrained static glow.
    func clarcWindowCanvas() -> some View {
        modifier(ClarcWindowCanvasModifier())
    }
}
