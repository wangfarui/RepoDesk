import Foundation
@testable import RepoDesk

private struct QAIntegrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
@MainActor
enum QAIntegrationVerification {
    static func main() async throws {
        try await verifyRealGitLifecycle()
        try verifyWindowStateAndAppStateRestoration()
        print("QA integration verification passed")
    }

    private static func verifyRealGitLifecycle() async throws {
        let fixture = try await RealGitFixture()
        defer { fixture.remove() }
        let reader = SystemGitRepositoryReader()
        let gitOperator = SystemGitRepositoryOperator()

        try Data("initial\nworking tree\n".utf8).write(to: fixture.url.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: fixture.url.appendingPathComponent("untracked.txt"))
        let snapshot = try await reader.snapshot(repositoryURL: fixture.url)
        try require(snapshot.unstagedCount == 1, "Real Git snapshot lost the tracked change.")
        try require(snapshot.untrackedCount == 1, "Real Git snapshot lost the untracked file.")

        let committedBlame = try await reader.blame(
            repositoryURL: fixture.url,
            path: "tracked.txt",
            revision: "HEAD",
            contentsPath: nil
        )
        let workingBlame = try await reader.blame(
            repositoryURL: fixture.url,
            path: "tracked.txt",
            revision: "HEAD",
            contentsPath: "tracked.txt"
        )
        try require(committedBlame.count == 1, "Committed Blame did not return the committed line.")
        try require(workingBlame.count == 2 && workingBlame[1].isUncommitted, "Working-tree Blame did not identify the new line.")

        let repository = RegisteredRepository(
            displayName: "qa-repository",
            relativePath: ".",
            isPinned: true
        )
        let fileBlameState = AppState(
            workspace: WorkspaceSummary(url: fixture.url),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )
        fileBlameState.selectedFileURL = fixture.url.appendingPathComponent("tracked.txt")
        fileBlameState.loadedDocument = .text(
            LoadedTextDocument(
                text: "initial\nworking tree\n",
                isLarge: false,
                encoding: .utf8,
                revision: DocumentRevision(byteCount: 0, contentDigest: 0)
            )
        )
        fileBlameState.documentText = "initial\neditor line\n"
        fileBlameState.documentOriginalText = "initial\nworking tree\n"
        fileBlameState.repositorySnapshots[repository.id] = snapshot
        let fileViewBlame = try await fileBlameState.blameForSelectedFile()
        try require(
            fileViewBlame.count == 2 && fileViewBlame[1].isUncommitted,
            "Files Blame did not annotate the current editor contents."
        )

        _ = try await gitOperator.createCommit(
            repositoryURL: fixture.url,
            message: "QA real commit",
            changes: [
                GitChangeSelection(path: "tracked.txt", kind: .changes),
                GitChangeSelection(path: "untracked.txt", kind: .unversioned)
            ]
        )
        let committedStatus = try await fixture.gitOutput(["status", "--porcelain"])
        let committedSubject = try await fixture.gitOutput(["log", "-1", "--format=%s"])
        try require(committedStatus.isEmpty, "Real Commit left working-tree changes.")
        try require(committedSubject == "QA real commit", "Real Commit subject was not persisted.")

        try Data("stashed tracked change\n".utf8).write(
            to: fixture.url.appendingPathComponent("tracked.txt")
        )
        try Data("stashed untracked change\n".utf8).write(
            to: fixture.url.appendingPathComponent("stash-untracked.txt")
        )
        try await gitOperator.stashChanges(repositoryURL: fixture.url, message: "QA stash")
        let stashes = try await gitOperator.listStashes(repositoryURL: fixture.url)
        let stash = try value(stashes.first, "Real Stash was not listed.")
        try require(stash.reference == "stash@{0}", "Real Stash reference was not preserved.")
        let stashedStatus = try await fixture.gitOutput(["status", "--porcelain"])
        try require(
            stashedStatus.isEmpty,
            "Real Stash left working-tree changes."
        )

        try await gitOperator.unstashChanges(repositoryURL: fixture.url, stash: stash)
        let restoredTrackedContents = try String(
            contentsOf: fixture.url.appendingPathComponent("tracked.txt"),
            encoding: .utf8
        )
        let restoredUntrackedContents = try String(
            contentsOf: fixture.url.appendingPathComponent("stash-untracked.txt"),
            encoding: .utf8
        )
        try require(
            restoredTrackedContents == "stashed tracked change\n",
            "Real Unstash did not restore the tracked change."
        )
        try require(
            restoredUntrackedContents == "stashed untracked change\n",
            "Real Unstash did not restore the untracked change."
        )
        let stashesAfterRestore = try await gitOperator.listStashes(repositoryURL: fixture.url)
        try require(
            stashesAfterRestore.isEmpty,
            "Real Unstash did not remove the restored Stash."
        )

        try await gitOperator.stashChanges(repositoryURL: fixture.url, message: "QA dropped stash")
        let stashToDrop = try value(
            try await gitOperator.listStashes(repositoryURL: fixture.url).first,
            "Real Stash for deletion was not listed."
        )
        try await gitOperator.dropStash(repositoryURL: fixture.url, stash: stashToDrop)
        let stashesAfterDrop = try await gitOperator.listStashes(repositoryURL: fixture.url)
        try require(
            stashesAfterDrop.isEmpty,
            "Real Stash deletion did not remove the selected Stash."
        )

        let remoteURL = try await fixture.makeBareRemote()
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        try await fixture.git(["remote", "add", "origin", remoteURL.path])
        try await fixture.git(["push", "--set-upstream", "origin", "main"])
        try await fixture.git(["switch", "--create", "feature/qa"])
        try Data("feature\n".utf8).write(to: fixture.url.appendingPathComponent("feature.txt"))
        try await fixture.git(["add", "feature.txt"])
        try await fixture.git(["commit", "--message", "Feature change"])
        try await fixture.git(["push", "--set-upstream", "origin", "feature/qa"])
        try await fixture.git(["switch", "main"])
        try await fixture.git(["branch", "--delete", "feature/qa"])

        let remoteBranch = try value(
            try await reader.branches(repositoryURL: fixture.url).first { $0.name == "origin/feature/qa" },
            "Remote tracking Branch was not discovered."
        )
        try await gitOperator.switchBranch(repositoryURL: fixture.url, branch: remoteBranch)
        let currentBranch = try await fixture.gitOutput(["branch", "--show-current"])
        let upstreamBranch = try await fixture.gitOutput(["rev-parse", "--abbrev-ref", "@{upstream}"])
        try require(currentBranch == "feature/qa", "Remote tracking Branch did not checkout locally.")
        try require(upstreamBranch == "origin/feature/qa", "Tracking upstream was not configured.")

        try await fixture.git(["switch", "main"])
        try Data("feature conflict\n".utf8).write(to: fixture.url.appendingPathComponent("conflict.txt"))
        try await fixture.git(["add", "conflict.txt"])
        try await fixture.git(["commit", "--message", "Feature conflict"])
        try await fixture.git(["switch", "feature/qa"])
        try Data("branch conflict\n".utf8).write(to: fixture.url.appendingPathComponent("conflict.txt"))
        try await fixture.git(["add", "conflict.txt"])
        try await fixture.git(["commit", "--message", "Branch conflict"])
        try await fixture.git(["switch", "main"])
        try Data("main conflict\n".utf8).write(to: fixture.url.appendingPathComponent("conflict.txt"))
        try await fixture.git(["add", "conflict.txt"])
        try await fixture.git(["commit", "--message", "Main conflict"])

        do {
            try await gitOperator.mergeBranch(
                repositoryURL: fixture.url,
                branch: GitBranch(name: "feature/qa", hash: "", upstream: "origin/feature/qa", isRemote: false, isCurrent: false)
            )
            throw QAIntegrationFailure(message: "Conflicting Merge unexpectedly completed without a conflict.")
        } catch is GitRepositoryOperationError {
            // Expected: the conflict is resolved through the explicit RepoDesk flow below.
        }
        let conflicts = try await gitOperator.conflictFiles(repositoryURL: fixture.url)
        try require(conflicts.count == 1 && conflicts[0].path == "conflict.txt", "Conflict file was not exposed.")
        var resolved = conflicts[0]
        resolved.result = "resolved\n"
        try await gitOperator.resolveConflict(repositoryURL: fixture.url, file: resolved)
        try await gitOperator.continueMerge(repositoryURL: fixture.url)
        let mergeStatus = try await fixture.gitOutput(["status", "--porcelain"])
        try require(mergeStatus.isEmpty, "Continue Merge left a dirty working tree.")
    }

