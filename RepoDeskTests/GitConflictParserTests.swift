import Testing
@testable import RepoDesk

struct GitConflictParserTests {
    @Test func resolutionDocumentPreservesSegmentsAndStableConflictIDs() {
        let source = """
        before
        <<<<<<< HEAD
        ours-one
        =======
        theirs-one
        >>>>>>> feature
        middle
        <<<<<<< HEAD
        ours-two
        =======
        theirs-two
        >>>>>>> feature
        after
        """
        var document = GitConflictResolutionDocument(text: source)

        #expect(document.blocks.map(\.id) == [0, 1])
        #expect(document.unresolvedBlockIDs == [0, 1])
        #expect(document.renderedText() == source)

        document.resolve(0, with: .theirs)

        #expect(document.unresolvedBlockIDs == [1])
        #expect(document.blocks.map(\.id) == [0, 1])
        #expect(document.renderedText().contains("theirs-one\n"))
        #expect(document.renderedText().contains("<<<<<<< HEAD\nours-two"))

        document.resolve(1, with: "custom-two\n")

        #expect(document.isResolved)
        #expect(document.renderedText() == "before\ntheirs-one\nmiddle\ncustom-two\nafter")
    }

    @Test func resolvedConflictCanBeReopenedWithoutLosingOtherResolutions() {
        var document = GitConflictResolutionDocument(text: """
        <<<<<<< HEAD
        left
        =======
        right
        >>>>>>> branch
        """)

        document.resolve(0, with: .ours)
        #expect(document.isResolved)

        document.markUnresolved(0)

        #expect(document.unresolvedBlockIDs == [0])
        #expect(document.renderedText().contains("<<<<<<< HEAD"))
    }

    @Test func textWithoutConflictMarkersIsAlreadyResolved() {
        let document = GitConflictResolutionDocument(text: "plain\ntext\n")

        #expect(document.blocks.isEmpty)
        #expect(document.isResolved)
        #expect(document.renderedText() == "plain\ntext\n")
    }
}
