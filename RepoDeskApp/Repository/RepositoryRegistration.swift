import Foundation

enum RepositoryRegistration {
    static func make(
        directoryURL: URL,
        workspaceURL: URL,
        fileManager: FileManager = .default
    ) throws -> RegisteredRepository {
        let workspace = workspaceURL.standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RepositoryRegistrationError.directoryUnavailable(directory.path)
        }

        let isWorkspaceRoot = directory.path == workspace.path
        let workspacePrefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        guard isWorkspaceRoot || directory.path.hasPrefix(workspacePrefix) else {
            throw RepositoryRegistrationError.outsideWorkspace(directory.path)
        }

        let gitMarker = directory.appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: gitMarker.path) else {
            throw RepositoryRegistrationError.notGitRepository(directory.path)
        }

        let relativePath = isWorkspaceRoot
            ? "."
            : String(directory.path.dropFirst(workspacePrefix.count))
        return RegisteredRepository(
            displayName: directory.lastPathComponent,
            relativePath: relativePath,
            isPinned: false
        )
    }
}
