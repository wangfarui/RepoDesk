import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct GitWriteInteractionTests {
    @Test func workspaceAllRepositoriesCannotCommit() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator()
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = changedSnapshot(branch: "main")

        #expect(state.changesCommitRepository == nil)
        #expect(!state.canCommitChanges)
        await state.commitChanges(andPush: false)
        #expect(await gitOperator.createdCommitMessages().isEmpty)
    }

    @Test func successfulCommitClearsRepositoryDraftAndRefreshesSnapshot() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator()
        let reader = GitWriteReader(snapshot: cleanSnapshot(branch: "main"))
        let state = makeState(repository: repository, reader: reader, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = changedSnapshot(branch: "main")
        state.selectChangesRepositoryScope(repository.id)
        state.updateChangesCommitMessage("Implement commit workflow")

        await state.commitChanges(andPush: false)

        #expect(await gitOperator.createdCommitMessages() == ["Implement commit workflow"])
        #expect(state.changesCommitMessage.isEmpty)
        #expect(state.commitOperationStatusMessage == "Commit 成功。")
        #expect(state.commitOperationErrorMessage == nil)
        guard case .succeeded(let result) = state.commitExecutionState else {
            Issue.record("Commit did not enter the success state")
            return
        }
        #expect(result.commitHash == "created")
        #expect(!result.wasPushed)
        #expect(state.repositorySnapshots[repository.id]?.changes.isEmpty == true)
    }

    @Test func commitUsesOnlyIncludedChanges() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator()
        let state = makeState(repository: repository, gitOperator: gitOperator)
        let included = GitFileChange(
            path: "Included.swift",
            originalPath: nil,
            indexStatus: .modified,
            workTreeStatus: .modified,
            isUntracked: false,
            isConflicted: false
        )
        let excluded = GitFileChange(
            path: "Excluded.swift",
            originalPath: nil,
            indexStatus: .modified,
            workTreeStatus: .modified,
            isUntracked: false,
            isConflicted: false
        )
        state.repositorySnapshots[repository.id] = GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: [included, excluded],
            lastCommit: nil
        )
        state.selectChangesRepositoryScope(repository.id)
        state.updateChangesCommitMessage("Partial")
        state.setCommitInclusion(
            [GitChangeSelection(path: excluded.path, kind: .changes)],
            repositoryID: repository.id,
            included: false
        )

        await state.commitChanges(andPush: false)

        #expect(await gitOperator.committedPaths() == [[included.path]])
    }

    @Test func pushFailureKeepsCommitCompletedAndDoesNotRestoreDraft() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator(failsPush: true)
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = changedSnapshot(branch: "main")
        state.selectChangesRepositoryScope(repository.id)
        state.updateChangesCommitMessage("Commit before failed push")

        await state.commitChanges(andPush: true)

        #expect(await gitOperator.createdCommitMessages() == ["Commit before failed push"])
        #expect(await gitOperator.pushCount() == 1)
        #expect(state.changesCommitMessage.isEmpty)
        #expect(state.commitOperationErrorMessage?.contains("Commit 已完成，但 Push 失败") == true)
        guard case .pushFailed(let result, _) = state.commitExecutionState else {
            Issue.record("Commit and Push did not preserve the partial-success state")
            return
        }
        #expect(result.commitHash == "created")
        #expect(!result.wasPushed)
    }

    @Test func commitAndPushPublishesEachExecutionPhase() async {
        let repository = makeRepository()
        let gitOperator = ControlledCommitGitRepositoryOperator()
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = changedSnapshot(branch: "main")
        state.selectChangesRepositoryScope(repository.id)
        state.updateChangesCommitMessage("Visible progress")

        let operation = Task { await state.commitChanges(andPush: true) }
        await gitOperator.waitUntilCommitStarts()
        guard case .committing(let context) = state.commitExecutionState else {
            Issue.record("Commit phase was not published")
            return
        }
        #expect(context.fileCount == 1)
        #expect(context.shouldPush)

        await gitOperator.finishCommit()
        await gitOperator.waitUntilPushStarts()
        guard case .pushing(_, let hash) = state.commitExecutionState else {
            Issue.record("Push phase was not published")
            return
        }
        #expect(hash == "controlled")

        await gitOperator.finishPush()
        await operation.value
        guard case .succeeded(let result) = state.commitExecutionState else {
            Issue.record("Commit and Push did not enter the success state")
            return
        }
        #expect(result.wasPushed)
    }

    @Test func retryPushDoesNotCreateAnotherCommit() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator(pushFailures: 1)
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = changedSnapshot(branch: "main")
        state.selectChangesRepositoryScope(repository.id)
        state.updateChangesCommitMessage("Retry only the push")

        await state.commitChanges(andPush: true)
        await state.retryCommitPush()

        #expect(await gitOperator.createdCommitMessages() == ["Retry only the push"])
        #expect(await gitOperator.pushCount() == 2)
        guard case .succeeded(let result) = state.commitExecutionState else {
            Issue.record("Retry Push did not enter the success state")
            return
        }
        #expect(result.wasPushed)
    }

    @Test func switchingBranchRefreshesCurrentSnapshotAndBranchCatalog() async {
        let repository = makeRepository()
        let targetBranch = GitBranch(
            name: "release/next",
            hash: "abc",
            upstream: "origin/release/next",
            isRemote: false,
            isCurrent: false
        )
        let refreshedBranch = GitBranch(
            name: targetBranch.name,
            hash: targetBranch.hash,
            upstream: targetBranch.upstream,
            isRemote: false,
            isCurrent: true
        )
        let reader = GitWriteReader(
            snapshot: cleanSnapshot(branch: targetBranch.name),
            branches: [refreshedBranch]
        )
        let gitOperator = RecordingGitRepositoryOperator()
        let state = makeState(repository: repository, reader: reader, gitOperator: gitOperator)
        state.selectRepositoryContext(repository.id)

        let switched = await state.switchBranch(targetBranch)

        #expect(switched)
        #expect(await gitOperator.switchedBranchNames() == [targetBranch.name])
        #expect(state.repositorySnapshots[repository.id]?.branch == targetBranch.name)
        #expect(state.branches == [refreshedBranch])
        #expect(state.branchSwitchErrorMessage == nil)
    }

    @Test func fetchRefreshesAllBranchHistoryWithoutSwitchingWorkingBranch() async {
        let repository = makeRepository()
        let remoteBranch = GitBranch(
            name: "origin/release/next",
            hash: "remote-tip",
            upstream: nil,
            isRemote: true,
            isCurrent: false
        )
        let reader = FetchGitReader(branches: [remoteBranch])
        let gitOperator = RecordingGitRepositoryOperator()
        let state = makeState(repository: repository, reader: reader, gitOperator: gitOperator)
        state.selectRepositoryContext(repository.id)
        state.selectSection(.history)
        state.historyBranchFilter = .all
        state.repositorySnapshots[repository.id] = cleanSnapshot(branch: "main")

        await state.performGitRemoteOperation(.fetch)

        #expect(await gitOperator.fetchCount() == 1)
        #expect((await gitOperator.switchedBranchNames()).isEmpty)
        #expect(state.branches == [remoteBranch])
        #expect(state.commitHistory.map(\.hash) == ["remote-tip"])
        #expect(await reader.historyRevisions() == ["--all"])
        guard case .succeeded(let result) = state.gitRemoteOperationState else {
            Issue.record("Fetch did not publish a success state")
            return
        }
        #expect(result.context.kind == .fetch)
        #expect(result.context.repositoryID == repository.id)
        #expect(result.context.branch == "main")
    }

    @Test func remoteOperationPublishesRunningStateAndBlocksConcurrentGitActions() async {
        let repository = makeRepository()
        let gitOperator = ControlledFetchGitRepositoryOperator()
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = cleanSnapshot(branch: "main")
        state.selectRepositoryContext(repository.id)

        let operation = Task { await state.performGitRemoteOperation(.fetch) }
        await gitOperator.waitUntilFetchStarts()

        guard case .running(let context) = state.gitRemoteOperationState else {
            Issue.record("Fetch did not publish a running state")
            return
        }
        #expect(context.kind == .fetch)
        #expect(context.repositoryName == repository.name)
        #expect(context.branch == "main")
        #expect(state.isGitWriteOperationRunning)

        await state.performGitRemoteOperation(.push)
        #expect(await gitOperator.pushCount() == 0)

        await gitOperator.finishFetch()
        await operation.value
        guard case .succeeded(let result) = state.gitRemoteOperationState else {
            Issue.record("Fetch did not publish a success state")
            return
        }
        #expect(result.context.id == context.id)
    }

    @Test func failedRemoteOperationCanBeRetried() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator(fetchFailures: 1)
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = cleanSnapshot(branch: "main")
        state.selectRepositoryContext(repository.id)

        await state.performGitRemoteOperation(.fetch)
        guard case .failed(let context, let message) = state.gitRemoteOperationState else {
            Issue.record("Fetch failure was not published")
            return
        }
        #expect(context.kind == .fetch)
        #expect(message == "remote unavailable")

        await state.retryGitRemoteOperation()
        #expect(await gitOperator.fetchCount() == 2)
        guard case .succeeded(let result) = state.gitRemoteOperationState else {
            Issue.record("Retried Fetch did not succeed")
            return
        }
        #expect(result.context.kind == .fetch)
    }

    @Test func pullConflictPublishesPersistentConflictState() async {
        let repository = makeRepository()
        let conflict = GitConflictFile(
            path: "Sources/App.swift",
            ours: "ours",
            theirs: "theirs",
            result: "conflict",
            isResolved: false
        )
        let gitOperator = RecordingGitRepositoryOperator(pullConflictFiles: [conflict])
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = cleanSnapshot(branch: "main")
        state.selectRepositoryContext(repository.id)

        await state.performGitRemoteOperation(.pull)

        guard case .requiresConflictResolution(let context, let fileCount) = state.gitRemoteOperationState else {
            Issue.record("Pull conflict state was not published")
            return
        }
        #expect(context.kind == .pull)
        #expect(fileCount == 1)
        #expect(state.conflictFiles == [conflict])
        #expect(state.mergeSourceBranch == "upstream")
        #expect(state.isGitWriteOperationRunning)
    }

    @Test func applyingConflictResultStagesAndRemovesTheFileFromThePendingList() async {
        let repository = makeRepository()
        let conflict = GitConflictFile(
            path: "Sources/App.swift",
            ours: "ours\n",
            theirs: "theirs\n",
            result: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n",
            isResolved: false
        )
        let gitOperator = RecordingGitRepositoryOperator()
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.selectRepositoryContext(repository.id)
        state.conflictFiles = [conflict]
        state.mergeSourceBranch = "feature"

        let didResolve = await state.resolveConflict(
            path: conflict.path,
            result: "merged\n"
        )

        #expect(didResolve)
        #expect(state.conflictFiles.isEmpty)
        #expect(state.mergeSourceBranch == nil)
        #expect(await gitOperator.continueMergeCount() == 1)
        let resolvedFiles = await gitOperator.resolvedConflictFiles()
        #expect(resolvedFiles.count == 1)
        #expect(resolvedFiles.first?.path == conflict.path)
        #expect(resolvedFiles.first?.result == "merged\n")
        #expect(resolvedFiles.first?.isResolved == true)
    }

    @Test func acceptingWholeConflictFileUsesTheRequestedSideAndRemovesIt() async {
        let repository = makeRepository()
        let conflict = GitConflictFile(
            path: "pom.xml",
            ours: "<version>main</version>\n",
            theirs: "<version>feature</version>\n",
            result: "conflict",
            isResolved: false
        )
        let gitOperator = RecordingGitRepositoryOperator()
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.selectRepositoryContext(repository.id)
        state.conflictFiles = [conflict]
        state.mergeSourceBranch = "feature"

        let didResolve = await state.acceptConflictFile(path: conflict.path, side: .theirs)

        #expect(didResolve)
        #expect(state.conflictFiles.isEmpty)
        let resolvedFiles = await gitOperator.resolvedConflictFiles()
        #expect(resolvedFiles.first?.result == conflict.theirs)
    }

    @Test func closingWithPendingConflictsAbortsTheWholeMerge() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator()
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.selectRepositoryContext(repository.id)
        state.conflictFiles = [
            GitConflictFile(
                path: "pom.xml",
                ours: "ours",
                theirs: "theirs",
                result: "conflict",
                isResolved: false
            )
        ]
        state.mergeSourceBranch = "feature"

        await state.closeMergeConflictResolution()

        let abortCount = await gitOperator.abortMergeCount()
        #expect(abortCount == 1)
        #expect(state.conflictFiles.isEmpty)
        #expect(state.mergeSourceBranch == nil)
    }

    @Test func continueMergeIsAvailableAfterAllPendingFilesAreRemoved() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator()
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.selectRepositoryContext(repository.id)
        state.mergeSourceBranch = "feature"

        await state.continueMerge()

        let continueCount = await gitOperator.continueMergeCount()
        #expect(continueCount == 1)
        #expect(state.mergeSourceBranch == nil)
        #expect(state.branchOperationStatusMessage == "Merge 完成。")
    }

    @Test func pushWithNoNewCommitsPublishesInformationalState() async {
        let repository = makeRepository()
        let gitOperator = RecordingGitRepositoryOperator(pushOutcome: .upToDate)
        let state = makeState(repository: repository, gitOperator: gitOperator)
        state.repositorySnapshots[repository.id] = cleanSnapshot(branch: "main")
        state.selectRepositoryContext(repository.id)

        await state.performGitRemoteOperation(.push)

        #expect(await gitOperator.pushCount() == 1)
        guard case .noChangesToPush(let context) = state.gitRemoteOperationState else {
            Issue.record("Up-to-date Push did not publish the informational state")
            return
        }
        #expect(context.kind == .push)
        #expect(context.branch == "main")
    }

    private func makeState(
        repository: RegisteredRepository,
        reader: (any GitRepositoryReading)? = nil,
        gitOperator: any GitRepositoryOperating
    ) -> AppState {
        AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader ?? GitWriteReader(snapshot: cleanSnapshot(branch: "main")),
            gitRepositoryOperator: gitOperator,
            restoresWorkspaceOnLaunch: false
        )
    }

    private func makeRepository() -> RegisteredRepository {
        RegisteredRepository(displayName: "repo", relativePath: ".", isPinned: false)
    }

    private func changedSnapshot(branch: String) -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: branch,
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: [
                GitFileChange(
                    path: "NewFile.swift",
                    originalPath: nil,
                    indexStatus: .untracked,
                    workTreeStatus: .untracked,
                    isUntracked: true,
                    isConflicted: false
                )
            ],
            lastCommit: nil
        )
    }

    private func cleanSnapshot(branch: String) -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: branch,
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: [],
            lastCommit: nil
        )
    }
}

