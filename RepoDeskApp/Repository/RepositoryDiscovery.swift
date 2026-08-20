import Foundation

protocol RepositoryDiscovering: Sendable {
    func discoverRepositories(in workspaceURL: URL) async -> [RegisteredRepository]
}

struct FileSystemRepositoryDiscoverer: RepositoryDiscovering {
    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".gradle", ".idea", "build", "node_modules", "target"
    ]

    func discoverRepositories(in workspaceURL: URL) async -> [RegisteredRepository] {
        await Task.detached(priority: .userInitiated) {
            Self.scan(workspaceURL: workspaceURL)
        }.value
    }

    private static func scan(workspaceURL: URL) -> [RegisteredRepository] {
        let fileManager = FileManager()
        let workspace = workspaceURL.standardizedFileURL
        var repositories: [RegisteredRepository] = []

        if let root = try? RepositoryRegistration.make(
            directoryURL: workspace,
            workspaceURL: workspace,
            fileManager: fileManager
        ) {
            repositories.append(root)
        }

        guard let enumerator = fileManager.enumerator(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return repositories
        }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let name = url.lastPathComponent
            if skippedDirectoryNames.contains(name) || name.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }

            if let repository = try? RepositoryRegistration.make(
                directoryURL: url,
                workspaceURL: workspace,
                fileManager: fileManager
            ) {
                repositories.append(repository)
            }
        }

        return repositories.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}
