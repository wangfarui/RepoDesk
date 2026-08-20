import Foundation

enum MavenProjectRefreshPlanner {
    private static let projectFileNames: Set<String> = [
        "pom.xml",
        "mvnw",
        "mvnw.cmd"
    ]

    static func shouldRefresh(
        for batch: WorkspaceChangeBatch,
        repositoryURL: URL
    ) -> Bool {
        shouldRefresh(for: WorkspaceChangeScope(batch), repositoryURL: repositoryURL)
    }

    static func shouldRefresh(
        for scope: WorkspaceChangeScope,
        repositoryURL: URL
    ) -> Bool {
        guard !scope.hasMonitoringError else { return false }
        if scope.requiresFullRescan { return true }

        let repositoryPath = repositoryURL.standardizedFileURL.path
        let prefix = repositoryPath.hasSuffix("/") ? repositoryPath : repositoryPath + "/"
        return scope.changedPaths.contains { changedPath in
            let fileName = (changedPath as NSString).lastPathComponent
            return (changedPath == repositoryPath || changedPath.hasPrefix(prefix))
                && projectFileNames.contains(fileName)
        }
    }
}
