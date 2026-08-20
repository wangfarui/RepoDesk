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

        await state.fetchCurrentRepository()

        #expect(await gitOperator.fetchCount() == 1)
        #expect((await gitOperator.switchedBranchNames()).isEmpty)
        #expect(state.branches == [remoteBranch])
        #expect(state.commitHistory.map(\.hash) == ["remote-tip"])
        #expect(await reader.historyRevisions() == ["--all"])
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
    private var commitMessages: [String] = []
    private var pushes = 0
    private var fetches = 0
    private var branchNames: [String] = []
    private var commitPaths: [[String]] = []

    init(failsPush: Bool = false, pushFailures: Int? = nil) {
        remainingPushFailures = pushFailures ?? (failsPush ? 1 : 0)
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

    func fetch(repositoryURL: URL) async throws {
        fetches += 1
    }

    func switchBranch(repositoryURL: URL, branch: GitBranch) async throws {
        branchNames.append(branch.name)
    }

    func createdCommitMessages() -> [String] { commitMessages }
    func pushCount() -> Int { pushes }
    func fetchCount() -> Int { fetches }
    func switchedBranchNames() -> [String] { branchNames }
    func committedPaths() -> [[String]] { commitPaths }
}

private actor ControlledCommitGitRepositoryOperator: GitRepositoryOperating {
    private var commitStarted = false
    private var pushStarted = false
    private var commitStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var pushStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitContinuation: CheckedContinuation<Void, Never>?
    private var pushContinuation: CheckedContinuation<Void, Never>?

    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit {
        await createCommit(repositoryURL: repositoryURL, message: message, changes: [])
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

    var errorDescription: String? { "remote unavailable" }
}
