import Foundation

struct GitConflictDocumentBlock: Equatable, Identifiable, Sendable {
    let id: Int
    let ours: String
    let theirs: String
    let original: String
}

enum GitConflictDocumentSegment: Equatable, Sendable {
    case unchanged(id: Int, text: String)
    case conflict(GitConflictDocumentBlock)
}

struct GitConflictResolutionDocument: Equatable, Sendable {
    let segments: [GitConflictDocumentSegment]
    private(set) var resolutions: [Int: String] = [:]

    init(text: String) {
        segments = GitConflictParser.segments(in: text)
    }

    var blocks: [GitConflictDocumentBlock] {
        segments.compactMap { segment in
            guard case .conflict(let block) = segment else { return nil }
            return block
        }
    }

    var unresolvedBlockIDs: [Int] {
        blocks.map(\.id).filter { resolutions[$0] == nil }
    }

    var isResolved: Bool {
        unresolvedBlockIDs.isEmpty
    }

    func resolution(for blockID: Int) -> String? {
        resolutions[blockID]
    }

    mutating func resolve(_ blockID: Int, with side: GitConflictSide) {
        guard let block = blocks.first(where: { $0.id == blockID }) else { return }
        resolutions[blockID] = side == .ours ? block.ours : block.theirs
    }

    mutating func resolve(_ blockID: Int, with text: String) {
        guard blocks.contains(where: { $0.id == blockID }) else { return }
        resolutions[blockID] = text
    }

    mutating func markUnresolved(_ blockID: Int) {
        resolutions.removeValue(forKey: blockID)
    }

    func renderedText() -> String {
        segments.map { segment in
            switch segment {
            case .unchanged(_, let text):
                text
            case .conflict(let block):
                resolutions[block.id] ?? block.original
            }
        }.joined()
    }
}

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

    static func segments(in text: String) -> [GitConflictDocumentSegment] {
        let matches = matches(in: text)
        guard !matches.isEmpty else {
            return text.isEmpty ? [] : [.unchanged(id: 0, text: text)]
        }

        let source = text as NSString
        var cursor = 0
        var segmentID = 0
        var segments: [GitConflictDocumentSegment] = []
        for (blockID, match) in matches.enumerated() {
            if match.range.location > cursor {
                segments.append(
                    .unchanged(
                        id: segmentID,
                        text: source.substring(
                            with: NSRange(
                                location: cursor,
                                length: match.range.location - cursor
                            )
                        )
                    )
                )
                segmentID += 1
            }
            segments.append(
                .conflict(
                    GitConflictDocumentBlock(
                        id: blockID,
                        ours: substring(text, range: match.range(at: 1)),
                        theirs: substring(text, range: match.range(at: 2)),
                        original: substring(text, range: match.range)
                    )
                )
            )
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length {
            segments.append(
                .unchanged(
                    id: segmentID,
                    text: source.substring(
                        with: NSRange(location: cursor, length: source.length - cursor)
                    )
                )
            )
        }
        return segments
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
