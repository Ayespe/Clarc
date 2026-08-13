import SwiftUI
import AppKit
import ClarcCore

struct HistoryListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    /// Selected session ids. A single selection opens that session; multiple
    /// selections (cmd/shift-click) drive batch context-menu actions.
    @State private var selection = Set<String>()
    /// Anchor row for shift-click range selection.
    @State private var selectionAnchor: String?
    @AppStorage("historyShowAllProjects") private var showAllProjects = true
    @State private var showDeleteAllAlert = false
    @State private var sessionIdsPendingDeletion = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .alert("Delete All Chats", isPresented: $showDeleteAllAlert) {
            Button("Delete Chats", role: .destructive) {
                guard !deleteAllTargets.contains(where: { appState.isSessionStreaming($0.id) }) else { return }
                let projectId: UUID?
                if windowState.isProjectWindow {
                    projectId = windowState.selectedProject?.id
                } else {
                    projectId = showAllProjects ? nil : windowState.selectedProject?.id
                }
                Task { await appState.deleteAllSessions(projectId: projectId, in: windowState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let isCurrentOnly = windowState.isProjectWindow || !showAllProjects
            if isCurrentOnly {
                Text("All chats in the current project and their corresponding Claude Code history will be deleted. They cannot be recovered through Clarc.")
            } else {
                Text("All chats and their corresponding Claude Code history will be deleted. They cannot be recovered through Clarc.")
            }
        }
        .alert("Rename Chat", isPresented: isRenamingBinding) {
            TextField("Chat name", text: $renameText)
            Button("Rename") {
                if let session = renamingSession, !renameText.isEmpty {
                    Task { await appState.renameSession(session, to: renameText) }
                }
                renamingSession = nil
            }
            Button("Cancel", role: .cancel) {
                renamingSession = nil
            }
        }
        .confirmationDialog(
            sessionIdsPendingDeletion.count > 1 ? "Delete Chats?" : "Delete Chat?",
            isPresented: Binding(
                get: { !sessionIdsPendingDeletion.isEmpty },
                set: { if !$0 { sessionIdsPendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(sessionIdsPendingDeletion.count > 1 ? "Delete Chats" : "Delete Chat", role: .destructive) {
                let ids = sessionIdsPendingDeletion
                sessionIdsPendingDeletion = []
                guard !ids.contains(where: { appState.isSessionStreaming($0) }) else { return }
                Task { await deleteSessions(ids: ids) }
            }
            Button("Cancel", role: .cancel) { sessionIdsPendingDeletion = [] }
        } message: {
            Text("This will delete the corresponding Claude Code chat history. It cannot be recovered through Clarc.")
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("History")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)

            Spacer()

            // No need to toggle all/current in the project window
            if !windowState.isProjectWindow {
                Button {
                    showAllProjects.toggle()
                } label: {
                    Image(systemName: showAllProjects ? "tray.2" : "tray")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(showAllProjects ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                }
                .buttonStyle(.borderless)
                .help(showAllProjects ? "Show current project only" : "Show all projects")
            }

            Button {
                showDeleteAllAlert = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .buttonStyle(.borderless)
            .disabled(deleteAllTargets.isEmpty || deleteAllTargets.contains(where: { appState.isSessionStreaming($0.id) }))
            .help(deleteAllTargets.contains(where: { appState.isSessionStreaming($0.id) })
                ? "Wait for running chats to finish before deleting them"
                : "Delete All Chats")
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        // Fully custom selection: no `List(selection:)` binding, so macOS never
        // paints its system-accent highlight. We track selection ourselves and
        // draw the selected row with the theme color via `.listRowBackground`.
        List {
            ForEach(sessions) { session in
                sessionRow(session)
                    .listRowBackground(rowBackground(for: session))
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap(session) }
                    .contextMenu { sessionContextMenu(for: contextTargets(for: session)) }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: appState.currentSession(in: windowState)?.id, initial: true) { _, id in
            syncSelectionToCurrent(id)
        }
    }

    /// Selected-row background painted in the theme color, inset into a pill.
    @ViewBuilder
    private func rowBackground(for session: DisplaySession) -> some View {
        if selection.contains(session.id) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ClaudeTheme.sidebarItemSelected)
                .padding(.horizontal, 8)
        }
    }

    /// Resolve a click into single open / cmd-toggle / shift-range selection.
    private func handleTap(_ session: DisplaySession) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(session.id) {
                selection.remove(session.id)
            } else {
                selection.insert(session.id)
            }
            selectionAnchor = session.id
        } else if flags.contains(.shift), let anchor = selectionAnchor,
                  let lo = sessions.firstIndex(where: { $0.id == anchor }),
                  let hi = sessions.firstIndex(where: { $0.id == session.id }) {
            let range = lo <= hi ? lo...hi : hi...lo
            selection.formUnion(sessions[range].map(\.id))
        } else {
            selection = [session.id]
            selectionAnchor = session.id
            appState.selectSession(id: session.id, in: windowState)
        }
    }

    /// Right-click targets: the whole selection if the clicked row is part of
    /// it, otherwise just the clicked row.
    private func contextTargets(for session: DisplaySession) -> Set<String> {
        selection.contains(session.id) ? selection : [session.id]
    }

    /// Mirror the open session into `selection` unless the user is mid
    /// multi-selection, in which case their choice must not be clobbered.
    private func syncSelectionToCurrent(_ id: String?) {
        guard selection.count <= 1 else { return }
        selection = id.map { [$0] } ?? []
        selectionAnchor = id
    }

    private func sessionRow(_ session: DisplaySession) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textPrimary.opacity(0.9))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if showAllProjects && !windowState.isProjectWindow, let projectName = session.projectName {
                        Text(projectName)
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            .foregroundStyle(ClaudeTheme.accent.opacity(0.8))
                            .lineLimit(1)

                        Text("·")
                            .font(.system(size: ClaudeTheme.size(10)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }

                    Text(formattedDate(session.updatedAt))
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }

            Spacer()

            StreamingIndicator(sessionId: session.id)

            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: ClaudeTheme.size(9)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Context Menu

    /// Context menu for the right-clicked selection. `ids` is the effective
    /// target set macOS hands us: the full selection when right-clicking a
    /// selected row, or just the clicked row otherwise. Rename is hidden for
    /// multi-selections; pin/delete apply to every targeted session.
    @ViewBuilder
    private func sessionContextMenu(for ids: Set<String>) -> some View {
        let targets = sessions.filter { ids.contains($0.id) }
        if !targets.isEmpty {
            let allPinned = targets.allSatisfy { $0.isPinned }
            Button {
                Task { await applyPin(to: targets, pin: !allPinned) }
            } label: {
                Label(
                    allPinned ? "Unpin Chat" : "Pin Chat",
                    systemImage: allPinned ? "pin.slash" : "pin"
                )
            }

            if targets.count == 1, let only = targets.first {
                Button {
                    renameText = only.title
                    renamingSession = chatSession(for: only.id)
                } label: {
                    Label("Rename Chat", systemImage: "pencil")
                }

                Button {
                    if let summary = sessionSummary(for: only.id) {
                        Task { await appState.revealSessionInFinder(summary) }
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }

            Divider()

            Button(role: .destructive) {
                sessionIdsPendingDeletion = Set(targets.map(\.id))
            } label: {
                Label(
                    targets.count > 1 ? "Delete Chats" : "Delete Chat",
                    systemImage: "trash"
                )
            }
            .disabled(targets.contains(where: { appState.isSessionStreaming($0.id) }))
        }
    }

    private func sessionSummary(for id: String) -> ChatSession.Summary? {
        appState.allSessionSummaries.first(where: { $0.id == id })
    }

    private func chatSession(for id: String) -> ChatSession? {
        sessionSummary(for: id)?.makeSession()
    }

    private func applyPin(to targets: [DisplaySession], pin: Bool) async {
        for target in targets where target.isPinned != pin {
            if let session = chatSession(for: target.id) {
                await appState.togglePinSession(session)
            }
        }
    }

    private func deleteSessions(ids: Set<String>) async {
        for id in ids {
            if let session = chatSession(for: id) {
                await appState.deleteSession(session, in: windowState)
            }
        }
        selection.subtract(ids)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: ClaudeTheme.size(20)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No chat history")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Display Model

    private struct DisplaySession: Identifiable, Equatable {
        let id: String
        let projectId: UUID
        let title: String
        let updatedAt: Date
        let isPinned: Bool
        let projectName: String?
    }

    private var sessions: [DisplaySession] {
        (windowState.isProjectWindow || !showAllProjects)
            ? currentProjectSessions
            : allProjectSessions
    }

    private var deleteAllTargets: [ChatSession.Summary] {
        if windowState.isProjectWindow || !showAllProjects {
            guard let projectId = windowState.selectedProject?.id else { return [] }
            return appState.allSessionSummaries.filter { $0.projectId == projectId }
        }
        return appState.allSessionSummaries
    }

    private static func sessionOrder(
        _ a: ChatSession.Summary, _ b: ChatSession.Summary
    ) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        return a.updatedAt > b.updatedAt
    }

    private var currentProjectSessions: [DisplaySession] {
        guard let projectId = windowState.selectedProject?.id else { return [] }
        return appState.allSessionSummaries
            .filter { $0.projectId == projectId }
            .sorted { Self.sessionOrder($0, $1) }
            .map { summary in
                DisplaySession(
                    id: summary.id,
                    projectId: summary.projectId,
                    title: summary.title,
                    updatedAt: summary.updatedAt,
                    isPinned: summary.isPinned,
                    projectName: nil
                )
            }
    }

    private var allProjectSessions: [DisplaySession] {
        let projectNames = Dictionary(
            uniqueKeysWithValues: appState.projects.map { ($0.id, $0.name) }
        )
        var seen = Set<String>()
        return appState.allSessionSummaries
            .sorted { Self.sessionOrder($0, $1) }
            .filter { seen.insert($0.id).inserted }
            .map { summary in
                DisplaySession(
                    id: summary.id,
                    projectId: summary.projectId,
                    title: summary.title,
                    updatedAt: summary.updatedAt,
                    isPinned: summary.isPinned,
                    projectName: projectNames[summary.projectId]
                )
            }
    }

    // MARK: - Helpers

    private var isRenamingBinding: Binding<Bool> {
        Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = .current
        f.unitsStyle = .abbreviated
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Background-streaming spinner isolated into its own view. Reading
/// `sessionStates` here keeps that fast-changing dependency out of the parent
/// list, so streaming text deltas no longer re-render the whole session list.
private struct StreamingIndicator: View {
    @Environment(AppState.self) private var appState
    let sessionId: String

    var body: some View {
        if appState.isSessionStreaming(sessionId) {
            ProgressView()
                .controlSize(.mini)
                .help("Response in progress in the background")
        }
    }
}

#Preview {
    HistoryListView()
        .environment(AppState())
        .environment(WindowState())
        .frame(width: 260)
}
