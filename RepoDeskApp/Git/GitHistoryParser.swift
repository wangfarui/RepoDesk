import Foundation

enum GitHistoryParser {
    static func parse(_ data: Data) -> [GitCommitSummary] {
        let dateFormatter = ISO8601DateFormatter()
        return data.split(separator: 0x1e).compactMap { record in
            let fields = record.split(separator: 0x1f, omittingEmptySubsequences: false)
            guard fields.count >= 5 else { return nil }
            let hash = String(decoding: fields[0], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dateText = String(decoding: fields[3], as: UTF8.self)
            let refs = String(decoding: fields[4], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return GitCommitSummary(
                hash: hash,
                subject: String(decoding: fields[1], as: UTF8.self),
                author: String(decoding: fields[2], as: UTF8.self),
                authoredAt: dateFormatter.date(from: dateText),
                refs: refs
            )
        }
    }
}
