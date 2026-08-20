import Foundation

protocol WorkspaceFileBrowsing: Sendable {
    func children(of directoryURL: URL) async throws -> [WorkspaceFileEntry]
}

struct FileSystemWorkspaceBrowser: WorkspaceFileBrowsing {
    func children(of directoryURL: URL) async throws -> [WorkspaceFileEntry] {
        try await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            return urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isDirectory == true || values.isRegularFile == true || values.isSymbolicLink == true else {
                    return nil
                }
                return WorkspaceFileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values.isDirectory == true
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
    }
}
