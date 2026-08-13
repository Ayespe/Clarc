import SwiftUI
import ClarcCore
import ClarcChatKit

// MARK: - Settings Sheet

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedTab = 0
    @State private var showUserManual = false

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(showUserManual: $showUserManual)
                .tabItem {
                    Label("General", systemImage: "slider.horizontal.3")
                }
                .tag(0)

            ChatSettingsTab()
                .tabItem {
                    Label("Message", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(1)

            SlashCommandManagerView(isEmbedded: true)
                .tabItem {
                    Label("Slash Commands", systemImage: "terminal.fill")
                }
                .tag(2)

            ShortcutManagerView(isEmbedded: true)
                .tabItem {
                    Label("Shortcuts", systemImage: "bolt.fill")
                }
                .tag(3)
        }
        .frame(width: 680, height: 620)
        .clarcWindowCanvas()
        .tint(ClaudeTheme.accent)
        .focusable(false)
        .onAppear { selectedTab = 0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "Settings" else { return }
            selectedTab = 0
        }
        .sheet(isPresented: $showUserManual) {
            UserManualView()
        }
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @Binding var showUserManual: Bool
    @State private var showSkillMarket = false

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                appearanceSection
                Divider()
                fontSizeSection
                Divider()
                notificationsSection
                Divider()
                inspectorLayoutSection
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    skillMarketSection
                    helpSection
                    sourceCodeSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Toggle Section

    private func toggleSection(
        title: LocalizedStringKey,
        label: LocalizedStringKey,
        detail: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text(detail)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - Font Size Section

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Font Size")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            fontSizeRow(
                label: "Interface",
                value: appState.fontSizeAdjustment,
                onDecrease: { appState.decreaseFontSize() },
                onIncrease: { appState.increaseFontSize() },
                onReset: { appState.fontSizeAdjustment = 0 }
            )
            fontSizeRow(
                label: "Messages",
                value: appState.messageFontSizeAdjustment,
                onDecrease: { appState.decreaseMessageFontSize() },
                onIncrease: { appState.increaseMessageFontSize() },
                onReset: { appState.messageFontSizeAdjustment = 0 }
            )
            Text("font.size.hint")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private func fontSizeRow(label: LocalizedStringKey, value: Int, onDecrease: @escaping () -> Void, onIncrease: @escaping () -> Void, onReset: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            fontStepButton(systemName: "minus", action: onDecrease)
                .disabled(value <= ThemeStore.minFontSizeAdjustment)
            Group {
                if value == 0 {
                    Text("Default")
                } else {
                    Text(verbatim: value > 0 ? "+\(value)" : "\(value)")
                }
            }
            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
            .frame(minWidth: 48, alignment: .center)
            fontStepButton(systemName: "plus", action: onIncrease)
                .disabled(value >= ThemeStore.maxFontSizeAdjustment)
            if value != 0 {
                Button("Reset", action: onReset)
                    .buttonStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.accent)
            }
        }
    }

    private func fontStepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 26, height: 26)
                .clarcGlassSurface(.control, cornerRadius: 7)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 14) {
            Text("Notifications")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn completion notifications")
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text("Choose when Clarc alerts you after a response finishes.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $appState.turnCompletionNotificationMode) {
                    Text("Always").tag(TurnCompletionNotificationMode.always)
                    Text("When Clarc is inactive").tag(TurnCompletionNotificationMode.whenInactive)
                    Text("Never").tag(TurnCompletionNotificationMode.never)
                }
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: appState.turnCompletionNotificationMode) { _, mode in
                    guard mode != .never else { return }
                    Task { await NotificationService.shared.requestAuthorizationIfNeeded() }
                }
            }

            Toggle(isOn: $appState.questionNotificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable question notifications")
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text("Show an alert when input is required to continue.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: appState.questionNotificationsEnabled) { _, enabled in
                guard enabled else { return }
                Task { await NotificationService.shared.requestAuthorizationIfNeeded() }
            }

            Text("The Dock icon bounces once when an enabled alert arrives while Clarc is inactive.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Inspector Layout Section

    private var inspectorLayoutSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Panel Layout")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Choose where the memo and terminal panel is docked.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: $appState.inspectorPosition) {
                Text("Right").tag(InspectorPosition.right)
                Text("Bottom").tag(InspectorPosition.bottom)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            Toggle(isOn: $appState.inspectorShowBoth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show memo and terminal together")
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text("Splits the panel in two. On the right they stack (memo on top); at the bottom they sit side by side (memo on the left).")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 10) {
            Text("Appearance")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Picker("Appearance", selection: $appState.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

            Text(appState.appearanceMode.detail)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
    }

    // MARK: - Skill Market Section

    private var skillMarketSection: some View {
        Button {
            showSkillMarket = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Skill Marketplace")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.primary)
                    Text("Browse and manage Claude Code skills")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .clarcGlassSurface(.control, cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSkillMarket) {
            SkillMarketView(isEmbedded: false)
        }
    }

    // MARK: - Source Code Section

    private var sourceCodeSection: some View {
        Link(destination: URL(string: "https://github.com/ttnear/Clarc")!) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open Source")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.primary)
                    Text(verbatim: "github.com/ttnear/Clarc")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .clarcGlassSurface(.control, cornerRadius: 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Help Section

    private var helpSection: some View {
        Button {
            showUserManual = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.fill")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                Text("User Guide")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .clarcGlassSurface(.control, cornerRadius: 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chat Settings Tab

struct ChatSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                modelSection(selectedModel: $appState.selectedModel)
                Divider()
                permissionModeSection
                Divider()
                effortSection
                Divider()
                thinkingSection
                Divider()
                focusModeSection
                Divider()
                autoPreviewSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Model Section

    private func modelSection(selectedModel: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default Model")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the model per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: selectedModel) {
                ForEach(appState.availableModels, id: \.self) { model in
                    Text(appState.modelDisplayName(model)).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(appState.modelDescription(selectedModel.wrappedValue))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Permission Mode Section

    private var permissionModeSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Default Permission Mode")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the permission mode per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { appState.permissionMode },
                set: { appState.setDefaultPermissionMode($0) }
            )) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text(AppState.permissionModeDisplayName(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(AppState.permissionModeDescription(appState.permissionMode))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Thinking Section

    private var thinkingSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Thinking Display")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("thinking.auto.expand.desc")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Toggle("Auto-expand thinking while Claude is working", isOn: $appState.autoExpandThinking)
                .toggleStyle(.switch)
                .fixedSize()
        }
    }

    // MARK: - Effort Section

    private var effortSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Default Effort Level")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the effort level per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: $appState.selectedEffort) {
                Text("Auto").tag("auto")
                ForEach(AppState.availableEfforts, id: \.self) { effort in
                    Text(effortDisplayName(effort)).tag(effort)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(AppState.effortDescription(appState.selectedEffort))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Focus Mode Section

    private var focusModeSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Focus Mode")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("focus.mode.desc")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.focusMode) {
                Text("Enable Focus Mode")
            }
            .toggleStyle(.switch)
            .fixedSize()
        }
    }

    // MARK: - Auto-Preview Attachments Section

    private var autoPreviewSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Auto-preview Attachments")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("auto.preview.desc")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("URL links", isOn: $appState.autoPreviewSettings.url)
                Toggle("File paths", isOn: $appState.autoPreviewSettings.filePath)
                Toggle("Images", isOn: $appState.autoPreviewSettings.image)
                Toggle("Long text (200+ characters)", isOn: $appState.autoPreviewSettings.longText)
            }
            .toggleStyle(.checkbox)
        }
    }

    private func effortDisplayName(_ effort: String) -> String {
        switch effort {
        case "low":    return "Low"
        case "medium": return "Medium"
        case "high":   return "High"
        case "xhigh":  return "Extra High"
        case "max":    return "Max"
        default:       return effort.capitalized
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .environment(WindowState())
}
