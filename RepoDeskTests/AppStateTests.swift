import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct AppStateTests {
    @Test func selectedRepositoryUsesRepositoryIdentifier() {
        let state = AppState.preview

        #expect(state.selectedRepository?.name == "sample-service")
        state.selectedRepositoryID = "platform/common"
        #expect(state.selectedRepository?.name == "platform-common")
    }

    @Test func restoresLastWorkspaceOnLaunch() {
        let restoredURL = URL(fileURLWithPath: "/tmp/restored-workspace", isDirectory: true)
        let store = WorkspaceStoreDouble(restoredURL: restoredURL)

        let state = AppState(
            workspaceStore: store,
            workspacePicker: WorkspacePickerDouble(),
            repositoryStore: RepositoryStoreDouble(),
            restoresWorkspaceOnLaunch: true
        )

        #expect(state.workspace?.path == restoredURL.path)
        #expect(store.restoreCallCount == 1)
    }

    @Test func rootSnapshotTaskLoadsAllRepositoriesWhenRestoringFiles() async {
        let workspaceURL = URL(
            fileURLWithPath: "/tmp/restored-files-workspace",
            isDirectory: true
        )
        let repositories = ["repo-a", "repo-b", "repo-c"].map {
            RegisteredRepository(displayName: $0, relativePath: $0, isPinned: false)
        }
        let repositoryStore = RepositoryStoreDouble()
        repositoryStore.storedState = RepositoryWorkspaceState(
            repositories: repositories,
            selectedRepositoryID: repositories[0].id
        )
        let reader = RecordingSnapshotReader()
        let state = AppState(
            workspaceStore: WorkspaceStoreDouble(restoredURL: workspaceURL),
            repositoryStore: repositoryStore,
            gitRepositoryReader: reader,
            windowStateStore: WindowStateStoreDouble(selectedSection: .files),
            restoresWorkspaceOnLaunch: true
        )
        let rootView = RootView(appState: state)

        #expect(state.selectedSection == .files)
        await rootView.ensureWorkspaceRepositorySnapshots()

        #expect(Set(await reader.snapshotRepositoryNames()) == Set(repositories.map(\.id)))
        #expect(Set(state.repositorySnapshots.keys) == Set(repositories.map(\.id)))
        let restoredTaskID = RepositorySnapshotTaskID(
            workspacePath: workspaceURL.standardizedFileURL.path,
            repositoryIDs: repositories.map(\.id)
        )
        #expect(rootView.repositorySnapshotTaskID == restoredTaskID)

        state.repositories.append(
            RegisteredRepository(displayName: "repo-d", relativePath: "repo-d", isPinned: false)
        )
        #expect(rootView.repositorySnapshotTaskID != restoredTaskID)

        let repositoryTaskID = rootView.repositorySnapshotTaskID
        state.workspace = WorkspaceSummary(name: "other", path: "/tmp/other-workspace")
        #expect(rootView.repositorySnapshotTaskID != repositoryTaskID)
    }

    @Test func workspaceEventRefreshesAffectedUnselectedRepositoryOutsideChanges() async {
        let workspaceURL = URL(
            fileURLWithPath: "/tmp/workspace-event-refresh",
            isDirectory: true
        )
        let repositories = ["repo-a", "repo-b"].map {
            RegisteredRepository(displayName: $0, relativePath: $0, isPinned: false)
        }
        let changedURL = workspaceURL
            .appendingPathComponent("repo-b", isDirectory: true)
            .appendingPathComponent("Sources/App.swift")
        let monitor = OneShotWorkspaceChangeMonitor(
            batch: WorkspaceChangeBatch(
                changedURLs: [changedURL],
                requiresFullRescan: false,
                monitoringError: nil
            )
        )
        let reader = RecordingSnapshotReader()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            repositories: repositories,
            selectedRepositoryID: repositories[0].id,
            selectedSection: .files,
            gitRepositoryReader: reader,
            workspaceChangeMonitor: monitor,
            restoresWorkspaceOnLaunch: false
        )
        state.repositorySnapshots = Dictionary(
            uniqueKeysWithValues: repositories.map { ($0.id, snapshot(changes: [])) }
        )

        await state.monitorWorkspace()

        #expect(await reader.snapshotRepositoryNames() == ["repo-b"])
        #expect(state.refreshingRepositoryIDs.isEmpty)
        let changedRepositoryURL = workspaceURL.appendingPathComponent("repo-b", isDirectory: true)
        #expect(state.mavenProjectRevision(for: changedRepositoryURL) == 0)
    }

    @Test func workspacePomEventIncrementsOnlyAffectedMavenProjectRevision() async {
        let workspaceURL = URL(fileURLWithPath: "/tmp/maven-pom-refresh", isDirectory: true)
        let repositories = ["repo-a", "repo-b"].map {
            RegisteredRepository(displayName: $0, relativePath: $0, isPinned: false)
        }
        let changedRepositoryURL = workspaceURL.appendingPathComponent("repo-b", isDirectory: true)
        let monitor = OneShotWorkspaceChangeMonitor(
            batch: WorkspaceChangeBatch(
                changedURLs: [changedRepositoryURL.appendingPathComponent("module/pom.xml")],
                requiresFullRescan: false,
                monitoringError: nil
            )
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            repositories: repositories,
            selectedRepositoryID: repositories[0].id,
            selectedSection: .files,
            gitRepositoryReader: RecordingSnapshotReader(),
            workspaceChangeMonitor: monitor,
            restoresWorkspaceOnLaunch: false
        )

        await state.monitorWorkspace()

        #expect(
            state.mavenProjectRevision(
                for: workspaceURL.appendingPathComponent("repo-a", isDirectory: true)
            ) == 0
        )
        #expect(state.mavenProjectRevision(for: changedRepositoryURL) == 1)
    }

    @Test func choosingWorkspaceResetsRepositoryContext() {
        let selectedURL = URL(fileURLWithPath: "/tmp/new-workspace", isDirectory: true)
        let store = WorkspaceStoreDouble()
        let state = AppState(
            workspace: WorkspaceSummary(name: "old", path: "/tmp/old"),
            repositories: [
                RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
            ],
            selectedRepositoryID: "repo",
            selectedSection: .changes,
            workspaceStore: store,
            workspacePicker: WorkspacePickerDouble(selectedURL: selectedURL),
            repositoryStore: RepositoryStoreDouble(),
            restoresWorkspaceOnLaunch: false
        )

        state.chooseWorkspace()

        #expect(state.workspace?.path == selectedURL.path)
        #expect(state.repositories.isEmpty)
        #expect(state.selectedRepositoryID == nil)
        #expect(state.selectedSection == .overview)
        #expect(store.rememberedURLs == [selectedURL])
    }

    @Test func removingSelectedRepositorySelectsNextAndPersists() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let repositoryStore = RepositoryStoreDouble()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            repositories: [
                RegisteredRepository(displayName: "first", relativePath: "first", isPinned: false),
                RegisteredRepository(displayName: "second", relativePath: "second", isPinned: false)
            ],
            selectedRepositoryID: "first",
            repositoryStore: repositoryStore,
            restoresWorkspaceOnLaunch: false
        )

        state.removeRepository("first")

        #expect(state.repositories.map(\.id) == ["second"])
        #expect(state.selectedRepositoryID == "second")
        #expect(repositoryStore.savedState?.selectedRepositoryID == "second")
    }

    @Test func ignoredDiscoveryDirectoryPersistsWithoutBlockingManualRegistration() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskDiscoverySettings-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("generated/repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repositoryURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let repositoryStore = RepositoryStoreDouble()
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositoryStore: repositoryStore,
            repositoryPicker: FixedRepositoryPicker(selectedURL: repositoryURL),
            gitRepositoryReader: PagedGitReader(),
            restoresWorkspaceOnLaunch: false
        )

        state.chooseRepositoryDiscoveryIgnoredDirectory()

        #expect(state.repositoryDiscoverySettings.ignoredDirectoryPaths == ["generated/repo"])
        #expect(
            repositoryStore.savedState?.discoverySettings.ignoredDirectoryPaths
                == ["generated/repo"]
        )

        state.chooseRepository()

        #expect(state.repositories.map(\.relativePath) == ["generated/repo"])
        #expect(state.repositoryDiscoverySettings.ignoredDirectoryPaths == ["generated/repo"])
    }

    @Test func pinnedRepositoriesSortBeforeUnpinnedRepositories() {
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/workspace"),
            repositories: [
                RegisteredRepository(displayName: "first", relativePath: "first", isPinned: false),
                RegisteredRepository(displayName: "second", relativePath: "second", isPinned: false)
            ],
            repositoryStore: RepositoryStoreDouble(),
            restoresWorkspaceOnLaunch: false
        )

        state.toggleRepositoryPin("second")

        #expect(state.repositories.map(\.id) == ["second", "first"])
    }

    @Test func changesAreUniqueAndCanBeReadForRepositoriesOtherThanTheActiveRepository() {
        let active = RegisteredRepository(displayName: "active", relativePath: "active", isPinned: false)
        let other = RegisteredRepository(displayName: "other", relativePath: "other", isPinned: false)
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/workspace"),
            repositories: [active, other],
            selectedRepositoryID: active.id,
            restoresWorkspaceOnLaunch: false
        )
        let partiallyStagedAddition = GitFileChange(
            path: "file.swift",
            originalPath: nil,
            indexStatus: .added,
            workTreeStatus: .modified,
            isUntracked: false,
            isConflicted: false
        )
        let unversionedFile = GitFileChange(
            path: "notes.txt",
            originalPath: nil,
            indexStatus: .untracked,
            workTreeStatus: .untracked,
            isUntracked: true,
            isConflicted: false
        )
        state.repositorySnapshots[other.id] = snapshot(
            changes: [partiallyStagedAddition, unversionedFile]
        )

        #expect(state.changes(for: .changes, repositoryID: other.id).map(\.path) == ["file.swift"])
        #expect(state.changes(for: .unversioned, repositoryID: other.id).map(\.path) == ["notes.txt"])
        #expect(state.changes(for: .changes, repositoryID: active.id).isEmpty)
    }

    @Test func registeringDiscoveredRepositoriesLoadsEveryMissingSnapshotWithoutOpeningChanges() async {
        let workspaceURL = URL(fileURLWithPath: "/tmp/discovered-repositories", isDirectory: true)
        let repositories = ["repo-a", "repo-b", "repo-c"].map {
            RegisteredRepository(displayName: $0, relativePath: $0, isPinned: false)
        }
        let reader = RecordingSnapshotReader()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            selectedSection: .overview,
            repositoryStore: RepositoryStoreDouble(),
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )

        state.registerDiscoveredRepositories(repositories)
        for _ in 0..<100 where state.repositorySnapshots.count < repositories.count {
            await Task.yield()
        }

        #expect(state.selectedSection == .overview)
        #expect(Set(await reader.snapshotRepositoryNames()) == Set(repositories.map(\.id)))
        #expect(Set(state.repositorySnapshots.keys) == Set(repositories.map(\.id)))
    }

    @Test func registeringDiscoveredRepositoriesSkipsNewRepositoryWithExistingSnapshot() async {
        let repositories = ["repo-a", "repo-b", "repo-c"].map {
            RegisteredRepository(displayName: $0, relativePath: $0, isPinned: false)
        }
        let reader = RecordingSnapshotReader()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/discovered-repositories"),
            repositoryStore: RepositoryStoreDouble(),
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )
        state.repositorySnapshots["repo-b"] = snapshot(changes: [])

        state.registerDiscoveredRepositories(repositories)
        for _ in 0..<100 where state.repositorySnapshots.count < repositories.count {
            await Task.yield()
        }

        #expect(Set(await reader.snapshotRepositoryNames()) == ["repo-a", "repo-c"])
        #expect(Set(state.repositorySnapshots.keys) == Set(repositories.map(\.id)))
    }

    @Test func overviewLoadsMissingSnapshotsForRestoredRepositories() async {
        let repositories = ["repo-a", "repo-b", "repo-c"].map {
            RegisteredRepository(displayName: $0, relativePath: $0, isPinned: false)
        }
        let reader = RecordingSnapshotReader()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/restored-repositories"),
            repositories: repositories,
            selectedRepositoryID: repositories[0].id,
            selectedSection: .overview,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )
        state.repositorySnapshots[repositories[0].id] = snapshot(changes: [])

        await state.ensureRepositorySnapshots()

        #expect(Set(await reader.snapshotRepositoryNames()) == Set(repositories.dropFirst().map(\.id)))
        #expect(Set(state.repositorySnapshots.keys) == Set(repositories.map(\.id)))
    }

    @Test func refreshAllRepositoriesLimitsCrossRepositoryConcurrency() async {
        let repositories = (1...6).map {
            RegisteredRepository(displayName: "repo-\($0)", relativePath: "repo-\($0)", isPinned: false)
        }
        let reader = ControlledSnapshotReader()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/refresh-concurrency"),
            repositories: repositories,
            selectedRepositoryID: repositories[0].id,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )

        let refresh = Task { await state.refreshAllRepositories() }
        for _ in 0..<100 where await reader.startedCount() < 4 {
            await Task.yield()
        }

        #expect(await reader.startedCount() == 4)
        #expect(await reader.maximumActiveCount() == 4)
        await reader.unblock()
        await refresh.value

        #expect(await reader.startedCount() == repositories.count)
        #expect(await reader.maximumActiveCount() == 4)
        #expect(state.refreshingRepositoryIDs.isEmpty)
    }

    @Test func refreshChangesScopeFollowsRepositoryAndWorkspaceSelection() async {
        let repositories = ["repo-a", "repo-b"].map {
            RegisteredRepository(displayName: $0, relativePath: $0, isPinned: false)
        }
        let reader = RecordingSnapshotReader()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/changes-scope-refresh"),
            repositories: repositories,
            selectedRepositoryID: repositories[0].id,
            selectedSection: .changes,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )

        state.selectChangesRepositoryScope(repositories[1].id)
        await state.refreshChangesScope()
        #expect(await reader.snapshotRepositoryNames() == ["repo-b"])

        await reader.resetSnapshotRepositoryNames()
        state.selectRepositoryContext(repositories[0].id)
        await state.refreshChangesScope()
        #expect(await reader.snapshotRepositoryNames() == ["repo-a"])

        await reader.resetSnapshotRepositoryNames()
        state.selectWorkspaceContext()
        await state.refreshChangesScope()
        #expect(Set(await reader.snapshotRepositoryNames()) == Set(["repo-a", "repo-b"]))
    }

    @Test func overlappingRefreshForSameRepositorySharesRequestAndCleansState() async {
        let repository = RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
        let reader = ControlledSnapshotReader()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp/overlapping-refresh"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: reader,
            restoresWorkspaceOnLaunch: false
        )

        let firstRefresh = Task { await state.refreshAllRepositories() }
        for _ in 0..<100 where await reader.startedCount() < 1 {
            await Task.yield()
        }
        let overlappingRefresh = Task { await state.refreshAllRepositories() }
        for _ in 0..<20 { await Task.yield() }

        #expect(await reader.startedCount() == 1)
        #expect(state.refreshingRepositoryIDs == Set([repository.id]))
        await reader.unblock()
        await firstRefresh.value
        await overlappingRefresh.value

        #expect(await reader.startedCount() == 1)
        #expect(state.repositorySnapshots[repository.id] != nil)
        #expect(state.refreshingRepositoryIDs.isEmpty)
    }

    @Test func historyPaginationRemovesDuplicateBoundaryCommits() async {
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: ".",
            isPinned: false
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "tmp", path: "/tmp"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: PagedGitReader(),
            restoresWorkspaceOnLaunch: false
        )

        await state.loadHistory()
        await state.loadHistory(reset: false)

        #expect(state.commitHistory.map(\.hash) == ["a", "b", "c"])
    }

    @Test func relocatingRepositoryMigratesRepositoryKeyedWindowState() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskRelocation-\(UUID().uuidString)", isDirectory: true)
        let oldURL = workspaceURL.appendingPathComponent("old", isDirectory: true)
        let newURL = workspaceURL.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: newURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let repository = RegisteredRepository(
            displayName: "Custom Name",
            relativePath: "old",
            isPinned: true
        )
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            repositoryStore: RepositoryStoreDouble(),
            repositoryPicker: FixedRepositoryPicker(selectedURL: newURL),
            gitRepositoryReader: PagedGitReader(),
            taskStore: ApplicationSupportRepoTaskStore(
                applicationSupportURL: workspaceURL.appendingPathComponent("AppSupport")
            ),
            restoresWorkspaceOnLaunch: false
        )
        let selection = GitChangeSelection(path: "file.swift", kind: .changes)
        state.rememberedChangeSelections[repository.id] = selection
        state.rememberedHistoryBranchFilters[repository.id] = .branch("release")
        state.rememberedHistoryAuthorFilters[repository.id] = .author("RepoDesk")
        state.rememberedCommitHashes[repository.id] = "abc"

        state.relocateRepository(repository.id)

        #expect(state.repositories.map(\.id) == ["new"])
        #expect(state.repositories.first?.displayName == "Custom Name")
        #expect(state.repositories.first?.isPinned == true)
        #expect(state.selectedRepositoryID == "new")
        #expect(state.rememberedChangeSelections["new"] == selection)
        #expect(state.rememberedHistoryBranchFilters["new"] == .branch("release"))
        #expect(state.rememberedHistoryAuthorFilters["new"] == .author("RepoDesk"))
        #expect(state.rememberedCommitHashes["new"] == "abc")
        #expect(state.rememberedChangeSelections["old"] == nil)
    }

    @Test func moduleGroupingUsesNearestBuildMarker() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskModules-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("repo", isDirectory: true)
        let moduleURL = repositoryURL.appendingPathComponent("services/orders", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleURL, withIntermediateDirectories: true)
        try Data().write(to: moduleURL.appendingPathComponent("pom.xml"))
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let repository = RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            restoresWorkspaceOnLaunch: false
        )
        let selection = GitChangeSelection(
            path: "services/orders/src/main/java/Order.java",
            kind: .changes
        )

        #expect(state.modulePath(for: selection, repositoryID: repository.id) == "services/orders")
    }

    @Test func fileSwitchActivatesAnotherTabWithoutUnsavedConfirmation() async {
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            documentLoader: StaticDocumentLoader(),
            restoresWorkspaceOnLaunch: false
        )

        state.selectFile(firstURL)
        await waitForDocument(in: state)
        state.documentText = "edited"
        state.selectFile(secondURL)

        await waitForDocument(in: state)
        #expect(state.selectedFileURL == secondURL)
        #expect(state.documentText == "original")
        #expect(!state.hasUnsavedDocumentChanges)
        #expect(state.openFileTabs.map(\.url) == [firstURL, secondURL])
    }

    @Test func fileTabsUseConfiguredLimitAndCloseActions() async {
        let urls = (1...3).map { URL(fileURLWithPath: "/tmp/file\($0).txt") }
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            documentLoader: StaticDocumentLoader(),
            restoresWorkspaceOnLaunch: false
        )
        state.setMaximumOpenFileTabs(2)

        for url in urls {
            state.selectFile(url)
            await waitForDocument(in: state)
        }

        #expect(state.openFileTabs.map(\.url) == [urls[1], urls[2]])
        #expect(state.selectedFileURL == urls[2])

        state.closeSelectedFileTab()
        #expect(state.openFileTabs.map(\.url) == [urls[1]])
        #expect(state.selectedFileURL == urls[1])

        state.closeAllFileTabs()
        #expect(state.openFileTabs.isEmpty)
        #expect(state.selectedFileURL == nil)
    }

    @Test func commandWShortcutOnlyClosesSelectedFileInFilesSection() {
        #expect(
            RepoDeskKeyboardShortcut.isCloseFileTab(
                key: "w",
                modifiers: .command,
                selectedSection: .files,
                hasSelectedFile: true
            )
        )
        #expect(
            !RepoDeskKeyboardShortcut.isCloseFileTab(
                key: "w",
                modifiers: [.command, .shift],
                selectedSection: .files,
                hasSelectedFile: true
            )
        )
        #expect(
            !RepoDeskKeyboardShortcut.isCloseFileTab(
                key: "w",
                modifiers: .command,
                selectedSection: .changes,
                hasSelectedFile: true
            )
        )
        #expect(
            !RepoDeskKeyboardShortcut.isCloseFileTab(
                key: "w",
                modifiers: .command,
                selectedSection: .files,
                hasSelectedFile: false
            )
        )
    }

    @Test func commandZShortcutOnlyUndoesDeletionInFilesSection() {
        #expect(
            RepoDeskKeyboardShortcut.isUndoFileDeletion(
                key: "z",
                modifiers: .command,
                selectedSection: .files,
                canUndo: true
            )
        )
        #expect(
            !RepoDeskKeyboardShortcut.isUndoFileDeletion(
                key: "z",
                modifiers: [.command, .shift],
                selectedSection: .files,
                canUndo: true
            )
        )
        #expect(
            !RepoDeskKeyboardShortcut.isUndoFileDeletion(
                key: "z",
                modifiers: .command,
                selectedSection: .changes,
                canUndo: true
            )
        )
        #expect(
            !RepoDeskKeyboardShortcut.isUndoFileDeletion(
                key: "z",
                modifiers: .command,
                selectedSection: .files,
                canUndo: false
            )
        )
    }

    @Test func closingOtherFileTabsKeepsTargetAndActivatesIt() async throws {
        let urls = (1...3).map { URL(fileURLWithPath: "/tmp/other-file\($0).txt") }
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            documentLoader: StaticDocumentLoader(),
            restoresWorkspaceOnLaunch: false
        )
        state.setMaximumOpenFileTabs(3)

        for url in urls {
            state.selectFile(url)
            await waitForDocument(in: state)
        }

        let targetTab = try #require(state.openFileTabs.first { $0.url == urls[0] })
        state.closeOtherFileTabs(keeping: targetTab.id)

        #expect(state.openFileTabs.map(\.url) == [urls[0]])
        #expect(state.selectedFileURL == urls[0])
        #expect(state.documentText == "original")
    }

    @Test func fileTabsRestoreTheirLastVisibleLine() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            documentLoader: StaticDocumentLoader(),
            restoresWorkspaceOnLaunch: false
        )

        state.selectFile(firstURL)
        await waitForDocument(in: state)
        state.rememberSelectedFileVisibleLine(42)
        state.selectFile(secondURL)
        await waitForDocument(in: state)
        state.rememberSelectedFileVisibleLine(7)

        let firstTab = try #require(state.openFileTabs.first { $0.url == firstURL })
        state.selectFileTab(firstTab)

        #expect(state.selectedFileURL == firstURL)
        #expect(state.selectedSourceNavigationRequest?.line == 42)
        #expect(state.openFileTabs.first { $0.url == secondURL }?.visibleLine == 7)

        state.selectFile(firstURL, line: 18)
        #expect(state.selectedSourceNavigationRequest?.line == 18)
        #expect(state.openFileTabs.first { $0.url == firstURL }?.visibleLine == 18)
    }

    @Test func fileTabsAreScopedToWorkspaceAndRepositoryContexts() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskTabContexts-\(UUID().uuidString)", isDirectory: true)
        let repositoryAURL = workspaceURL.appendingPathComponent("repo-a", isDirectory: true)
        let repositoryBURL = workspaceURL.appendingPathComponent("repo-b", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryAURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repositoryBURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceFile = workspaceURL.appendingPathComponent("Workspace.txt")
        let repositoryAFile = repositoryAURL.appendingPathComponent("A.txt")
        let repositoryBFile = repositoryBURL.appendingPathComponent("B.txt")
        for fileURL in [workspaceFile, repositoryAFile, repositoryBFile] {
            try Data("original".utf8).write(to: fileURL)
        }
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [
                RegisteredRepository(displayName: "repo-a", relativePath: "repo-a", isPinned: false),
                RegisteredRepository(displayName: "repo-b", relativePath: "repo-b", isPinned: false)
            ],
            selectedRepositoryID: "repo-a",
            documentLoader: StaticDocumentLoader(),
            windowStateStore: WindowStateStoreDouble(selectedSection: .files),
            restoresWorkspaceOnLaunch: false
        )

        state.selectFile(workspaceFile)
        await waitForDocument(in: state)
        state.rememberSelectedFileVisibleLine(11)
        state.selectRepositoryContext("repo-a")
        #expect(state.openFileTabs.isEmpty)

        state.selectFile(repositoryAFile)
        await waitForDocument(in: state)
        state.rememberSelectedFileVisibleLine(22)
        state.selectRepositoryContext("repo-b")
        #expect(state.openFileTabs.isEmpty)

        state.selectFile(repositoryBFile)
        await waitForDocument(in: state)
        state.selectWorkspaceContext()
        #expect(state.openFileTabs.map(\.url) == [workspaceFile])
        #expect(state.selectedSourceNavigationRequest?.line == 11)

        state.selectRepositoryContext("repo-a")
        #expect(state.openFileTabs.map(\.url) == [repositoryAFile])
        #expect(state.selectedSourceNavigationRequest?.line == 22)

        state.selectRepositoryContext("repo-b")
        #expect(state.openFileTabs.map(\.url) == [repositoryBFile])
    }

    @Test func fileTabsRestoreAfterApplicationRelaunch() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskTabRelaunch-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let firstURL = repositoryURL.appendingPathComponent("First.md")
        let secondURL = repositoryURL.appendingPathComponent("Second.swift")
        try Data("# First".utf8).write(to: firstURL)
        try Data("let second = true".utf8).write(to: secondURL)
        let repository = RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
        let windowStateStore = WindowStateStoreDouble(selectedSection: .files)
        let repositoryStore = RepositoryStoreDouble()
        repositoryStore.storedState = RepositoryWorkspaceState(
            repositories: [repository],
            selectedRepositoryID: repository.id
        )
        let firstState = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            selectedSection: .files,
            repositoryStore: repositoryStore,
            documentLoader: StaticDocumentLoader(),
            windowStateStore: windowStateStore,
            restoresWorkspaceOnLaunch: false
        )
        firstState.selectRepositoryContext(repository.id)
        firstState.selectFile(firstURL)
        await waitForDocument(in: firstState)
        firstState.setMarkdownPreview(true)
        firstState.rememberSelectedFileVisibleLine(17)
        firstState.selectFile(secondURL)
        await waitForDocument(in: firstState)
        firstState.rememberSelectedFileVisibleLine(33)
        firstState.persistStateBeforeTermination()

        let restoredState = AppState(
            workspaceStore: WorkspaceStoreDouble(restoredURL: workspaceURL),
            repositoryStore: repositoryStore,
            documentLoader: StaticDocumentLoader(),
            windowStateStore: windowStateStore,
            restoresWorkspaceOnLaunch: true
        )

        #expect(restoredState.navigationContext == .repository(repository.id))
        #expect(restoredState.openFileTabs.map(\.url) == [firstURL, secondURL])
        #expect(restoredState.selectedFileURL == secondURL)
        #expect(restoredState.openFileTabs.first?.showsMarkdownPreview == true)
        #expect(restoredState.openFileTabs.first?.visibleLine == 17)
        #expect(restoredState.openFileTabs.last?.visibleLine == 33)
    }

    @Test func directoryLoadFailureCanBeRetried() async {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let browser = FlakyWorkspaceBrowser()
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            workspaceFileBrowser: browser,
            restoresWorkspaceOnLaunch: false
        )

        await state.loadWorkspaceRoot()
        #expect(state.directoryLoadErrors[workspaceURL] == "Directory is temporarily unavailable.")
        #expect(state.fileChildren[workspaceURL] == nil)

        state.retryDirectory(workspaceURL)
        for _ in 0..<100 where state.fileChildren[workspaceURL] == nil {
            await Task.yield()
        }
        #expect(state.directoryLoadErrors[workspaceURL] == nil)
        #expect(state.fileChildren[workspaceURL]?.map(\.name) == ["Recovered.txt"])
    }

    @Test func compactFoldersLoadSingleDirectoryChainOnExpansion() async {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let sourcesURL = workspaceURL.appendingPathComponent("Sources", isDirectory: true)
        let mainURL = sourcesURL.appendingPathComponent("main", isDirectory: true)
        let browser = DirectoryChainBrowser(
            entriesByDirectory: [
                workspaceURL: [WorkspaceFileEntry(url: sourcesURL, name: "Sources", isDirectory: true)],
                sourcesURL: [WorkspaceFileEntry(url: mainURL, name: "main", isDirectory: true)],
                mainURL: [
                    WorkspaceFileEntry(
                        url: mainURL.appendingPathComponent("App.swift"),
                        name: "App.swift",
                        isDirectory: false
                    )
                ]
            ]
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            workspaceFileBrowser: browser,
            restoresWorkspaceOnLaunch: false
        )

        await state.loadWorkspaceRoot()
        state.toggleDirectory(sourcesURL)
        for _ in 0..<100 where state.fileChildren[mainURL] == nil {
            await Task.yield()
        }

        #expect(state.fileChildren[mainURL]?.map(\.name) == ["App.swift"])
    }

    @Test func disablingCompactFoldersLoadsOnlyExpandedDirectory() async {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let sourcesURL = workspaceURL.appendingPathComponent("Sources", isDirectory: true)
        let mainURL = sourcesURL.appendingPathComponent("main", isDirectory: true)
        let browser = DirectoryChainBrowser(
            entriesByDirectory: [
                workspaceURL: [WorkspaceFileEntry(url: sourcesURL, name: "Sources", isDirectory: true)],
                sourcesURL: [WorkspaceFileEntry(url: mainURL, name: "main", isDirectory: true)],
                mainURL: []
            ]
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            workspaceFileBrowser: browser,
            restoresWorkspaceOnLaunch: false
        )
        state.setCompactsSingleChildDirectories(false)

        await state.loadWorkspaceRoot()
        state.toggleDirectory(sourcesURL)
        for _ in 0..<100 where state.fileChildren[sourcesURL] == nil {
            await Task.yield()
        }

        #expect(state.fileChildren[sourcesURL]?.map(\.name) == ["main"])
        #expect(state.fileChildren[mainURL] == nil)
    }

    @Test func revealingSelectedFileLoadsAndExpandsItsDirectoryChain() async {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let sourcesURL = workspaceURL.appendingPathComponent("Sources", isDirectory: true)
        let featureURL = sourcesURL.appendingPathComponent("Feature", isDirectory: true)
        let fileURL = featureURL.appendingPathComponent("Screen.swift")
        let browser = DirectoryChainBrowser(
            entriesByDirectory: [
                workspaceURL: [WorkspaceFileEntry(url: sourcesURL, name: "Sources", isDirectory: true)],
                sourcesURL: [WorkspaceFileEntry(url: featureURL, name: "Feature", isDirectory: true)],
                featureURL: [WorkspaceFileEntry(url: fileURL, name: "Screen.swift", isDirectory: false)]
            ]
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            workspaceFileBrowser: browser,
            restoresWorkspaceOnLaunch: false
        )
        state.selectedFileURL = fileURL

        #expect(state.canRevealSelectedFileInTree)
        await state.revealSelectedFileInTree()

        #expect(state.expandedDirectoryURLs == [sourcesURL, featureURL])
        #expect(state.fileChildren[featureURL]?.map(\.name) == ["Screen.swift"])
        #expect(state.fileTreeRevealRequest?.fileURL == fileURL)

        let firstRequestID = state.fileTreeRevealRequest?.id
        await state.revealSelectedFileInTree()
        #expect(state.fileTreeRevealRequest?.id != firstRequestID)
    }

    @Test func revealingSelectedFileIsDisabledWithoutAnInScopeFile() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            restoresWorkspaceOnLaunch: false
        )

        #expect(!state.canRevealSelectedFileInTree)
        state.selectedFileURL = URL(fileURLWithPath: "/tmp/other/Outside.swift")
        #expect(!state.canRevealSelectedFileInTree)
    }

    @Test func openingWorkspaceJavaNavigationSourceUsesResolvedSourceFile() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/java-navigation-workspace", isDirectory: true)
        let sourceURL = workspaceURL
            .appendingPathComponent(
                "manager/inventorymanager-client/src/main/java/com/example/InventoryManagerClientService.java"
            )
        let repository = RegisteredRepository(
            displayName: "manager",
            relativePath: "manager",
            isPinned: false
        )
        let dependencyURL = URL(
            string: "jdt://contents/inventorymanager-client-2.6.1-SNAPSHOT.jar/com/example/InventoryManagerClientService.class"
        )!
        let target = JavaNavigationTarget(
            fileURL: dependencyURL,
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 12, character: 4),
                end: JavaSourcePosition(line: 12, character: 28)
            ),
            selectionRange: nil,
            name: "InventoryManagerClientService",
            detail: nil,
            containerName: nil,
            kind: .interface,
            origin: .workspaceRepository(
                repositoryID: repository.id,
                repositoryName: repository.name,
                fileURL: sourceURL
            )
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            repositories: [repository],
            selectedRepositoryID: "other",
            selectedSection: .changes,
            restoresWorkspaceOnLaunch: false
        )
        state.javaNavigationSourcePresentation = JavaNavigationSourcePresentation(
            target: target,
            origin: target.origin!,
            navigationOrigin: nil,
            anchor: nil
        )

        state.openJavaNavigationSource()

        #expect(state.navigationContext == .repository(repository.id))
        #expect(state.selectedSection == .files)
        #expect(state.selectedFileURL == sourceURL.standardizedFileURL)
        #expect(state.openFileTabs.map(\.url) == [sourceURL.standardizedFileURL])
        #expect(state.javaNavigationSourcePresentation == nil)
    }

    @Test func crossRepositoryJavaNavigationPreservesBackForwardContext() {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-CrossRepositoryNavigation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let sourceURL = workspaceURL
            .appendingPathComponent("consumer/src/main/java/example/Consumer.java")
        let targetURL = workspaceURL
            .appendingPathComponent("manager/src/main/java/example/InventoryManagerClientService.java")
        try? FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("class Consumer {}".utf8).write(to: sourceURL)
        try? Data("interface InventoryManagerClientService {}".utf8).write(to: targetURL)

        let consumer = RegisteredRepository(
            displayName: "consumer",
            relativePath: "consumer",
            isPinned: false
        )
        let manager = RegisteredRepository(
            displayName: "manager",
            relativePath: "manager",
            isPinned: false
        )
        let origin = JavaNavigationHistoryEntry(
            fileURL: sourceURL,
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 4, character: 8),
                end: JavaSourcePosition(line: 4, character: 8)
            )
        )
        let target = JavaNavigationTarget(
            fileURL: targetURL,
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 12, character: 4),
                end: JavaSourcePosition(line: 12, character: 28)
            ),
            selectionRange: nil,
            name: "InventoryManagerClientService",
            detail: nil,
            containerName: nil,
            kind: .interface,
            origin: .workspaceRepository(
                repositoryID: manager.id,
                repositoryName: manager.name,
                fileURL: targetURL
            )
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: workspaceURL.path),
            repositories: [consumer, manager],
            selectedRepositoryID: consumer.id,
            selectedSection: .files,
            restoresWorkspaceOnLaunch: false
        )
        state.selectRepositoryContext(consumer.id)
        state.selectFile(sourceURL, range: origin.range)
        state.javaNavigationSourcePresentation = JavaNavigationSourcePresentation(
            target: target,
            origin: target.origin!,
            navigationOrigin: origin,
            anchor: nil
        )

        state.openJavaNavigationSource()

        #expect(state.navigationContext == .repository(manager.id))
        #expect(state.selectedFileURL == targetURL.standardizedFileURL)
        #expect(state.navigateFileBack())
        #expect(state.navigationContext == .repository(consumer.id))
        #expect(state.selectedFileURL == sourceURL.standardizedFileURL)
        #expect(state.navigateFileForward())
        #expect(state.navigationContext == .repository(manager.id))
        #expect(state.selectedFileURL == targetURL.standardizedFileURL)
    }

    private func waitForDocument(in state: AppState) async {
        for _ in 0..<100 where state.isLoadingDocument {
            await Task.yield()
        }
    }

    private func snapshot(changes: [GitFileChange]) -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: changes,
            lastCommit: nil
        )
    }
}

