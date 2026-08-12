import Testing
@testable import ClarcCore

@Suite("git status porcelain v1 -z parser")
struct GitPorcelainEntryTests {
    @Test("Parses staged, unstaged and untracked paths with spaces")
    func ordinaryEntries() {
        let output = "M  staged file.swift\0 M unstaged file.swift\0?? new file.txt\0"

        let entries = parseGitStatusPorcelainV1Z(output)

        #expect(entries.count == 3)
        #expect(entries[0].path == "staged file.swift")
        #expect(entries[0].isStaged)
        #expect(!entries[0].isUnstaged)
        #expect(entries[0].kind == .modified)
        #expect(entries[1].path == "unstaged file.swift")
        #expect(!entries[1].isStaged)
        #expect(entries[1].isUnstaged)
        #expect(entries[2].path == "new file.txt")
        #expect(entries[2].isUntracked)
        #expect(entries[2].kind == .untracked)
    }

    @Test("Rename keeps verbatim destination and original path")
    func renameEntry() {
        let output = "R  destination name.swift\0source name.swift\0"

        let entries = parseGitStatusPorcelainV1Z(output)

        #expect(entries.count == 1)
        #expect(entries[0].path == "destination name.swift")
        #expect(entries[0].originalPath == "source name.swift")
        #expect(entries[0].kind == .renamed)
        #expect(entries[0].isStaged)
    }

    @Test("NUL format preserves newlines and skips ignored entries")
    func unusualPathsAndIgnored() {
        let output = " M folder/line\nbreak.swift\0!! ignored.cache\0"

        let entries = parseGitStatusPorcelainV1Z(output)

        #expect(entries.count == 1)
        #expect(entries[0].path == "folder/line\nbreak.swift")
    }

    @Test("Recognizes conflicts, deletes, adds, copies and type changes")
    func kinds() {
        let output = "UU conflict.swift\0 D deleted.swift\0A  added.swift\0C  copy.swift\0original.swift\0 T type.swift\0"

        let entries = parseGitStatusPorcelainV1Z(output)

        #expect(entries.map(\.kind) == [.conflicted, .deleted, .added, .copied, .typeChanged])
        #expect(entries[3].originalPath == "original.swift")
    }

    @Test("Malformed and empty records are ignored safely")
    func malformedRecords() {
        let output = "M\0bad record\0\0"

        #expect(parseGitStatusPorcelainV1Z(output).isEmpty)
    }
}
