import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct BackgroundRepositoryRefreshTests {
    @Test func initialRefreshRetriesTransientFailureAndPublishesRecoveredSnapshot() async {
        let repository = testRepository
        let snapshot = testSnapshot(changes: [testChange])
        let reader = FlakySnapshotReader(
            failuresBeforeSuccess: 1,
            snapshot: snapshot
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-workspace"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )

        await state.refreshCurrentRepository()

        #expect(await reader.snapshotCallCount() == 2)
        #expect(state.repositorySnapshots[repository.id] == snapshot)
        #expect(state.repositorySnapshotErrors[repository.id] == nil)
        #expect(!state.refreshingRepositoryIDs.contains(repository.id))
    }

    @Test func initialRefreshStopsAfterConfiguredRetryLimit() async {
        let repository = testRepository
        let reader = FlakySnapshotReader(
            failuresBeforeSuccess: 100,
            snapshot: testSnapshot(changes: [])
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-workspace"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            repositorySnapshotRetryDelays: [.zero, .zero],
            restoresWorkspaceOnLaunch: false
        )

        await state.refreshCurrentRepository()

        #expect(await reader.snapshotCallCount() == 3)
        #expect(state.repositorySnapshots[repository.id] == nil)
        #expect(state.repositorySnapshotErrors[repository.id] == "Snapshot refresh failed.")
        #expect(!state.refreshingRepositoryIDs.contains(repository.id))
    }

    @Test func cancellingInitialRefreshStopsPendingRetriesWithoutPublishingError() async {
        let repository = testRepository
        let reader = FlakySnapshotReader(
            failuresBeforeSuccess: 100,
            snapshot: testSnapshot(changes: [])
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-workspace"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            repositorySnapshotRetryDelays: [.seconds(30), .seconds(30)],
            restoresWorkspaceOnLaunch: false
        )

        let refresh = Task { await state.refreshCurrentRepository() }
        await waitUntil { await reader.snapshotCallCount() == 1 }
        refresh.cancel()
        await refresh.value

        #expect(await reader.snapshotCallCount() == 1)
        #expect(state.repositorySnapshots[repository.id] == nil)
        #expect(state.repositorySnapshotErrors[repository.id] == nil)
        #expect(!state.refreshingRepositoryIDs.contains(repository.id))
    }

    @Test func removingRepositoryDiscardsSnapshotThatFinishesLater() async {
        let repository = testRepository
        let reader = ControlledRefreshReader(
            snapshot: testSnapshot(changes: [testChange]),
            diff: testDiff(newLines: []),
            blocksSnapshot: true
        )
        let state = makeState(repository: repository, reader: reader)

        let refresh = Task { await state.refreshCurrentRepository() }
        await waitUntil { await reader.hasStartedSnapshot() }
        state.removeRepository(repository.id)
        await reader.unblockSnapshot()
        await refresh.value

        #expect(state.repositorySnapshots[repository.id] == nil)
        #expect(state.repositorySnapshotErrors[repository.id] == nil)
        #expect(!state.refreshingRepositoryIDs.contains(repository.id))
    }

    @Test func switchingWorkspaceDiscardsSnapshotFromPreviousWorkspace() async {
        let repository = testRepository
        let reader = ControlledRefreshReader(
            snapshot: testSnapshot(changes: [testChange]),
            diff: testDiff(newLines: []),
            blocksSnapshot: true
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "old", path: "/tmp/old-workspace"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            repositoryStore: EmptyRepositoryStore(),
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )

        let refresh = Task { await state.refreshCurrentRepository() }
        await waitUntil { await reader.hasStartedSnapshot() }
        state.openWorkspace(at: URL(fileURLWithPath: "/tmp/new-workspace", isDirectory: true))
        await reader.unblockSnapshot()
        await refresh.value

        #expect(state.workspace?.path == "/tmp/new-workspace")
        #expect(state.repositories.isEmpty)
        #expect(state.repositorySnapshots.isEmpty)
        #expect(state.repositorySnapshotErrors.isEmpty)
        #expect(state.refreshingRepositoryIDs.isEmpty)
    }

    @Test func retryDiagnosticsDistinguishTimeoutCommandFailureAndCancellation() async throws {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskRefreshDiagnostics-\(UUID().uuidString)")
        let logURL = logDirectory.appendingPathComponent("refresh.log")
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let logger = AppDiagnosticLogger(logURL: logURL)

        let timeoutRepository = RegisteredRepository(
            displayName: "timeout",
            relativePath: "timeout-repo",
            isPinned: false
        )
        let timeoutState = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-workspace"),
            repositories: [timeoutRepository],
            selectedRepositoryID: timeoutRepository.id,
            gitRepositoryReader: CategorizedFailureReader(failure: .timeout),
            diagnosticLogger: logger,
            repositorySnapshotRetryDelays: [],
            restoresWorkspaceOnLaunch: false
        )
        await timeoutState.refreshCurrentRepository()

        let commandRepository = RegisteredRepository(
            displayName: "command",
            relativePath: "command-repo",
            isPinned: false
        )
        let commandState = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-workspace"),
            repositories: [commandRepository],
            selectedRepositoryID: commandRepository.id,
            gitRepositoryReader: CategorizedFailureReader(failure: .command),
            diagnosticLogger: logger,
            repositorySnapshotRetryDelays: [],
            restoresWorkspaceOnLaunch: false
        )
        await commandState.refreshCurrentRepository()

        let cancelledRepository = RegisteredRepository(
            displayName: "cancelled",
            relativePath: "cancelled-repo",
            isPinned: false
        )
        let cancelledReader = FlakySnapshotReader(
            failuresBeforeSuccess: 100,
            snapshot: testSnapshot(changes: [])
        )
        let cancelledState = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-workspace"),
            repositories: [cancelledRepository],
            selectedRepositoryID: cancelledRepository.id,
            gitRepositoryReader: cancelledReader,
            diagnosticLogger: logger,
            repositorySnapshotRetryDelays: [.seconds(30)],
            restoresWorkspaceOnLaunch: false
        )
        let cancelledRefresh = Task { await cancelledState.refreshCurrentRepository() }
        await waitUntil { await cancelledReader.snapshotCallCount() == 1 }
        cancelledRefresh.cancel()
        await cancelledRefresh.value

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains(
            "event=exhausted repository=timeout-repo attempt=1 failure=timeout"
        ))
        #expect(log.contains(
            "event=exhausted repository=command-repo attempt=1 failure=command-failed"
        ))
        #expect(log.contains(
            "event=cancelled repository=cancelled-repo attempt=1"
        ))
    }

    @Test func identicalSnapshotRefreshKeepsVisibleDiffWhileRefreshingInBackground() async {
        let repository = testRepository
        let change = testChange
        let snapshot = testSnapshot(changes: [change])
        let oldDiff = testDiff(newLines: ["before"])
        let newDiff = testDiff(newLines: ["after"])
        let reader = ControlledRefreshReader(snapshot: snapshot, diff: newDiff, blocksDiff: true)
        let state = makeState(repository: repository, reader: reader)
        state.repositorySnapshots[repository.id] = snapshot
        state.selectedChangeRepositoryID = repository.id
        state.selectedChange = GitChangeSelection(path: change.path, kind: .changes)
        state.currentDiff = oldDiff

        let refresh = Task { await state.refreshCurrentRepository() }
        await waitUntil { await reader.hasStartedDiff() }

        #expect(!state.isLoadingDiff)
        #expect(state.currentDiff == oldDiff)
        #expect(!state.refreshingRepositoryIDs.contains(repository.id))

        await reader.unblockDiff()
        await refresh.value
        #expect(state.currentDiff == newDiff)
    }

    @Test func refreshFailureRetriesSilentlyAndKeepsCachedSnapshot() async {
        let repository = testRepository
        let snapshot = testSnapshot(changes: [testChange])
        let reader = ControlledRefreshReader(
            snapshot: snapshot,
            diff: testDiff(newLines: []),
            failsSnapshot: true
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-workspace"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            repositorySnapshotRetryDelays: [.zero, .zero],
            restoresWorkspaceOnLaunch: false
        )
        state.repositorySnapshots[repository.id] = snapshot

        await state.refreshCurrentRepository()

        #expect(await reader.snapshotCallCount() == 3)
        #expect(state.repositorySnapshots[repository.id] == snapshot)
        #expect(state.repositorySnapshotErrors[repository.id] == nil)
        #expect(!state.refreshingRepositoryIDs.contains(repository.id))
    }

    @Test func backgroundDiffFailureKeepsVisibleDiffAndErrorState() async {
        let repository = testRepository
        let change = testChange
        let snapshot = testSnapshot(changes: [change])
        let oldDiff = testDiff(newLines: ["visible"])
        let reader = ControlledRefreshReader(
            snapshot: snapshot,
            diff: testDiff(newLines: []),
            failsDiff: true
        )
        let state = makeState(repository: repository, reader: reader)
        state.repositorySnapshots[repository.id] = snapshot
        state.selectedChangeRepositoryID = repository.id
        state.selectedChange = GitChangeSelection(path: change.path, kind: .changes)
        state.currentDiff = oldDiff

        await state.refreshCurrentRepository()

        #expect(state.currentDiff == oldDiff)
        #expect(state.diffErrorMessage == nil)
        #expect(!state.isLoadingDiff)
    }

    @Test func refreshMovesSelectedUnversionedFileIntoChangesAfterGitAdd() async {
        let repository = testRepository
        let path = "Sources/New.swift"
        let unversionedChange = GitFileChange(
            path: path,
            originalPath: nil,
            indexStatus: .untracked,
            workTreeStatus: .untracked,
            isUntracked: true,
            isConflicted: false
        )
        let trackedChange = GitFileChange(
            path: path,
            originalPath: nil,
            indexStatus: .added,
            workTreeStatus: .unchanged,
            isUntracked: false,
            isConflicted: false
        )
        let reader = ControlledRefreshReader(
            snapshot: testSnapshot(changes: [trackedChange]),
            diff: testDiff(newLines: ["new"])
        )
        let state = makeState(repository: repository, reader: reader)
        state.repositorySnapshots[repository.id] = testSnapshot(changes: [unversionedChange])
        state.selectedChangeRepositoryID = repository.id
        state.selectedChange = GitChangeSelection(path: path, kind: .unversioned)
        state.rememberedChangeSelections[repository.id] = state.selectedChange

        await state.refreshCurrentRepository()

        #expect(state.selectedChange?.kind == .changes)
        #expect(state.rememberedChangeSelections[repository.id]?.kind == .changes)
    }

    @Test func initialRefreshUsesVisibleRepositoryLoading() async {
        let repository = testRepository
        let reader = ControlledRefreshReader(
            snapshot: testSnapshot(changes: []),
            diff: testDiff(newLines: []),
            blocksSnapshot: true
        )
        let state = makeState(repository: repository, reader: reader)

        let refresh = Task { await state.refreshCurrentRepository() }
        await waitUntil { await reader.hasStartedSnapshot() }

        #expect(state.refreshingRepositoryIDs.contains(repository.id))
        await reader.unblockSnapshot()
        await refresh.value
        #expect(!state.refreshingRepositoryIDs.contains(repository.id))
    }

    @Test func selectingDifferentChangeRetainsPreviousDiffUntilReplacementLoads() async {
        let repository = testRepository
        let oldDiff = testDiff(newLines: ["old"])
        let newDiff = testDiff(newLines: ["new"])
        let reader = ControlledRefreshReader(
            snapshot: testSnapshot(changes: []),
            diff: newDiff,
            blocksDiff: true
        )
        let state = makeState(repository: repository, reader: reader)
        state.selectedChangeRepositoryID = repository.id
        state.selectedChange = GitChangeSelection(path: "Sources/Old.swift", kind: .changes)
        state.currentDiff = oldDiff

        state.selectChange(GitChangeSelection(path: "Sources/New.swift", kind: .changes))

        #expect(state.currentDiff == oldDiff)
        #expect(state.isLoadingDiff)
        await reader.unblockDiff()
        for _ in 0..<100 where state.currentDiff != newDiff || state.isLoadingDiff {
            await Task.yield()
        }
        #expect(state.currentDiff == newDiff)
        #expect(!state.isLoadingDiff)
    }

    private var testRepository: RegisteredRepository {
        RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
    }

    private var testChange: GitFileChange {
        GitFileChange(
            path: "Sources/App.swift",
            originalPath: nil,
            indexStatus: .unchanged,
            workTreeStatus: .modified,
            isUntracked: false,
            isConflicted: false
        )
    }

    private func testSnapshot(changes: [GitFileChange]) -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: changes,
            lastCommit: nil
        )
    }

    private func testDiff(newLines: [String]) -> GitFileDiff {
        GitFileDiff(
            path: "Sources/App.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: ["before"],
            newLines: newLines,
            hunks: [],
            isBinary: false
        )
    }

    private func makeState(
        repository: RegisteredRepository,
        reader: ControlledRefreshReader
    ) -> AppState {
        AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-workspace"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<100 where !(await condition()) {
            await Task.yield()
        }
    }
}

