import Foundation

enum GitConflictParser {
    static func blocks(in text: String) -> [GitConflictBlock] {
        matches(in: text).enumerated().map { index, match in
            GitConflictBlock(
                index: index,
                ours: substring(text, range: match.range(at: 1)),
                theirs: substring(text, range: match.range(at: 2))
            )
        }
    }

    static func resolving(_ blockIndex: Int, in text: String, with side: GitConflictSide) -> String? {
        let matches = matches(in: text)
        guard matches.indices.contains(blockIndex) else { return nil }
        let match = matches[blockIndex]
        let replacementRange = Range(match.range, in: text)
        guard let replacementRange else { return nil }
        let selectedRange = side == .ours ? match.range(at: 1) : match.range(at: 2)
        let replacement = substring(text, range: selectedRange)
        return text.replacingCharacters(in: replacementRange, with: replacement)
    }

    private static func matches(in text: String) -> [NSTextCheckingResult] {
        let pattern = #"^<<<<<<<[^\n]*\n(.*?)(?:^\|\|\|\|\|\|\|[^\n]*\n.*?)*?^=======\n(.*?)^>>>>>>>[^\n]*(?:\n|$)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        ) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func substring(_ text: String, range: NSRange) -> String {
        guard let range = Range(range, in: text) else { return "" }
        return String(text[range])
    }
}
