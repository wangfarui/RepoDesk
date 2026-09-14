import Foundation

enum JavaSymbolMatcher {
    static func sorted(
        _ targets: [JavaNavigationTarget],
        query: String
    ) -> [JavaNavigationTarget] {
        let query = query.lowercased()
        return targets.sorted { lhs, rhs in
            let lhsScore = score(lhs.name, query: query)
            let rhsScore = score(rhs.name, query: query)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func score(_ candidate: String, query: String) -> Int {
        let candidateLower = candidate.lowercased()
        if candidateLower == query { return 10_000 }
        if candidateLower.hasPrefix(query) { return 8_000 - candidate.count }
        if candidateLower.contains(query) { return 6_000 - candidate.count }
        let capitals = String(candidate.filter(\.isUppercase)).lowercased()
        if capitals.hasPrefix(query) { return 4_000 - candidate.count }
        var queryIndex = query.startIndex
        for character in candidateLower where queryIndex < query.endIndex {
            if character == query[queryIndex] {
                queryIndex = query.index(after: queryIndex)
            }
        }
        return queryIndex == query.endIndex ? 2_000 - candidate.count : 0
    }
}
