import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct HistoryAuthorFilterTests {
    @Test func selectMeUsesResolvedGitUserAndPersistsSemanticFilter() async {
        let repository = RegisteredRepository(
            displayName: "repo-a",
            relativePath: "repo-a",
            isPinned: false
        )
        let reader = HistoryAuthorReader(userNamesByRepository: ["repo-a": "Alice"])
        let state = makeState(repositories: [repository], selectedRepositoryID: repository.id, reader: reader)

        await state.loadHistoryAuthors()
        state.selectHistoryAuthorFilter(.me)
        await waitUntil { await reader.historyAuthors().contains("Alice") }

        #expect(state.historyAuthorFilter == .me)
        #expect(state.rememberedHistoryAuthorFilters[repository.id] == .me)
        #expect(await reader.historyAuthors().contains("Alice"))
    }

    @Test func selectMeWithoutGitUserDoesNotLoadUnfilteredHistory() async {
        let repository = RegisteredRepository(
            displayName: "repo-a",
            relativePath: "repo-a",
            isPinned: false
        )
        let reader = HistoryAuthorReader(userNamesByRepository: [:])
        let state = makeState(repositories: [repository], selectedRepositoryID: repository.id, reader: reader)

        await state.loadHistoryAuthors()
        state.selectHistoryAuthorFilter(.me)
        await Task.yield()
        await Task.yield()

        #expect(state.historyAuthorFilter == .me)
        #expect(state.rememberedHistoryAuthorFilters[repository.id] == .me)
        #expect(state.historyCurrentUserName == nil)
        #expect(state.historyCurrentUserErrorMessage == "当前 Repository 未配置 Git user.name。")
        #expect(await reader.historyAuthors().isEmpty)
        #expect(state.commitHistory.isEmpty)
        #expect(!state.hasMoreHistory)
    }

    @Test func switchingRepositoriesResolvesEachGitUserIndependently() async {
        let repositories = [
            RegisteredRepository(displayName: "repo-a", relativePath: "repo-a", isPinned: false),
            RegisteredRepository(displayName: "repo-b", relativePath: "repo-b", isPinned: false)
        ]
        let reader = HistoryAuthorReader(
            userNamesByRepository: ["repo-a": "Alice", "repo-b": "Bob"]
        )
        let state = makeState(
            repositories: repositories,
            selectedRepositoryID: repositories[0].id,
            reader: reader
        )

        await state.loadHistoryAuthors()
        #expect(state.historyCurrentUserName == "Alice")

        state.selectRepository(repositories[1].id)
        #expect(state.historyCurrentUserName == nil)
        await state.loadHistoryAuthors()

        #expect(state.historyCurrentUserName == "Bob")
        #expect(await reader.userNameRepositoryNames() == ["repo-a", "repo-b"])
    }

    private func makeState(
        repositories: [RegisteredRepository],
        selectedRepositoryID: RegisteredRepository.ID,
        reader: HistoryAuthorReader
    ) -> AppState {
        AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/history-author-filter"),
            repositories: repositories,
            selectedRepositoryID: selectedRepositoryID,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<100 {
            if await condition() { return }
            await Task.yield()
        }
    }
}

private actor HistoryAuthorReader: GitRepositoryReading {
    private let userNamesByRepository: [String: String]
    private var requestedHistoryAuthors: [String?] = []
    private var requestedUserNameRepositories: [String] = []

    init(userNamesByRepository: [String: String]) {
        self.userNamesByRepository = userNamesByRepository
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
    ) async throws -> [GitCommitSummary] {
        requestedHistoryAuthors.append(author)
        return []
    }

    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }

    func authors(repositoryURL: URL) async throws -> [String] {
        Array(userNamesByRepository.values).sorted()
    }

    func currentUserName(repositoryURL: URL) async throws -> String? {
        let repositoryName = repositoryURL.lastPathComponent
        requestedUserNameRepositories.append(repositoryName)
        return userNamesByRepository[repositoryName]
    }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: "", author: "", authoredAt: nil),
            files: []
        )
    }

    func historyAuthors() -> [String?] { requestedHistoryAuthors }

    func userNameRepositoryNames() -> [String] { requestedUserNameRepositories }
}
