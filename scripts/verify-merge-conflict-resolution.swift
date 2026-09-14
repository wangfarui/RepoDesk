import Foundation
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyMergeConflictResolution {
    static func main() async throws {
        try verifyStableConflictNavigationModel()
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: ".",
            isPinned: false
        )
        let gitOperator = MergeConflictOperator()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: MergeConflictReader(),
            gitRepositoryOperator: gitOperator,
            restoresWorkspaceOnLaunch: false
        )
        state.selectRepositoryContext(repository.id)
        state.mergeSourceBranch = "feature"
        state.conflictFiles = [
            conflict(path: "module-a/pom.xml"),
            conflict(path: "module-b/pom.xml")
        ]

        let firstResolved = await state.resolveConflict(
            path: "module-a/pom.xml",
            result: "<version>merged</version>\n"
        )
        try require(firstResolved, "Apply did not resolve the selected file.")
        try require(
            state.conflictFiles.map(\.path) == ["module-b/pom.xml"],
            "Apply did not remove the resolved file from the pending list."
        )

        await state.closeMergeConflictResolution()
        let abortCount = await gitOperator.abortCount()
        try require(abortCount == 1, "Close did not abort a partial Merge.")
        try require(state.conflictFiles.isEmpty, "Abort did not clear pending conflicts.")
        try require(state.mergeSourceBranch == nil, "Abort did not close the conflict flow.")

        state.mergeSourceBranch = "feature"
        state.conflictFiles = [conflict(path: "pom.xml")]
        let accepted = await state.acceptConflictFile(path: "pom.xml", side: .theirs)
        try require(accepted, "Accept Theirs did not resolve the file.")
        try require(state.conflictFiles.isEmpty, "Accept Theirs did not remove the file.")
        let resolvedFiles = await gitOperator.resolvedFiles()
        try require(
            resolvedFiles.last?.result == "<version>theirs</version>\n",
            "Accept Theirs wrote the wrong result."
        )

        await state.continueMerge()
        let continueCount = await gitOperator.continueCount()
        try require(continueCount == 1, "Continue Merge was not executed.")
        try require(state.mergeSourceBranch == nil, "Continue Merge did not close the conflict flow.")

        print("Merge conflict resolution verification passed")
    }

    private static func verifyStableConflictNavigationModel() throws {
        let source = """
        before
        <<<<<<< HEAD
        ours-one
        =======
        theirs-one
        >>>>>>> feature
        middle
        <<<<<<< HEAD
        ours-two
        =======
        theirs-two
        >>>>>>> feature
        after
        """
        var document = GitConflictResolutionDocument(text: source)
        try require(document.unresolvedBlockIDs == [0, 1], "Initial unresolved conflicts are wrong.")

        document.resolve(0, with: .theirs)
        try require(
            document.unresolvedBlockIDs == [1],
            "Resolved conflicts were not removed from unresolved navigation."
        )
        try require(
            document.blocks.map(\.id) == [0, 1],
            "Resolved conflicts disappeared from all-conflict navigation."
        )

        document.resolve(1, with: "custom-two\n")
        try require(document.isResolved, "Custom resolution did not resolve the final conflict.")
        try require(
            document.renderedText() == "before\ntheirs-one\nmiddle\ncustom-two\nafter",
            "The rendered merge result did not preserve non-conflicting segments."
        )

        document.markUnresolved(0)
        try require(
            document.unresolvedBlockIDs == [0],
            "Reopened conflict did not return to unresolved navigation."
        )
    }

    private static func conflict(path: String) -> GitConflictFile {
        GitConflictFile(
            path: path,
            ours: "<version>ours</version>\n",
            theirs: "<version>theirs</version>\n",
            result: "<<<<<<< HEAD\n<version>ours</version>\n=======\n<version>theirs</version>\n>>>>>>> feature\n",
            isResolved: false
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw VerificationError(message: message) }
    }
}

private actor MergeConflictOperator: GitRepositoryOperating {
    private var files: [GitConflictFile] = []
    private var aborts = 0
    private var continues = 0

    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit {
        GitCreatedCommit(hash: "unused")
    }

    func pushCurrentBranch(repositoryURL: URL) async throws {}
    func switchBranch(repositoryURL: URL, branch: GitBranch) async throws {}

    func resolveConflict(repositoryURL: URL, file: GitConflictFile) async throws {
        files.append(file)
    }

    func abortMerge(repositoryURL: URL) async throws {
        aborts += 1
    }

    func continueMerge(repositoryURL: URL) async throws {
        continues += 1
    }

    func resolvedFiles() -> [GitConflictFile] { files }
    func abortCount() -> Int { aborts }
    func continueCount() -> Int { continues }
}

private struct MergeConflictReader: GitRepositoryReading {
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

    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { [] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        throw VerificationError(message: "Commit loading is not expected.")
    }
}