private actor RecordingSnapshotReader: GitRepositoryReading {
    private var repositoryNames: [String] = []

    func snapshotRepositoryNames() -> [String] { repositoryNames }

    func resetSnapshotRepositoryNames() {
        repositoryNames = []
    }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        repositoryNames.append(repositoryURL.lastPathComponent)
        return GitRepositorySnapshot(
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
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: "", author: "", authoredAt: nil),
            files: []
        )
    }
}

private struct OneShotWorkspaceChangeMonitor: WorkspaceChangeMonitoring {
    let batch: WorkspaceChangeBatch

    func events(in workspaceURL: URL) -> AsyncStream<WorkspaceChangeBatch> {
        AsyncStream { continuation in
            continuation.yield(batch)
            continuation.finish()
        }
    }
}

private actor ControlledSnapshotReader: GitRepositoryReading {
    private var isBlocked = true
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var started = 0
    private var active = 0
    private var maximumActive = 0

    func startedCount() -> Int { started }
    func maximumActiveCount() -> Int { maximumActive }

    func unblock() {
        isBlocked = false
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        started += 1
        active += 1
        maximumActive = max(maximumActive, active)
        if isBlocked {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        active -= 1
        return GitRepositorySnapshot(
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
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: "", author: "", authoredAt: nil),
            files: []
        )
    }
}

