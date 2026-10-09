import Foundation

struct GitConflictDocumentBlock: Equatable, Identifiable, Sendable {
    let id: Int
    let ours: String
    let theirs: String
    let original: String
    let base: String
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

    init(text: String, base: String?) {
        segments = GitConflictParser.segments(in: text, base: base)
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
        renderedText(overrides: [:])
    }

    func renderedText(overrides: [Int: String]) -> String {
        segments.map { segment in
            switch segment {
            case .unchanged(_, let text):
                text
            case .conflict(let block):
                overrides[block.id] ?? resolutions[block.id] ?? block.original
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
                theirs: substring(text, range: match.range(at: 3))
            )
        }
    }

    static func resolving(_ blockIndex: Int, in text: String, with side: GitConflictSide) -> String? {
        let matches = matches(in: text)
        guard matches.indices.contains(blockIndex) else { return nil }
        let match = matches[blockIndex]
        let replacementRange = Range(match.range, in: text)
        guard let replacementRange else { return nil }
        let selectedRange = side == .ours ? match.range(at: 1) : match.range(at: 3)
        let replacement = substring(text, range: selectedRange)
        return text.replacingCharacters(in: replacementRange, with: replacement)
    }

    static func segments(in text: String, base: String? = nil) -> [GitConflictDocumentSegment] {
        let matches = matches(in: text)
        guard !matches.isEmpty else {
            return text.isEmpty ? [] : [.unchanged(id: 0, text: text)]
        }

        let source = text as NSString
        let ancestorSlices = base.map { baseSlices(in: text, matches: matches, base: $0) }
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
                        theirs: substring(text, range: match.range(at: 3)),
                        original: substring(text, range: match.range),
                        base: match.range(at: 2).location != NSNotFound
                            ? substring(text, range: match.range(at: 2))
                            : ancestorSlices?[blockID] ?? ""
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
        let pattern = #"^<<<<<<<[^\n]*\n(.*?)(?:^\|\|\|\|\|\|\|[^\n]*\n(.*?))?^=======\r?\n(.*?)^>>>>>>>[^\n]*(?:\n|$)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        ) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // Two-way markers omit the ancestor. Align the merged Yours text with stage 1
    // and use the surrounding matching lines to locate each ancestor span.
    private static func baseSlices(
        in text: String,
        matches: [NSTextCheckingResult],
        base: String
    ) -> [String] {
        let source = text as NSString
        var cursor = 0
        var oursLines: [String] = []
        var conflictRanges: [Range<Int>] = []
        for match in matches {
            oursLines += lineChunks(source.substring(with: NSRange(
                location: cursor, length: match.range.location - cursor
            )))
            let start = oursLines.count
            oursLines += lineChunks(substring(text, range: match.range(at: 1)))
            conflictRanges.append(start..<oursLines.count)
            cursor = NSMaxRange(match.range)
        }
        oursLines += lineChunks(source.substring(from: cursor))
        let baseLines = lineChunks(base)
        let difference = baseLines.difference(from: oursLines)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let anchors = Array(zip(
            oursLines.indices.filter { !removed.contains($0) },
            baseLines.indices.filter { !inserted.contains($0) }
        ))
        let ranges = conflictRanges.map { conflict -> Range<Int> in
            let start = anchors.last(where: { $0.0 < conflict.lowerBound })
                .map { $0.1 + 1 } ?? 0
            let end = anchors.first(where: { $0.0 >= conflict.upperBound })
                .map { $0.1 } ?? baseLines.count
            return start..<max(start, end)
        }
        return ranges.enumerated().map { index, range in
            // Without a common anchor, adjacent conflicts cannot be separated
            // reliably. Leave the ancestor empty instead of duplicating it.
            guard !ranges.enumerated().contains(where: {
                $0.offset != index && $0.element.overlaps(range)
            }) else { return "" }
            return baseLines[range].joined()
        }
    }

    private static func lineChunks(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        let trailingNewline = lines.last == ""
        if trailingNewline { lines.removeLast() }
        return lines.enumerated().map { index, line in
            index < lines.count - 1 || trailingNewline ? line + "\n" : line
        }
    }

    private static func substring(_ text: String, range: NSRange) -> String {
        guard let range = Range(range, in: text) else { return "" }
        return String(text[range])
    }
}
