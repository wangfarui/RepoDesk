import Foundation
import Testing
@testable import RepoDesk

struct GitRepositoryOperatorTests {
    @Test func createCommitStagesEverythingAndDoesNotExposeMessageInErrors() async throws {
        let secretMessage = "PMY-2048 internal customer detail"
        let runner = SequencedGitCommandRunner(
            results: [
                commandResult(),
                commandResult(status: 1, error: "hook rejected \(secretMessage)")
            ]
        )
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)

        do {
            _ = try await operatorUnderTest.createCommit(
                repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
                message: secretMessage
            )
            Issue.record("Expected Commit to fail")
        } catch let error as GitRepositoryOperationError {
            #expect(error.errorDescription?.contains(secretMessage) == false)
            #expect(error.errorDescription?.contains("<redacted>") == true)
        }

        let requests = await runner.recordedRequests()
        #expect(requests.map(\.arguments) == [
            ["add", "--all"],
            ["commit", "--message", secretMessage]
        ])
        #expect(requests.allSatisfy { $0.environment?["LC_ALL"] == "C" })
        #expect(requests.allSatisfy { $0.environment?["GIT_TERMINAL_PROMPT"] == "0" })
    }

    @Test func createCommitRejectsWhitespaceWithoutStartingGit() async {
        let runner = SequencedGitCommandRunner(results: [])
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)

        do {
            _ = try await operatorUnderTest.createCommit(
                repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
                message: " \n\t "
            )
            Issue.record("Expected empty message to be rejected")
        } catch let error as GitRepositoryOperationError {
            #expect(error == .emptyCommitMessage)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let requests = await runner.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test func partialCommitStagesAndCommitsOnlySelectedPaths() async throws {
        let runner = SequencedGitCommandRunner(
            results: [commandResult(), commandResult(), commandResult(output: "created\n")]
        )
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)

        _ = try await operatorUnderTest.createCommit(
            repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
            message: "Partial commit",
            changes: [
                GitChangeSelection(
                    path: "Sources/New.swift",
                    kind: .changes,
                    originalPath: "Sources/Old.swift"
                )
            ]
        )

        let requests = await runner.recordedRequests()
        #expect(requests.map(\.arguments) == [
            ["add", "--all", "--", "Sources/New.swift", "Sources/Old.swift"],
            ["commit", "--message", "Partial commit", "--only", "--", "Sources/New.swift", "Sources/Old.swift"],
            ["rev-parse", "--verify", "HEAD"]
        ])
    }

    @Test func fetchPullAndPushUseCurrentRepositoryCommands() async throws {
        let runner = SequencedGitCommandRunner(
            results: [commandResult(), commandResult(), commandResult()]
        )
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)
        let repositoryURL = URL(fileURLWithPath: "/tmp/repo")

        try await operatorUnderTest.fetch(repositoryURL: repositoryURL)
        try await operatorUnderTest.pullCurrentBranch(repositoryURL: repositoryURL)
        try await operatorUnderTest.pushCurrentBranch(repositoryURL: repositoryURL)

        let requests = await runner.recordedRequests()
        #expect(requests.map(\.arguments) == [
            ["fetch", "--all", "--prune"],
            ["pull"],
            ["push", "--porcelain"]
        ])
    }

    @Test func stashCommandsIncludeUntrackedFilesAndParseEntries() async throws {
        let runner = SequencedGitCommandRunner(
            results: [
                commandResult(),
                commandResult(output: "1111111111111111111111111111111111111111\0stash@{0}\0On main: WIP\n2222222222222222222222222222222222222222\0stash@{1}\0On main: Older\n"),
                commandResult(),
                commandResult()
            ]
        )
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)
        let repositoryURL = URL(fileURLWithPath: "/tmp/repo")

        try await operatorUnderTest.stashChanges(repositoryURL: repositoryURL, message: "WIP")
        let stashes = try await operatorUnderTest.listStashes(repositoryURL: repositoryURL)
        try await operatorUnderTest.unstashChanges(
            repositoryURL: repositoryURL,
            stash: stashes[0]
        )
        try await operatorUnderTest.dropStash(
            repositoryURL: repositoryURL,
            stash: stashes[1]
        )

        #expect(stashes == [
            GitStash(reference: "stash@{0}", message: "On main: WIP", hash: "1111111111111111111111111111111111111111"),
            GitStash(reference: "stash@{1}", message: "On main: Older", hash: "2222222222222222222222222222222222222222")
        ])
        let requests = await runner.recordedRequests()
        #expect(requests.map(\.arguments) == [
            ["stash", "push", "--include-untracked", "--message", "WIP"],
            ["stash", "list", "--format=%H%x00%gd%x00%gs"],
            ["stash", "pop", "stash@{0}"],
            ["stash", "drop", "stash@{1}"]
        ])
    }

    @Test func rollbackRestoresTrackedPathsAndHandlesUntrackedPathsSeparately() async throws {
        let runner = SequencedGitCommandRunner(results: [commandResult()])
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)
        let repositoryURL = URL(fileURLWithPath: "/tmp/repo")

        try await operatorUnderTest.rollbackChanges(
            repositoryURL: repositoryURL,
            changes: [
                GitChangeSelection(path: "Sources/App.swift", kind: .changes),
                GitChangeSelection(path: "Scratch.txt", kind: .unversioned)
            ]
        )

        let requests = await runner.recordedRequests()
        #expect(requests.map(\.arguments) == [
            ["restore", "--source=HEAD", "--staged", "--worktree", "--", "Sources/App.swift"]
        ])
    }

    @Test func pushOutcomeDistinguishesUpToDateFromPublishedCommits() async throws {
        let runner = SequencedGitCommandRunner(
            results: [
                commandResult(output: "=\trefs/heads/main:refs/heads/main\t[up to date]\nDone\n"),
                commandResult(output: " \trefs/heads/main:refs/heads/main\tabc123..def456\nDone\n")
            ]
        )
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)
        let repositoryURL = URL(fileURLWithPath: "/tmp/repo")

        let upToDate = try await operatorUnderTest.pushCurrentBranchOutcome(
            repositoryURL: repositoryURL
        )
        let pushed = try await operatorUnderTest.pushCurrentBranchOutcome(
            repositoryURL: repositoryURL
        )

        #expect(upToDate == .upToDate)
        #expect(pushed == .pushed)
    }

    @Test func explicitPushCreatesRemoteBranchAndSetsUpstreamWithoutSwitching() async throws {
        let runner = SequencedGitCommandRunner(
            results: [
                commandResult(),
                commandResult(output: "*\trefs/heads/feature/local:refs/heads/review/remote\t[new branch]\nDone\n")
            ]
        )
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)

        let outcome = try await operatorUnderTest.push(
            repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
            localBranch: "feature/local",
            remote: "origin",
            remoteBranch: "review/remote",
            setUpstream: true
        )

        let requests = await runner.recordedRequests()
        #expect(outcome == .pushed)
        #expect(requests.map(\.arguments) == [
            ["check-ref-format", "--branch", "review/remote"],
            [
                "push", "--porcelain", "--set-upstream", "origin",
                "refs/heads/feature/local:refs/heads/review/remote"
            ]
        ])
        #expect(!requests.flatMap(\.arguments).contains("switch"))
    }

    @Test func remoteBranchCreatesTrackingBranchWhenLocalBranchIsMissing() async throws {
        let runner = SequencedGitCommandRunner(
            results: [commandResult(status: 1), commandResult()]
        )
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)
        let branch = GitBranch(
            name: "origin/feature/payments",
            hash: "abc",
            upstream: nil,
            isRemote: true,
            isCurrent: false
        )

        try await operatorUnderTest.switchBranch(
            repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
            branch: branch
        )

        let requests = await runner.recordedRequests()
        #expect(requests.map(\.arguments) == [
            ["show-ref", "--verify", "--quiet", "refs/heads/feature/payments"],
            ["switch", "--track", "--create", "feature/payments", "origin/feature/payments"]
        ])
    }

    @Test func remoteBranchUsesExistingLocalBranchAndRejectsRemoteHead() async throws {
        let runner = SequencedGitCommandRunner(results: [commandResult(), commandResult()])
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)
        let branch = GitBranch(
            name: "origin/release",
            hash: "abc",
            upstream: nil,
            isRemote: true,
            isCurrent: false
        )

        _ = try await operatorUnderTest.switchBranch(
            repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
            branch: branch
        )
        let requests = await runner.recordedRequests()
        #expect(requests.map(\.arguments) == [
            ["show-ref", "--verify", "--quiet", "refs/heads/release"],
            ["switch", "release"]
        ])

        do {
            _ = try await operatorUnderTest.switchBranch(
                repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
                branch: GitBranch(
                    name: "origin/HEAD",
                    hash: "abc",
                    upstream: nil,
                    isRemote: true,
                    isCurrent: false
                )
            )
            Issue.record("Expected origin/HEAD to be rejected")
        } catch let error as GitRepositoryOperationError {
            #expect(error == .invalidRemoteBranch("origin/HEAD"))
        }
    }

    @Test func localBranchSwitchAndPushUseNonInteractiveGitCommands() async throws {
        let runner = SequencedGitCommandRunner(results: [commandResult(), commandResult()])
        let operatorUnderTest = SystemGitRepositoryOperator(commandRunner: runner)

        try await operatorUnderTest.switchBranch(
            repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
            branch: GitBranch(
                name: "release/next",
                hash: "abc",
                upstream: "origin/release/next",
                isRemote: false,
                isCurrent: false
            )
        )
        try await operatorUnderTest.pushCurrentBranch(
            repositoryURL: URL(fileURLWithPath: "/tmp/repo")
        )

        let requests = await runner.recordedRequests()
        #expect(requests.map(\.arguments) == [["switch", "release/next"], ["push", "--porcelain"]])
        #expect(requests.allSatisfy { $0.environment?["GIT_TERMINAL_PROMPT"] == "0" })
    }

    @Test func createsRealCommitContainingTrackedAndUnversionedFiles() async throws {
        let fixture = try await GitOperatorFixture()
        defer { fixture.remove() }
        try Data("changed\n".utf8).write(to: fixture.url.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: fixture.url.appendingPathComponent("unversioned.txt"))

        let result = try await SystemGitRepositoryOperator().createCommit(
            repositoryURL: fixture.url,
            message: "Commit from RepoDesk"
        )

        let head = try await fixture.gitOutput(["rev-parse", "HEAD"])
        let subject = try await fixture.gitOutput(["log", "-1", "--format=%s"])
        let status = try await fixture.gitOutput(["status", "--porcelain"])
        #expect(result.hash == head)
        #expect(subject == "Commit from RepoDesk")
        #expect(status.isEmpty)
    }

    @Test func switchesRealRemoteBranchToNewTrackingBranch() async throws {
        let fixture = try await GitOperatorFixture()
        defer { fixture.remove() }
        let remoteURL = try await fixture.makeBareRemote()
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try await fixture.git(["remote", "add", "origin", remoteURL.path])
        try await fixture.git(["push", "--set-upstream", "origin", "main"])
        try await fixture.git(["switch", "--create", "feature/remote"])
        try Data("remote\n".utf8).write(to: fixture.url.appendingPathComponent("remote.txt"))
        try await fixture.git(["add", "--all"])
        try await fixture.git(["commit", "--message", "Remote branch"])
        try await fixture.git(["push", "--set-upstream", "origin", "feature/remote"])
        try await fixture.git(["switch", "main"])
        try await fixture.git(["branch", "--delete", "feature/remote"])

        try await SystemGitRepositoryOperator().switchBranch(
            repositoryURL: fixture.url,
            branch: GitBranch(
                name: "origin/feature/remote",
                hash: "unused",
                upstream: nil,
                isRemote: true,
                isCurrent: false
            )
        )

        let current = try await fixture.gitOutput(["branch", "--show-current"])
        let upstream = try await fixture.gitOutput(["rev-parse", "--abbrev-ref", "@{upstream}"])
        #expect(current == "feature/remote")
        #expect(upstream == "origin/feature/remote")
    }
}