private struct PagedGitReader: GitRepositoryReading {
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
            path: "test.txt",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
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
        let hashes = skip == 0 ? ["a", "b"] : ["b", "c"]
        return hashes.map {
            GitCommitSummary(hash: $0, subject: $0, author: "Test", authoredAt: nil)
        }
    }

    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { ["Test"] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(hash: hash, subject: hash, author: "Test", authoredAt: nil),
            files: []
        )
    }
}

@MainActor
private struct FixedRepositoryPicker: RepositoryPicking {
    let selectedURL: URL

    func chooseRepository(in workspaceURL: URL, purpose: RepositoryPickerPurpose) -> URL? {
        selectedURL
    }
}

private actor FlakyWorkspaceBrowser: WorkspaceFileBrowsing {
    private var attemptCount = 0

    func children(of directoryURL: URL) async throws -> [WorkspaceFileEntry] {
        attemptCount += 1
        if attemptCount == 1 {
            throw DirectoryTemporarilyUnavailableError()
        }
        return [
            WorkspaceFileEntry(
                url: directoryURL.appendingPathComponent("Recovered.txt"),
                name: "Recovered.txt",
                isDirectory: false
            )
        ]
    }
}

private actor DirectoryChainBrowser: WorkspaceFileBrowsing {
    let entriesByDirectory: [URL: [WorkspaceFileEntry]]

    init(entriesByDirectory: [URL: [WorkspaceFileEntry]]) {
        self.entriesByDirectory = entriesByDirectory
    }

    func children(of directoryURL: URL) async throws -> [WorkspaceFileEntry] {
        entriesByDirectory[directoryURL.standardizedFileURL] ?? []
    }
}

