import Foundation
@testable import RepoDesk

private struct InteractionRestorationVerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyInteractionRestoration {
    static func main() async throws {
        try verifyPersistenceCompatibility()
        try verifyAppStateRestoration()
        try await verifyHistoryFileRestoration()
        print("Interaction restoration verification passed")
    }

    private static func verifyPersistenceCompatibility() throws {
        let suiteName = "RepoDeskInteractionRestoration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw InteractionRestorationVerificationError(message: "Could not create UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsWindowStateStore(defaults: defaults)
        let workspaceURL = URL(fileURLWithPath: "/tmp/interaction-persistence", isDirectory: true)
        let runID = UUID()
        let state = WorkspaceWindowState(
            selectedSection: .history,
            selectedFilePath: "/tmp/interaction-persistence/README.md",
            selectedFileShowsMarkdownPreview: true,
            fileTabSessionsByContext: [
                "workspace": FileTabSessionState(
                    tabs: [
                        PersistedFileTab(
                            path: "/tmp/interaction-persistence/README.md",
                            showsMarkdownPreview: true,
                            visibleLine: 12
                        ),
                        PersistedFileTab(
                            path: "/tmp/interaction-persistence/Sources/App.swift",
                            visibleLine: 38
                        )
                    ],
                    selectedFilePath: "/tmp/interaction-persistence/README.md"
                )
            ],
            selectedChangesByRepository: [
                "repo": GitChangeSelection(path: "Sources/App.swift", kind: .changes)
            ],
            selectedChangeRepositoryID: "repo",
            selectedCommitHashesByRepository: ["repo": "abc123"],
            selectedCommitFilesByRepository: [
                "repo": HistoryCommitFileSelection(commitHash: "abc123", path: "Sources/App.swift")
            ],
            mavenSelectionsByRepository: ["repo": .recentRun(runID)],
            historyGrouping: .all,
            navigationRepositoryID: "repo"
        )
        store.save(state, for: workspaceURL)
        try require(store.state(for: workspaceURL) == state, "Extended window state did not round-trip")

        let legacy = try JSONDecoder().decode(
            WorkspaceWindowState.self,
            from: Data(
                """
                {
                  "selectedSection": "Changes",
                  "selectedChangesByRepository": {}
                }
                """.utf8
            )
        )
        try require(!legacy.selectedFileShowsMarkdownPreview, "Legacy Markdown state default changed")
        try require(legacy.fileTabSessionsByContext.isEmpty, "Legacy file Tab state should be empty")
        try require(legacy.selectedChangeRepositoryID == nil, "Legacy Changes selection should be empty")
        try require(legacy.selectedCommitFilesByRepository.isEmpty, "Legacy History file state should be empty")
        try require(legacy.mavenSelectionsByRepository.isEmpty, "Legacy Maven state should be empty")
    }

    private static func verifyAppStateRestoration() throws {
        let workspaceURL = URL(fileURLWithPath: "/tmp/interaction-restoration", isDirectory: true)
        let repository = RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
        let change = GitChangeSelection(path: "Sources/App.swift", kind: .changes)
        let mavenSelection = MavenWindowSelection.target(modulePath: "service", goal: .install)
        let markdownURL = workspaceURL.appendingPathComponent("README.md")
        let sourceURL = workspaceURL.appendingPathComponent("Sources/App.swift")
        let windowStore = VerificationWindowStateStore(
            state: WorkspaceWindowState(
                selectedSection: .changes,
                selectedFilePath: markdownURL.path,
                selectedFileShowsMarkdownPreview: true,
                fileTabSessionsByContext: [
                    "workspace": FileTabSessionState(
                        tabs: [
                            PersistedFileTab(
                                path: markdownURL.path,
                                showsMarkdownPreview: true,
                                visibleLine: 14
                            ),
                            PersistedFileTab(path: sourceURL.path, visibleLine: 27)
                        ],
                        selectedFilePath: markdownURL.path
                    )
                ],
                selectedChangesByRepository: [repository.id: change],
                selectedChangeRepositoryID: repository.id,
                mavenSelectionsByRepository: [repository.id: mavenSelection],
                historyGrouping: .module
            )
        )
        let state = AppState(
            workspaceStore: VerificationWorkspaceStore(restoredURL: workspaceURL),
            repositoryStore: VerificationRepositoryStore(
                state: RepositoryWorkspaceState(
                    repositories: [repository],
                    selectedRepositoryID: repository.id
                )
            ),
            documentLoader: VerificationDocumentLoader(),
            windowStateStore: windowStore,
            restoresWorkspaceOnLaunch: true
        )

        try require(state.isWorkspaceContext, "Workspace navigation context was not restored")
        try require(state.selectedSection == .changes, "Selected section was not restored")
        try require(state.selectedChangeRepositoryID == repository.id, "Changes repository was not restored")
        try require(state.selectedChange == change, "Changes file was not restored")
        try require(state.mavenSelection(for: repository.id) == mavenSelection, "Maven selection was not restored")
        try require(state.historyGrouping == .module, "History grouping was not restored")
        state.toggleHistoryGrouping(.directory)
        try require(windowStore.savedState?.historyGrouping == .all, "History grouping was not persisted")
        try require(state.selectedFileURL == markdownURL, "Selected file was not restored")
        try require(state.showsMarkdownPreview, "Markdown view mode was not restored")
        try require(
            state.openFileTabs.map(\.url) == [markdownURL, sourceURL],
            "Open file Tabs were not restored in order"
        )
        try require(
            state.openFileTabs.map(\.visibleLine) == [14, 27],
            "Open file Tab line positions were not restored"
        )
        try require(
            windowStore.savedState?.selectedFileShowsMarkdownPreview == true,
            "Restoring a file overwrote its Markdown view mode"
        )
    }

