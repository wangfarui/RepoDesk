import Foundation

enum WorkspaceChangeStressError: LocalizedError {
    case tooSlow(TimeInterval)
    case incorrectRefreshSet(Int)
    case incorrectRepositoryScope(String)
    case refreshStorm(batch: Int, repositoryCount: Int)

    var errorDescription: String? {
        switch self {
        case .tooSlow(let duration):
            "Workspace change planning blocked for \(duration.formatted(.number.precision(.fractionLength(3))))s."
        case .incorrectRefreshSet(let count):
            "Workspace change planning refreshed \(count) directories instead of one."
        case .incorrectRepositoryScope(let message):
            message
        case .refreshStorm(let batch, let repositoryCount):
            "Continuous write batch \(batch) refreshed \(repositoryCount) repositories instead of one."
        }
    }
}

@main
struct WorkspaceChangeStressVerification {
    static func main() throws {
        let rootURL = URL(fileURLWithPath: "/tmp/RepoDeskWorkspaceStress", isDirectory: true)
        let activeDirectory = rootURL.appendingPathComponent("active", isDirectory: true)
        try verifyRepositoryScope(workspaceURL: rootURL, repositoryURL: activeDirectory)
        try verifyContinuousWritesStayRepositoryScoped(workspaceURL: rootURL)
        let loadedDirectories = Set(
            (0..<500).map {
                rootURL.appendingPathComponent("loaded-\($0)", isDirectory: true)
            } + [activeDirectory]
        )
        let changedURLs = Set(
            (0..<10_000).map {
                activeDirectory.appendingPathComponent("File\($0).swift")
            }
        )
        let batch = WorkspaceChangeBatch(
            changedURLs: changedURLs,
            requiresFullRescan: false,
            monitoringError: nil
        )

        let clock = ContinuousClock()
        var fastestSeconds = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = clock.now
            let directories = WorkspaceTreeRefreshPlanner.directoriesToRefresh(
                for: batch,
                workspaceURL: rootURL,
                loadedDirectoryURLs: loadedDirectories
            )
            let duration = start.duration(to: clock.now)
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000

            guard directories == [activeDirectory.standardizedFileURL] else {
                throw WorkspaceChangeStressError.incorrectRefreshSet(directories.count)
            }
            fastestSeconds = min(fastestSeconds, seconds)
        }
        guard fastestSeconds < 0.5 else {
            throw WorkspaceChangeStressError.tooSlow(fastestSeconds)
        }
        print("Workspace change stress verification passed in \(fastestSeconds)s")
    }

    private static func verifyContinuousWritesStayRepositoryScoped(workspaceURL: URL) throws {
        let repositoryURLs = (0..<100).map {
            workspaceURL.appendingPathComponent("repository-\($0)", isDirectory: true)
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        for batchIndex in 0..<200 {
            let activeRepositoryIndex = batchIndex % repositoryURLs.count
            let activeRepositoryURL = repositoryURLs[activeRepositoryIndex]
            let batch = WorkspaceChangeBatch(
                changedURLs: Set((0..<100).map {
                    activeRepositoryURL.appendingPathComponent("generated/File\(batchIndex)-\($0).swift")
                }),
                requiresFullRescan: false,
                monitoringError: nil
            )
            let scope = WorkspaceChangeScope(batch)
            let affectedRepositories = repositoryURLs.filter {
                scope.affectsRepository(at: $0)
            }
            guard affectedRepositories == [activeRepositoryURL] else {
                throw WorkspaceChangeStressError.refreshStorm(
                    batch: batchIndex,
                    repositoryCount: affectedRepositories.count
                )
            }
        }
        let duration = startedAt.duration(to: clock.now)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds < 1 else {
            throw WorkspaceChangeStressError.tooSlow(seconds)
        }
    }

    private static func verifyRepositoryScope(workspaceURL: URL, repositoryURL: URL) throws {
        let rootFileBatch = WorkspaceChangeBatch(
            changedURLs: [workspaceURL.appendingPathComponent("AGENTS.md")],
            requiresFullRescan: false,
            monitoringError: nil
        )
        guard !WorkspaceTreeRefreshPlanner.batch(
            rootFileBatch,
            affectsRepositoryAt: repositoryURL
        ) else {
            throw WorkspaceChangeStressError.incorrectRepositoryScope(
                "A Workspace root file incorrectly affected a nested Repository."
            )
        }

        let repositoryFileBatch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL.appendingPathComponent("Sources/App.swift")],
            requiresFullRescan: false,
            monitoringError: nil
        )
        guard WorkspaceTreeRefreshPlanner.batch(
            repositoryFileBatch,
            affectsRepositoryAt: repositoryURL
        ) else {
            throw WorkspaceChangeStressError.incorrectRepositoryScope(
                "A Repository file did not affect its Repository."
            )
        }

        let repositoryDirectoryBatch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL],
            requiresFullRescan: false,
            monitoringError: nil
        )
        guard WorkspaceTreeRefreshPlanner.batch(
            repositoryDirectoryBatch,
            affectsRepositoryAt: repositoryURL
        ) else {
            throw WorkspaceChangeStressError.incorrectRepositoryScope(
                "A Repository directory event did not affect its Repository."
            )
        }
    }
}
