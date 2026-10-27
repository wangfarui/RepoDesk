import Foundation
@testable import RepoDesk

private struct VerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@main
enum VerifyHistoryHashSearch {
    static func main() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskHashSearch-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = workspace.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let suiteName = "RepoDeskHashSearch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = try await git(["init", "-b", "main"], at: repositoryURL)
        _ = try await git(["config", "user.name", "Search Author"], at: repositoryURL)
        _ = try await git(["config", "user.email", "search@example.invalid"], at: repositoryURL)
        try Data("original\n".utf8).write(to: repositoryURL.appendingPathComponent("old.txt"))
        _ = try await git(["add", "old.txt"], at: repositoryURL)
        _ = try await git(["commit", "-m", "Old target"], at: repositoryURL)
        let oldest = try await git(["rev-parse", "HEAD"], at: repositoryURL)
        for index in 0..<60 {
            _ = try await git(["commit", "--allow-empty", "-m", "Recent \(index)"], at: repositoryURL)
        }
        _ = try await git(["mv", "old.txt", "renamed.txt"], at: repositoryURL)
        _ = try await git(["commit", "-m", "Rename tracked file"], at: repositoryURL)
        let newest = try await git(["rev-parse", "HEAD"], at: repositoryURL)
        _ = try await git(["checkout", "-b", "side", oldest], at: repositoryURL)
        _ = try await git(["commit", "--allow-empty", "--author=Other Author <other@example.invalid>", "-m", "Side target"], at: repositoryURL)
        let side = try await git(["rev-parse", "HEAD"], at: repositoryURL)
        _ = try await git(["checkout", "main"], at: repositoryURL)

        let reader = SystemGitRepositoryReader()
        let initial = try await reader.history(repositoryURL: repositoryURL, limit: 50, skip: 0, revision: nil, author: nil)
        try require(initial.count == 50 && !initial.contains { $0.hash == oldest }, "Fixture must place the target beyond the first page")
        func search(_ query: String, path: String? = nil, limit: Int = 50, skip: Int = 0,
                    revision: String? = nil, author: String? = nil) async throws -> [GitCommitSummary] {
            try await reader.searchHistory(repositoryURL: repositoryURL, hashPrefix: query, path: path,
                                           limit: limit, skip: skip, revision: revision, author: author)
        }
        let oldMatch = try await search(" \n\(oldest.prefix(12).uppercased()) \n")
        try require(oldMatch.map(\.hash) == [oldest], "Short hash must find unloaded commits and normalize case/whitespace")
        try require(try await search(oldest).map(\.hash) == [oldest], "Full hash must match")
        try require(try await search("not-a-hash").isEmpty, "Invalid hash must return no matches")
        try require(try await search(String(repeating: "0", count: 40)).isEmpty, "Missing hash must return no matches")
        try require(try await search(side).isEmpty, "Current branch must exclude side-only commits")
        try require(try await search(side, revision: "--all").map(\.hash) == [side], "All branches must include side-only commits")
        try require(try await search(side, revision: "side", author: "Other Author").map(\.hash) == [side], "Branch and author filters must apply together")
        try require(try await search(side, revision: "--all", author: "Search Author").isEmpty, "Author filter must exclude other authors")
        try require(try await search(oldest, path: "renamed.txt").map(\.hash) == [oldest], "File history search must follow renames")
        try require(try await search(oldest, path: "missing.txt").isEmpty, "File scope must exclude unrelated commits")

        let all = try await reader.history(repositoryURL: repositoryURL, limit: 100, skip: 0, revision: nil, author: nil)
        let prefix = Dictionary(grouping: all, by: { String($0.hash.prefix(1)) })
            .first { $0.value.count > 1 }!.key
        let expected = all.filter { $0.hash.hasPrefix(prefix) }
        let firstMatch = try await search(prefix, limit: 1)
        let secondMatch = try await search(prefix, limit: 1, skip: 1)
        try require(firstMatch.map(\.hash) == [expected[0].hash] && secondMatch.map(\.hash) == [expected[1].hash],
                    "Ambiguous prefixes must retain history order and paginate matching commits")

