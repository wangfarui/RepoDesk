import Foundation

enum FuzzySearch {
    static func filteredAndSorted<Element>(
        _ elements: [Element],
        query: String,
        text: (Element) -> String
    ) -> [Element] {
        let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedQuery.isEmpty else { return elements }

        return elements.enumerated()
            .compactMap { index, element -> RankedElement<Element>? in
                guard let score = score(candidate: text(element), normalizedQuery: normalizedQuery) else {
                    return nil
                }
                return RankedElement(element: element, score: score, originalIndex: index)
            }
            .sorted {
                if $0.score != $1.score { return $0.score < $1.score }
                return $0.originalIndex < $1.originalIndex
            }
            .map(\.element)
    }

    static func matches(_ candidate: String, query: String) -> Bool {
        let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedQuery.isEmpty else { return true }
        return score(candidate: candidate, normalizedQuery: normalizedQuery) != nil
    }

    private static func score(candidate: String, normalizedQuery: String) -> MatchScore? {
        let normalizedCandidate = normalize(candidate)
        if normalizedCandidate == normalizedQuery {
            return MatchScore(kind: .exact, start: 0, span: normalizedCandidate.count)
        }

        if normalizedCandidate.hasPrefix(normalizedQuery) {
            return MatchScore(kind: .prefix, start: 0, span: normalizedQuery.count)
        }

        if let range = normalizedCandidate.range(of: normalizedQuery) {
            let start = normalizedCandidate.distance(from: normalizedCandidate.startIndex, to: range.lowerBound)
            return MatchScore(kind: .substring, start: start, span: normalizedQuery.count)
        }

        let candidateCharacters = Array(normalizedCandidate)
        let queryCharacters = Array(normalizedQuery)
        guard let firstQueryCharacter = queryCharacters.first else { return nil }

        var bestScore: MatchScore?
        for start in candidateCharacters.indices where candidateCharacters[start] == firstQueryCharacter {
            var candidateIndex = start + 1
            var lastMatch = start
            var matched = true

            for queryCharacter in queryCharacters.dropFirst() {
                while candidateIndex < candidateCharacters.count,
                      candidateCharacters[candidateIndex] != queryCharacter {
                    candidateIndex += 1
                }
                guard candidateIndex < candidateCharacters.count else {
                    matched = false
                    break
                }
                lastMatch = candidateIndex
                candidateIndex += 1
            }

            guard matched else { continue }
            let score = MatchScore(kind: .subsequence, start: start, span: lastMatch - start + 1)
            if let currentBestScore = bestScore {
                if score < currentBestScore { bestScore = score }
            } else {
                bestScore = score
            }
        }
        return bestScore
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private struct RankedElement<Element> {
    let element: Element
    let score: MatchScore
    let originalIndex: Int
}

private struct MatchScore: Comparable {
    let kind: MatchKind
    let start: Int
    let span: Int

    static func < (lhs: MatchScore, rhs: MatchScore) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.span != rhs.span { return lhs.span < rhs.span }
        return lhs.start < rhs.start
    }
}

private enum MatchKind: Int, Comparable {
    case exact
    case prefix
    case substring
    case subsequence

    static func < (lhs: MatchKind, rhs: MatchKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
