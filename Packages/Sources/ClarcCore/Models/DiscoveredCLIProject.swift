import Foundation

/// A workspace recovered from Claude Code's on-disk session index.
///
/// `cwd` is read from JSONL records instead of reverse-decoding the lossy
/// directory name used under `~/.claude/projects`.
public struct DiscoveredCLIProject: Sendable, Equatable {
    public let cwd: String
    public let cliDirectory: URL
    public let latestActivityAt: Date?

    public init(cwd: String, cliDirectory: URL, latestActivityAt: Date?) {
        self.cwd = cwd
        self.cliDirectory = cliDirectory
        self.latestActivityAt = latestActivityAt
    }
}
