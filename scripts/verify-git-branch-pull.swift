import Foundation
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw VerificationError(message: message) }
}

private struct Fixture {
    let root: URL
    let local: URL
    let remote: URL
    let publisher: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoDesk-BranchPull-\(UUID().uuidString)")
        local = root.appendingPathComponent("local")
        remote = root.appendingPathComponent("remote.git")
        publisher = root.appendingPathComponent("publisher")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try git(["init", "--bare", remote.path], in: root)
        try git(["init", "--initial-branch=main"], in: local)
        try configure(local)
        try commit("base.txt", "base\n", in: local)
        try git(["remote", "add", "team", remote.path], in: local)
        try git(["push", "team", "main:release/remote"], in: local)
        try git(["branch", "--track", "develop", "team/release/remote"], in: local)
        try git(["clone", "--branch", "release/remote", remote.path, publisher.path], in: root)
        try configure(publisher)
    }

    func configure(_ directory: URL) throws {
        try git(["config", "user.name", "RepoDesk Verification"], in: directory)
        try git(["config", "user.email", "repodesk@example.test"], in: directory)
        try git(["config", "commit.gpgsign", "false"], in: directory)
    }

    func commit(_ path: String, _ contents: String, in directory: URL) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(path))
        try git(["add", "--", path], in: directory)
        try git(["commit", "-m", path], in: directory)
    }

    func publish(_ path: String, _ contents: String) throws {
        try commit(path, contents, in: publisher)
        try git(["push", "origin", "HEAD:release/remote"], in: publisher)
    }

    func git(_ arguments: [String], in directory: URL? = nil) throws {
        _ = try output(arguments, in: directory)
    }

    func output(_ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? local
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VerificationError(message: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func verifyNoTemporaryWorktrees() throws {
        let listing = try output(["worktree", "list", "--porcelain"])
        try require(!listing.contains("RepoDesk-Pull-"), "Temporary Pull worktree was not removed.")
    }
}

@main
@MainActor
enum VerifyGitBranchPull {
    static func main() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operatorUnderTest = SystemGitRepositoryOperator()
        let originalHead = try fixture.output(["rev-parse", "HEAD"])
        try Data("staged\n".utf8).write(to: fixture.local.appendingPathComponent("base.txt"))
        try fixture.git(["add", "base.txt"])
        try Data("unstaged\n".utf8).write(to: fixture.local.appendingPathComponent("base.txt"))
        try Data("untracked\n".utf8).write(to: fixture.local.appendingPathComponent("untracked.txt"))
        let status = try fixture.output(["status", "--porcelain"])
        let index = try fixture.output(["write-tree"])

        try await verifyMissingUpstream(fixture, operatorUnderTest)
        try fixture.publish("remote.txt", "remote\n")
        try await operatorUnderTest.pullBranch(repositoryURL: fixture.local, branchName: "develop")
        let remoteHash = try fixture.output(["rev-parse", "HEAD"], in: fixture.publisher)
        try require(try fixture.output(["rev-parse", "develop"]) == remoteHash, "Non-current Pull did not fast-forward the selected branch.")
        try verifyOriginalWorktree(fixture, head: originalHead, status: status, index: index)
        try fixture.verifyNoTemporaryWorktrees()

        // A diverged branch must merge even when Git is configured to rebase/fast-forward only.
        let seed = try fixture.output(["commit-tree", remoteHash + "^{tree}", "-p", remoteHash, "-m", "Local divergence"])
        try fixture.git(["update-ref", "refs/heads/develop", seed])
        try fixture.git(["config", "pull.rebase", "true"])
        try fixture.git(["config", "pull.ff", "only"])
        try fixture.publish("remote.txt", "remote update\n")
        try await operatorUnderTest.pullBranch(repositoryURL: fixture.local, branchName: "develop")
        let parents = try fixture.output(["rev-list", "--parents", "-n", "1", "develop"]).split(separator: " ")
        let newRemoteHash = try fixture.output(["rev-parse", "HEAD"], in: fixture.publisher)
        try require(parents.count == 3 && parents[1] == Substring(seed) && parents[2] == Substring(newRemoteHash), "Diverged Pull did not preserve both parents.")
        try await operatorUnderTest.pullBranch(repositoryURL: fixture.local, branchName: "develop")
        try verifyOriginalWorktree(fixture, head: originalHead, status: status, index: index)
        try fixture.verifyNoTemporaryWorktrees()

        try await verifyConflict(fixture, operatorUnderTest)
        try verifyOriginalWorktree(fixture, head: originalHead, status: status, index: index)
        try await verifyOtherWorktree(fixture, operatorUnderTest)
        try await verifyConcurrentChange(fixture)
        try await verifyStateAndRetry(fixture)
        try await verifyCurrentBranch()
        print("Git branch Pull verification passed (fast-forward, merge, dirty worktree, missing upstream, conflicts, linked worktree, concurrent update, retry, current branch)")
    }

    private static func verifyOriginalWorktree(_ fixture: Fixture, head: String, status: String, index: String) throws {
        try require(try fixture.output(["symbolic-ref", "HEAD"]) == "refs/heads/main", "Pull switched the original branch.")
        try require(try fixture.output(["rev-parse", "HEAD"]) == head, "Pull changed the original HEAD.")
        try require(try fixture.output(["status", "--porcelain"]) == status, "Pull changed the working-tree status.")
        try require(try fixture.output(["write-tree"]) == index, "Pull changed the original index.")
        try require(try String(contentsOf: fixture.local.appendingPathComponent("base.txt"), encoding: .utf8) == "unstaged\n", "Pull changed unstaged content.")
        try require(try String(contentsOf: fixture.local.appendingPathComponent("untracked.txt"), encoding: .utf8) == "untracked\n", "Pull changed untracked content.")
    }

    private static func verifyMissingUpstream(_ fixture: Fixture, _ gitOperator: SystemGitRepositoryOperator) async throws {
        do {
            try await gitOperator.pullBranch(repositoryURL: fixture.local, branchName: "main")
            throw VerificationError(message: "Pull accepted a branch without an upstream.")
        } catch GitRepositoryOperationError.missingPullUpstream(let name) {
            try require(name == "main", "Missing upstream message names the wrong branch.")
        }
    }

    private static func verifyConflict(_ fixture: Fixture, _ gitOperator: SystemGitRepositoryOperator) async throws {
        try fixture.git(["branch", "--track", "conflicting", "team/release/remote"])
        let linked = fixture.root.appendingPathComponent("conflict-setup")
        try fixture.git(["worktree", "add", linked.path, "conflicting"])
        try fixture.commit("base.txt", "local conflict\n", in: linked)
        try fixture.git(["worktree", "remove", linked.path])
        let before = try fixture.output(["rev-parse", "conflicting"])
        try fixture.publish("base.txt", "remote conflict\n")
        do {
            try await gitOperator.pullBranch(repositoryURL: fixture.local, branchName: "conflicting")
            throw VerificationError(message: "Conflicting Pull unexpectedly succeeded.")
        } catch let error as GitRepositoryOperationError {
            try require(error.localizedDescription.contains("本次合并已取消") && error.localizedDescription.contains("base.txt"), "Isolated conflict feedback was not explicit.")
        }
        try require(try fixture.output(["rev-parse", "conflicting"]) == before, "Conflicting Pull changed the target branch.")
        try fixture.verifyNoTemporaryWorktrees()
    }

    private static func verifyOtherWorktree(_ fixture: Fixture, _ gitOperator: SystemGitRepositoryOperator) async throws {
        let linked = fixture.root.appendingPathComponent("linked")
        try fixture.git(["worktree", "add", linked.path, "develop"])
        let before = try fixture.output(["rev-parse", "develop"])
        do {
            try await gitOperator.pullBranch(repositoryURL: fixture.local, branchName: "develop")
            throw VerificationError(message: "Pull updated a branch checked out in another worktree.")
        } catch let error as GitRepositoryOperationError {
            try require(error.localizedDescription.contains("已在工作区中检出"), "Linked-worktree error was not explicit.")
        }
        try require(try fixture.output(["rev-parse", "develop"]) == before, "Rejected Pull changed another worktree's branch.")
        try fixture.git(["worktree", "remove", linked.path])
    }

    private static func verifyConcurrentChange(_ fixture: Fixture) async throws {
        let before = try fixture.output(["rev-parse", "develop"])
        let replacement = try fixture.output(["commit-tree", before + "^{tree}", "-p", before, "-m", "Concurrent commit"])
        let runner = ConcurrentUpdateRunner(replacement: replacement)
        do {
            try await SystemGitRepositoryOperator(commandRunner: runner).pullBranch(repositoryURL: fixture.local, branchName: "develop")
            throw VerificationError(message: "Pull overwrote a concurrent branch change.")
        } catch is GitRepositoryOperationError {}
        try require(try fixture.output(["rev-parse", "develop"]) == replacement, "Concurrent commit was lost.")
        try fixture.verifyNoTemporaryWorktrees()
    }

    private static func verifyStateAndRetry(_ fixture: Fixture) async throws {
        let repository = RegisteredRepository(displayName: "pull-repo", relativePath: ".", isPinned: false)
        let state = AppState(workspace: WorkspaceSummary(url: fixture.local), repositories: [repository], selectedRepositoryID: repository.id, restoresWorkspaceOnLaunch: false)
        state.selectRepositoryContext(repository.id)
        let branch = GitBranch(name: "develop", hash: "stale", upstream: "team/release/remote", isRemote: false, isCurrent: false)
        try fixture.git(["remote", "set-url", "team", fixture.root.appendingPathComponent("missing.git").path])
        await state.pullBranch(branch)
        guard case .failed(let context, _) = state.gitRemoteOperationState else { throw VerificationError(message: "Pull failure was not published.") }
        try require(context.branch == "develop" && context.pullBranchName == "develop", "Pull state lost the target branch.")
        try fixture.git(["remote", "set-url", "team", fixture.remote.path])
        await state.retryGitRemoteOperation()
        guard case .succeeded(let result) = state.gitRemoteOperationState else { throw VerificationError(message: "Pull retry did not succeed on the selected branch.") }
        try require(result.context.branch == "develop", "Retry pulled the current branch instead of the selected branch.")
        try require(state.repositorySnapshots[repository.id]?.branch == "main", "Pull refresh selected another branch.")
        try fixture.verifyNoTemporaryWorktrees()
    }

    private static func verifyCurrentBranch() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.git(["branch", "--set-upstream-to=team/release/remote", "main"])
        try fixture.publish("new.txt", "current branch update\n")
        try Data("staged current\n".utf8).write(to: fixture.local.appendingPathComponent("base.txt"))
        try fixture.git(["add", "base.txt"])
        try Data("unstaged current\n".utf8).write(to: fixture.local.appendingPathComponent("base.txt"))
        let indexBefore = try fixture.output(["write-tree"])
        try await SystemGitRepositoryOperator().pullBranch(repositoryURL: fixture.local, branchName: "main")
        try require(try fixture.output(["rev-parse", "HEAD"]) == fixture.output(["rev-parse", "HEAD"], in: fixture.publisher), "Current-branch Pull did not update HEAD.")
        try require(try fixture.output(["show", ":base.txt"]) == "staged current", "Current Pull lost staged changes.")
        try require(try String(contentsOf: fixture.local.appendingPathComponent("base.txt"), encoding: .utf8) == "unstaged current\n", "Current Pull lost unstaged changes.")
        try require(try fixture.output(["write-tree"]) != indexBefore, "Current Pull did not include the fetched file in the index.")
        try fixture.git(["restore", "--staged", "--worktree", "base.txt"])
        try fixture.commit("base.txt", "current local conflict\n", in: fixture.local)
        try fixture.publish("base.txt", "current remote conflict\n")
        let repository = RegisteredRepository(displayName: "current-pull", relativePath: ".", isPinned: false)
        let state = AppState(workspace: WorkspaceSummary(url: fixture.local), repositories: [repository], selectedRepositoryID: repository.id, restoresWorkspaceOnLaunch: false)
        state.selectRepositoryContext(repository.id)
        await state.pullBranch(GitBranch(name: "main", hash: "stale", upstream: "team/release/remote", isRemote: false, isCurrent: false))
        guard case .requiresConflictResolution(let context, let count) = state.gitRemoteOperationState else { throw VerificationError(message: "Current-branch Pull did not enter conflict resolution.") }
        try require(context.branch == "main" && count == 1, "Current Pull conflict was attached to the wrong branch.")
        await state.abortMerge()
        try require(try fixture.output(["symbolic-ref", "HEAD"]) == "refs/heads/main", "Conflict abort changed branch.")
        try require(try fixture.output(["status", "--porcelain"]).isEmpty, "Conflict abort left unresolved changes.")
    }
}

private struct ConcurrentUpdateRunner: CommandRunning {
    let replacement: String

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let runner = SystemCommandRunner()
        if request.arguments.first == "update-ref", request.arguments.contains("refs/heads/develop") {
            let result = try await runner.run(CommandRequest(executableURL: request.executableURL, arguments: ["update-ref", "refs/heads/develop", replacement], workingDirectoryURL: request.workingDirectoryURL, environment: request.environment))
            guard result.terminationStatus == 0 else { throw VerificationError(message: "Could not simulate concurrent branch update.") }
        }
        return try await runner.run(request)
    }
}
