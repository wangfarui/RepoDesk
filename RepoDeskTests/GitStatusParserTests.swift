import Foundation
import Testing
@testable import RepoDesk

struct GitStatusParserTests {
    @Test func parsesBranchCountsAndChangeKinds() {
        let fixture = [
            "# branch.head feature/status",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 abcdef abcdef Sources/App.swift",
            "1 M. N... 100644 100644 100644 abcdef abcdef staged file.md",
            "? new file.txt"
        ].joined(separator: "\0") + "\0"

        let status = GitStatusParser.parse(Data(fixture.utf8))

        #expect(status.branch == "feature/status")
        #expect(status.aheadCount == 2)
        #expect(status.behindCount == 1)
        #expect(status.changes.count == 3)
        #expect(status.changes[0].isUnstaged)
        #expect(status.changes[1].isStaged)
        #expect(status.changes[1].path == "staged file.md")
        #expect(status.changes[2].isUntracked)
    }

    @Test func parsesRenameOriginalPathAndConflict() {
        let fixture = [
            "2 R. N... 100644 100644 100644 abcdef abcdef R100 new name.swift",
            "old name.swift",
            "u UU N... 100644 100644 100644 100644 abcdef abcdef abcdef conflict.txt"
        ].joined(separator: "\0") + "\0"

        let status = GitStatusParser.parse(Data(fixture.utf8))

        #expect(status.changes[0].path == "new name.swift")
        #expect(status.changes[0].originalPath == "old name.swift")
        #expect(status.changes[0].indexStatus == .renamed)
        #expect(status.changes[1].isConflicted)
    }

    @Test func parsesCopyDetachedHeadAndSpecialFileNames() {
        let fixture = [
            "# branch.head (detached)",
            "2 C. N... 100644 100644 100644 abcdef abcdef C100 copied name.swift",
            "source name.swift",
            "1 .M N... 100644 100644 100644 abcdef abcdef tabs\tand spaces.txt",
            "? line\nbreak.txt"
        ].joined(separator: "\0") + "\0"

        let status = GitStatusParser.parse(Data(fixture.utf8))

        #expect(status.isDetachedHEAD)
        #expect(status.branch == "Detached HEAD")
        #expect(status.changes[0].indexStatus == .copied)
        #expect(status.changes[0].originalPath == "source name.swift")
        #expect(status.changes[0].path == "copied name.swift")
        #expect(status.changes[1].path == "tabs\tand spaces.txt")
        #expect(status.changes[2].path == "line\nbreak.txt")
    }
}
