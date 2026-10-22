import Foundation
@testable import RepoDesk

private struct SearchResultSelectionVerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
enum VerifySearchResultSelection {
    static func main() throws {
        var selection = SearchResultSelection()
        try expect(selection.moved(by: -1, count: 3) == 0, "Up from the first result moved away")
        try expect(selection.moved(by: 1, count: 3) == 1, "Down did not select the next result")
        selection.index = 2
        try expect(selection.moved(by: 1, count: 3) == 2, "Down from the last result wrapped")
        try expect(selection.moved(by: -1, count: 3) == 1, "Up did not select the previous result")
        try expect(selection.moved(by: 1, count: 0) == nil, "Empty results still moved")

        selection.index = 8
        selection.clamp(toCount: 3)
        try expect(selection.index == 2, "Clamp left the selection outside the results")
        selection.clamp(toCount: 0)
        try expect(selection.index == 0, "Empty results left a stale selection")
        selection.index = 4
        selection.reset()
        try expect(selection.index == 0, "Reset did not return to the first result")
        print("Search result selection verification passed")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SearchResultSelectionVerificationError(message: message) }
    }
}
