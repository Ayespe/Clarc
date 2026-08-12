import SwiftUI
import ClarcCore
import UniformTypeIdentifiers

/// Codex-style workspace navigator: projects are the stable top-level rows and
/// their most recent sessions live directly beneath them.
struct ProjectListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFilePicker = false
    @State private var projectToRemove: Project?
    @State private var renamingSession: ChatSession?
    @State private var sessionRenameText = ""
    @State private var sessionToDelete: ChatSession.Summary?
    @State private var expandedSessionProjectIds = Set<UUID>()
    @AppStorage("projectTreeExpandedIds") private var expandedIdsStorage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if sortedProjects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .onAppear {
            restoreExpandedProjects()
            if let id = windowState.selectedProject?.id {
                setExpanded(true, projectId: id)
            }
        }
        .onChange(of: windowState.selectedProject?.id) { _, id in
            if let id { setExpanded(true, projectId: id) }
        }
        .confirmationDialog(
            "Remove \"\(projectToRemove?.name ?? "")\" from Clarc?",
            isPresented: Binding(
                get: { projectToRemove != nil },
                set: { if !$0 { projectToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Project", role: .destructive) {
                if let project = projectToRemove {
                    Task { await appState.removeProject(project, in: windowState) }
                }
                projectToRemove = nil
            }
            Button("Cancel", role: .cancel) { projectToRemove = nil }
        } message: {
            Text("This will remove the project from Clarc. The files on disk will not be deleted.")
        }
        .alert("Rename Chat", isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField("Chat name", text: $sessionRenameText)
            Button("Rename") {
                if let session = renamingSession,
                   !sessionRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await appState.renameSession(session, to: sessionRenameText) }
                }
                renamingSession = nil
            }
            Button("Cancel", role: .cancel) { renamingSession = nil }
        }
        .confirmationDialog(
            "Delete Chat?",
            isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { if !$0 { sessionToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Chat", role: .destructive) {
                if let session = sessionToDelete,
                   !appState.isSessionStreaming(session.id) {
                    Task { await appState.deleteSession(session.makeSession(), in: windowState) }
                }
                sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        } message: {
            Text("This will delete the corresponding Claude Code chat history. It cannot be recovered through Clarc.")
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Projects")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)

            Spacer()

            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Add Project")
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleFolderSelection
            )
        }
    }

    private var projectList: some View {
        List {
            ForEach(sortedProjects) { project in
                projectHeader(project)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if expandedProjectIds.contains(project.id) {
                    let sessions = sessions(for: project)
                    let visible = expandedSessionProjectIds.contains(project.id)
                        ? sessions
                        : Array(sessions.prefix(10))

                    if sessions.isEmpty {
                        Text("No chat history")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .padding(.leading, 28)
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(visible) { session in
                            sessionRow(session)
                                .listRowBackground(sessionBackground(session))
                                .listRowSeparator(.hidden)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if sessions.count > 10 {
                            showMoreRow(project: project, isExpanded: expandedSessionProjectIds.contains(project.id))
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: expandedProjectIds)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: expandedSessionProjectIds)
    }

    private func projectHeader(_ project: Project) -> some View {
        Button {
            let wasSelected = windowState.selectedProject?.id == project.id
            if !wasSelected { appState.selectProject(project, in: windowState) }
            setExpanded(wasSelected ? !expandedProjectIds.contains(project.id) : true, projectId: project.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .rotationEffect(.degrees(expandedProjectIds.contains(project.id) ? 90 : 0))

                Image(systemName: "folder.fill")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                    Text(abbreviatePath(project.path))
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if project.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: ClaudeTheme.size(8)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await appState.togglePinProject(project) }
            } label: {
                Label(
                    project.isPinned ? "Unpin Project" : "Pin Project",
                    systemImage: project.isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                appState.revealProjectInFinder(project)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) {
                projectToRemove = project
            } label: {
                Label("Remove Project", systemImage: "minus.circle")
            }
        }
    }

    private func sessionRow(_ session: ChatSession.Summary) -> some View {
        Button {
            appState.selectSession(id: session.id, in: windowState)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: session.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(session.isCompleted ? ClaudeTheme.accent : ClaudeTheme.textTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textPrimary.opacity(session.isCompleted ? 0.5 : 0.9))
                        .strikethrough(session.isCompleted, color: ClaudeTheme.textTertiary)
                        .lineLimit(1)
                    Text(Self.relativeDateFormatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }

                Spacer(minLength: 4)

                if appState.isSessionStreaming(session.id) {
                    ProgressView().controlSize(.mini)
                } else if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: ClaudeTheme.size(8)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .padding(.leading, 27)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await appState.togglePinSession(session.makeSession()) }
            } label: {
                Label(
                    session.isPinned ? "Unpin Chat" : "Pin Chat",
                    systemImage: session.isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                sessionRenameText = session.title
                renamingSession = session.makeSession()
            } label: {
                Label("Rename Chat", systemImage: "pencil")
            }
            Button {
                Task { await appState.revealSessionInFinder(session) }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Divider()
            Button {
                Task { await appState.toggleCompleteSession(id: session.id) }
            } label: {
                Label(session.isCompleted ? "Mark as Incomplete" : "Mark as Complete",
                      systemImage: session.isCompleted ? "circle" : "checkmark.circle")
            }
            Divider()
            Button(role: .destructive) {
                sessionToDelete = session
            } label: {
                Label("Delete Chat", systemImage: "trash")
            }
            .disabled(appState.isSessionStreaming(session.id))
        }
    }

    private func showMoreRow(project: Project, isExpanded: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                if isExpanded {
                    expandedSessionProjectIds.remove(project.id)
                } else {
                    expandedSessionProjectIds.insert(project.id)
                }
            }
        } label: {
            Text(LocalizedStringKey(isExpanded ? "Show Less" : "Show More"))
        }
        .buttonStyle(.plain)
        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
        .foregroundStyle(ClaudeTheme.accent)
        .padding(.leading, 55)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sessionBackground(_ session: ChatSession.Summary) -> some View {
        if windowState.currentSessionId == session.id {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ClaudeTheme.sidebarItemSelected)
                .padding(.horizontal, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: ClaudeTheme.size(20)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No Projects")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Button("Add Project") { showFilePicker = true }
                .buttonStyle(.link)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var sortedProjects: [Project] {
        var latest: [UUID: Date] = [:]
        for session in appState.allSessionSummaries {
            latest[session.projectId] = max(latest[session.projectId] ?? .distantPast, session.updatedAt)
        }
        return Project.sortedForSidebar(appState.projects, latestActivityByProject: latest)
    }

    private func sessions(for project: Project) -> [ChatSession.Summary] {
        appState.allSessionSummaries
            .filter { $0.projectId == project.id }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.updatedAt > $1.updatedAt
            }
    }

    private var expandedProjectIds: Set<UUID> {
        Set(expandedIdsStorage.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func restoreExpandedProjects() {
        let valid = Set(appState.projects.map(\.id))
        let restored = expandedProjectIds.intersection(valid)
        expandedIdsStorage = restored.map(\.uuidString).sorted().joined(separator: ",")
    }

    private func setExpanded(_ expanded: Bool, projectId: UUID) {
        var ids = expandedProjectIds
        if expanded { ids.insert(projectId) } else { ids.remove(projectId) }
        expandedIdsStorage = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func abbreviatePath(_ path: String) -> String {
        path.hasPrefix(Self.homePath) ? "~" + path.dropFirst(Self.homePath.count) : path
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await appState.addProjectFromFolder(url, in: windowState) }
    }
}

struct RenameProjectSheet: View {
    @Binding var name: String
    @Environment(\.dismiss) private var dismiss
    var onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Rename Project").font(.headline)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { confirm() }
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Rename") { confirm() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }

    private func confirm() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onConfirm()
        dismiss()
    }
}

#if DEBUG
#Preview {
    ProjectListView()
        .environment(AppState())
        .environment(WindowState())
        .frame(width: 280, height: 700)
}
#endif
