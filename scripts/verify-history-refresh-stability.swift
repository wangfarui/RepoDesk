import Foundation
@testable import RepoDesk

private enum VerificationError: LocalizedError {
    case historyIndicatorInterruptedVisibleContent
    case visibleCommitReloaded(Int)
    case historyRefreshDidNotStart

    var errorDescription: String? {
        switch self {
        case .historyIndicatorInterruptedVisibleContent:
            "Background refresh exposed a loading indicator over existing History content."
        case .visibleCommitReloaded(let count):
            "Background refresh reloaded the unchanged visible Commit \(count) time(s)."
        case .historyRefreshDidNotStart:
            "The workspace event did not reach the History refresh request."
        }
    }
}

@MainActor
@main
enum VerifyHistoryRefreshStability {
    static func main() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskHistoryRefresh-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let summary = GitCommitSummary(
            hash: "abc123",
            subject: "Visible commit",
            author: "RepoDesk",
            authoredAt: nil
        )
        let file = GitCommitFile(path: "Sources/App.swift", originalPath: nil, status: .modified)
        let detail = GitCommitDetail(summary: summary, files: [file])
        let reader = ControlledHistoryRefreshReader(summary: summary, detail: detail)
        let changedURL = repositoryURL.appendingPathComponent("Sources/App.swift")
        let monitor = SingleBatchMonitor(
            batch: WorkspaceChangeBatch(
                changedURLs: [changedURL],
                requiresFullRescan: false,
                monitoringError: nil
            )
        )
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: "repo",
            isPinned: false
        )
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            selectedSection: .history,
            gitRepositoryReader: reader,
            workspaceChangeMonitor: monitor,
            restoresWorkspaceOnLaunch: false
        )
        state.commitHistory = [summary]
        state.selectedCommitHash = summary.hash
        state.selectedCommitDetail = detail
        state.selectedCommitFile = file
        state.commitFileDiff = GitFileDiff(
            path: file.path,
            originalPath: nil,
            oldLabel: "old",
            newLabel: "new",
            oldLines: [],
            newLines: [],
            hunks: [],
            isBinary: false
        )

        let monitoringTask = Task { await state.monitorWorkspace() }
        for _ in 0..<200 where !(await reader.hasStartedHistory()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await reader.hasStartedHistory() else {
            throw VerificationError.historyRefreshDidNotStart
        }
        guard !state.showsHistoryLoadingIndicator else {
            await reader.completeHistory()
            await monitoringTask.value
            throw VerificationError.historyIndicatorInterruptedVisibleContent
        }

        await reader.completeHistory()
        await monitoringTask.value
        for _ in 0..<50 { await Task.yield() }
        let commitLoads = await reader.commitLoadCount()
        guard commitLoads == 0 else {
            throw VerificationError.visibleCommitReloaded(commitLoads)
        }

        print("History refresh stability verification passed")
    }
}

private struct SingleBatchMonitor: WorkspaceChangeMonitoring {
    let batch: WorkspaceChangeBatch

    func events(in workspaceURL: URL) -> AsyncStream<WorkspaceChangeBatch> {
        AsyncStream { continuation in
            continuation.yield(batch)
            continuation.finish()
        }
    }
}

private actor ControlledHistoryRefreshReader: GitRepositoryReading {
    private let summary: GitCommitSummary
    private let detail: GitCommitDetail
    private var historyContinuation: CheckedContinuation<Void, Never>?
    private var historyStarted = false
    private var commitLoads = 0

    init(summary: GitCommitSummary, detail: GitCommitDetail) {
        self.summary = summary
        self.detail = detail
    }

    func hasStartedHistory() -> Bool { historyStarted }
    func commitLoadCount() -> Int { commitLoads }

    func completeHistory() {
        historyContinuation?.resume()
        historyContinuation = nil
    }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: [],
            lastCommit: summary
        )
    }

    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        GitFileDiff(
            path: detail.files.first?.path ?? "",
            originalPath: nil,
            oldLabel: "old",
            newLabel: "new",
            oldLines: [],
            newLines: [],
            hunks: [],
            isBinary: false
        )
    }

    func history(
        repositoryURL: URL,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] {
        historyStarted = true
        await withCheckedContinuation { historyContinuation = $0 }
        return [summary]
    }

    func branches(repositoryURL: URL) async throws -> [GitBranch] {
        [GitBranch(name: "main", hash: summary.hash, upstream: nil, isRemote: false, isCurrent: true)]
    }

    func authors(repositoryURL: URL) async throws -> [String] { [summary.author] }
    func currentUserName(repositoryURL: URL) async throws -> String? { summary.author }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        commitLoads += 1
        return detail
    }
}