    private static func verifyHistoryFileRestoration() async throws {
        let workspaceURL = URL(fileURLWithPath: "/tmp/history-selection-restoration", isDirectory: true)
        let repository = RegisteredRepository(displayName: "repo", relativePath: ".", isPinned: false)
        let selectedFile = GitCommitFile(path: "Sources/Selected.swift", originalPath: nil, status: .modified)
        let reader = VerificationGitReader(files: [
            GitCommitFile(path: "Sources/First.swift", originalPath: nil, status: .modified),
            selectedFile
        ])
        let state = AppState(
            workspaceStore: VerificationWorkspaceStore(restoredURL: workspaceURL),
            repositoryStore: VerificationRepositoryStore(
                state: RepositoryWorkspaceState(
                    repositories: [repository],
                    selectedRepositoryID: repository.id
                )
            ),
            gitRepositoryReader: reader,
            windowStateStore: VerificationWindowStateStore(
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
        for _ in 0..<200 where state.isLoadingCommit {
            await Task.yield()
        }
        try require(state.selectedCommitFile == selectedFile, "History commit file was not restored")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw InteractionRestorationVerificationError(message: message) }
    }
}

@MainActor
private final class VerificationWorkspaceStore: WorkspaceStoring {
    let restoredURL: URL?

    init(restoredURL: URL?) {
        self.restoredURL = restoredURL
    }

    func restoreLastWorkspace() -> URL? { restoredURL }
    func recentWorkspaces() -> [RecentWorkspace] { [] }
    func rememberWorkspace(_ url: URL) {}
    func removeWorkspace(_ workspace: RecentWorkspace) {}
    func resolve(_ workspace: RecentWorkspace) -> URL {
        URL(fileURLWithPath: workspace.path, isDirectory: true)
    }
}

@MainActor
private final class VerificationRepositoryStore: RepositoryStoring {
    let storedState: RepositoryWorkspaceState

    init(state: RepositoryWorkspaceState) {
        storedState = state
    }

    func state(for workspaceURL: URL) -> RepositoryWorkspaceState { storedState }
    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {}
}

@MainActor
private final class VerificationWindowStateStore: WindowStateStoring {
    let storedState: WorkspaceWindowState
    private(set) var savedState: WorkspaceWindowState?

    init(state: WorkspaceWindowState) {
        storedState = state
    }

    func state(for workspaceURL: URL) -> WorkspaceWindowState { storedState }
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {
        savedState = state
    }
}

private struct VerificationDocumentLoader: DocumentLoading {
    func load(_ fileURL: URL) async -> LoadedDocument {
        .text(
            LoadedTextDocument(
                text: "# Restored",
                isLarge: false,
                encoding: .utf8,
                revision: DocumentRevision(byteCount: 10, contentDigest: 0)
            )
        )
    }
}

private struct VerificationGitReader: GitRepositoryReading {
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
