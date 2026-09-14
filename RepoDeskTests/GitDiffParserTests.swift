import Foundation
import Testing
@testable import RepoDesk

struct GitDiffParserTests {
    @Test func blameIndexToleratesDuplicateFinalLineNumbers() {
        let older = GitBlameLine(
            lineNumber: 85,
            commitHash: "old",
            author: "Old Author",
            authoredAt: nil
        )
        let newer = GitBlameLine(
            lineNumber: 85,
            commitHash: "new",
            author: "New Author",
            authoredAt: nil
        )

        let indexed = [older, newer].indexedByLineNumber

        #expect(indexed.count == 1)
        #expect(indexed[85] == newer)
    }

    @Test func blameParserReadsAuthorDateBoundaryAndUncommittedLines() {
        let data = Data("""
        ^1111111111111111111111111111111111111111 1 1 1
        author Alice
        author-time 1704067200
        filename file.txt
        \tcommitted
        0000000000000000000000000000000000000000 2 2 1
        author Not Committed Yet
        author-time 1704153600
        filename file.txt
        \tuncommitted
        """.utf8)

        let lines = GitBlameParser.parse(data)

        #expect(lines.count == 2)
        #expect(lines[0].lineNumber == 1)
        #expect(lines[0].author == "Alice")
        #expect(lines[0].commitHash == String(repeating: "1", count: 40))
        #expect(lines[0].authoredAt != nil)
        #expect(lines[1].lineNumber == 2)
        #expect(lines[1].author == "未提交")
        #expect(lines[1].isUncommitted)
    }

    @Test func blameParserSeparatesHeadersAfterCRLFContentLines() {
        let data = Data(
            "1111111111111111111111111111111111111111 1 1 1\n"
                .appending("author Alice\n")
                .appending("author-time 1704067200\n")
                .appending("filename file.txt\n")
                .appending("\tfirst\r\n")
                .appending("2222222222222222222222222222222222222222 2 2 1\n")
                .appending("author Bob\n")
                .appending("author-time 1704153600\n")
                .appending("filename file.txt\n")
                .appending("\tsecond\r\n")
                .utf8
        )

        let lines = GitBlameParser.parse(data)

        #expect(lines.map(\.lineNumber) == [1, 2])
        #expect(lines.map(\.author) == ["Alice", "Bob"])
    }

    @Test func parsesOnlyHunkContentAndLineKinds() {
        let patch = """
        diff --git a/Sample.java b/Sample.java
        index 1111111..2222222 100644
        --- a/Sample.java
        +++ b/Sample.java
        @@ -2,3 +2,3 @@
         class Sample {
        -    int value = 1;
        +    int value = 2;
         }
        """

        let hunks = GitDiffParser.parseHunks(patch)

        #expect(hunks.count == 1)
        #expect(hunks[0].oldStart == 2)
        #expect(hunks[0].newStart == 2)
        #expect(hunks[0].lines.map(\.kind) == [.context, .deletion, .addition, .context])
        #expect(!hunks[0].lines.contains(where: { $0.text.hasPrefix("diff --git") }))
        #expect(!hunks[0].lines.contains(where: { $0.text.hasPrefix("@@") }))
    }

    @Test func preservesEmptyLinesAndOptionalHunkCounts() {
        let patch = """
        @@ -1 +1,2 @@
        -old
        +new
        +
        """

        let hunks = GitDiffParser.parseHunks(patch)

        #expect(hunks[0].oldCount == 1)
        #expect(hunks[0].newCount == 2)
        #expect(hunks[0].lines.last?.text == "")
    }

    @Test func normalizesCRLFInFileAndHunkLines() {
        let lines = GitDiffParser.lines(from: Data("first\r\nsecond\r\n".utf8))
        let hunks = GitDiffParser.parseHunks("""
        @@ -1 +1,2 @@
         first\r
        +inserted\r
        """)

        #expect(lines == ["first", "second"])
        #expect(hunks[0].lines.map(\.text) == ["first", "inserted"])
        #expect(hunks[0].lines.map(\.kind) == [.context, .addition])
    }
}
