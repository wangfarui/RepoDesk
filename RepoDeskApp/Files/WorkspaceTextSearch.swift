import Foundation

struct WorkspaceTextSearchResult: Equatable, Identifiable, Sendable {
    let fileURL: URL
    let line: Int
    let lineText: String

    var id: String { "\(fileURL.standardizedFileURL.path):\(line)" }
}

protocol WorkspaceTextSearching: Sendable {
    func search(in workspaceURL: URL, query: String, limit: Int) async -> [WorkspaceTextSearchResult]
}

struct FileSystemWorkspaceTextSearch: WorkspaceTextSearching {
    private static let skippedDirectories: Set<String> = [
        ".git", ".gradle", ".idea", "build", "node_modules", "target"
    ]
    private static let maximumSearchFileSize = 10_000_000

    func search(in workspaceURL: URL, query: String, limit: Int = 300) async -> [WorkspaceTextSearchResult] {
        await Task.detached(priority: .userInitiated) {
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedQuery.isEmpty,
                  limit > 0,
                  let enumerator = FileManager.default.enumerator(
                    at: workspaceURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                  ) else {
                return []
            }

            var results: [WorkspaceTextSearchResult] = []
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
                ) else { continue }
                if values.isDirectory == true {
                    if Self.skippedDirectories.contains(url.lastPathComponent)
                        || url.lastPathComponent.hasPrefix(".") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      (values.fileSize ?? 0) <= Self.maximumSearchFileSize,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      (!Self.isBinary(data) || Self.isUTF16(data)),
                      let text = Self.decodeText(data) else { continue }

                for (lineIndex, lineText) in text.components(separatedBy: .newlines).enumerated() {
                    guard lineText.localizedCaseInsensitiveContains(normalizedQuery) else { continue }
                    results.append(
                        WorkspaceTextSearchResult(
                            fileURL: url,
                            line: lineIndex + 1,
                            lineText: lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    if results.count >= limit { break }
                }
                if results.count >= limit { break }
            }
            return results
        }.value
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(8_192).contains(0)
    }

    private static func isUTF16(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    }
}
