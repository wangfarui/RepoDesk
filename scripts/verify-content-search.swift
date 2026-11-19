import Foundation

private struct ContentSearchVerificationError: Error {
    let message: String
}

@main
enum ContentSearchVerification {
    static func main() throws {
        let text = "cat Cat catapult\r\n_cat cat_ cat"
        let insensitive = ContentSearchMatcher.matches(
            in: text,
            query: "cat",
            options: ContentSearchOptions()
        )
        try require(insensitive.count == 6, "Case-insensitive search lost matches.")

        let caseSensitive = ContentSearchMatcher.matches(
            in: text,
            query: "Cat",
            options: ContentSearchOptions(matchesCase: true)
        )
        try require(caseSensitive.map(\.range.location) == [4], "Match Case was not enforced.")

        let wholeWords = ContentSearchMatcher.matches(
            in: text,
            query: "cat",
            options: ContentSearchOptions(matchesWholeWords: true)
        )
        try require(
            wholeWords.map(\.range.location) == [0, 4, 28],
            "Words did not enforce identifier boundaries."
        )

        var navigation = ContentFindState()
        navigation.navigate(by: -1, matchCount: 3)
        try require(navigation.currentMatchIndex == 2, "Previous navigation did not wrap.")
        navigation.navigate(by: 1, matchCount: 3)
        try require(navigation.currentMatchIndex == 0, "Next navigation did not wrap.")

        try verifySearchFromSelection()
        print("Content search verification passed")
    }

    private static func verifySearchFromSelection() throws {
        let text = "😀 中文\r\n中文 中文\r\n"
        let selected = (text as NSString).range(of: "中文", options: .backwards)
        var state = ContentFindState()
        state.query = "previous query"
        state.present(selection: selected, in: text)
        let ranges = state.documentMatchRanges(in: text)
        try require(state.isPresented && state.query == "中文", "Find did not prefill the selected text.")
        try require(ranges.count == 3 && ranges[state.currentMatchIndex] == selected,
                    "Find did not activate the selected UTF-16 occurrence.")
        state.navigate(by: -1, matchCount: ranges.count)
        try require(state.currentMatchIndex == 1, "Previous did not start from the selected occurrence.")
        state.present(selection: selected, in: text)
        try require(state.currentMatchIndex == 2, "Refinding the same query lost the new selection.")
        state.navigate(by: 1, matchCount: ranges.count)
        try require(state.currentMatchIndex == 0, "Next did not wrap from the selected occurrence.")
        state.present(selection: NSRange(location: 0, length: 0), in: text)
        try require(state.query == "中文" && state.currentMatchIndex == 0, "A caret replaced the current query.")
        state.query = "😀"
        try require(state.currentMatchIndex == 0 && state.documentMatchRanges(in: text).count == 1,
                    "Editing the query did not reset the active match.")

        let multiline = "start\r\nend\r\nstart\r\nend"
        let multilineSelection = (multiline as NSString).range(of: "start\r\nend", options: .backwards)
        state.present(selection: multilineSelection, in: multiline)
        let multilineRanges = state.documentMatchRanges(in: multiline)
        try require(state.query == "start\r\nend" && multilineRanges.count == 2
                    && multilineRanges[state.currentMatchIndex] == multilineSelection,
                    "A multiline selection did not keep its original text and position.")

        let overlap = "aaaaaa"
        let overlapSelection = NSRange(location: 1, length: 2)
        state.matchesWholeWords = true
        state.present(selection: overlapSelection, in: overlap)
        try require(!state.matchesWholeWords && state.documentMatchRanges(in: overlap) == [
            overlapSelection, NSRange(location: 3, length: 2)
        ], "An overlapping selection was hidden by another occurrence or whole-word filtering.")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ContentSearchVerificationError(message: message) }
    }
}
