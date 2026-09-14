import AppKit
import Foundation

@main
struct GitDiffSelectionVerification {
    @MainActor
    static func main() {
        let rows = [
            GitDiffSelectableTextRow(text: "let first = 1", selectedLine: 1),
            GitDiffSelectableTextRow(text: "", height: 25, gapID: "gap-1"),
            GitDiffSelectableTextRow(text: "let third = 3", selectedLine: 3)
        ]
        let model = GitDiffSelectableTextModel(rows: rows)
        let fullRange = NSRange(
            location: 0,
            length: (model.storageText as NSString).length
        )

        require(
            model.copiedText(in: fullRange) == "let first = 1\n\nlet third = 3",
            "Diff copy text included a non-code placeholder or lost line breaks."
        )
        let sourceMarkerModel = GitDiffSelectableTextModel(rows: [
            GitDiffSelectableTextRow(
                text: "before\(GitDiffSelectableTextModel.emptyLineMarker)after"
            )
        ])
        require(
            sourceMarkerModel.copiedText(in: NSRange(
                location: 0,
                length: (sourceMarkerModel.storageText as NSString).length
            )) == "before\(GitDiffSelectableTextModel.emptyLineMarker)after",
            "Diff copy removed a zero-width character that belonged to source code."
        )
        require(
            model.row(atVerticalOffset: 30)?.gapID == "gap-1",
            "Collapsed gap hit testing did not preserve its action row."
        )

        let query = "queryInventoryGoodsPurchaseCost"
        let searchModel = GitDiffSelectableTextModel(rows: [
            GitDiffSelectableTextRow(text: "before"),
            GitDiffSelectableTextRow(text: ""),
            GitDiffSelectableTextRow(text: "public func \(query)()")
        ])
        let searchMatch = searchModel.searchMatches(
            query: query,
            options: ContentSearchOptions()
        ).first
        require(
            searchMatch.map {
                (searchModel.storageText as NSString).substring(with: $0.range)
            } == query,
            "Diff search range drifted after an empty selectable row."
        )

        let textView = GitDiffSelectableTextViewSurface(frame: NSRect(
            x: 0,
            y: 0,
            width: 400,
            height: 69
        ))
        textView.configure()
        textView.apply(model)
        require(textView.isSelectable, "Diff text must remain selectable.")
        require(!textView.isEditable, "Diff text must remain read-only.")
        require(
            textView.string == model.storageText,
            "The native selection surface did not load all code rows."
        )

        print("Git diff multi-line selection verification passed")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("Verification failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