private actor RecordingGitRepositoryOperator: GitRepositoryOperating {
    private var remainingPushFailures: Int
    private var remainingFetchFailures: Int
    private let pullConflictFiles: [GitConflictFile]
    private let pushOutcome: GitPushOutcome
    private var commitMessages: [String] = []
    private var pushes = 0
    private var fetches = 0
    private var branchNames: [String] = []
    private var commitPaths: [[String]] = []
    private var resolvedConflicts: [GitConflictFile] = []
    private var abortMerges = 0
    private var continueMerges = 0

    init(
        failsPush: Bool = false,
        pushFailures: Int? = nil,
        fetchFailures: Int = 0,
        pullConflictFiles: [GitConflictFile] = [],
        pushOutcome: GitPushOutcome = .pushed
    ) {
        remainingPushFailures = pushFailures ?? (failsPush ? 1 : 0)
        remainingFetchFailures = fetchFailures
        self.pullConflictFiles = pullConflictFiles
        self.pushOutcome = pushOutcome
    }

    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit {
        commitMessages.append(message)
        return GitCreatedCommit(hash: "created")
    }

    func createCommit(
        repositoryURL: URL,
        message: String,
        changes: [GitChangeSelection]
    ) async throws -> GitCreatedCommit {
        commitMessages.append(message)
        commitPaths.append(changes.map(\.path).sorted())
        return GitCreatedCommit(hash: "created")
    }

    func pushCurrentBranch(repositoryURL: URL) async throws {
        pushes += 1
        if remainingPushFailures > 0 {
            remainingPushFailures -= 1
            throw GitWriteTestError.pushFailed
        }
    }

    func pushCurrentBranchOutcome(repositoryURL: URL) async throws -> GitPushOutcome {
        try await pushCurrentBranch(repositoryURL: repositoryURL)
        return pushOutcome
    }

    func fetch(repositoryURL: URL) async throws {
        fetches += 1
        if remainingFetchFailures > 0 {
            remainingFetchFailures -= 1
            throw GitWriteTestError.remoteFailed
        }
    }

    func pullCurrentBranch(repositoryURL: URL) async throws {
        if !pullConflictFiles.isEmpty {
            throw GitWriteTestError.remoteFailed
        }
    }

    func conflictFiles(repositoryURL: URL) async throws -> [GitConflictFile] { pullConflictFiles }

    func resolveConflict(repositoryURL: URL, file: GitConflictFile) async throws {
        resolvedConflicts.append(file)
    }

    func abortMerge(repositoryURL: URL) async throws {
        abortMerges += 1
    }

    func continueMerge(repositoryURL: URL) async throws {
        continueMerges += 1
    }

    func switchBranch(repositoryURL: URL, branch: GitBranch) async throws {
        branchNames.append(branch.name)
    }

    func createdCommitMessages() -> [String] { commitMessages }
    func pushCount() -> Int { pushes }
    func fetchCount() -> Int { fetches }
    func switchedBranchNames() -> [String] { branchNames }
    func committedPaths() -> [[String]] { commitPaths }
    func resolvedConflictFiles() -> [GitConflictFile] { resolvedConflicts }
    func abortMergeCount() -> Int { abortMerges }
    func continueMergeCount() -> Int { continueMerges }
}

