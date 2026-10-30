import Foundation

protocol WorkspaceFileSearching: Sendable {
    func search(in workspaceURL: URL, query: String, limit: Int) async -> [WorkspaceFileEntry]
}

struct FileSystemWorkspaceSearch: WorkspaceFileSearching {
    private static let skippedDirectories: Set<String> = [
        ".git", ".gradle", ".idea", "build", "node_modules", "target"
    ]

    func search(in workspaceURL: URL, query: String, limit: Int = 100) async -> [WorkspaceFileEntry] {
        guard !Task.isCancelled else { return [] }
        let worker = Task.detached(priority: .userInitiated) { () -> [WorkspaceFileEntry] in
            let normalizedQuery = query
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedQuery.isEmpty,
                  limit > 0,
                  let enumerator = FileManager.default.enumerator(
                    at: workspaceURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [],
                    errorHandler: { _, _ in true }
                  ) else {
                return []
            }
            var matches: [(entry: WorkspaceFileEntry, score: Int)] = []
            while !Task.isCancelled, let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                    continue
                }
                if values.isDirectory == true {
                    if Self.skippedDirectories.contains(url.lastPathComponent)
                        || url.lastPathComponent.hasPrefix(".")
                        || ["app", "framework", "bundle", "xcodeproj"].contains(url.pathExtension.lowercased()) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      !url.lastPathComponent.hasPrefix("."),
                      let score = Self.fuzzyScore(
                          query: normalizedQuery,
                          candidate: url.lastPathComponent
                      ) else { continue }
                matches.append((
                    WorkspaceFileEntry(url: url, name: url.lastPathComponent, isDirectory: false),
                    score
                ))
            }
            guard !Task.isCancelled else { return [] }
            let ranked = try? matches.sorted {
                    try Task.checkCancellation()
                    if $0.score != $1.score { return $0.score > $1.score }
                    let nameOrder = $0.entry.name.localizedStandardCompare($1.entry.name)
                    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                    return $0.entry.url.path < $1.entry.url.path
                }
            return (ranked ?? []).prefix(limit).map(\.entry)
        }
        return await withTaskCancellationHandler {
            if Task.isCancelled { worker.cancel() }
            return await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Returns a relevance score when every query character appears in order.
    /// Prefix and contiguous matches rank ahead of loose subsequence matches.
    private static func fuzzyScore(query: String, candidate: String) -> Int? {
        let query = Array(query.lowercased())
        let candidate = Array(candidate.lowercased())
        guard !query.isEmpty, !candidate.isEmpty else { return nil }

        var queryIndex = 0
        var previousMatchIndex: Int?
        var score = 0
        var matchedCount = 0
        for (candidateIndex, character) in candidate.enumerated() {
            guard queryIndex < query.count else { break }
            guard character == query[queryIndex] else { continue }

            matchedCount += 1
            score += 10
            if candidateIndex == queryIndex { score += 20 }
            if let previousMatchIndex, candidateIndex == previousMatchIndex + 1 { score += 8 }
            if candidateIndex == 0 { score += 15 }
            previousMatchIndex = candidateIndex
            queryIndex += 1
        }
        guard matchedCount == query.count else { return nil }
        return score - (candidate.count - query.count)
    }
}
