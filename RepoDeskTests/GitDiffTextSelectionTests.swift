import CoreGraphics
import Foundation
import Testing
@testable import RepoDesk

struct GitDiffTextSelectionTests {
    @Test func copiedTextContainsOnlyCodeRowsAndPreservesLineBreaks() {
        let model = GitDiffSelectableTextModel(rows: [
            GitDiffSelectableTextRow(text: "let first = 1"),
            GitDiffSelectableTextRow(text: ""),
            GitDiffSelectableTextRow(text: "let third = 3")
        ])

        let copiedText = model.copiedText(in: NSRange(
            location: 0,
            length: (model.storageText as NSString).length
        ))

        #expect(copiedText == "let first = 1\n\nlet third = 3")
        #expect(!copiedText.contains(GitDiffSelectableTextModel.emptyLineMarker))

        let emptyLineModel = GitDiffSelectableTextModel(rows: [
            GitDiffSelectableTextRow(text: "")
        ])
        #expect(emptyLineModel.copiedText(in: NSRange(location: 0, length: 1)) == "")

        let sourceMarkerModel = GitDiffSelectableTextModel(rows: [
            GitDiffSelectableTextRow(
                text: "before\(GitDiffSelectableTextModel.emptyLineMarker)after"
            )
        ])
        #expect(sourceMarkerModel.copiedText(in: NSRange(
            location: 0,
            length: (sourceMarkerModel.storageText as NSString).length
        )) == "before\(GitDiffSelectableTextModel.emptyLineMarker)after")
    }

    @Test func verticalHitTestingDistinguishesCodeAndCollapsedGapRows() {
        let codeRow = GitDiffSelectableTextRow(
            text: "before",
            selectedLine: 8
        )
        let gapRow = GitDiffSelectableTextRow(
            text: "",
            height: 25,
            gapID: "gap-1"
        )
        let trailingRow = GitDiffSelectableTextRow(
            text: "after",
            selectedLine: 20
        )
        let model = GitDiffSelectableTextModel(rows: [codeRow, gapRow, trailingRow])

        #expect(model.row(atVerticalOffset: 10) == codeRow)
        #expect(model.row(atVerticalOffset: 30) == gapRow)
        #expect(model.row(atVerticalOffset: 50) == trailingRow)
        #expect(model.row(atVerticalOffset: 80) == nil)
    }

    @Test func searchRangesStayAlignedAfterEmptyRows() {
        let query = "queryInventoryGoodsPurchaseCost"
        let model = GitDiffSelectableTextModel(rows: [
            GitDiffSelectableTextRow(text: "before"),
            GitDiffSelectableTextRow(text: ""),
            GitDiffSelectableTextRow(text: "public func \(query)()")
        ])

        let match = model.searchMatches(
            query: query,
            options: ContentSearchOptions()
        ).first
        let matchedText = match.map {
            (model.storageText as NSString).substring(with: $0.range)
        }

        #expect(matchedText == query)
    }
}