    private static func verifyWindowStateAndAppStateRestoration() throws {
        let suiteName = "RepoDeskQAIntegration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw QAIntegrationFailure(message: "Could not create an isolated UserDefaults suite.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspaceURL = URL(fileURLWithPath: "/tmp/qa-restoration", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try? Data("# QA\n".utf8).write(to: workspaceURL.appendingPathComponent("README.md"))
        let repository = RegisteredRepository(displayName: "service", relativePath: "service", isPinned: false)
        let selection = GitChangeSelection(path: "Sources/App.swift", kind: .changes)
        let mavenSelection = MavenWindowSelection.target(modulePath: "service", goal: .package)
        let windowState = WorkspaceWindowState(
            selectedSection: .tasks,
            selectedFilePath: workspaceURL.appendingPathComponent("README.md").path,
            selectedFileShowsMarkdownPreview: true,
            selectedChangesByRepository: [repository.id: selection],
            selectedChangeRepositoryID: repository.id,
            selectedCommitHashesByRepository: [repository.id: "abc123"],
            selectedCommitFilesByRepository: [repository.id: HistoryCommitFileSelection(commitHash: "abc123", path: "Sources/App.swift")],
            mavenSelectionsByRepository: [repository.id: mavenSelection],
            changesRepositoryScopeID: repository.id,
            changesGrouping: .module,
            navigationRepositoryID: repository.id,
            historyVerticalSplitFraction: 0.42,
            historyHorizontalSplitFraction: 0.61
        )
        let store = UserDefaultsWindowStateStore(defaults: defaults)
        store.save(windowState, for: workspaceURL)
        try require(store.state(for: workspaceURL) == windowState, "Window state did not round-trip through UserDefaults.")

        let appState = AppState(
            workspaceStore: QAWorkspaceStore(restoredURL: workspaceURL),
            repositoryStore: QARepositoryStore(repositories: [repository]),
            windowStateStore: store,
            restoresWorkspaceOnLaunch: true
        )
        try require(appState.selectedSection == .tasks, "AppState did not restore the selected page.")
        try require(appState.selectedFileURL?.lastPathComponent == "README.md", "AppState did not restore the selected file.")
        try require(appState.selectedChange == selection, "AppState did not restore the Changes selection.")
        try require(appState.mavenSelection(for: repository.id) == mavenSelection, "AppState did not restore Maven selection.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw QAIntegrationFailure(message: message) }
    }

    private static func value<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw QAIntegrationFailure(message: message) }
        return value
    }
}

