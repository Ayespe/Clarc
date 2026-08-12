import SwiftUI
import ClarcCore

/// View that visually shows the Git status of the project.
struct GitStatusView: View {
    let projectPath: String
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var gitStatus: GitStatusInfo = .loading
    @State private var refreshTask: Task<Void, Never>?
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [RemoteBranch] = []
    @State private var headWatcher: (any DispatchSourceFileSystemObject)?
    @State private var showChangesPopover = false
    @State private var changesPage: ChangesPage = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch gitStatus {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Checking...")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Spacer()
                }

            case .notARepo:
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text("Not a Git repository")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Spacer()
                }

            case .clean(let branch):
                // First row: branch button + refresh
                HStack(spacing: 8) {
                    branchMenu(branch)
                    Spacer()
                    refreshButton
                }
                // Second row: status
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                    Text("No changes")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }

            case .dirty(let branch, let changes, let entries):
                // First row: branch button + refresh
                HStack(spacing: 8) {
                    branchMenu(branch)
                    Spacer()
                    refreshButton
                }
                // Second row: change status + badges
                Button {
                    showChangesPopover.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ClaudeTheme.accent)
                            .frame(width: 6, height: 6)
                        Text("\(changes.total) changed")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.accent)

                        if changes.modified > 0 {
                            badge("M \(changes.modified)", color: .blue)
                        }
                        if changes.added > 0 {
                            badge("A \(changes.added)", color: ClaudeTheme.statusSuccess)
                        }
                        if changes.deleted > 0 {
                            badge("D \(changes.deleted)", color: ClaudeTheme.statusError)
                        }

                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .help("Review changes")
                .popover(isPresented: $showChangesPopover, arrowEdge: .bottom) {
                    changesPopover(entries: entries)
                }

            case .error:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text("Failed to check status")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Spacer()
                    refreshButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.5))
        .onAppear {
            refresh()
            startWatchingHEAD()
        }
        .onDisappear {
            stopWatchingHEAD()
        }
        .onChange(of: projectPath) { _, _ in
            // Refresh status directly here: relying on .task(id:) alone misses the
            // refresh when selectProject batches its mutations into a single
            // transaction, leaving the previous project's git status on screen.
            refresh()
            // Enqueue stop/start on the next run loop tick — keeps the watcher lifecycle
            // out of the selectProject first-frame critical path.
            Task { @MainActor in
                stopWatchingHEAD()
                startWatchingHEAD()
            }
        }
        .onChange(of: appState.isStreaming(in: windowState)) { old, new in
            if old && !new { refresh() }
        }
    }

    // MARK: - Refresh Button

    private var refreshButton: some View {
        Button {
            refresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .buttonStyle(.borderless)
        .help("Refresh")
    }

    // MARK: - Branch Menu

    private func branchMenu(_ currentBranch: String) -> some View {
        Menu {
            Section("Local") {
                ForEach(localBranches, id: \.self) { branch in
                    Button {
                        Task {
                            let success = await gitCheckout(branch: branch, at: projectPath)
                            if success { refresh(); loadBranches() }
                        }
                    } label: {
                        HStack {
                            Text(branch)
                            if branch == currentBranch {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(branch == currentBranch)
                }
                if localBranches.isEmpty {
                    Text("No local branches")
                }
            }

            Section("Remote") {
                ForEach(remoteBranches, id: \.self) { branch in
                    remoteBranchButton(branch)
                }
                if remoteBranches.isEmpty {
                    Text("No remote branches")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: ClaudeTheme.size(10)))
                Text(currentBranch)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
            }
            .foregroundStyle(ClaudeTheme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(ClaudeTheme.surfacePrimary.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch Branch")
        .onAppear { loadBranches() }
        .onChange(of: projectPath) { _, _ in loadBranches() }
    }

    private func remoteBranchButton(_ branch: RemoteBranch) -> some View {
        Button {
            Task {
                let success = await gitCheckoutRemote(branch: branch, localBranches: localBranches, at: projectPath)
                if success { refresh(); loadBranches() }
            }
        } label: {
            Text(branch.displayName)
        }
    }

    // MARK: - Branch Loading

    private func loadBranches() {
        Task {
            let result = await fetchGitBranches(at: projectPath)
            localBranches = result.local
            remoteBranches = result.remote
        }
    }

    private var currentBranchName: String? {
        switch gitStatus {
        case .clean(let branch): branch
        case .dirty(let branch, _, _): branch
        default: nil
        }
    }

    // MARK: - Badge

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: ClaudeTheme.size(10)))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Changes Popover

    private enum ChangesPage: String, CaseIterable, Identifiable {
        case all = "All Changes"
        case lastTurn = "Last Turn"

        var id: Self { self }
    }

    private struct TurnTouchedFile: Identifiable {
        let path: String
        let toolName: String
        var id: String { path }
    }

    private func changesPopover(entries: [GitPorcelainEntry]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Changes")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer()

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Picker("", selection: $changesPage) {
                ForEach(ChangesPage.allCases) { page in
                    Text(LocalizedStringKey(page.rawValue)).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ClaudeThemeDivider()

            switch changesPage {
            case .all:
                allChangesList(entries)
            case .lastTurn:
                lastTurnChangesList(gitEntries: entries)
            }
        }
        .frame(width: 420, height: 360)
        .background(ClaudeTheme.background)
    }

    private func allChangesList(_ entries: [GitPorcelainEntry]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    Button {
                        openGitEntry(entry)
                    } label: {
                        gitEntryRow(entry)
                    }
                    .buttonStyle(.plain)

                    if entry.id != entries.last?.id {
                        ClaudeThemeDivider().padding(.leading, 36)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func lastTurnChangesList(gitEntries: [GitPorcelainEntry]) -> some View {
        let files = lastTurnTouchedFiles
        return VStack(spacing: 0) {
            if files.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: ClaudeTheme.size(18)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text("No files touched this turn")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files) { file in
                            let canOpen = canOpenTouchedFile(file, gitEntries: gitEntries)
                            Button {
                                openTouchedFile(file, gitEntries: gitEntries)
                            } label: {
                                touchedFileRow(file)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canOpen)

                            if file.id != files.last?.id {
                                ClaudeThemeDivider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            ClaudeThemeDivider()
            Text("Only files explicitly reported by Claude editing tools are shown.")
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private func gitEntryRow(_ entry: GitPorcelainEntry) -> some View {
        HStack(spacing: 9) {
            Image(systemName: changeIcon(entry.kind))
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(changeColor(entry.kind))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                if let originalPath = entry.originalPath {
                    Text("\(originalPath) → \(entry.path)")
                        .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(entry.path)
                        .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 5) {
                    changeTag(changeLabel(entry.kind), color: changeColor(entry.kind))
                    if entry.isUntracked {
                        changeTag("Untracked", color: ClaudeTheme.statusSuccess)
                    } else {
                        if entry.isStaged { changeTag("Staged", color: ClaudeTheme.accent) }
                        if entry.isUnstaged { changeTag("Unstaged", color: ClaudeTheme.textSecondary) }
                    }
                }
            }

            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func touchedFileRow(_ file: TurnTouchedFile) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayPath(file.path))
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.toolName)
                    .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func changeTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: ClaudeTheme.size(9), weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func changeLabel(_ kind: GitPorcelainEntry.Kind) -> String {
        switch kind {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Added"
        case .conflicted: "Conflict"
        case .typeChanged: "Type Changed"
        case .unknown: "Changed"
        }
    }

    private func changeIcon(_ kind: GitPorcelainEntry.Kind) -> String {
        switch kind {
        case .added, .untracked: "plus.circle"
        case .deleted: "minus.circle"
        case .renamed: "arrow.right.circle"
        case .copied: "doc.on.doc"
        case .conflicted: "exclamationmark.triangle"
        case .modified, .typeChanged, .unknown: "pencil.circle"
        }
    }

    private func changeColor(_ kind: GitPorcelainEntry.Kind) -> Color {
        switch kind {
        case .added, .untracked: ClaudeTheme.statusSuccess
        case .deleted, .conflicted: ClaudeTheme.statusError
        case .renamed, .copied: ClaudeTheme.accent
        case .modified, .typeChanged, .unknown: .blue
        }
    }

    private var lastTurnTouchedFiles: [TurnTouchedFile] {
        let messages = appState.streamState(in: windowState).allMessages
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else { return [] }

        let supportedTools: Set<String> = ["edit", "write", "multiedit", "notebookedit"]
        var filesByPath: [String: TurnTouchedFile] = [:]

        for message in messages[messages.index(after: lastUserIndex)...] {
            for toolCall in message.toolCalls {
                let normalizedName = toolCall.name
                    .lowercased()
                    .replacingOccurrences(of: "_", with: "")
                guard supportedTools.contains(normalizedName),
                      toolCall.result != nil,
                      !toolCall.isError,
                      let rawPath = toolPath(from: toolCall),
                      !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                let path = absolutePath(rawPath)
                filesByPath[path] = TurnTouchedFile(path: path, toolName: toolCall.name)
            }
        }

        return filesByPath.values.sorted {
            displayPath($0.path).localizedStandardCompare(displayPath($1.path)) == .orderedAscending
        }
    }

    private func toolPath(from toolCall: ToolCall) -> String? {
        let keys = ["file_path", "notebook_path", "path"]
        return keys.lazy.compactMap { toolCall.input[$0]?.stringValue }.first
    }

    private func absolutePath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return (expanded as NSString).standardizingPath
        }
        return (URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent(expanded).path as NSString).standardizingPath
    }

    private func displayPath(_ absolutePath: String) -> String {
        let root = (projectPath as NSString).standardizingPath
        let path = (absolutePath as NSString).standardizingPath
        if path == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return path
    }

    private func absoluteGitPath(_ entry: GitPorcelainEntry) -> String {
        (URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent(entry.path).path as NSString).standardizingPath
    }

    private func openGitEntry(_ entry: GitPorcelainEntry) {
        let path = absoluteGitPath(entry)
        let preview = PreviewFile(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
        if entry.isUntracked {
            windowState.inspectorFile = preview
        } else {
            windowState.diffFile = preview
        }
        showChangesPopover = false
    }

    private func matchingGitEntry(for file: TurnTouchedFile, in entries: [GitPorcelainEntry]) -> GitPorcelainEntry? {
        entries.first { absoluteGitPath($0) == file.path }
    }

    private func canOpenTouchedFile(_ file: TurnTouchedFile, gitEntries: [GitPorcelainEntry]) -> Bool {
        matchingGitEntry(for: file, in: gitEntries) != nil
            || FileManager.default.fileExists(atPath: file.path)
    }

    private func openTouchedFile(_ file: TurnTouchedFile, gitEntries: [GitPorcelainEntry]) {
        let preview = PreviewFile(path: file.path, name: URL(fileURLWithPath: file.path).lastPathComponent)
        if let entry = matchingGitEntry(for: file, in: gitEntries), !entry.isUntracked {
            windowState.diffFile = preview
        } else if FileManager.default.fileExists(atPath: file.path) {
            windowState.inspectorFile = preview
        } else {
            return
        }
        showChangesPopover = false
    }

    // MARK: - HEAD Watcher

    private func startWatchingHEAD() {
        let headPath = projectPath + "/.git/HEAD"
        let fd = open(headPath, O_EVTONLY)
        guard fd != -1 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak source] in
            let data = source?.data ?? []
            refresh()
            if !data.intersection([.delete, .rename]).isEmpty {
                stopWatchingHEAD()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    startWatchingHEAD()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        headWatcher = source
    }

    private func stopWatchingHEAD() {
        headWatcher?.cancel()
        headWatcher = nil
    }

    // MARK: - Refresh

    private func refresh() {
        refreshTask?.cancel()
        let path = projectPath
        refreshTask = Task {
            let fresh = await fetchGitStatus(at: path)
            guard !Task.isCancelled else { return }
            gitStatus = fresh
        }
    }
}

// MARK: - Git Status Model

enum GitStatusInfo: Sendable {
    case loading
    case notARepo
    case clean(branch: String)
    case dirty(branch: String, changes: ChangeCount, entries: [GitPorcelainEntry])
    case error

    struct ChangeCount: Sendable {
        let modified: Int
        let added: Int
        let deleted: Int
        var total: Int { modified + added + deleted }

        init(entries: [GitPorcelainEntry]) {
            var modified = 0
            var added = 0
            var deleted = 0
            for entry in entries {
                switch entry.kind {
                case .added, .untracked:
                    added += 1
                case .deleted:
                    deleted += 1
                default:
                    modified += 1
                }
            }
            self.modified = modified
            self.added = added
            self.deleted = deleted
        }
    }
}

// MARK: - Git Status Fetcher

private func fetchGitStatus(at path: String) async -> GitStatusInfo {
    // Run both git calls in parallel — saves the slower one's wait time (~100-250ms)
    async let branchResult = GitHelper.run(["rev-parse", "--abbrev-ref", "HEAD"], at: path)
    async let statusResult = GitHelper.run([
        "status", "--porcelain=v1", "-z", "--untracked-files=all",
    ], at: path)
    let (b, s) = await (branchResult, statusResult)

    guard let branchRaw = b, !branchRaw.isEmpty else { return .notARepo }
    guard let statusRaw = s else { return .error }

    let branch = branchRaw.trimmingCharacters(in: .whitespacesAndNewlines)

    let entries = parseGitStatusPorcelainV1Z(statusRaw)
    if entries.isEmpty {
        return .clean(branch: branch)
    }

    return .dirty(
        branch: branch,
        changes: .init(entries: entries),
        entries: entries
    )
}

// MARK: - Git Branch List

struct BranchList {
    var local: [String] = []
    var remote: [RemoteBranch] = []
}

struct RemoteBranch: Hashable, Sendable {
    let remote: String
    let name: String

    var refName: String { "\(remote)/\(name)" }
    var displayName: String { refName }
}

private func fetchGitBranches(at path: String) async -> BranchList {
    guard let result = await GitHelper.run([
        "for-each-ref",
        "--format=%(refname)",
        "refs/heads",
        "refs/remotes"
    ], at: path) else {
        return BranchList()
    }

    var local: [String] = []
    var remote: [RemoteBranch] = []

    for line in result.components(separatedBy: "\n") {
        let refName = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refName.isEmpty else { continue }
        guard !refName.hasSuffix("/HEAD") else { continue }

        if refName.hasPrefix("refs/heads/") {
            local.append(String(refName.dropFirst("refs/heads/".count)))
        } else if refName.hasPrefix("refs/remotes/") {
            let remoteRef = String(refName.dropFirst("refs/remotes/".count))
            guard let slashIndex = remoteRef.firstIndex(of: "/") else { continue }
            let remoteName = String(remoteRef[..<slashIndex])
            let branchName = String(remoteRef[remoteRef.index(after: slashIndex)...])
            remote.append(RemoteBranch(remote: remoteName, name: branchName))
        }
    }

    return BranchList(
        local: local.sorted(),
        remote: remote.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    )
}

// MARK: - Git Checkout

private func gitCheckout(branch: String, at path: String) async -> Bool {
    await GitHelper.run(["switch", branch], at: path) != nil
}

private func gitCheckoutRemote(branch: RemoteBranch, localBranches: [String], at path: String) async -> Bool {
    if localBranches.contains(branch.name) {
        guard await GitHelper.run(["switch", branch.name], at: path) != nil else {
            return false
        }
        _ = await GitHelper.run(["branch", "--set-upstream-to", branch.refName, branch.name], at: path)
        return true
    }

    return await GitHelper.run(["switch", "--track", "-c", branch.name, branch.refName], at: path) != nil
}


#Preview {
    VStack(spacing: 0) {
        GitStatusView(projectPath: "/Users/jmlee/workspace/Clarc")
    }
    .frame(width: 400)
}