private actor FlakySnapshotReader: GitRepositoryReading {
    private var failuresRemaining: Int
    private let returnedSnapshot: GitRepositorySnapshot
    private var snapshotCalls = 0

    init(failuresBeforeSuccess: Int, snapshot: GitRepositorySnapshot) {
        failuresRemaining = failuresBeforeSuccess
        returnedSnapshot = snapshot
    }

    func snapshotCallCount() -> Int { snapshotCalls }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        snapshotCalls += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ControlledRefreshError.snapshotFailed
        }
        return returnedSnapshot
    }

    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        GitFileDiff(
            path: target.path,
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
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
    ) async throws -> [GitCommitSummary] { [] }

    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { [] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: "", author: "", authoredAt: nil),
            files: []
        )
    }
}

private struct CategorizedFailureReader: GitRepositoryReading {
    enum Failure: Sendable {
        case timeout
        case command
    }

    let failure: Failure

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        switch failure {
        case .timeout:
            throw CommandRunnerError.timedOut(.seconds(10))
        case .command:
            throw GitRepositoryError.commandFailed(
                arguments: ["status"],
                message: "failed"
            )
        }
    }

    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        throw GitRepositoryError.commandFailed(arguments: ["diff"], message: "failed")
    }

    func history(
        repositoryURL: URL,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] { [] }

    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { [] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: "", author: "", authoredAt: nil),
            files: []
        )
    }
}

