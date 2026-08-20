import Foundation
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyCommitExecution {
    static func main() async throws {
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: ".",
            isPinned: false
        )
        let gitOperator = CommitExecutionOperator()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: CommitExecutionReader(),
            gitRepositoryOperator: gitOperator,
            restoresWorkspaceOnLaunch: false
        )
        state.repositorySnapshots[repository.id] = changedSnapshot()
        state.selectRepositoryContext(repository.id)
        state.updateChangesCommitMessage("Verify commit execution")

        await state.commitChanges(andPush: true)
        guard case .pushFailed(let partialResult, _) = state.commitExecutionState else {
            throw VerificationError(message: "Push failure did not preserve the created commit.")
        }
        let initialCommitCount = await gitOperator.commitCount()
        let initialPushCount = await gitOperator.pushCount()
        try require(partialResult.commitHash == "created-hash", "Unexpected created commit hash.")
        try require(initialCommitCount == 1, "Initial operation did not create one commit.")
        try require(initialPushCount == 1, "Initial operation did not attempt one push.")

        await state.retryCommitPush()
        guard case .succeeded(let result) = state.commitExecutionState else {
            throw VerificationError(message: "Retry Push did not enter the success state.")
        }
        let retriedCommitCount = await gitOperator.commitCount()
        let retriedPushCount = await gitOperator.pushCount()
        try require(result.wasPushed, "Retry result was not marked pushed.")
        try require(retriedCommitCount == 1, "Retry Push created a duplicate commit.")
        try require(retriedPushCount == 2, "Retry Push did not perform a second push.")
        print("Commit execution verification passed")
    }

    private static func changedSnapshot() -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: [
                GitFileChange(
                    path: "Changed.swift",
                    originalPath: nil,
                    indexStatus: .modified,
                    workTreeStatus: .modified,
                    isUntracked: false,
                    isConflicted: false
                )
            ],
            lastCommit: nil
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError(message: message) }
    }
}

private actor CommitExecutionOperator: GitRepositoryOperating {
    private var commits = 0
    private var pushes = 0

    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit {
        commits += 1
        return GitCreatedCommit(hash: "created-hash")
    }

    func createCommit(
        repositoryURL: URL,
        message: String,
        changes: [GitChangeSelection]
    ) async throws -> GitCreatedCommit {
        try await createCommit(repositoryURL: repositoryURL, message: message)
    }

    func pushCurrentBranch(repositoryURL: URL) async throws {
        pushes += 1
        if pushes == 1 {
            throw CommitExecutionVerificationFailure.pushFailed
        }
    }

    func switchBranch(repositoryURL: URL, branch: GitBranch) async throws {}
    func commitCount() -> Int { commits }
    func pushCount() -> Int { pushes }
}

private struct CommitExecutionReader: GitRepositoryReading {
    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 1,
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

    func branches(repositoryURL: URL) async throws -> [GitBranch] {
        [
            GitBranch(
                name: "main",
                hash: "created-hash",
                upstream: "origin/main",
                isRemote: false,
                isCurrent: true
            )
        ]
    }

    func authors(repositoryURL: URL) async throws -> [String] { [] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: "", author: "", authoredAt: nil),
            files: []
        )
    }
}

private enum CommitExecutionVerificationFailure: LocalizedError {
    case pushFailed

    var errorDescription: String? { "remote unavailable" }
}
