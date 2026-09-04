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
        print("Content search verification passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ContentSearchVerificationError(message: message) }
    }
}
