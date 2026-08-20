import Foundation

enum GitDiffParser {
    static func parseHunks(_ patch: String) -> [GitDiffHunk] {
        var hunks: [GitDiffHunk] = []
        var currentHeader: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)?
        var currentLines: [GitPatchLine] = []

        func finishCurrentHunk() {
            guard let header = currentHeader else { return }
            hunks.append(
                GitDiffHunk(
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    lines: currentLines
                )
            )
            currentHeader = nil
            currentLines = []
        }

        let normalizedPatch = normalizeLineEndings(in: patch)
        for rawLine in normalizedPatch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@ "), let header = parseHeader(line) {
                finishCurrentHunk()
                currentHeader = header
                continue
            }
            guard currentHeader != nil, let prefix = line.first else { continue }
            switch prefix {
            case " ":
                currentLines.append(GitPatchLine(kind: .context, text: String(line.dropFirst())))
            case "-":
                currentLines.append(GitPatchLine(kind: .deletion, text: String(line.dropFirst())))
            case "+":
                currentLines.append(GitPatchLine(kind: .addition, text: String(line.dropFirst())))
            case "\\":
                continue
            default:
                continue
            }
        }
        finishCurrentHunk()
        return hunks
    }

    static func lines(from data: Data?) -> [String] {
        guard let data, !data.isEmpty else { return [] }
        var text = normalizeLineEndings(in: String(decoding: data, as: UTF8.self))
        if text.hasSuffix("\n") {
            text.removeLast()
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func normalizeLineEndings(in text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func parseHeader(
        _ line: String
    ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
              ) else { return nil }
        let text = line as NSString
        func integer(at index: Int, default defaultValue: Int) -> Int {
            let range = match.range(at: index)
            return range.location == NSNotFound ? defaultValue : (Int(text.substring(with: range)) ?? defaultValue)
        }
        return (
            oldStart: integer(at: 1, default: 0),
            oldCount: integer(at: 2, default: 1),
            newStart: integer(at: 3, default: 0),
            newCount: integer(at: 4, default: 1)
        )
    }
}