private actor ControlledFetchGitRepositoryOperator: GitRepositoryOperating {
    private var fetchStarted = false
    private var fetchStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var pushes = 0

    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit {
        GitCreatedCommit(hash: "unused")
    }

    func fetch(repositoryURL: URL) async throws {
        fetchStarted = true
        fetchStartWaiters.forEach { $0.resume() }
        fetchStartWaiters = []
        await withCheckedContinuation { fetchContinuation = $0 }
    }

    func pushCurrentBranch(repositoryURL: URL) async throws {
        pushes += 1
    }

    func switchBranch(repositoryURL: URL, branch: GitBranch) async throws {}

    func waitUntilFetchStarts() async {
        guard !fetchStarted else { return }
        await withCheckedContinuation { fetchStartWaiters.append($0) }
    }

    func finishFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    func pushCount() -> Int { pushes }
}

private actor ControlledCommitGitRepositoryOperator: GitRepositoryOperating {
    private var commitStarted = false
    private var pushStarted = false
    private var commitStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var pushStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitContinuation: CheckedContinuation<Void, Never>?
    private var pushContinuation: CheckedContinuation<Void, Never>?

    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit {
        try await createCommit(repositoryURL: repositoryURL, message: message, changes: [])
    }

    func createCommit(
        repositoryURL: URL,
        message: String,
        changes: [GitChangeSelection]
    ) async throws -> GitCreatedCommit {
        commitStarted = true
        commitStartWaiters.forEach { $0.resume() }
        commitStartWaiters = []
        await withCheckedContinuation { commitContinuation = $0 }
        return GitCreatedCommit(hash: "controlled")
    }

    func pushCurrentBranch(repositoryURL: URL) async throws {
        pushStarted = true
        pushStartWaiters.forEach { $0.resume() }
        pushStartWaiters = []
        await withCheckedContinuation { pushContinuation = $0 }
    }

    func switchBranch(repositoryURL: URL, branch: GitBranch) async throws {}

    func waitUntilCommitStarts() async {
        guard !commitStarted else { return }
        await withCheckedContinuation { commitStartWaiters.append($0) }
    }

    func waitUntilPushStarts() async {
        guard !pushStarted else { return }
        await withCheckedContinuation { pushStartWaiters.append($0) }
    }

    func finishCommit() {
        commitContinuation?.resume()
        commitContinuation = nil
    }

    func finishPush() {
        pushContinuation?.resume()
        pushContinuation = nil
    }
}

