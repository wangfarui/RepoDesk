import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct HistoryInteractionTests {
    @Test func showingFileHistoryScopesToTheSelectedFile() async {
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: ".",
            isPinned: false
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "tmp", path: "/tmp/project"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: SuspendedCommitReader(),
            restoresWorkspaceOnLaunch: false
        )

        state.showFileHistory(
            for: URL(fileURLWithPath: "/tmp/project/Sources/App.swift")
        )

        #expect(state.selectedSection == .history)
        #expect(state.historyFileRepositoryID == repository.id)
        #expect(state.historyFilePath == "Sources/App.swift")
    }

    @Test func selectingCommitKeepsVisibleContentUntilReplacementIsReady() async {
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: ".",
            isPinned: false
        )
        let reader = SuspendedCommitReader()
        let state = AppState(
            workspace: WorkspaceSummary(name: "tmp", path: "/tmp"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )
        let oldFile = GitCommitFile(path: "old.swift", originalPath: nil, status: .modified)
        let oldDetail = commitDetail(hash: "old", files: [oldFile])
        let oldDiff = fileDiff(path: oldFile.path)
        state.selectedCommitHash = "old"
        state.selectedCommitDetail = oldDetail
        state.selectedCommitFile = oldFile
        state.commitFileDiff = oldDiff

        state.selectCommit("new")

        #expect(state.isLoadingCommit)
        #expect(state.selectedCommitDetail == oldDetail)
        #expect(state.selectedCommitFile == oldFile)
        #expect(state.commitFileDiff == oldDiff)

        let newFile = GitCommitFile(path: "new.swift", originalPath: nil, status: .added)
        await reader.complete(commitDetail(hash: "new", files: [newFile]))
        for _ in 0..<100 where state.isLoadingCommit {
            await Task.yield()
        }

        #expect(state.selectedCommitDetail?.summary.hash == "new")
        #expect(state.selectedCommitFile == newFile)
    }

    private func commitDetail(hash: String, files: [GitCommitFile]) -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(
                hash: hash,
                subject: hash,
                author: "RepoDesk",
                authoredAt: nil
            ),
            files: files
        )
    }

    private func fileDiff(path: String) -> GitFileDiff {
        GitFileDiff(
            path: path,
            originalPath: nil,
            oldLabel: "修改前",
            newLabel: "修改后",
            oldLines: [],
            newLines: [],
            hunks: [],
            isBinary: false
        )
    }
}

private actor SuspendedCommitReader: GitRepositoryReading {
    private var continuation: CheckedContinuation<GitCommitDetail, Never>?
    private var pendingDetail: GitCommitDetail?

    func complete(_ detail: GitCommitDetail) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: detail)
        } else {
            pendingDetail = detail
        }
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
            path: "new.swift",
            originalPath: nil,
            oldLabel: "修改前",
            newLabel: "修改后",
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
        if let pendingDetail {
            self.pendingDetail = nil
            return pendingDetail
        }
        return await withCheckedContinuation { continuation = $0 }
    }
}