private actor ControlledRefreshReader: GitRepositoryReading {
    private let returnedSnapshot: GitRepositorySnapshot
    private let returnedDiff: GitFileDiff
    private let failsSnapshot: Bool
    private let failsDiff: Bool
    private var snapshotBlocked: Bool
    private var diffBlocked: Bool
    private var snapshotStarted = false
    private var snapshotCalls = 0
    private var diffStarted = false
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private var diffWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        snapshot: GitRepositorySnapshot,
        diff: GitFileDiff,
        failsSnapshot: Bool = false,
        failsDiff: Bool = false,
        blocksSnapshot: Bool = false,
        blocksDiff: Bool = false
    ) {
        returnedSnapshot = snapshot
        returnedDiff = diff
        self.failsSnapshot = failsSnapshot
        self.failsDiff = failsDiff
        snapshotBlocked = blocksSnapshot
        diffBlocked = blocksDiff
    }

    func hasStartedSnapshot() -> Bool { snapshotStarted }
    func snapshotCallCount() -> Int { snapshotCalls }
    func hasStartedDiff() -> Bool { diffStarted }

    func unblockSnapshot() {
        snapshotBlocked = false
        let waiters = snapshotWaiters
        snapshotWaiters = []
        waiters.forEach { $0.resume() }
    }

    func unblockDiff() {
        diffBlocked = false
        let waiters = diffWaiters
        diffWaiters = []
        waiters.forEach { $0.resume() }
    }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        snapshotCalls += 1
        snapshotStarted = true
        if snapshotBlocked {
            await withCheckedContinuation { snapshotWaiters.append($0) }
        }
        if failsSnapshot {
            throw ControlledRefreshError.snapshotFailed
        }
        return returnedSnapshot
    }

    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        diffStarted = true
        if diffBlocked {
            await withCheckedContinuation { diffWaiters.append($0) }
        }
        if failsDiff {
            throw ControlledRefreshError.diffFailed
        }
        return returnedDiff
    }

    func history(
        repositoryURL: URL,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] { [] }

    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { [] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: "", author: "", authoredAt: nil),
            files: []
        )
    }
}

private enum ControlledRefreshError: LocalizedError {
    case snapshotFailed
    case diffFailed

    var errorDescription: String? {
        switch self {
        case .snapshotFailed: "Snapshot refresh failed."
        case .diffFailed: "Diff refresh failed."
        }
    }
}

@MainActor
private final class EmptyRepositoryStore: RepositoryStoring {
    func state(for workspaceURL: URL) -> RepositoryWorkspaceState { .empty }
    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {}
}
