import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct NavigationContextTests {
    @Test func availableSectionsFollowNavigationContext() {
        let state = makeState()

        #expect(state.isWorkspaceContext)
        #expect(state.availableSections == [.overview, .changes, .files, .tasks])

        state.selectRepositoryContext("repo-a")

        #expect(state.isRepositoryContext)
        #expect(state.availableSections == [.changes, .files, .history, .tasks])
    }

    @Test func selectingWorkspaceContextLeavesRepositoryOnlySection() {
        let state = makeState()
        state.selectRepositoryContext("repo-a")
        state.selectSection(.history)

        state.selectWorkspaceContext()

        #expect(state.isWorkspaceContext)
        #expect(state.selectedSection == .overview)
        #expect(state.changesRepositoryScopeID == nil)
    }

    @Test func selectingRepositoryContextSelectsRepositoryAndDefaultSection() {
        let state = makeState()

        state.selectRepositoryContext("repo-b")

        #expect(state.isRepositoryContext)
        #expect(state.selectedRepositoryID == "repo-b")
        #expect(state.selectedSection == .changes)
        #expect(state.changesRepositoryScopeID == "repo-b")
    }

    @Test func reselectingActiveRepositoryReconcilesChangesSelectionAndDiff() {
        let state = makeState()
        let repositorySelection = GitChangeSelection(path: "src/RepoA.java", kind: .changes)
        let otherRepositorySelection = GitChangeSelection(path: "src/RepoB.java", kind: .changes)
        state.rememberedChangeSelections["repo-a"] = repositorySelection
        state.selectedChangeRepositoryID = "repo-b"
        state.selectedChange = otherRepositorySelection
        state.currentDiff = GitFileDiff(
            path: otherRepositorySelection.path,
            originalPath: nil,
            oldLabel: "a/src/RepoB.java",
            newLabel: "b/src/RepoB.java",
            oldLines: ["old"],
            newLines: ["new"],
            hunks: [],
            isBinary: false
        )

        state.selectRepositoryContext("repo-a")

        #expect(state.navigationContext == .repository("repo-a"))
        #expect(state.selectedRepositoryID == "repo-a")
        #expect(state.changesRepositoryScopeID == "repo-a")
        #expect(state.selectedChangeRepositoryID == "repo-a")
        #expect(state.selectedChange == repositorySelection)
        #expect(state.currentDiff == nil)
    }

    @Test func selectingChangeFromAnotherRepositoryKeepsWorkspaceContext() {
        let state = makeState()
        let selection = GitChangeSelection(path: "src/Other.java", kind: .changes)

        state.selectChange(selection, repositoryID: "repo-b")

        #expect(state.isWorkspaceContext)
        #expect(state.selectedRepositoryID == "repo-a")
        #expect(state.selectedChangeRepositoryID == "repo-b")
        #expect(state.selectedChange == selection)
    }

    @Test func restoresRepositoryNavigationContextFromWindowState() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/navigation-context-restore", isDirectory: true)
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: "repo",
            isPinned: false
        )
        let windowState = WorkspaceWindowState(
            selectedSection: .history,
            selectedFilePath: nil,
            selectedChangesByRepository: [:],
            navigationRepositoryID: repository.id
        )
        let state = AppState(
            workspaceStore: NavigationWorkspaceStore(restoredURL: workspaceURL),
            repositoryStore: NavigationRepositoryStore(
                state: RepositoryWorkspaceState(
                    repositories: [repository],
                    selectedRepositoryID: repository.id
                )
            ),
            windowStateStore: NavigationWindowStateStore(state: windowState),
            restoresWorkspaceOnLaunch: true
        )

        #expect(state.isRepositoryContext)
        #expect(state.selectedRepositoryID == repository.id)
        #expect(state.selectedSection == .history)
        #expect(state.availableSections == [.changes, .files, .history, .tasks])
    }

    private func makeState() -> AppState {
        AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/navigation-context"),
            repositories: [
                RegisteredRepository(displayName: "repo-a", relativePath: "repo-a", isPinned: false),
                RegisteredRepository(displayName: "repo-b", relativePath: "repo-b", isPinned: false)
            ],
            selectedRepositoryID: "repo-a",
            repositoryStore: NavigationRepositoryStore(state: .empty),
            gitRepositoryReader: NavigationGitReader(),
            windowStateStore: NavigationWindowStateStore(state: .initial),
            restoresWorkspaceOnLaunch: false
        )
    }
}

private struct NavigationGitReader: GitRepositoryReading {
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
            path: "src/Other.java",
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
        GitCommitDetail(
            summary: GitCommitSummary(
                hash: hash,
                subject: "",
                author: "",
                authoredAt: nil
            ),
            files: []
        )
    }
}

@MainActor
private final class NavigationWorkspaceStore: WorkspaceStoring {
    let restoredURL: URL?

    init(restoredURL: URL?) {
        self.restoredURL = restoredURL
    }

    func restoreLastWorkspace() -> URL? { restoredURL }
    func recentWorkspaces() -> [RecentWorkspace] { [] }
    func rememberWorkspace(_ url: URL) {}
    func resolve(_ workspace: RecentWorkspace) -> URL {
        URL(fileURLWithPath: workspace.path, isDirectory: true)
    }
}

@MainActor
private final class NavigationRepositoryStore: RepositoryStoring {
    private let storedState: RepositoryWorkspaceState

    init(state: RepositoryWorkspaceState) {
        storedState = state
    }

    func state(for workspaceURL: URL) -> RepositoryWorkspaceState { storedState }
    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {}
}

@MainActor
private final class NavigationWindowStateStore: WindowStateStoring {
    private let storedState: WorkspaceWindowState

    init(state: WorkspaceWindowState) {
        storedState = state
    }

    func state(for workspaceURL: URL) -> WorkspaceWindowState { storedState }
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {}
}
