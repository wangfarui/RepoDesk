import Foundation

struct RepositoryDiscoverySettings: Codable, Equatable, Sendable {
    private(set) var ignoredDirectoryPaths: [String]

    static let `default` = RepositoryDiscoverySettings(ignoredDirectoryPaths: [])

    init(ignoredDirectoryPaths: [String]) {
        self.ignoredDirectoryPaths = Self.normalizedPaths(ignoredDirectoryPaths)
    }

    @discardableResult
    mutating func addIgnoredDirectory(
        _ directoryURL: URL,
        in workspaceURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let relativePath = try Self.relativeDirectoryPath(
            for: directoryURL,
            in: workspaceURL,
            fileManager: fileManager
        )
        guard !ignoredDirectoryPaths.contains(relativePath) else { return false }
        ignoredDirectoryPaths.append(relativePath)
        ignoredDirectoryPaths = Self.normalizedPaths(ignoredDirectoryPaths)
        return true
    }

    @discardableResult
    mutating func removeIgnoredDirectory(relativePath: String) -> Bool {
        guard let index = ignoredDirectoryPaths.firstIndex(of: relativePath) else { return false }
        ignoredDirectoryPaths.remove(at: index)
        return true
    }

    mutating func removeAllIgnoredDirectories() {
        ignoredDirectoryPaths.removeAll()
    }

    private static func relativeDirectoryPath(
        for directoryURL: URL,
        in workspaceURL: URL,
        fileManager: FileManager
    ) throws -> String {
        let workspace = workspaceURL.standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RepositoryDiscoverySettingsError.directoryUnavailable(directory.path)
        }

        guard directory.path != workspace.path else {
            throw RepositoryDiscoverySettingsError.workspaceRootCannotBeIgnored
        }

        let workspacePrefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        guard directory.path.hasPrefix(workspacePrefix) else {
            throw RepositoryDiscoverySettingsError.outsideWorkspace(directory.path)
        }

        return String(directory.path.dropFirst(workspacePrefix.count))
    }

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        Array(Set(paths.map(normalizeStoredPath).filter { !$0.isEmpty && $0 != "." }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func normalizeStoredPath(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return "" }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                return ""
            default:
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }
}

enum RepositoryDiscoverySettingsError: LocalizedError, Equatable {
    case directoryUnavailable(String)
    case outsideWorkspace(String)
    case workspaceRootCannotBeIgnored

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let path):
            "The selected directory is unavailable: \(path)"
        case .outsideWorkspace(let path):
            "The selected directory is outside the current workspace: \(path)"
        case .workspaceRootCannotBeIgnored:
            "The workspace root cannot be ignored during repository discovery."
        }
    }
}

protocol RepositoryDiscovering: Sendable {
    func discoverRepositories(
        in workspaceURL: URL,
        settings: RepositoryDiscoverySettings
    ) async -> [RegisteredRepository]
}

struct FileSystemRepositoryDiscoverer: RepositoryDiscovering {
    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".gradle", ".idea", "build", "node_modules", "target"
    ]

    func discoverRepositories(
        in workspaceURL: URL,
        settings: RepositoryDiscoverySettings
    ) async -> [RegisteredRepository] {
        await Task.detached(priority: .userInitiated) {
            Self.scan(workspaceURL: workspaceURL, settings: settings)
        }.value
    }

    private static func scan(
        workspaceURL: URL,
        settings: RepositoryDiscoverySettings
    ) -> [RegisteredRepository] {
        let fileManager = FileManager()
        let workspace = workspaceURL.standardizedFileURL
        let workspacePrefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        let ignoredDirectoryPaths = Set(settings.ignoredDirectoryPaths)
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
            let relativePath = String(url.standardizedFileURL.path.dropFirst(workspacePrefix.count))
            if ignoredDirectoryPaths.contains(relativePath)
                || skippedDirectoryNames.contains(name)
                || name.hasPrefix(".") {
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
