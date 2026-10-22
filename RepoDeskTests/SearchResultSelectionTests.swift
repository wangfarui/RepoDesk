import Testing
@testable import RepoDesk

struct SearchResultSelectionTests {
    @Test func movementStopsAtBothEnds() {
        var selection = SearchResultSelection()

        #expect(selection.moved(by: -1, count: 3) == 0)
        #expect(selection.moved(by: 1, count: 3) == 1)

        selection.index = 2
        #expect(selection.moved(by: 1, count: 3) == 2)
        #expect(selection.moved(by: -1, count: 3) == 1)
    }

    @Test func emptyResultsDoNotMove() {
        let selection = SearchResultSelection()

        #expect(selection.moved(by: 1, count: 0) == nil)
        #expect(selection.moved(by: -1, count: 0) == nil)
    }

    @Test func clampAndResetKeepAValidIndex() {
        var selection = SearchResultSelection(index: 8)

        selection.clamp(toCount: 3)
        #expect(selection.index == 2)

        selection.clamp(toCount: 0)
        #expect(selection.index == 0)

        selection.index = 4
        selection.reset()
        #expect(selection.index == 0)
    }
}
