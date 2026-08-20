import Foundation

protocol WorkspaceFileSearching: Sendable {
    func search(in workspaceURL: URL, query: String, limit: Int) async -> [WorkspaceFileEntry]
}

struct FileSystemWorkspaceSearch: WorkspaceFileSearching {
    private static let skippedDirectories: Set<String> = [
        ".git", ".gradle", ".idea", "build", "node_modules", "target"
    ]

    func search(in workspaceURL: URL, query: String, limit: Int = 100) async -> [WorkspaceFileEntry] {
        await Task.detached(priority: .userInitiated) {
            guard !query.isEmpty,
                  let enumerator = FileManager.default.enumerator(
                    at: workspaceURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                  ) else {
                return []
            }
            var matches: [WorkspaceFileEntry] = []
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                    continue
                }
                if values.isDirectory == true {
                    if Self.skippedDirectories.contains(url.lastPathComponent)
                        || url.lastPathComponent.hasPrefix(".") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
                matches.append(
                    WorkspaceFileEntry(url: url, name: url.lastPathComponent, isDirectory: false)
                )
                if matches.count >= limit { break }
            }
            return matches.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
    }
}