        let repository = RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
        func makeState(reader: any GitRepositoryReading) -> AppState {
            AppState(workspace: WorkspaceSummary(url: workspace), repositories: [repository],
                     selectedRepositoryID: repository.id, selectedSection: .history,
                     gitRepositoryReader: reader, windowStateStore: UserDefaultsWindowStateStore(defaults: defaults),
                     restoresWorkspaceOnLaunch: false)
        }
        let state = makeState(reader: reader)
        await state.loadHistory()
        state.setHistoryHashQuery(" \(oldest.prefix(12).uppercased()) ")
        try await waitUntil { !state.isLoadingHistory && !state.isLoadingCommit }
        try require(state.commitHistory.map(\.hash) == [oldest] && state.selectedCommitDetail?.summary.hash == oldest,
                    "Unique match must select and load the target detail")
        state.selectHistoryAuthorFilter(.author("Other Author"))
        try await waitUntil { !state.isLoadingHistory }
        try require(state.commitHistory.isEmpty && state.selectedCommitHash == nil, "Changing author must reapply the hash query")
        state.selectHistoryAuthorFilter(.all)
        try await waitUntil { !state.isLoadingHistory }
        state.setHistoryHashQuery("not-a-hash")
        try await waitUntil { !state.isLoadingHistory }
        try require(state.commitHistory.isEmpty && state.selectedCommitDetail == nil && !state.hasMoreHistory,
                    "No match must clear old details and disable pagination")
        state.setHistoryHashQuery("")
        try await waitUntil { !state.isLoadingHistory }
        try require(state.commitHistory.map(\.hash) == initial.map(\.hash) && state.hasMoreHistory,
                    "Clearing search must restore normal History pagination")
        state.setHistoryHashQuery(side)
        state.selectHistoryBranchFilter(.all)
        try await waitUntil { !state.isLoadingHistory }
        try require(state.commitHistory.map(\.hash) == [side], "Changing branch must reapply the hash query")

        let gate = SuspendedHashLogRunner()
        let racingState = makeState(reader: SystemGitRepositoryReader(commandRunner: gate))
        racingState.setHistoryHashQuery(oldest)
        try await waitUntil { await gate.started }
        racingState.setHistoryHashQuery(newest)
        try await waitUntil { !racingState.isLoadingHistory }
        await gate.release()
        try await waitUntil { await gate.finished }
        try require(racingState.commitHistory.map(\.hash) == [newest], "An old search must not overwrite a newer query")

        // Switching repositories also cancels a query still waiting in the debounce interval.
        let secondRepository = RegisteredRepository(displayName: "other", relativePath: "other", isPinned: false)
        let switchState = AppState(workspace: WorkspaceSummary(url: workspace), repositories: [repository, secondRepository],
                                   selectedRepositoryID: repository.id, gitRepositoryReader: reader,
                                   windowStateStore: UserDefaultsWindowStateStore(defaults: defaults), restoresWorkspaceOnLaunch: false)
        switchState.setHistoryHashQuery(oldest)
        switchState.selectRepository(secondRepository.id)
        try await Task.sleep(for: .milliseconds(350))
        try require(switchState.historyHashQuery.isEmpty && switchState.commitHistory.isEmpty && !switchState.isLoadingHistory,
                    "Switching repositories must clear the query and cancel pending searches")
        print("History hash search verification passed (unloaded history, prefixes, scopes, pagination, selection, clear, stale requests)")
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VerificationFailure(message: "Timed out waiting for History search")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationFailure(message: message) }
    }

    private static func git(_ arguments: [String], at repositoryURL: URL) async throws -> String {
        let result = try await SystemCommandRunner().run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments,
            workingDirectoryURL: repositoryURL, environment: nil
        ))
        guard result.terminationStatus == 0 else {
            throw VerificationFailure(message: String(decoding: result.standardError, as: UTF8.self))
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor SuspendedHashLogRunner: CommandRunning {
    private(set) var started = false
    private(set) var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let result = try await SystemCommandRunner().run(request)
        if request.arguments.contains("--format=%H"), !started {
            started = true
            await withCheckedContinuation { continuation = $0 }
            finished = true
        }
        return result
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
