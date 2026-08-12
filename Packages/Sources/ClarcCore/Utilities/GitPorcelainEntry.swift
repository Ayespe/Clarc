import Foundation

/// One path-level record from `git status --porcelain=v1 -z`.
///
/// The two status columns are kept intact so callers can distinguish staged
/// and unstaged changes. Rename/copy records also retain their original path.
public struct GitPorcelainEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case modified
        case added
        case deleted
        case renamed
        case copied
        case untracked
        case conflicted
        case typeChanged
        case unknown
    }

    public let indexStatus: Character
    public let workTreeStatus: Character
    public let path: String
    public let originalPath: String?

    public var id: String {
        "\(indexStatus)\(workTreeStatus):\(originalPath ?? "")->\(path)"
    }

    public var isUntracked: Bool {
        indexStatus == "?" && workTreeStatus == "?"
    }

    public var isStaged: Bool {
        !isUntracked && indexStatus != " " && indexStatus != "!"
    }

    public var isUnstaged: Bool {
        !isUntracked && workTreeStatus != " " && workTreeStatus != "!"
    }

    public var kind: Kind {
        if isUntracked { return .untracked }

        let pair = String([indexStatus, workTreeStatus])
        let conflictPairs: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        if conflictPairs.contains(pair) || indexStatus == "U" || workTreeStatus == "U" {
            return .conflicted
        }
        if indexStatus == "R" || workTreeStatus == "R" { return .renamed }
        if indexStatus == "C" || workTreeStatus == "C" { return .copied }
        if indexStatus == "D" || workTreeStatus == "D" { return .deleted }
        if indexStatus == "A" || workTreeStatus == "A" { return .added }
        if indexStatus == "T" || workTreeStatus == "T" { return .typeChanged }
        if indexStatus == "M" || workTreeStatus == "M" { return .modified }
        return .unknown
    }

    public init(
        indexStatus: Character,
        workTreeStatus: Character,
        path: String,
        originalPath: String? = nil
    ) {
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.path = path
        self.originalPath = originalPath
    }
}

/// Parse NUL-delimited porcelain v1 output without interpreting path quoting.
/// With `-z`, paths are emitted verbatim, including spaces and newlines. Git
/// emits rename/copy destinations in the main record followed by the original
/// path as the next NUL-delimited field.
public func parseGitStatusPorcelainV1Z(_ output: String) -> [GitPorcelainEntry] {
    let fields = output.split(separator: "\0", omittingEmptySubsequences: true)
    var entries: [GitPorcelainEntry] = []
    var index = 0

    while index < fields.count {
        let record = String(fields[index])
        index += 1

        guard record.count >= 3 else { continue }
        let first = record.startIndex
        let second = record.index(after: first)
        let separator = record.index(after: second)
        guard record[separator] == " " else { continue }

        let indexStatus = record[first]
        let workTreeStatus = record[second]
        let path = String(record[record.index(after: separator)...])
        guard !path.isEmpty else { continue }

        // `!!` appears only when callers explicitly request ignored files. Be
        // defensive and omit it from a changes list.
        if indexStatus == "!" && workTreeStatus == "!" { continue }

        let carriesOriginalPath = indexStatus == "R" || indexStatus == "C"
            || workTreeStatus == "R" || workTreeStatus == "C"
        var originalPath: String?
        if carriesOriginalPath, index < fields.count {
            originalPath = String(fields[index])
            index += 1
        }

        entries.append(GitPorcelainEntry(
            indexStatus: indexStatus,
            workTreeStatus: workTreeStatus,
            path: path,
            originalPath: originalPath
        ))
    }

    return entries
}