private actor SequencedGitCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private var requests: [CommandRequest] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        guard !results.isEmpty else {
            return commandResult(status: 1, error: "Unexpected Git command")
        }
        return results.removeFirst()
    }

    func recordedRequests() -> [CommandRequest] {
        requests
    }
}

private struct GitOperatorFixture: Sendable {
    let url: URL
    private let runner = SystemCommandRunner(timeout: .seconds(30))

    init() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskGitOperatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await git(["init", "--initial-branch", "main"])
        try await git(["config", "user.email", "repodesk@example.invalid"])
        try await git(["config", "user.name", "RepoDesk Tests"])
        try Data("initial\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
        try await git(["add", "tracked.txt"])
        try await git(["commit", "--message", "Initial commit"])
    }

    func makeBareRemote() async throws -> URL {
        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskGitRemote-\(UUID().uuidString).git", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["init", "--bare"],
                workingDirectoryURL: remoteURL,
                environment: nil
            )
        )
        guard result.terminationStatus == 0 else {
            throw GitRepositoryOperationError.commandFailed(
                operation: .resolveBranch,
                message: String(decoding: result.standardError, as: UTF8.self)
            )
        }
        return remoteURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func git(_ arguments: [String]) async throws {
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                workingDirectoryURL: url,
                environment: nil
            )
        )
        guard result.terminationStatus == 0 else {
            throw GitRepositoryOperationError.commandFailed(
                operation: .resolveBranch,
                message: String(decoding: result.standardError, as: UTF8.self)
            )
        }
    }

    func gitOutput(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                workingDirectoryURL: url,
                environment: nil
            )
        )
        guard result.terminationStatus == 0 else {
            throw GitRepositoryOperationError.commandFailed(
                operation: .resolveBranch,
                message: String(decoding: result.standardError, as: UTF8.self)
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func commandResult(
    status: Int32 = 0,
    output: String = "",
    error: String = ""
) -> CommandResult {
    CommandResult(
        standardOutput: Data(output.utf8),
        standardError: Data(error.utf8),
        terminationStatus: status
    )
}
