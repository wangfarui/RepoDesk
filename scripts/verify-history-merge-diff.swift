import Foundation
@testable import RepoDesk

private struct VerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@main
enum HistoryMergeDiffVerification {
    static func main() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskHistoryMerge-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let file = GitCommitFile(path: "resolved.txt", originalPath: nil, status: .modified)
        let detail = GitCommitDetail(
            summary: GitCommitSummary(
                hash: "merge",
                subject: "Merge source",
                author: "RepoDesk",
                authoredAt: nil
            ),
            files: [file],
            parentHashes: ["target", "source"]
        )
        let mergeDiff = GitMergeFileDiff(
            target: fileDiff(path: file.path, oldLabel: "target", oldLine: "target"),
            source: fileDiff(path: file.path, oldLabel: "source", oldLine: "source")
        )
        let reader = MergeHistoryReader(mergeDiff: mergeDiff)
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: "repo",
            isPinned: false
        )
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )
        state.selectedCommitHash = detail.summary.hash
        state.selectedCommitDetail = detail
        state.selectedCommitFile = file

        await state.loadSelectedCommitDiff()

        guard state.mergeCommitFileDiff == mergeDiff else {
            throw VerificationFailure(message: "History did not publish the three-way Merge Diff")
        }
        guard state.commitFileDiff == nil else {
            throw VerificationFailure(message: "History kept a stale two-way Diff for a Merge Commit")
        }
        guard await reader.mergeDiffLoadCount() == 1 else {
            throw VerificationFailure(message: "History did not route the Merge Commit through mergeFileDiff")
        }

        print("History merge diff verification passed")
    }

    private static func fileDiff(path: String, oldLabel: String, oldLine: String) -> GitFileDiff {
        GitFileDiff(
            path: path,
            originalPath: nil,
            oldLabel: oldLabel,
            newLabel: "merge",
            oldLines: [oldLine],
            newLines: ["resolved"],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 1,
                    newStart: 1,
                    newCount: 1,
                    lines: [
                        GitPatchLine(kind: .deletion, text: oldLine),
                        GitPatchLine(kind: .addition, text: "resolved")
                    ]
                )
            ],
            isBinary: false
        )
    }
}

private actor MergeHistoryReader: GitRepositoryReading {
    let mergeDiff: GitMergeFileDiff
    private var mergeLoads = 0

    init(mergeDiff: GitMergeFileDiff) {
        self.mergeDiff = mergeDiff
    }

    func mergeDiffLoadCount() -> Int { mergeLoads }

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
        throw VerificationFailure(message: "Merge Commit unexpectedly used the two-way fileDiff path")
    }

    func mergeFileDiff(
        repositoryURL: URL,
        hash: String,
        parentHashes: [String],
        file: GitCommitFile,
        ignoringWhitespace: Bool
    ) async throws -> GitMergeFileDiff {
        mergeLoads += 1
        return mergeDiff
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
        throw VerificationFailure(message: "Commit detail should already be loaded")
    }
}