private struct RealGitFixture: Sendable {
    let url: URL
    private let runner = SystemCommandRunner(timeout: .seconds(30))

    init() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskQAIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await git(["init", "--initial-branch", "main"])
        try await git(["config", "user.email", "repodesk@example.invalid"])
        try await git(["config", "user.name", "RepoDesk QA"])
        try Data("initial\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
        try Data("base\n".utf8).write(to: url.appendingPathComponent("conflict.txt"))
        try await git(["add", "--all"])
        try await git(["commit", "--message", "Initial commit"])
    }

    func makeBareRemote() async throws -> URL {
        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskQA-remote-\(UUID().uuidString).git", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
        let result = try await runner.run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "--bare"],
            workingDirectoryURL: remoteURL,
            environment: nil
        ))
        try require(result.terminationStatus == 0, "Could not create the QA bare remote.")
        return remoteURL
    }

    func git(_ arguments: [String]) async throws {
        let result = try await runner.run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectoryURL: url,
            environment: nil
        ))
        try require(result.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed: \(String(decoding: result.standardError, as: UTF8.self))")
    }

    func gitOutput(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectoryURL: url,
            environment: nil
        ))
        try require(result.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed.")
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw QAIntegrationFailure(message: message) }
    }
}

@MainActor
private final class QAWorkspaceStore: WorkspaceStoring {
    let restoredURL: URL?
    init(restoredURL: URL?) { self.restoredURL = restoredURL }
    func restoreLastWorkspace() -> URL? { restoredURL }
    func recentWorkspaces() -> [RecentWorkspace] { [] }
    func rememberWorkspace(_ url: URL) {}
    func removeWorkspace(_ workspace: RecentWorkspace) {}
    func resolve(_ workspace: RecentWorkspace) -> URL { URL(fileURLWithPath: workspace.path, isDirectory: true) }
}

@MainActor
private final class QARepositoryStore: RepositoryStoring {
    let stateValue: RepositoryWorkspaceState
    init(repositories: [RegisteredRepository]) {
        stateValue = RepositoryWorkspaceState(repositories: repositories, selectedRepositoryID: repositories.first?.id)
    }
    func state(for workspaceURL: URL) -> RepositoryWorkspaceState { stateValue }
    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {}
}