private struct DirectoryTemporarilyUnavailableError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Directory is temporarily unavailable."
    }
}

private struct StaticDocumentLoader: DocumentLoading {
    func load(_ fileURL: URL) async -> LoadedDocument {
        let data = Data("original".utf8)
        return .text(
            LoadedTextDocument(
                text: "original",
                isLarge: false,
                encoding: .utf8,
                revision: FileSystemDocumentStore.revision(for: data)
            )
        )
    }
}

@MainActor
private final class WorkspaceStoreDouble: WorkspaceStoring {
    private let restoredURL: URL?
    private(set) var restoreCallCount = 0
    private(set) var rememberedURLs: [URL] = []

    init(restoredURL: URL? = nil) {
        self.restoredURL = restoredURL
    }

    func restoreLastWorkspace() -> URL? {
        restoreCallCount += 1
        return restoredURL
    }

    func recentWorkspaces() -> [RecentWorkspace] { [] }

    func rememberWorkspace(_ url: URL) {
        rememberedURLs.append(url)
    }

    func removeWorkspace(_ workspace: RecentWorkspace) {}

    func resolve(_ workspace: RecentWorkspace) -> URL {
        URL(fileURLWithPath: workspace.path, isDirectory: true)
    }
}

@MainActor
private struct WorkspacePickerDouble: WorkspacePicking {
    var selectedURL: URL?

    func chooseWorkspace() -> URL? { selectedURL }
}

@MainActor
private final class RepositoryStoreDouble: RepositoryStoring {
    var storedState: RepositoryWorkspaceState = .empty
    private(set) var savedState: RepositoryWorkspaceState?

    func state(for workspaceURL: URL) -> RepositoryWorkspaceState {
        storedState
    }

    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {
        savedState = state
    }
}

@MainActor
private final class WindowStateStoreDouble: WindowStateStoring {
    private var storedState: WorkspaceWindowState

    init(selectedSection: AppSection) {
        storedState = WorkspaceWindowState(
            selectedSection: selectedSection,
            selectedFilePath: nil,
            selectedChangesByRepository: [:]
        )
    }

    func state(for workspaceURL: URL) -> WorkspaceWindowState {
        storedState
    }

    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {
        storedState = state
    }
}
