import Foundation
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyMergeConflictResolution {
    static func main() async throws {
        try await verifyMergeOutcomes()
        try verifyStableConflictNavigationModel()
        try verifyConflictBaseSlices()
        try verifyNavigationScopeModel()
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

    private static func verifyMergeOutcomes() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-merge-outcomes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let runner = SystemCommandRunner()
        func git(_ arguments: [String]) async throws -> String {
            let result = try await runner.run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: [
                    "-c", "user.name=RepoDesk Verification", "-c", "user.email=verification@example.invalid",
                    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"
                ] + arguments,
                workingDirectoryURL: url,
                environment: nil
            ))
            try require(result.terminationStatus == 0, "Merge fixture command failed: \(arguments.first ?? "git")")
            return String(decoding: result.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        _ = try await git(["init", "--initial-branch=main"])
        _ = try await git(["config", "user.name", "RepoDesk Verification"])
        _ = try await git(["config", "user.email", "verification@example.invalid"])
        _ = try await git(["config", "commit.gpgsign", "false"])
        _ = try await git(["config", "core.hooksPath", "/dev/null"])
        _ = try await git(["config", "merge.ff", "true"])
        _ = try await git(["commit", "--allow-empty", "-m", "Initial"])
        _ = try await git(["branch", "feature"])

        let repository = RegisteredRepository(displayName: "repo", relativePath: ".", isPinned: false)
        let state = AppState(
            workspace: WorkspaceSummary(name: "merge verification", path: url.path),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: MergeConflictReader(),
            gitRepositoryOperator: SystemGitRepositoryOperator(),
            restoresWorkspaceOnLaunch: false
        )
        state.selectRepositoryContext(repository.id)
        let branch = GitBranch(name: "feature", hash: "", upstream: nil, isRemote: false, isCurrent: false)
        let upToDateMessage = "当前分支已包含该分支的最新代码，无需合并。"

        let originalHead = try await git(["rev-parse", "HEAD"])
        await state.mergeBranch(branch)
        try require(state.branchOperationStatusMessage == upToDateMessage, "Equal tips did not show the no-op message.")
        let sameHead = try await git(["rev-parse", "HEAD"])
        try require(sameHead == originalHead, "No-op Merge changed HEAD.")
        try require(state.branchOperationErrorMessage == nil, "No-op Merge was treated as an error.")
        try require(state.mergeSourceBranch == nil, "No-op Merge opened conflict resolution.")

        _ = try await git(["commit", "--allow-empty", "-m", "Main ahead"])
        await state.mergeBranch(branch)
        try require(state.branchOperationStatusMessage == upToDateMessage, "An included ancestor was not recognized.")

        _ = try await git(["switch", "feature"])
        _ = try await git(["merge", "--ff-only", "main"])
        _ = try await git(["commit", "--allow-empty", "-m", "Feature ahead"])
        let featureHead = try await git(["rev-parse", "HEAD"])
        _ = try await git(["switch", "main"])
        await state.mergeBranch(branch)
        try require(state.branchOperationStatusMessage == "Merge 成功。", "Fast-forward with identical files was mistaken for a no-op.")
        let fastForwardHead = try await git(["rev-parse", "HEAD"])
        try require(fastForwardHead == featureHead, "Fast-forward did not include the feature commit.")

        await state.mergeBranch(branch)
        try require(state.branchOperationStatusMessage == upToDateMessage, "Repeated Merge did not show the no-op message.")

        _ = try await git(["commit", "--allow-empty", "-m", "Main diverged"])
        _ = try await git(["switch", "feature"])
        _ = try await git(["commit", "--allow-empty", "-m", "Feature diverged"])
        _ = try await git(["switch", "main"])
        await state.mergeBranch(branch)
        try require(state.branchOperationStatusMessage == "Merge 成功。", "A real Merge with identical files was mistaken for a no-op.")
        let parents = try await git(["rev-list", "--parents", "-n", "1", "HEAD"])
        try require(parents.split(separator: " ").count == 3, "Diverged histories did not create a merge commit.")

        await state.mergeBranch(GitBranch(name: "missing", hash: "", upstream: nil, isRemote: false, isCurrent: false))
        try require(state.branchOperationStatusMessage == nil, "Failed Merge retained a success message.")
        try require(state.branchOperationErrorMessage != nil, "Failed Merge did not report its error.")
        print("Merge outcome verification passed (equal tips, ancestor, fast-forward, repeat, merge commit, failure)")
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

    private static func verifyNavigationScopeModel() throws {
        try require(
            MergeConflictNavigationScope.unresolved.blockIDs(
                allBlockIDs: [0, 1, 2],
                unresolvedBlockIDs: [1, 2]
            ) == [1, 2],
            "Unresolved navigation scope included resolved conflicts."
        )
        try require(
            MergeConflictNavigationScope.all.blockIDs(
                allBlockIDs: [0, 1, 2],
                unresolvedBlockIDs: [1, 2]
            ) == [0, 1, 2],
            "All navigation scope omitted resolved conflicts."
        )
    }

    private static func verifyConflictBaseSlices() throws {
        let text = "before\n<<<<<<< HEAD\nours-one\n=======\ntheirs-one\n>>>>>>> master\nmiddle\n<<<<<<< HEAD\nours-two\n=======\ntheirs-two\n>>>>>>> master\nafter\n"
        let base = "before\nbase-one\nmiddle\nbase-two\nafter\n"
        let document = GitConflictResolutionDocument(text: text, base: base)
        try require(
            document.blocks.map(\.base) == ["base-one\n", "base-two\n"],
            "Conflict result contains the whole base file instead of each conflict's base lines."
        )
        let diff3 = "before\n<<<<<<< HEAD\nours\n||||||| ancestor\nbase\n=======\ntheirs\n>>>>>>> master\nafter\n"
        let diff3Document = GitConflictResolutionDocument(text: diff3, base: "unrelated\n")
        try require(diff3Document.blocks.first?.ours == "ours\n", "Diff3 base leaked into Yours.")
        try require(diff3Document.blocks.first?.base == "base\n", "Diff3 ancestor was not used.")
        try require(diff3Document.blocks.first?.theirs == "theirs\n", "Diff3 Theirs is wrong.")
        try require(
            GitConflictParser.resolving(0, in: diff3, with: .ours) == "before\nours\nafter\n",
            "Resolving diff3 retained ancestor markers."
        )
        let crlf = diff3.replacingOccurrences(of: "\n", with: "\r\n")
        try require(
            GitConflictResolutionDocument(text: crlf).blocks.first?.base == "base\r\n",
            "CRLF diff3 was not parsed correctly."
        )
        let added = "before\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> master\nafter\n"
        try require(
            GitConflictResolutionDocument(text: added, base: "before\nafter\n").blocks.first?.base == "",
            "Add/add conflict invented ancestor content."
        )
        let deleted = "before\n<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> master\nafter\n"
        try require(
            GitConflictResolutionDocument(text: deleted, base: "before\nbase\nafter\n").blocks.first?.base == "base\n",
            "Modify/delete conflict lost its ancestor."
        )
        let shifted = "automatic-addition\n" + text
        try require(
            GitConflictResolutionDocument(text: shifted, base: base).blocks.map(\.base)
                == ["base-one\n", "base-two\n"],
            "Automatic merge changes shifted the ancestor slices."
        )

        let fixtureURL = URL(fileURLWithPath: "build/merge-searcher-repro")
        if FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent("base.xml").path) {
            let realBase = try String(contentsOf: fixtureURL.appendingPathComponent("base.xml"), encoding: .utf8)
            let realResult = try String(contentsOf: fixtureURL.appendingPathComponent("result.xml"), encoding: .utf8)
            var realDocument = GitConflictResolutionDocument(text: realResult, base: realBase)
            try require(realDocument.blocks.count == 2, "Searcher repro did not contain two conflicts.")
            try require(
                realDocument.blocks.map(\.base) == [
                    "        <revision>6.5.9-SNAPSHOT</revision>\n",
                    "        <saasbusinesscenter.version>9.6.1-SNAPSHOT</saasbusinesscenter.version>\n"
                ],
                "Searcher conflicts did not isolate the actual ancestor versions."
            )
            for block in realDocument.blocks { realDocument.resolve(block.id, with: .theirs) }
            try require(realDocument.isResolved, "Searcher conflicts could not be resolved.")
            try require(!realDocument.renderedText().contains("<<<<<<<"), "Searcher result retained conflict markers.")
            try require(
                realDocument.renderedText().components(separatedBy: "<?xml").count == 2,
                "Searcher resolution duplicated the POM."
            )
        }
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
