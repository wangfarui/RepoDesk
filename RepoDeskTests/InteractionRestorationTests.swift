import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct InteractionRestorationTests {
    @Test func restoresWorkspaceChangesAndMavenSelections() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/interaction-restoration", isDirectory: true)
        let repository = RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
        let change = GitChangeSelection(path: "Sources/App.swift", kind: .changes)
        let mavenSelection = MavenWindowSelection.target(modulePath: "service", goal: .package)
        let state = AppState(
            workspaceStore: RestorationWorkspaceStore(restoredURL: workspaceURL),
            repositoryStore: RestorationRepositoryStore(
                state: RepositoryWorkspaceState(
                    repositories: [repository],
                    selectedRepositoryID: repository.id
                )
            ),
            windowStateStore: RestorationWindowStateStore(
                state: WorkspaceWindowState(
                    selectedSection: .changes,
                    selectedFilePath: nil,
                    selectedChangesByRepository: [repository.id: change],
                    selectedChangeRepositoryID: repository.id,
                    mavenSelectionsByRepository: [repository.id: mavenSelection]
                )
            ),
            restoresWorkspaceOnLaunch: true
        )

        #expect(state.isWorkspaceContext)
        #expect(state.selectedSection == .changes)
        #expect(state.selectedChangeRepositoryID == repository.id)
        #expect(state.selectedChange == change)
        #expect(state.mavenSelection(for: repository.id) == mavenSelection)
    }

    @Test func restoresSelectedCommitFileAfterCommitLoads() async {
        let workspaceURL = URL(fileURLWithPath: "/tmp/history-file-restoration", isDirectory: true)
        let repository = RegisteredRepository(displayName: "repo", relativePath: ".", isPinned: false)
        let selectedFile = GitCommitFile(path: "Sources/Selected.swift", originalPath: nil, status: .modified)
        let reader = RestorationGitReader(files: [
            GitCommitFile(path: "Sources/First.swift", originalPath: nil, status: .modified),
            selectedFile
        ])
        let state = AppState(
            workspaceStore: RestorationWorkspaceStore(restoredURL: workspaceURL),
            repositoryStore: RestorationRepositoryStore(
                state: RepositoryWorkspaceState(
                    repositories: [repository],
                    selectedRepositoryID: repository.id
                )
            ),
            gitRepositoryReader: reader,
            windowStateStore: RestorationWindowStateStore(
                state: WorkspaceWindowState(
                    selectedSection: .history,
                    selectedFilePath: nil,
                    selectedChangesByRepository: [:],
                    selectedCommitHashesByRepository: [repository.id: "abc123"],
                    selectedCommitFilesByRepository: [
                        repository.id: HistoryCommitFileSelection(
                            commitHash: "abc123",
                            path: selectedFile.path
                        )
                    ],
                    navigationRepositoryID: repository.id
                )
            ),
            restoresWorkspaceOnLaunch: true
        )

        state.selectCommit("abc123")
        for _ in 0..<100 where state.isLoadingCommit {
            await Task.yield()
        }

        #expect(state.selectedCommitFile == selectedFile)
    }
}

@MainActor
private final class RestorationWorkspaceStore: WorkspaceStoring {
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
private final class RestorationRepositoryStore: RepositoryStoring {
    let storedState: RepositoryWorkspaceState

    init(state: RepositoryWorkspaceState) {
        storedState = state
    }

    func state(for workspaceURL: URL) -> RepositoryWorkspaceState { storedState }
    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {}
}

@MainActor
private final class RestorationWindowStateStore: WindowStateStoring {
    let storedState: WorkspaceWindowState

    init(state: WorkspaceWindowState) {
        storedState = state
    }

    func state(for workspaceURL: URL) -> WorkspaceWindowState { storedState }
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {}
}

private struct RestorationGitReader: GitRepositoryReading {
    let files: [GitCommitFile]

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
            path: files.first?.path ?? "",
            originalPath: nil,
            oldLabel: "before",
            newLabel: "after",
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
                subject: "Restore selection",
                author: "RepoDesk",
                authoredAt: nil
            ),
            files: files
        )
    }
}
