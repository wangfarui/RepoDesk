import Foundation

struct ParsedGitStatus: Equatable, Sendable {
    var branch = "HEAD"
    var isDetachedHEAD = false
    var aheadCount = 0
    var behindCount = 0
    var changes: [GitFileChange] = []
}

enum GitStatusParser {
    static func parse(_ data: Data) -> ParsedGitStatus {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var result = ParsedGitStatus()
        var index = 0

        while index < records.count {
            let record = String(decoding: records[index], as: UTF8.self)

            if record.hasPrefix("# branch.head ") {
                let branch = String(record.dropFirst("# branch.head ".count))
                result.isDetachedHEAD = branch == "(detached)"
                result.branch = result.isDetachedHEAD ? "Detached HEAD" : branch
            } else if record.hasPrefix("# branch.ab ") {
                parseAheadBehind(record, into: &result)
            } else if record.hasPrefix("1 ") {
                if let change = parseOrdinary(record) {
                    result.changes.append(change)
                }
            } else if record.hasPrefix("2 ") {
                let originalPath = index + 1 < records.count
                    ? String(decoding: records[index + 1], as: UTF8.self)
                    : nil
                if let change = parseRename(record, originalPath: originalPath) {
                    result.changes.append(change)
                }
                index += 1
            } else if record.hasPrefix("u ") {
                if let change = parseConflict(record) {
                    result.changes.append(change)
                }
            } else if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                result.changes.append(
                    GitFileChange(
                        path: path,
                        originalPath: nil,
                        indexStatus: .untracked,
                        workTreeStatus: .untracked,
                        isUntracked: true,
                        isConflicted: false
                    )
                )
            }
            index += 1
        }

        return result
    }

    private static func parseAheadBehind(_ record: String, into result: inout ParsedGitStatus) {
        let values = record.split(separator: " ")
        guard values.count >= 4 else { return }
        result.aheadCount = Int(values[2].dropFirst()) ?? 0
        result.behindCount = Int(values[3].dropFirst()) ?? 0
    }

    private static func parseOrdinary(_ record: String) -> GitFileChange? {
        let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9 else { return nil }
        return makeChange(xy: fields[1], path: String(fields[8]))
    }

    private static func parseRename(_ record: String, originalPath: String?) -> GitFileChange? {
        let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
        guard fields.count == 10 else { return nil }
        return makeChange(
            xy: fields[1],
            path: String(fields[9]),
            originalPath: originalPath
        )
    }

    private static func parseConflict(_ record: String) -> GitFileChange? {
        let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
        guard fields.count == 11 else { return nil }
        return makeChange(
            xy: fields[1],
            path: String(fields[10]),
            isConflicted: true
        )
    }

    private static func makeChange(
        xy: Substring,
        path: String,
        originalPath: String? = nil,
        isConflicted: Bool = false
    ) -> GitFileChange {
        let statuses = Array(xy)
        return GitFileChange(
            path: path,
            originalPath: originalPath,
            indexStatus: GitStatusCode(character: statuses.first),
            workTreeStatus: GitStatusCode(character: statuses.dropFirst().first),
            isUntracked: false,
            isConflicted: isConflicted
        )
    }
}
