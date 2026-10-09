import Foundation
import Testing
@testable import RepoDesk

struct GitConflictParserTests {
    @Test func ancestorIsScopedToEachConflictInALongFile() {
        let tail = String(repeating: "dependency\n", count: 500)
        let base = "before\nbase-one\nmiddle\nbase-two\nafter\n" + tail
        let text = "before\n<<<<<<< HEAD\nours-one\n=======\ntheirs-one\n>>>>>>> master\nmiddle\n<<<<<<< HEAD\nours-two\n=======\ntheirs-two\n>>>>>>> master\nafter\n" + tail
        let document = GitConflictResolutionDocument(text: text, base: base)

        #expect(document.blocks.map(\.base) == ["base-one\n", "base-two\n"])
        #expect(document.renderedText() == text)
    }

    @Test func diff3AncestorIsPreservedWithoutLeakingIntoEitherSide() {
        let text = "<<<<<<< HEAD\nours\n||||||| ancestor\nbase\n=======\ntheirs\n>>>>>>> master\n"
        let document = GitConflictResolutionDocument(text: text, base: "whole file\n")

        #expect(document.blocks.first?.ours == "ours\n")
        #expect(document.blocks.first?.base == "base\n")
        #expect(document.blocks.first?.theirs == "theirs\n")
        #expect(GitConflictParser.resolving(0, in: text, with: .theirs) == "theirs\n")
    }

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

    @Test func conflictFilePreservesMissingStagesAndBinaryState() {
        let binary = Data([0x00, 0xFF])
        let file = GitConflictFile(
            path: "generated.bin",
            ours: "",
            theirs: "",
            result: "",
            isResolved: false,
            theirsData: binary,
            hasBase: false,
            hasOurs: false,
            hasTheirs: true,
            isBinary: true
        )

        #expect(file.base == nil)
        #expect(!file.hasBase)
        #expect(!file.hasOurs)
        #expect(file.hasTheirs)
        #expect(file.isBinary)
        #expect(file.theirsData == binary)
    }
}
