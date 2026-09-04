import Foundation
import Testing
@testable import RepoDesk

struct ContentSearchTests {
    @Test func findsMatchesAcrossLinesAndPreservesDocumentRanges() {
        let text = "Alpha beta\r\nalpha Beta"
        let matches = ContentSearchMatcher.matches(
            in: text,
            query: "alpha",
            options: ContentSearchOptions()
        )

        #expect(matches.map(\.lineIndex) == [0, 1])
        #expect(matches.map(\.range) == [
            NSRange(location: 0, length: 5),
            NSRange(location: 12, length: 5)
        ])
    }

    @Test func supportsMatchCaseAndWholeWordOptions() {
        let text = "cat Cat catapult _cat cat_ cat"

        let caseSensitive = ContentSearchMatcher.matches(
            in: text,
            query: "Cat",
            options: ContentSearchOptions(matchesCase: true)
        )
        #expect(caseSensitive.map(\.range.location) == [4])

        let wholeWords = ContentSearchMatcher.matches(
            in: text,
            query: "cat",
            options: ContentSearchOptions(matchesWholeWords: true)
        )
        #expect(wholeWords.map(\.range.location) == [0, 4, 27])
    }

    @Test func navigationWrapsInBothDirections() {
        var state = ContentFindState()
        state.navigate(by: -1, matchCount: 3)
        #expect(state.currentMatchIndex == 2)
        state.navigate(by: 1, matchCount: 3)
        #expect(state.currentMatchIndex == 0)
        state.navigate(by: 1, matchCount: 3)
        #expect(state.currentMatchIndex == 1)
    }
}
