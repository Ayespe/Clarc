import SwiftUI
import ClarcCore

/// A transient, keyboard-first project/chat navigator. It deliberately has no
/// permanent sidebar field so the main hierarchy remains quiet.
struct QuickSwitcherView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private enum EntryKind: Equatable {
        case project
        case session
    }

    private struct Entry: Identifiable {
        let id: String
        let kind: EntryKind
        let title: String
        let subtitle: String
        let projectId: UUID
        let sessionId: String?
        let isPinned: Bool
        let isRunning: Bool
        let updatedAt: Date
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    TextField("Search projects and chats...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: ClaudeTheme.size(15)))
                        .focused($searchFocused)
                        .onSubmit { activateSelection() }
                        .onKeyPress(.downArrow) {
                            moveSelection(by: 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveSelection(by: -1)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            dismiss()
                            return .handled
                        }
                    Text("⌘⇧K")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium, design: .rounded))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ClaudeTheme.surfaceTertiary, in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                ClaudeThemeDivider()

                if entries.isEmpty {
                    Text("No matching projects or chats")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    entryRow(entry, selected: index == selectedIndex)
                                        .id(entry.id)
                                        .onTapGesture {
                                            selectedIndex = index
                                            activate(entry)
                                        }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 390)
                        .onChange(of: selectedIndex) { _, newIndex in
                            guard entries.indices.contains(newIndex) else { return }
                            proxy.scrollTo(entries[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 580)
            .clarcGlassSurface(.popover, cornerRadius: 18)
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
            .padding(.top, 74)
        }
        .onAppear {
            searchFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: entries.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
    }

    private var entries: [Entry] {
        let allowedProjects: [Project]
        if windowState.isProjectWindow, let current = windowState.selectedProject {
            allowedProjects = [current]
        } else {
            allowedProjects = appState.projects
        }
        let allowedIds = Set(allowedProjects.map(\.id))

        var candidates: [Entry] = []
        if !windowState.isProjectWindow {
            candidates += allowedProjects.map { project in
                Entry(
                    id: "project:\(project.id.uuidString)",
                    kind: .project,
                    title: project.name,
                    subtitle: abbreviatedPath(project.path),
                    projectId: project.id,
                    sessionId: nil,
                    isPinned: project.isPinned,
                    isRunning: appState.allSessionSummaries.contains {
                        $0.projectId == project.id && appState.isSessionStreaming($0.id)
                    },
                    updatedAt: appState.allSessionSummaries
                        .filter { $0.projectId == project.id }
                        .map(\.updatedAt)
                        .max() ?? .distantPast
                )
            }
        }

        candidates += appState.allSessionSummaries
            .filter { allowedIds.contains($0.projectId) }
            .compactMap { session in
                guard let project = allowedProjects.first(where: { $0.id == session.projectId }) else { return nil }
                return Entry(
                    id: "session:\(session.projectId.uuidString):\(session.id)",
                    kind: .session,
                    title: session.title,
                    subtitle: project.name,
                    projectId: session.projectId,
                    sessionId: session.id,
                    isPinned: session.isPinned,
                    isRunning: appState.isSessionStreaming(session.id),
                    updatedAt: session.updatedAt
                )
            }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates
            .compactMap { entry -> (Entry, Int)? in
                guard !needle.isEmpty else { return (entry, 0) }
                let titleScore = fuzzyScore(needle, in: entry.title)
                let subtitleScore = fuzzyScore(needle, in: entry.subtitle).map { $0 - 20 }
                guard let score = [titleScore, subtitleScore].compactMap({ $0 }).max() else { return nil }
                return (entry, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.isRunning != rhs.0.isRunning { return lhs.0.isRunning }
                if lhs.0.isPinned != rhs.0.isPinned { return lhs.0.isPinned }
                return lhs.0.updatedAt > rhs.0.updatedAt
            }
            .prefix(40)
            .map(\.0)
    }

    private func entryRow(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: entry.kind == .project ? "folder.fill" : "bubble.left")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(entry.kind == .project ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if entry.isRunning {
                ProgressView().controlSize(.mini)
            }
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: ClaudeTheme.size(9)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(selected ? ClaudeTheme.sidebarItemSelected : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    private func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), entries.count - 1)
    }

    private func activateSelection() {
        guard entries.indices.contains(selectedIndex) else { return }
        activate(entries[selectedIndex])
    }

    private func activate(_ entry: Entry) {
        switch entry.kind {
        case .project:
            guard let project = appState.projects.first(where: { $0.id == entry.projectId }) else { return }
            appState.selectProject(project, in: windowState)
        case .session:
            guard let sessionId = entry.sessionId else { return }
            appState.selectSession(id: sessionId, in: windowState)
        }
        dismiss()
    }

    private func dismiss() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            windowState.showQuickSwitcher = false
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Subsequence scoring works for Latin and CJK input without imposing a
    /// tokenizer. Exact/substring matches receive a strong preference.
    private func fuzzyScore(_ rawNeedle: String, in rawHaystack: String) -> Int? {
        let needle = rawNeedle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let haystack = rawHaystack.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !needle.isEmpty else { return 0 }
        if haystack == needle { return 1_000 }
        if let range = haystack.range(of: needle) {
            return 800 - haystack.distance(from: haystack.startIndex, to: range.lowerBound)
        }

        var searchIndex = haystack.startIndex
        var score = 400
        var previousMatch: String.Index?
        for character in needle {
            guard let match = haystack[searchIndex...].firstIndex(of: character) else { return nil }
            if let previousMatch, haystack.index(after: previousMatch) == match { score += 8 }
            score -= haystack.distance(from: searchIndex, to: match)
            searchIndex = haystack.index(after: match)
            previousMatch = match
        }
        return score
    }
}
