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

        state.annotateHistoryCommitFile(file)
        try await waitUntil { state.historyBlame.loadingSides.isEmpty }
        let requests = await reader.recordedBlameRequests()
        try require(Set(requests.map(\.revision)) == ["target", "merge", "source"], "History blame used the wrong revisions")
        try require(requests.allSatisfy { $0.path == file.path && $0.contentsPath == nil }, "History blame read working-tree contents")
        for side in GitHistoryBlameSide.allCases {
            try require(state.historyBlame.annotations(for: side)?[1]?.author == side.rawValue, "History blame mixed pane authors")
        }
        state.annotateHistoryCommitFile(file)
        try require(state.historyBlame.visibleSides.isEmpty, "File menu did not hide all annotations")
        state.toggleHistoryBlame(.source)
        try require(state.historyBlame.visibleSides == [.source], "Pane toggle changed other annotations")
        try require(await reader.recordedBlameRequests().count == 3, "Pane toggle did not reuse cached blame")

        await reader.suspendBlame()
        state.historyBlame.reset()
        await state.loadSelectedCommitDiff()
        state.annotateHistoryCommitFile(file)
        try await waitUntil { await reader.recordedBlameRequests().count == 6 }
        state.historyBlame.reset()
        let replacementDetail = GitCommitDetail(
            summary: GitCommitSummary(hash: "replacement", subject: "Replacement", author: "New", authoredAt: nil),
            files: [file]
        )
        state.historyBlame.configure(HistoryGitBlameContext(
            repositoryURL: repositoryURL, detail: replacementDetail, diff: mergeDiff.target
        ))
        state.historyBlame.toggleAll(using: reader)
        try await waitUntil { await reader.recordedBlameRequests().count == 7 }
        await reader.resumeBlame()
        try await waitUntil { state.historyBlame.loadingSides.isEmpty }
        try require(state.historyBlame.context?.commitHash == "replacement"
            && state.historyBlame.visibleSides == [.result], "Old blame requests survived a selection reset")
        try require(state.historyBlame.annotations(for: .result)?[1]?.author == "replacement",
                    "Stale blame annotations contaminated the replacement selection")

        try await verifyRealHistoryBlame(at: repositoryURL)
        print("History merge diff and blame verification passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationFailure(message: message) }
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VerificationFailure(message: "Timed out waiting for history blame")
    }

    private static func verifyRealHistoryBlame(at repositoryURL: URL) async throws {
        let runner = SystemCommandRunner()
        func git(_ arguments: [String], statuses: Set<Int32> = [0]) async throws -> String {
            let output = try await runner.run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            ))
            try require(statuses.contains(output.terminationStatus), "Git fixture failed: \(String(decoding: output.standardError, as: UTF8.self))")
            return String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fileURL = repositoryURL.appendingPathComponent("file.txt")
        func commit(_ author: String, date: String) async throws -> String {
            _ = try await git(["add", "--all"])
            _ = try await git(["-c", "user.name=\(author)", "commit", "--date=\(date)", "-m", author])
            return try await git(["rev-parse", "HEAD"])
        }
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.email", "repodesk@example.invalid"])
        try Data("keep\nremove\nbase\n".utf8).write(to: fileURL)
        let rootHash = try await commit("Initial", date: "2024-01-01T00:00:00Z")
        _ = try await git(["checkout", "-b", "source"])
        try Data("keep\nremove\nsource\n".utf8).write(to: fileURL)
        _ = try await commit("Source", date: "2024-01-02T00:00:00Z")
        _ = try await git(["checkout", "main"])
        try Data("keep\ntarget\nbase\n".utf8).write(to: fileURL)
        _ = try await commit("Target", date: "2024-01-03T00:00:00Z")
        _ = try await git(["-c", "user.name=Merger", "merge", "--no-ff", "--no-commit", "source"], statuses: [0, 1])
        try Data("inserted\nkeep\ntarget\nsource\n".utf8).write(to: fileURL)
        let mergeHash = try await commit("Merger", date: "2024-01-04T00:00:00Z")
        // Rename and then delete the file; historical blame must ignore current HEAD and disk.
        _ = try await git(["mv", "file.txt", "renamed.txt"])
        let renameHash = try await commit("Rename", date: "2024-01-05T00:00:00Z")
        _ = try await git(["rm", "renamed.txt"])
        let deleteHash = try await commit("Delete", date: "2024-01-06T00:00:00Z")
        try Data("working tree\n".utf8).write(to: fileURL)

        let reader = SystemGitRepositoryReader()
        let repository = RegisteredRepository(displayName: "repo", relativePath: ".", isPinned: false)
        let state = AppState(
            workspace: WorkspaceSummary(url: repositoryURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )
        let detail = try await reader.commit(repositoryURL: repositoryURL, hash: mergeHash)
        state.selectedCommitHash = mergeHash
        state.selectedCommitDetail = detail
        // Exercise the file menu's selection-and-load path, rather than preselecting the file.
        guard let file = detail.files.first(where: { $0.path == "file.txt" }) else {
            throw VerificationFailure(message: "Merge fixture file unavailable")
        }
        state.annotateHistoryCommitFile(file)
        try await waitUntil { !state.isLoadingCommitDiff && state.historyBlame.loadingSides.isEmpty }
        try require(state.historyBlame.errors.isEmpty, "Historical merge blame failed")
        try require(state.historyBlame.annotations(for: .target)?[2]?.author == "Target", "Target parent blame is incorrect")
        try require(state.historyBlame.annotations(for: .source)?[3]?.author == "Source", "Source parent blame is incorrect")
        let result = state.historyBlame.annotations(for: .result)
        try require((1...4).compactMap { result?[$0]?.author } == ["Merger", "Initial", "Target", "Source"], "Merge result blame lost line attribution")
        try require(result?[1]?.authoredAt == ISO8601DateFormatter().date(from: "2024-01-04T00:00:00Z"), "Historical author date is incorrect")
        try require(result?.values.allSatisfy { !$0.isUncommitted } == true, "Historical blame included working changes")

        guard let diff = state.mergeCommitFileDiff else { throw VerificationFailure(message: "Merge diff missing") }
        let rows = GitMergeDiffRenderModel(diff: diff).rows
        try require(rows.contains { $0.result?.number == 1 && $0.target == nil && $0.source == nil }, "Result insertion did not preserve empty parent rows")
        try require(rows.contains { $0.target?.number == 1 && $0.result?.number == 2 && $0.source?.number == 1 }, "Merge rows lost independent version line numbers")

        for (hash, expectedSides) in [(rootHash, Set([GitHistoryBlameSide.result])),
                                      (renameHash, Set([.target, .result])),
                                      (deleteHash, Set([.target]))] {
            let commitDetail = try await reader.commit(repositoryURL: repositoryURL, hash: hash)
            state.historyBlame.reset()
            state.selectedCommitHash = hash
            state.selectedCommitDetail = commitDetail
            state.selectedCommitFile = commitDetail.files.first
            await state.loadSelectedCommitDiff(annotate: true)
            try await waitUntil { state.historyBlame.loadingSides.isEmpty }
            try require(state.historyBlame.availableSides == expectedSides, "Empty history pane issued an invalid blame request")
            try require(state.historyBlame.visibleSides == expectedSides && state.historyBlame.errors.isEmpty, "Root/rename/delete blame failed")
            if hash == renameHash {
                try require(state.historyBlame.context?.targets[.target]?.path == "file.txt"
                    && state.historyBlame.context?.targets[.result]?.path == "renamed.txt", "Renamed history blame used the wrong paths")
            }
        }
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
    struct BlameRequest: Sendable {
        let revision: String
        let path: String
        let contentsPath: String?
    }
    private var blameRequests: [BlameRequest] = []
    private var suspendsBlame = false
    private var blameContinuations: [(CheckedContinuation<[GitBlameLine], Never>, [GitBlameLine])] = []

    func recordedBlameRequests() -> [BlameRequest] { blameRequests }
    func suspendBlame() { suspendsBlame = true }
    func resumeBlame() {
        suspendsBlame = false
        let pending = blameContinuations
        blameContinuations = []
        for (continuation, lines) in pending { continuation.resume(returning: lines) }
    }
    func blame(repositoryURL: URL, path: String, revision: String, contentsPath: String?) async throws -> [GitBlameLine] {
        blameRequests.append(BlameRequest(revision: revision, path: path, contentsPath: contentsPath))
        let lines = [GitBlameLine(lineNumber: 1, commitHash: revision,
                                 author: revision == "merge" ? "result" : revision, authoredAt: nil)]
        if suspendsBlame {
            return await withCheckedContinuation { blameContinuations.append(($0, lines)) }
        }
        return lines
    }

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
