import Testing
@testable import RepoDesk

struct FuzzySearchTests {
    @Test func substringMatchesRankBeforeOrderedSubsequences() {
        let values = ["my-application-internal", "origin/main", "maintenance"]

        let result = FuzzySearch.filteredAndSorted(values, query: "main") { $0 }

        #expect(result == ["maintenance", "origin/main", "my-application-internal"])
    }

    @Test func exactAndPrefixMatchesRankAheadOfOtherSubstrings() {
        let values = ["origin/main", "main-feature", "main"]

        let result = FuzzySearch.filteredAndSorted(values, query: "main") { $0 }

        #expect(result == ["main", "main-feature", "origin/main"])
    }

    @Test func orderedSubsequenceSupportsBranchAbbreviations() {
        let values = ["feature/payment-service", "feature/profile", "release/payment"]

        let result = FuzzySearch.filteredAndSorted(values, query: "fps") { $0 }

        #expect(result == ["feature/payment-service"])
    }

    @Test func matchingIsCaseAndDiacriticInsensitive() {
        #expect(FuzzySearch.matches("José García", query: "jose"))
        #expect(FuzzySearch.matches("Feature/Login", query: "flg"))
        #expect(!FuzzySearch.matches("Feature/Login", query: "xyz"))
    }

    @Test func emptyQueryPreservesOriginalOrder() {
        let values = ["zeta", "alpha", "main"]

        let result = FuzzySearch.filteredAndSorted(values, query: "   ") { $0 }

        #expect(result == values)
    }
}
