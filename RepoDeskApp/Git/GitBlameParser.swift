import Foundation

enum GitBlameParser {
    static func parse(_ data: Data) -> [GitBlameLine] {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var result: [GitBlameLine] = []
        var hash = ""
        var finalLine = 0
        var author = ""
        var authoredAt: Date?

        for lineValue in lines {
            let line = String(lineValue)
            if let header = parseHeader(line) {
                hash = header.hash
                finalLine = header.finalLine
                author = ""
                authoredAt = nil
            } else if line.hasPrefix("author ") {
                let value = String(line.dropFirst("author ".count))
                author = value == "Not Committed Yet" ? "未提交" : value
            } else if line.hasPrefix("author-time ") {
                if let seconds = TimeInterval(line.dropFirst("author-time ".count)) {
                    authoredAt = Date(timeIntervalSince1970: seconds)
                }
            } else if line.hasPrefix("\t"), finalLine > 0 {
                result.append(
                    GitBlameLine(
                        lineNumber: finalLine,
                        commitHash: hash,
                        author: author.isEmpty ? "未提交" : author,
                        authoredAt: authoredAt
                    )
                )
            }
        }
        return result
    }

    private static func parseHeader(_ line: String) -> (hash: String, finalLine: Int)? {
        let fields = line.split(separator: " ")
        guard fields.count >= 3 else { return nil }
        let rawHash = fields[0].first == "^" ? fields[0].dropFirst() : fields[0][...]
        guard rawHash.count == 40,
              rawHash.allSatisfy(\.isHexDigit),
              let finalLine = Int(fields[2]) else { return nil }
        return (String(rawHash), finalLine)
    }
}