private actor FetchGitReader: GitRepositoryReading {
    private let branchValues: [GitBranch]
    private var revisions: [String?] = []

    init(branches: [GitBranch]) {
        branchValues = branches
    }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: [],
            lastCommit: nil
        )
    }

    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        GitFileDiff(
            path: "remote.txt",
            originalPath: nil,
            oldLabel: "before",
            newLabel: "after",
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
        revisions.append(revision)
        return [
            GitCommitSummary(
                hash: "remote-tip",
                subject: "Latest remote commit",
                author: "RepoDesk",
                authoredAt: nil,
                refs: ["origin/release/next"]
            )
        ]
    }

    func branches(repositoryURL: URL) async throws -> [GitBranch] { branchValues }
    func authors(repositoryURL: URL) async throws -> [String] { ["RepoDesk"] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(
                hash: hash,
                subject: "Latest remote commit",
                author: "RepoDesk",
                authoredAt: nil
            ),
            files: []
        )
    }

    func historyRevisions() -> [String?] { revisions }
}

private struct GitWriteReader: GitRepositoryReading {
    let snapshotValue: GitRepositorySnapshot
    let branchValues: [GitBranch]

    init(snapshot: GitRepositorySnapshot, branches: [GitBranch] = []) {
        snapshotValue = snapshot
        branchValues = branches
    }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot { snapshotValue }

    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        GitFileDiff(
            path: "",
            originalPath: nil,
            oldLabel: "",
            newLabel: "",
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

    func branches(repositoryURL: URL) async throws -> [GitBranch] { branchValues }
    func authors(repositoryURL: URL) async throws -> [String] { [] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: "", author: "", authoredAt: nil),
            files: []
        )
    }
}

private enum GitWriteTestError: LocalizedError {
    case pushFailed
    case remoteFailed

    var errorDescription: String? { "remote unavailable" }
}
