import Foundation
import Observation

struct FileTreeRevealRequest: Equatable, Sendable {
    let id = UUID()
    let fileURL: URL
}

struct GitFileBlameTarget: Equatable, Sendable {
    let repositoryID: RegisteredRepository.ID
    let repositoryURL: URL
    let path: String

    static func resolve(
        fileURL: URL,
        workspaceURL: URL,
        repositories: [RegisteredRepository]
    ) -> GitFileBlameTarget? {
        let fileURL = fileURL.standardizedFileURL
        let workspaceURL = workspaceURL.standardizedFileURL

        return repositories.compactMap { repository -> GitFileBlameTarget? in
            let repositoryURL = repository.relativePath == "."
                ? workspaceURL
                : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
                    .standardizedFileURL
            guard WorkspaceTreeRefreshPlanner.isSameOrDescendant(fileURL, of: repositoryURL),
                  fileURL != repositoryURL else { return nil }
            let repositoryPrefix = repositoryURL.path.hasSuffix("/")
                ? repositoryURL.path
                : repositoryURL.path + "/"
            guard fileURL.path.hasPrefix(repositoryPrefix) else { return nil }
            return GitFileBlameTarget(
                repositoryID: repository.id,
                repositoryURL: repositoryURL,
                path: String(fileURL.path.dropFirst(repositoryPrefix.count))
            )
        }
        .max { lhs, rhs in
            lhs.repositoryURL.path.count < rhs.repositoryURL.path.count
        }
    }
}

struct OpenFileTab: Equatable, Identifiable, Sendable {
    var url: URL
    var loadedDocument: LoadedDocument?
    var text: String
    var originalText: String
    var fingerprint: String?
    var showsMarkdownPreview: Bool
    var isLoading: Bool
    var visibleLine: Int
    var importsExpanded = false

    var id: URL { url }
}

private actor RepositoryRefreshLimiter {
    private var availableSlots: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        precondition(limit > 0)
        availableSlots = limit
    }

    func acquire() async {
        if availableSlots > 0 {
            availableSlots -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availableSlots += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
@Observable
final class AppState {
    var workspace: WorkspaceSummary?
    var repositories: [RegisteredRepository]
    var selectedRepositoryID: RegisteredRepository.ID?
    var navigationContext: NavigationContext = .workspace
    var selectedSection: AppSection
    var lastRefreshed: Date?
    var recentWorkspaces: [RecentWorkspace]
    var discoveredRepositories: [RegisteredRepository] = []
    var repositoryDiscoverySettings = RepositoryDiscoverySettings.default
    var repositoryDiscoverySettingsErrorMessage: String?
    var isDiscoveringRepositories = false
    var isShowingDiscoveryResults = false
    var presentedRepositoryError: RepositoryRegistrationError?
    var repositorySnapshots: [RegisteredRepository.ID: GitRepositorySnapshot] = [:]
    var repositorySnapshotErrors: [RegisteredRepository.ID: String] = [:]
    var refreshingRepositoryIDs: Set<RegisteredRepository.ID> = []
    var selectedChange: GitChangeSelection?
    var selectedChangeRepositoryID: RegisteredRepository.ID?
    var currentDiff: GitFileDiff?
    var diffErrorMessage: String?
    var isLoadingDiff = false
    var ignoresWhitespaceInDiff = false
    var diffPresentation: GitDiffPresentation = .unified
    var changesAutoExpansion = ChangesAutoExpansionSettings.default
    var changesRepositoryScopeID: RegisteredRepository.ID?
    var changesGrouping: GitChangesGrouping = .directory
    var commitMessageDrafts: [RegisteredRepository.ID: String] = [:]
    var excludedCommitChanges: [RegisteredRepository.ID: Set<GitChangeSelection>] = [:]
    var commitExecutionState: GitCommitExecutionState = .idle
    var gitRemoteOperationState: GitRemoteOperationState = .idle
    var gitStashes: [GitStash] = []
    var stashesErrorMessage: String?
    var isSwitchingBranch = false
    var branchSwitchErrorMessage: String?
    var isPerformingBranchOperation = false
    var branchOperationErrorMessage: String?
    var branchOperationStatusMessage: String?
    var branchComparison: GitBranchComparison?
    var isLoadingBranchComparison = false
    var conflictFiles: [GitConflictFile] = []
    /// Files staged as resolved during the current merge, retained for review/revert.
    var resolvedConflictFiles: [GitConflictFile] = []
    var mergeSourceBranch: String?
    var isResolvingMergeConflict = false
    var fileChildren: [URL: [WorkspaceFileEntry]] = [:]
    var expandedDirectoryURLs: Set<URL> = []
    var loadingDirectoryURLs: Set<URL> = []
    var directoryLoadErrors: [URL: String] = [:]
    var fileTreeRevealRequest: FileTreeRevealRequest?
    var lastDeletedFileSession: WorkspaceFileDeletionSession?
    var lastDeletedFileTabs: [OpenFileTab] = []
    var lastDeletedSelectedFileURL: URL?
    var fileDeletionRestoreErrorMessage: String?
    var workspaceMonitoringErrorMessage: String?
    var automaticallyRefreshesWorkspace = true
    var refreshesWhenBecomingActive = true
    var showsHiddenFiles = false
    var compactsSingleChildDirectories = true
    var opensMarkdownInPreview = false
    var sidebarFontSize = RepoDeskFontSize.default
    var interfaceFontSize = RepoDeskFontSize.default
    var fileContentFontSize = RepoDeskFontSize.default
    var maximumOpenFileTabs = 5
    var shortcuts: [AppShortcutID: ShortcutBinding] = ShortcutBinding.defaults()
    var javaIndexSettings = JavaIndexSettings.default
    var javaIndexSnapshot = JavaIndexSnapshot.idle
    var javaSemanticTokens: [JavaSemanticToken] = []
    var javaNavigationLoadingPresentation: JavaNavigationLoadingPresentation?
    var javaNavigationResultPresentation: JavaNavigationResultPresentation?
    var javaNavigationSourcePresentation: JavaNavigationSourcePresentation?
    var javaSymbolSearchResults: [JavaNavigationTarget] = []
    var isSearchingJavaSymbols = false
    var openFileTabs: [OpenFileTab] = []
    var fileTabSessionsByContext: [String: FileTabSessionState] = [:]
    var selectedFileURL: URL?
    var loadedDocument: LoadedDocument?
    var documentText = ""
    var documentOriginalText = ""
    var isLoadingDocument = false
    var isSavingDocument = false
    var showsMarkdownPreview = false
    var selectedFileFingerprint: String?
    var showsDiscardAndReloadConfirmation = false
    var hasDocumentConflict = false
    var documentSaveErrorMessage: String?
    var lastDocumentSavedAt: Date?
    var pendingWorkspaceURL: URL?
    var showsDiscardAndCloseWorkspaceConfirmation = false
    var commitHistory: [GitCommitSummary] = []
    var branches: [GitBranch] = []
    var historyAuthors: [String] = []
    var selectedCommitHash: String?
    var selectedCommitDetail: GitCommitDetail?
    var selectedCommitFile: GitCommitFile?
    var commitFileDiff: GitFileDiff?
    var mergeCommitFileDiff: GitMergeFileDiff?
    let historyBlame = HistoryGitBlame()
    var isLoadingCommitDiff = false
    var commitDiffErrorMessage: String?
    var isLoadingHistory = false
    var isLoadingBranches = false
    var isLoadingHistoryAuthors = false
    var isLoadingCommit = false
    var historyErrorMessage: String?
    var branchesErrorMessage: String?
    var historyAuthorsErrorMessage: String?
    var historyCurrentUserName: String?
    var historyCurrentUserErrorMessage: String?
    var commitErrorMessage: String?
    var hasMoreHistory = true
    var historyFileRepositoryID: RegisteredRepository.ID?
    var historyFilePath: String?
    var historyBranchFilter: GitHistoryBranchFilter = .current
    var historyAuthorFilter: GitHistoryAuthorFilter = .all
    private(set) var historyHashQuery = ""
    var normalizedHistoryHashQuery: String {
        historyHashQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    var historyGrouping: GitChangesGrouping = .directory
    var historyVerticalSplitFraction = HistorySplitLayout.defaultVerticalFraction
    var historyHorizontalSplitFraction = HistorySplitLayout.defaultHorizontalFraction
    var taskCatalog = TaskCatalog(global: [], workspace: [], repository: [])
    var selectedTaskID: RepoTaskDefinition.ID?
    var resolvedSelectedTask: ResolvedRepoTask?
    var taskLog = ""
    var runningTaskID: RepoTaskDefinition.ID?
    var lastTaskRunResult: TaskRunResult?
    var taskErrorMessage: String?
    var recentTaskRuns: [TaskRunRecord] = []
    var mavenSettings = MavenSettings.empty
    let mavenEnvironmentValidationStore = MavenEnvironmentValidationStore()
    let mavenQueue: MavenRunQueue
    var mavenExecution: MavenExecutionPresentation {
        mavenQueue.execution(for: activeRepositoryURL)
    }
    var mavenQueueMessage: String? {
        mavenQueue.message(for: activeRepositoryURL)
    }
    var recentMavenRuns: [MavenRunRecord] {
        mavenQueue.activeRecords + persistedMavenRuns.map { sessionMavenRuns[$0.id] ?? $0 }
    }
    private var persistedMavenRuns: [MavenRunRecord] = []
    private var sessionMavenRuns: [UUID: MavenRunRecord] = [:]
    var mavenSettingsErrorMessage: String?
    var mavenProjectRevisions: [String: Int] = [:]
    var fileSearchResults: [WorkspaceFileEntry] = []
    var isSearchingFiles = false
    var textSearchResults: [WorkspaceTextSearchResult] = []
    var isSearchingText = false
    var rememberedChangeSelections: [RegisteredRepository.ID: GitChangeSelection] = [:]
    var rememberedHistoryBranchFilters: [RegisteredRepository.ID: GitHistoryBranchFilter] = [:]
    var rememberedHistoryAuthorFilters: [RegisteredRepository.ID: GitHistoryAuthorFilter] = [:]
    var rememberedCommitHashes: [RegisteredRepository.ID: String] = [:]
    var rememberedCommitFileSelections: [RegisteredRepository.ID: HistoryCommitFileSelection] = [:]
    var rememberedMavenSelections: [RegisteredRepository.ID: MavenWindowSelection] = [:]
    var selectedSourceNavigationRequest: NativeTextNavigationRequest?
    var jumpToSourceErrorMessage: String?

    private let workspaceStore: WorkspaceStoring
    private let workspacePicker: WorkspacePicking
    private let repositoryStore: RepositoryStoring
    private let repositoryPicker: RepositoryPicking
    private let repositoryDiscoverer: any RepositoryDiscovering
    private let gitRepositoryReader: any GitRepositoryReading
    private let gitRepositoryOperator: any GitRepositoryOperating
    private let workspaceFileBrowser: any WorkspaceFileBrowsing
    private let workspaceChangeMonitor: any WorkspaceChangeMonitoring
    private let documentLoader: any DocumentLoading
    private let documentSaver: any DocumentSaving
    private let taskStore: RepoTaskStoring
    private let taskRunner: any RepoTaskRunning
    private let mavenSettingsStore: MavenSettingsStoring
    private let mavenRunHistoryStore: MavenRunHistoryStoring
    private let workspaceFileSearch: any WorkspaceFileSearching
    private let workspaceTextSearch: any WorkspaceTextSearching
    private let windowStateStore: WindowStateStoring
    private let appPreferencesStore: AppPreferencesStoring
    private let javaLanguageProvider: any JavaLanguageProviding
    private let diagnosticLogger: AppDiagnosticLogger
    private var repositoryDiscoveryID: UUID?
    private var diffRequestID: UUID?
    private var documentRequestID: UUID?
    private var historyRequestID: UUID?
    @ObservationIgnored private var historyReloadTask: Task<Void, Never>?
    private var branchesRequestID: UUID?
    private var historyAuthorsRequestID: UUID?
    private var commitRequestID: UUID?
    private var commitDiffRequestID: UUID?
    private var fileSearchRequestID: UUID?
    private var textSearchRequestID: UUID?
    private var javaSymbolSearchRequestID: UUID?
    private var javaNavigationRequestID: UUID?
    private var repositoryRefreshContextID = UUID()
    private let repositoryRefreshLimiter = RepositoryRefreshLimiter(limit: 4)
    private let repositorySnapshotRetryDelays: [Duration]
    private var activeRepositoryRefreshIDs: Set<RegisteredRepository.ID> = []
    private var repositoryRefreshWaiters: [RegisteredRepository.ID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var commitSuccessDismissTask: Task<Void, Never>?
    @ObservationIgnored private var documentAutoSaveTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var documentAutoSaveRequestIDs: [URL: UUID] = [:]
    @ObservationIgnored private var windowStatePersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var gitRemoteOperationSuccessDismissTask: Task<Void, Never>?
    @ObservationIgnored private var javaLanguageEventTask: Task<Void, Never>?
    @ObservationIgnored private var javaSemanticTokensTask: Task<Void, Never>?
    @ObservationIgnored private var javaNavigationLoadingTask: Task<Void, Never>?
    @ObservationIgnored private var javaWorkspaceMavenProjectsTask: Task<[JavaWorkspaceMavenProject], Never>?
    @ObservationIgnored private var javaWorkspaceMavenProjectsCacheKey: String?
    @ObservationIgnored private var javaNavigationOriginCache: [String: JavaNavigationTargetOrigin] = [:]
    @ObservationIgnored private var javaSemanticTokenCacheByFile: [URL: JavaSemanticTokenCacheEntry] = [:]
    @ObservationIgnored private var fileNavigationBackStack: [JavaNavigationHistoryEntry] = []
    @ObservationIgnored private var fileNavigationForwardStack: [JavaNavigationHistoryEntry] = []
    @ObservationIgnored private var currentFileNavigationLocation: JavaNavigationHistoryEntry?
    @ObservationIgnored private var javaIndexPhases: [RegisteredRepository.ID: JavaRepositoryIndexPhase] = [:]

    private enum DiffLoadPresentation {
        case foreground
        case background
    }

    private struct JavaSemanticTokenCacheEntry: Sendable {
        let text: String
        let tokens: [JavaSemanticToken]
    }

    init(
        workspace: WorkspaceSummary? = nil,
        repositories: [RegisteredRepository] = [],
        selectedRepositoryID: RegisteredRepository.ID? = nil,
        selectedSection: AppSection = .overview,
        workspaceStore: WorkspaceStoring? = nil,
        workspacePicker: WorkspacePicking? = nil,
        repositoryStore: RepositoryStoring? = nil,
        repositoryPicker: RepositoryPicking? = nil,
        repositoryDiscoverer: (any RepositoryDiscovering)? = nil,
        gitRepositoryReader: (any GitRepositoryReading)? = nil,
        gitRepositoryOperator: (any GitRepositoryOperating)? = nil,
        workspaceFileBrowser: (any WorkspaceFileBrowsing)? = nil,
        workspaceChangeMonitor: (any WorkspaceChangeMonitoring)? = nil,
        documentLoader: (any DocumentLoading)? = nil,
        documentSaver: (any DocumentSaving)? = nil,
        taskStore: RepoTaskStoring? = nil,
        taskRunner: (any RepoTaskRunning)? = nil,
        mavenRunnerFactory: @escaping () -> any RepoTaskRunning = { SystemRepoTaskRunner() },
        mavenSettingsStore: MavenSettingsStoring? = nil,
        mavenRunHistoryStore: MavenRunHistoryStoring? = nil,
        workspaceFileSearch: (any WorkspaceFileSearching)? = nil,
        workspaceTextSearch: (any WorkspaceTextSearching)? = nil,
        windowStateStore: WindowStateStoring? = nil,
        appPreferencesStore: AppPreferencesStoring? = nil,
        javaLanguageProvider: (any JavaLanguageProviding)? = nil,
        diagnosticLogger: AppDiagnosticLogger = .shared,
        repositorySnapshotRetryDelays: [Duration] = [.milliseconds(250), .seconds(1)],
        restoresWorkspaceOnLaunch: Bool = true
    ) {
        let workspaceStore = workspaceStore ?? UserDefaultsWorkspaceStore()
        let appPreferencesStore = appPreferencesStore ?? UserDefaultsAppPreferencesStore()
        let appPreferences = appPreferencesStore.preferences()
        self.workspace = workspace
        self.repositories = repositories
        self.selectedRepositoryID = selectedRepositoryID
        self.selectedSection = selectedSection
        self.workspaceStore = workspaceStore
        self.workspacePicker = workspacePicker ?? SystemWorkspacePicker()
        self.repositoryStore = repositoryStore ?? UserDefaultsRepositoryStore()
        self.repositoryPicker = repositoryPicker ?? SystemRepositoryPicker()
        self.repositoryDiscoverer = repositoryDiscoverer ?? FileSystemRepositoryDiscoverer()
        self.gitRepositoryReader = gitRepositoryReader ?? SystemGitRepositoryReader()
        self.gitRepositoryOperator = gitRepositoryOperator ?? SystemGitRepositoryOperator()
        self.workspaceFileBrowser = workspaceFileBrowser ?? FileSystemWorkspaceBrowser()
        self.workspaceChangeMonitor = workspaceChangeMonitor ?? SystemWorkspaceChangeMonitor()
        self.documentLoader = documentLoader ?? FileSystemDocumentLoader()
        self.documentSaver = documentSaver ?? FileSystemDocumentStore()
        self.taskStore = taskStore ?? ApplicationSupportRepoTaskStore()
        self.taskRunner = taskRunner ?? SystemRepoTaskRunner()
        self.mavenQueue = MavenRunQueue(runnerFactory: mavenRunnerFactory)
        self.mavenSettingsStore = mavenSettingsStore ?? UserDefaultsMavenSettingsStore()
        self.mavenRunHistoryStore = mavenRunHistoryStore ?? UserDefaultsMavenRunHistoryStore()
        self.workspaceFileSearch = workspaceFileSearch ?? FileSystemWorkspaceSearch()
        self.workspaceTextSearch = workspaceTextSearch ?? FileSystemWorkspaceTextSearch()
        self.windowStateStore = windowStateStore ?? UserDefaultsWindowStateStore()
        self.appPreferencesStore = appPreferencesStore
        self.javaLanguageProvider = javaLanguageProvider
            ?? JavaLanguageEngine(settings: appPreferences.javaIndexSettings)
        self.diagnosticLogger = diagnosticLogger
        self.repositorySnapshotRetryDelays = repositorySnapshotRetryDelays
        automaticallyRefreshesWorkspace = appPreferences.automaticallyRefreshesWorkspace
        refreshesWhenBecomingActive = appPreferences.refreshesWhenBecomingActive
        showsHiddenFiles = appPreferences.showsHiddenFiles
        compactsSingleChildDirectories = appPreferences.compactsSingleChildDirectories
        opensMarkdownInPreview = appPreferences.opensMarkdownInPreview
        diffPresentation = appPreferences.diffPresentation
        ignoresWhitespaceInDiff = appPreferences.ignoresWhitespaceInDiff
        changesAutoExpansion = appPreferences.changesAutoExpansion
        sidebarFontSize = appPreferences.sidebarFontSize
        interfaceFontSize = appPreferences.interfaceFontSize
        fileContentFontSize = appPreferences.fileContentFontSize
        maximumOpenFileTabs = appPreferences.maximumOpenFileTabs
        shortcuts = appPreferences.shortcuts
        javaIndexSettings = appPreferences.javaIndexSettings
        recentTaskRuns = self.taskStore.recentRuns()
        repositoryDiscoveryID = nil
        diffRequestID = nil
        documentRequestID = nil
        historyRequestID = nil
        branchesRequestID = nil
        commitRequestID = nil
        commitDiffRequestID = nil
        fileSearchRequestID = nil
        textSearchRequestID = nil
        recentWorkspaces = workspaceStore.recentWorkspaces()

        if workspace == nil, restoresWorkspaceOnLaunch,
           let restoredURL = workspaceStore.restoreLastWorkspace() {
            self.workspace = WorkspaceSummary(url: restoredURL)
            loadRepositoryState(for: restoredURL)
            restoreWindowState(for: restoredURL)
            loadTaskCatalog()
        }
        if let workspaceURL {
            mavenSettings = self.mavenSettingsStore.settings(for: workspaceURL)
            persistedMavenRuns = self.mavenRunHistoryStore.recentRuns(for: workspaceURL)
        }
        observeJavaLanguageEvents()
        reloadJavaWorkspaceConfiguration()
    }

    var selectedRepository: RegisteredRepository? {
        repositories.first { $0.id == selectedRepositoryID }
    }

    var selectedChangeRepository: RegisteredRepository? {
        repositories.first { $0.id == selectedChangeRepositoryID }
    }

    var changesCommitRepositoryID: RegisteredRepository.ID? {
        isWorkspaceContext ? changesRepositoryScopeID : selectedRepositoryID
    }

    var changesCommitRepository: RegisteredRepository? {
        repositories.first { $0.id == changesCommitRepositoryID }
    }

    var changesCommitMessage: String {
        changesCommitRepositoryID.flatMap { commitMessageDrafts[$0] } ?? ""
    }

    var isGitWriteOperationRunning: Bool {
        isCommittingChanges
            || gitRemoteOperationState.blocksGitOperations
            || isSwitchingBranch
            || isPerformingBranchOperation
    }

    var isCommittingChanges: Bool {
        commitExecutionState.isRunning
    }

    var commitOperationErrorMessage: String? {
        switch commitExecutionState {
        case .commitFailed(_, let message):
            message
        case .pushFailed(_, let message):
            "Commit 已完成，但 Push 失败：\(message)"
        default:
            nil
        }
    }

    var commitOperationStatusMessage: String? {
        guard case .succeeded(let result) = commitExecutionState else { return nil }
        return result.wasPushed ? "Commit And Push 成功。" : "Commit 成功。"
    }

    var canCommitChanges: Bool {
        guard let repositoryID = changesCommitRepositoryID,
              !isGitWriteOperationRunning,
              !changesCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !includedCommitChanges(repositoryID: repositoryID).isEmpty
    }

    var isWorkspaceContext: Bool {
        if case .workspace = navigationContext { return true }
        return false
    }

    var isRepositoryContext: Bool { !isWorkspaceContext }

    var availableSections: [AppSection] {
        isWorkspaceContext ? AppSection.workspaceSections : AppSection.repositorySections
    }

    var currentWorkspaceURL: URL? { workspaceURL }

    var visibleWorkspaceRootURL: URL? {
        if isWorkspaceContext { return workspaceURL }
        return selectedRepository.flatMap(repositoryURL(for:))
    }

    var canRevealSelectedFileInTree: Bool {
        guard let selectedFileURL,
              let visibleWorkspaceRootURL else { return false }
        let fileURL = selectedFileURL.standardizedFileURL
        let rootURL = visibleWorkspaceRootURL.standardizedFileURL
        return fileURL != rootURL
            && WorkspaceTreeRefreshPlanner.isSameOrDescendant(fileURL, of: rootURL)
    }

    var showsHistoryLoadingIndicator: Bool {
        commitHistory.isEmpty
            && (isLoadingHistory || isLoadingBranches || isLoadingHistoryAuthors)
    }

    var hasUnsavedDocumentChanges: Bool {
        guard case .text(let document) = loadedDocument, !document.isLarge else { return false }
        return documentText != documentOriginalText
    }

    var canEditSelectedDocument: Bool {
        guard case .text(let document) = loadedDocument else { return false }
        return !document.isLarge
    }

    var canBlameSelectedFile: Bool {
        guard let selectedFileURL,
              let workspaceURL,
              case .text = loadedDocument else { return false }
        return GitFileBlameTarget.resolve(
            fileURL: selectedFileURL,
            workspaceURL: workspaceURL,
            repositories: repositories
        ) != nil
    }

    var canShowGitHistoryForSelectedFile: Bool {
        guard let selectedFileURL, let workspaceURL else { return false }
        return GitFileBlameTarget.resolve(
            fileURL: selectedFileURL,
            workspaceURL: workspaceURL,
            repositories: repositories
        ) != nil
    }

    var selectedDocumentEncoding: DocumentTextEncoding? {
        guard case .text(let document) = loadedDocument else { return nil }
        return document.encoding
    }

    var canNavigateFileBack: Bool { !fileNavigationBackStack.isEmpty }
    var canNavigateFileForward: Bool { !fileNavigationForwardStack.isEmpty }
    var canNavigateJavaBack: Bool { canNavigateFileBack }
    var canNavigateJavaForward: Bool { canNavigateFileForward }

    func refreshCurrentRepository() async {
        guard let repository = selectedRepository else { return }
        await refreshRepository(repository)
    }

    func refreshChangesScope() async {
        if isRepositoryContext {
            await refreshCurrentRepository()
            return
        }
        guard let repositoryID = changesRepositoryScopeID else {
            await refreshAllRepositories()
            return
        }
        guard let repository = repositories.first(where: { $0.id == repositoryID }) else { return }
        await refreshRepository(repository)
    }

    func monitorCurrentRepository() async {
        await refreshCurrentRepository()
    }

    func monitorWorkspace() async {
        guard let workspaceURL else { return }
        let monitoredWorkspaceURL = workspaceURL.standardizedFileURL
        await diagnosticLogger.record(
            "workspace-monitor start path=\(monitoredWorkspaceURL.path)"
        )
        await loadDirectory(monitoredWorkspaceURL)

        while !Task.isCancelled {
            var shouldRetry = false
            for await batch in workspaceChangeMonitor.events(in: monitoredWorkspaceURL) {
                guard !Task.isCancelled,
                      self.workspaceURL?.standardizedFileURL == monitoredWorkspaceURL else { return }
                let traceID = String(UUID().uuidString.prefix(8))
                let tracesBatch = batch.changedURLs.count >= 100
                    || batch.requiresFullRescan
                    || batch.monitoringError != nil
                if tracesBatch {
                    await diagnosticLogger.record(
                        "workspace-batch begin id=\(traceID) events=\(batch.changedURLs.count) "
                            + "fullRescan=\(batch.requiresFullRescan) section=\(selectedSection.rawValue)"
                    )
                }
                let clock = ContinuousClock()
                let startedAt = clock.now
                await applyWorkspaceChanges(
                    batch,
                    workspaceURL: monitoredWorkspaceURL,
                    traceID: tracesBatch ? traceID : nil
                )
                let duration = startedAt.duration(to: clock.now)
                let seconds = Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
                if tracesBatch || seconds >= 0.25 {
                    await diagnosticLogger.record(
                        "workspace-batch end id=\(traceID) duration=\(seconds)s "
                            + "events=\(batch.changedURLs.count)"
                    )
                }
                if batch.monitoringError != nil {
                    shouldRetry = true
                    break
                }
            }
            guard shouldRetry else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    func refreshAfterReturningToForeground() {
        Task {
            await refreshWorkspaceConsistency()
        }
    }

    func refreshWorkspaceConsistency() async {
        guard let workspaceURL else { return }
        let batch = WorkspaceChangeBatch(
            changedURLs: [],
            requiresFullRescan: true,
            monitoringError: nil
        )
        await refreshLoadedDirectories(for: batch, workspaceURL: workspaceURL)
        markMavenProjectRevisions(for: batch)
        reloadSelectedFileIfChanged(force: true)
        if selectedSection == .changes {
            await refreshAllRepositories()
        } else {
            await refreshCurrentRepository()
        }
        if selectedSection == .history {
            await refreshHistory()
        }
    }

    func refreshAllRepositories() async {
        await refreshRepositories(repositories)
        lastRefreshed = .now
    }

    func ensureRepositorySnapshots() async {
        let repositoriesNeedingSnapshot = repositories.filter {
            repositorySnapshots[$0.id] == nil && repositorySnapshotErrors[$0.id] == nil
        }
        await refreshRepositories(repositoriesNeedingSnapshot)
    }

    private func refreshRepositories(_ repositories: [RegisteredRepository]) async {
        await withTaskGroup(of: Void.self) { group in
            for repository in repositories {
                group.addTask { [weak self] in
                    await self?.refreshRepository(repository)
                }
            }
        }
    }

    func chooseWorkspace() {
        guard !isGitWriteOperationRunning else { return }
        guard let url = workspacePicker.chooseWorkspace() else { return }
        requestOpenWorkspace(at: url)
    }

    func openWorkspace(at url: URL) {
        guard !isGitWriteOperationRunning else { return }
        persistWindowState()
        discardLastDeletedFileSession()
        mavenQueue.reset()
        sessionMavenRuns.removeAll()
        repositoryRefreshContextID = UUID()
        workspaceStore.rememberWorkspace(url)
        recentWorkspaces = workspaceStore.recentWorkspaces()
        workspace = WorkspaceSummary(url: url)
        selectedSection = .overview
        lastRefreshed = nil
        discoveredRepositories = []
        repositoryDiscoverySettings = .default
        repositoryDiscoverySettingsErrorMessage = nil
        repositorySnapshots = [:]
        repositorySnapshotErrors = [:]
        refreshingRepositoryIDs = []
        selectedChange = nil
        selectedChangeRepositoryID = nil
        currentDiff = nil
        diffErrorMessage = nil
        fileChildren = [:]
        expandedDirectoryURLs = []
        loadingDirectoryURLs = []
        directoryLoadErrors = [:]
        workspaceMonitoringErrorMessage = nil
        selectedFileURL = nil
        selectedFileFingerprint = nil
        loadedDocument = nil
        resetDocumentEditingState()
        fileTabSessionsByContext = [:]
        resetHistoryHashSearch()
        commitHistory = []
        branches = []
        gitStashes = []
        stashesErrorMessage = nil
        historyAuthors = []
        historyCurrentUserName = nil
        historyCurrentUserErrorMessage = nil
        selectedCommitHash = nil
        selectedCommitDetail = nil
        selectedCommitFile = nil
        historyBlame.reset()
        commitFileDiff = nil
        mergeCommitFileDiff = nil
        commitDiffRequestID = nil
        isLoadingCommitDiff = false
        taskCatalog = TaskCatalog(global: [], workspace: [], repository: [])
        selectedTaskID = nil
        resolvedSelectedTask = nil
        persistedMavenRuns = []
        mavenSettingsErrorMessage = nil
        mavenProjectRevisions = [:]
        historyVerticalSplitFraction = HistorySplitLayout.defaultVerticalFraction
        historyHorizontalSplitFraction = HistorySplitLayout.defaultHorizontalFraction
        fileSearchRequestID = nil
        textSearchRequestID = nil
        fileSearchResults = []
        textSearchResults = []
        isSearchingFiles = false
        isSearchingText = false
        rememberedChangeSelections = [:]
        rememberedHistoryBranchFilters = [:]
        rememberedHistoryAuthorFilters = [:]
        rememberedCommitHashes = [:]
        rememberedCommitFileSelections = [:]
        rememberedMavenSelections = [:]
        commitMessageDrafts = [:]
        excludedCommitChanges = [:]
        clearCommitExecutionState()
        clearGitRemoteOperationState()
        isSwitchingBranch = false
        branchSwitchErrorMessage = nil
        isPerformingBranchOperation = false
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        branchComparison = nil
        isLoadingBranchComparison = false
        conflictFiles = []
        resolvedConflictFiles = []
        mergeSourceBranch = nil
        changesRepositoryScopeID = nil
        changesGrouping = .directory
        historyGrouping = .directory
        navigationContext = .workspace
        repositoryDiscoveryID = nil
        isDiscoveringRepositories = false
        isShowingDiscoveryResults = false
        loadRepositoryState(for: url)
        restoreWindowState(for: url)
        loadTaskCatalog()
        loadMavenSettings(for: url)
        javaIndexSnapshot = .idle
        javaIndexPhases = [:]
        javaSemanticTokens = []
        javaSemanticTokenCacheByFile = [:]
        resetFileNavigationHistory()
        reloadJavaWorkspaceConfiguration()
        Task { await loadDirectory(url.standardizedFileURL) }
    }

    func openRecentWorkspace(_ recentWorkspace: RecentWorkspace) {
        guard !isGitWriteOperationRunning else { return }
        requestOpenWorkspace(at: workspaceStore.resolve(recentWorkspace))
    }

    func removeRecentWorkspace(_ recentWorkspace: RecentWorkspace) {
        workspaceStore.removeWorkspace(recentWorkspace)
        recentWorkspaces = workspaceStore.recentWorkspaces()
    }

    func closeWorkspace() {
        guard !isGitWriteOperationRunning else { return }
        if hasUnsavedDocumentChanges {
            showsDiscardAndCloseWorkspaceConfirmation = true
            return
        }
        performCloseWorkspace()
    }

    func discardChangesAndCloseWorkspace() {
        showsDiscardAndCloseWorkspaceConfirmation = false
        performCloseWorkspace()
    }

    func discardChangesAndOpenPendingWorkspace() {
        guard let pendingWorkspaceURL else { return }
        self.pendingWorkspaceURL = nil
        openWorkspace(at: pendingWorkspaceURL)
    }

    func cancelPendingWorkspaceOpen() {
        pendingWorkspaceURL = nil
    }

    private func requestOpenWorkspace(at url: URL) {
        if hasUnsavedDocumentChanges {
            pendingWorkspaceURL = url
        } else {
            openWorkspace(at: url)
        }
    }

    private func performCloseWorkspace() {
        persistWindowState()
        discardLastDeletedFileSession()
        if runningTaskID != nil {
            stopRunningTask()
        }
        mavenQueue.reset()
        sessionMavenRuns.removeAll()
        repositoryRefreshContextID = UUID()
        workspace = nil
        repositories = []
        repositoryDiscoverySettings = .default
        repositoryDiscoverySettingsErrorMessage = nil
        selectedRepositoryID = nil
        navigationContext = .workspace
        selectedSection = .overview
        repositorySnapshots = [:]
        repositorySnapshotErrors = [:]
        refreshingRepositoryIDs = []
        selectedChange = nil
        selectedChangeRepositoryID = nil
        currentDiff = nil
        fileChildren = [:]
        expandedDirectoryURLs = []
        loadingDirectoryURLs = []
        directoryLoadErrors = [:]
        workspaceMonitoringErrorMessage = nil
        selectedFileURL = nil
        selectedFileFingerprint = nil
        loadedDocument = nil
        resetDocumentEditingState()
        fileTabSessionsByContext = [:]
        resetHistoryHashSearch()
        commitHistory = []
        branches = []
        gitStashes = []
        stashesErrorMessage = nil
        historyAuthors = []
        historyCurrentUserName = nil
        historyCurrentUserErrorMessage = nil
        selectedCommitDetail = nil
        selectedCommitFile = nil
        historyBlame.reset()
        commitFileDiff = nil
        mergeCommitFileDiff = nil
        taskCatalog = TaskCatalog(global: [], workspace: [], repository: [])
        mavenSettings = .empty
        persistedMavenRuns = []
        mavenSettingsErrorMessage = nil
        mavenProjectRevisions = [:]
        historyGrouping = .directory
        historyVerticalSplitFraction = HistorySplitLayout.defaultVerticalFraction
        historyHorizontalSplitFraction = HistorySplitLayout.defaultHorizontalFraction
        rememberedCommitFileSelections = [:]
        rememberedMavenSelections = [:]
        commitMessageDrafts = [:]
        excludedCommitChanges = [:]
        clearCommitExecutionState()
        clearGitRemoteOperationState()
        isSwitchingBranch = false
        branchSwitchErrorMessage = nil
        isPerformingBranchOperation = false
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        branchComparison = nil
        isLoadingBranchComparison = false
        conflictFiles = []
        resolvedConflictFiles = []
        mergeSourceBranch = nil
        javaIndexSnapshot = .idle
        javaIndexPhases = [:]
        javaSemanticTokens = []
        javaSemanticTokenCacheByFile = [:]
        javaNavigationRequestID = nil
        javaNavigationLoadingTask?.cancel()
        javaNavigationLoadingTask = nil
        javaNavigationLoadingPresentation = nil
        clearJavaNavigationCaches()
        javaNavigationResultPresentation = nil
        javaNavigationSourcePresentation = nil
        javaSymbolSearchResults = []
        resetFileNavigationHistory()
        Task { await javaLanguageProvider.shutdown() }
    }

    func chooseRepository() {
        guard let workspaceURL = availableWorkspaceURL() else { return }
        guard let repositoryURL = repositoryPicker.chooseRepository(
            in: workspaceURL,
            purpose: .register
        ) else { return }

        do {
            let repository = try RepositoryRegistration.make(
                directoryURL: repositoryURL,
                workspaceURL: workspaceURL
            )
            registerRepositories([repository])
        } catch let error as RepositoryRegistrationError {
            presentedRepositoryError = error
        } catch {
            presentedRepositoryError = .directoryUnavailable(repositoryURL.path)
        }
    }

    func discoverRepositories() {
        guard let workspaceURL = availableWorkspaceURL() else { return }
        let discoveryID = UUID()
        let settings = repositoryDiscoverySettings
        repositoryDiscoveryID = discoveryID
        isDiscoveringRepositories = true

        Task { [weak self] in
            guard let self else { return }
            let discovered = await repositoryDiscoverer.discoverRepositories(
                in: workspaceURL,
                settings: settings
            )
            guard repositoryDiscoveryID == discoveryID else { return }
            let registeredIDs = Set(repositories.map(\.id))
            discoveredRepositories = discovered.filter { !registeredIDs.contains($0.id) }
            repositoryDiscoveryID = nil
            isDiscoveringRepositories = false
            isShowingDiscoveryResults = true
        }
    }

    func chooseRepositoryDiscoveryIgnoredDirectory() {
        guard let workspaceURL = availableWorkspaceURL() else { return }
        guard let directoryURL = repositoryPicker.chooseRepository(
            in: workspaceURL,
            purpose: .ignoreForDiscovery
        ) else { return }

        do {
            var settings = repositoryDiscoverySettings
            guard try settings.addIgnoredDirectory(directoryURL, in: workspaceURL) else { return }
            repositoryDiscoverySettings = settings
            repositoryDiscoverySettingsErrorMessage = nil
            invalidateRepositoryDiscoveryResults()
            persistRepositoryState()
        } catch {
            repositoryDiscoverySettingsErrorMessage = error.localizedDescription
        }
    }

    func removeRepositoryDiscoveryIgnoredDirectory(_ relativePath: String) {
        var settings = repositoryDiscoverySettings
        guard settings.removeIgnoredDirectory(relativePath: relativePath) else { return }
        repositoryDiscoverySettings = settings
        invalidateRepositoryDiscoveryResults()
        persistRepositoryState()
    }

    func resetRepositoryDiscoveryIgnoredDirectories() {
        guard !repositoryDiscoverySettings.ignoredDirectoryPaths.isEmpty else { return }
        repositoryDiscoverySettings.removeAllIgnoredDirectories()
        invalidateRepositoryDiscoveryResults()
        persistRepositoryState()
    }

    private func invalidateRepositoryDiscoveryResults() {
        repositoryDiscoveryID = nil
        isDiscoveringRepositories = false
        isShowingDiscoveryResults = false
        discoveredRepositories = []
    }

    func registerDiscoveredRepositories(_ repositories: [RegisteredRepository]) {
        registerRepositories(repositories)
        isShowingDiscoveryResults = false
    }

    func selectRepository(_ id: RegisteredRepository.ID) {
        guard repositories.contains(where: { $0.id == id }) else { return }
        let repositoryChanged = selectedRepositoryID != id
        let rememberedSelection = rememberedChangeSelections[id]
        let changesSelectionChanged = selectedChangeRepositoryID != id
            || selectedChange != rememberedSelection
        if repositoryChanged {
            selectedRepositoryID = id
        }
        if repositoryChanged || changesSelectionChanged {
            diffRequestID = nil
            isLoadingDiff = false
            selectedChangeRepositoryID = id
            selectedChange = rememberedSelection
            currentDiff = nil
            diffErrorMessage = nil
        }
        guard repositoryChanged else { return }
        resetHistoryHashSearch()
        commitHistory = []
        branches = []
        gitStashes = []
        stashesErrorMessage = nil
        branchesRequestID = nil
        isLoadingBranches = false
        branchSwitchErrorMessage = nil
        selectedCommitHash = nil
        selectedCommitDetail = nil
        selectedCommitFile = nil
        historyBlame.reset()
        commitFileDiff = nil
        mergeCommitFileDiff = nil
        historyErrorMessage = nil
        branchesErrorMessage = nil
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        branchComparison = nil
        conflictFiles = []
        resolvedConflictFiles = []
        mergeSourceBranch = nil
        historyAuthorsErrorMessage = nil
        historyCurrentUserName = nil
        historyCurrentUserErrorMessage = nil
        commitErrorMessage = nil
        historyFileRepositoryID = nil
        historyFilePath = nil
        historyBranchFilter = rememberedHistoryBranchFilters[id] ?? .current
        historyAuthorFilter = rememberedHistoryAuthorFilters[id] ?? .all
        selectedCommitHash = rememberedCommitHashes[id]
        persistRepositoryState()
        persistWindowState()
        Task { await javaLanguageProvider.prioritize(repositoryID: id) }
        if let repositoryURL = selectedRepository.flatMap(repositoryURL(for:)) {
            let workspaceURL = self.workspaceURL
            let repositories = self.repositories
            Task {
                await JavaWorkspaceNavigationFallback.prepareMethodCallers(
                    fileURL: repositoryURL, workspaceURL: workspaceURL, repositories: repositories
                )
            }
        }
        loadTaskCatalog()
    }

    func selectRepositoryContext(_ id: RegisteredRepository.ID) {
        guard repositories.contains(where: { $0.id == id }) else { return }
        let targetContext = NavigationContext.repository(id)
        let contextChanged = navigationContext != targetContext
        if contextChanged {
            persistWindowState()
        }
        selectRepository(id)
        navigationContext = targetContext
        changesRepositoryScopeID = id
        if selectedSection == .overview {
            selectedSection = .changes
        }
        if contextChanged {
            restoreFileTabsForCurrentContext()
        }
        persistWindowState()
    }

    func selectWorkspaceContext() {
        let contextChanged = navigationContext != .workspace
        if contextChanged {
            persistWindowState()
        }
        navigationContext = .workspace
        changesRepositoryScopeID = nil
        selectedChange = nil
        selectedChangeRepositoryID = nil
        currentDiff = nil
        diffErrorMessage = nil
        if selectedSection == .history {
            selectedSection = .overview
        }
        if contextChanged {
            restoreFileTabsForCurrentContext()
        }
        persistWindowState()
    }

    func selectSection(_ section: AppSection) {
        guard availableSections.contains(section) else { return }
        selectedSection = section
        if section == .files, let rootURL = visibleWorkspaceRootURL {
            Task { await loadDirectory(rootURL) }
        }
        persistWindowState()
    }

    func selectChangesRepositoryScope(_ repositoryID: RegisteredRepository.ID?) {
        guard isWorkspaceContext else { return }
        guard repositoryID == nil || repositories.contains(where: { $0.id == repositoryID }) else {
            return
        }
        changesRepositoryScopeID = repositoryID
        clearCommitExecutionState()
        if let selectedChangeRepositoryID,
           repositoryID != nil,
           repositoryID != selectedChangeRepositoryID {
            selectedChange = nil
            self.selectedChangeRepositoryID = nil
            currentDiff = nil
        }
        persistWindowState()
    }

    func selectChangesGrouping(_ grouping: GitChangesGrouping) {
        changesGrouping = grouping
        persistWindowState()
    }

    func toggleChangesGrouping(_ grouping: GitChangesGrouping) {
        if changesGrouping.contains(grouping) {
            changesGrouping.remove(grouping)
        } else {
            changesGrouping.insert(grouping)
        }
        persistWindowState()
    }

    func toggleHistoryGrouping(_ grouping: GitChangesGrouping) {
        if historyGrouping.contains(grouping) {
            historyGrouping.remove(grouping)
        } else {
            historyGrouping.insert(grouping)
        }
        persistWindowState()
    }

    func updateChangesCommitMessage(_ message: String) {
        guard let repositoryID = changesCommitRepositoryID else { return }
        commitMessageDrafts[repositoryID] = message
        clearCommitExecutionState()
    }

    func includedCommitChanges(repositoryID: RegisteredRepository.ID) -> [GitChangeSelection] {
        let excluded = excludedCommitChanges[repositoryID] ?? []
        return GitChangeKind.allDisplayCases.flatMap { kind in
            changes(for: kind, repositoryID: repositoryID)
        }.filter { !excluded.contains($0) }
    }

    func isIncludedInCommit(_ selection: GitChangeSelection, repositoryID: RegisteredRepository.ID) -> Bool {
        excludedCommitChanges[repositoryID]?.contains(selection) != true
    }

    func setCommitInclusion(
        _ selections: [GitChangeSelection],
        repositoryID: RegisteredRepository.ID,
        included: Bool
    ) {
        var excluded = excludedCommitChanges[repositoryID] ?? []
        if included {
            excluded.subtract(selections)
        } else {
            excluded.formUnion(selections)
        }
        excludedCommitChanges[repositoryID] = excluded
        clearCommitExecutionState()
    }

    func commitChanges(andPush: Bool) async {
        guard !isGitWriteOperationRunning,
              let repository = changesCommitRepository,
              let repositoryURL = repositoryURL(for: repository) else { return }
        let repositoryID = repository.id
        let changes = includedCommitChanges(repositoryID: repositoryID)
        let context = commitExecutionContext(
            repository: repository,
            fileCount: changes.count,
            shouldPush: andPush
        )
        let message = changesCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            setCommitExecutionState(.commitFailed(context: context, message: "请输入 Commit 信息。"))
            return
        }

        setCommitExecutionState(.committing(context))

        let createdCommit: GitCreatedCommit
        do {
            createdCommit = try await gitRepositoryOperator.createCommit(
                repositoryURL: repositoryURL,
                message: message,
                changes: changes
            )
            commitMessageDrafts[repositoryID] = nil
        } catch {
            setCommitExecutionState(
                .commitFailed(context: context, message: error.localizedDescription)
            )
            await refreshRepository(repository)
            return
        }

        if andPush {
            setCommitExecutionState(
                .pushing(context: context, commitHash: createdCommit.hash)
            )
            do {
                try await gitRepositoryOperator.pushCurrentBranch(repositoryURL: repositoryURL)
            } catch {
                setCommitExecutionState(
                    .pushFailed(
                        result: GitCommitExecutionResult(
                            context: context,
                            commitHash: createdCommit.hash,
                            wasPushed: false
                        ),
                        message: error.localizedDescription
                    )
                )
                await refreshRepository(repository)
                if selectedRepositoryID == repositoryID {
                    await loadBranches()
                }
                return
            }
        }

        setCommitExecutionState(
            .succeeded(
                GitCommitExecutionResult(
                    context: context,
                    commitHash: createdCommit.hash,
                    wasPushed: andPush
                )
            )
        )
        await refreshRepository(repository)
        if selectedRepositoryID == repositoryID {
            await loadBranches()
        }
    }

    func retryCommitPush() async {
        guard case .pushFailed(let result, _) = commitExecutionState,
              !isGitWriteOperationRunning,
              let repository = repositories.first(where: { $0.id == result.context.repositoryID }),
              let repositoryURL = repositoryURL(for: repository) else { return }

        setCommitExecutionState(
            .pushing(context: result.context, commitHash: result.commitHash)
        )
        do {
            try await gitRepositoryOperator.pushCurrentBranch(repositoryURL: repositoryURL)
            setCommitExecutionState(
                .succeeded(
                    GitCommitExecutionResult(
                        context: result.context,
                        commitHash: result.commitHash,
                        wasPushed: true
                    )
                )
            )
        } catch {
            setCommitExecutionState(.pushFailed(result: result, message: error.localizedDescription))
        }
        await refreshRepository(repository)
        if selectedRepositoryID == repository.id {
            await loadBranches()
        }
    }

    func dismissCommitExecutionResult() {
        guard !commitExecutionState.isRunning else { return }
        clearCommitExecutionState()
    }

    func showCommitInHistory(_ result: GitCommitExecutionResult) {
        selectRepositoryContext(result.context.repositoryID)
        selectSection(.history)
        Task {
            await loadHistory()
            if commitHistory.contains(where: { $0.hash == result.commitHash }) {
                selectCommit(result.commitHash)
            }
        }
    }

    func showFileHistory(for fileURL: URL) {
        guard let workspaceURL,
              let target = GitFileBlameTarget.resolve(
                  fileURL: fileURL,
                  workspaceURL: workspaceURL,
                  repositories: repositories
              ) else { return }

        selectRepositoryContext(target.repositoryID)
        historyFileRepositoryID = target.repositoryID
        historyFilePath = target.path
        selectedSection = .history
        resetHistorySelectionAndReload()
    }

    func showFileBlameCommitInHistory(_ hash: String, fileURL: URL) {
        guard hash.count == 40, hash.allSatisfy(\.isHexDigit), hash.contains(where: { $0 != "0" }),
              let workspaceURL,
              let target = GitFileBlameTarget.resolve(fileURL: fileURL, workspaceURL: workspaceURL,
                                                     repositories: repositories) else { return }
        selectRepositoryContext(target.repositoryID)
        historyFileRepositoryID = nil
        historyFilePath = nil
        historyBranchFilter = .all
        historyAuthorFilter = .all
        rememberedHistoryBranchFilters[target.repositoryID] = .all
        rememberedHistoryAuthorFilters[target.repositoryID] = nil
        historyHashQuery = hash.lowercased()
        selectedSection = .history
        // Exact hash search reaches commits beyond the loaded page, including renamed files.
        resetHistorySelectionAndReload()
    }

    func clearFileHistoryScope() {
        guard historyFilePath != nil else { return }
        historyFileRepositoryID = nil
        historyFilePath = nil
        resetHistorySelectionAndReload()
    }

    private func commitExecutionContext(
        repository: RegisteredRepository,
        fileCount: Int,
        shouldPush: Bool
    ) -> GitCommitExecutionContext {
        let branch = repositorySnapshots[repository.id]?.branch ?? "当前分支"
        let pushTarget = branches.first {
            !$0.isRemote && ($0.isCurrent || $0.name == branch)
        }?.upstream ?? branch
        return GitCommitExecutionContext(
            repositoryID: repository.id,
            repositoryName: repository.name,
            branch: branch,
            fileCount: fileCount,
            shouldPush: shouldPush,
            pushTarget: pushTarget
        )
    }

    private func setCommitExecutionState(_ state: GitCommitExecutionState) {
        commitSuccessDismissTask?.cancel()
        commitSuccessDismissTask = nil
        commitExecutionState = state
        guard case .succeeded(let result) = state else { return }
        commitSuccessDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            guard let self,
                  commitExecutionState == .succeeded(result) else { return }
            commitExecutionState = .idle
            commitSuccessDismissTask = nil
        }
    }

    private func clearCommitExecutionState() {
        commitSuccessDismissTask?.cancel()
        commitSuccessDismissTask = nil
        commitExecutionState = .idle
    }

    @discardableResult
    func switchBranch(_ branch: GitBranch) async -> Bool {
        guard !isGitWriteOperationRunning,
              isRepositoryContext,
              let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository) else { return false }
        if branch.isCurrent { return true }

        let repositoryID = repository.id
        isSwitchingBranch = true
        branchSwitchErrorMessage = nil
        defer { isSwitchingBranch = false }

        do {
            try await gitRepositoryOperator.switchBranch(
                repositoryURL: repositoryURL,
                branch: branch
            )
        } catch {
            branchSwitchErrorMessage = error.localizedDescription
            return false
        }

        await javaLanguageProvider.notifyFilesChanged([repositoryURL])

        guard selectedRepositoryID == repositoryID else {
            await refreshRepository(repository)
            return true
        }
        await refreshWorkspaceConsistency()
        if selectedSection != .history {
            await loadBranches()
        }
        return true
    }

    func pushBranch(_ branch: GitBranch) async {
        await performBranchOperation {
            try await self.gitRepositoryOperator.pushBranch(repositoryURL: $0, branch: branch)
        }
    }

    func pullBranch(_ branch: GitBranch) async {
        guard !branch.isRemote, isRepositoryContext, let repository = selectedRepository else { return }
        await performGitRemoteOperation(.pull, repository: repository, pullBranchName: branch.name)
    }

    func performGitRemoteOperation(_ kind: GitRemoteOperationKind) async {
        guard !isGitWriteOperationRunning,
              isRepositoryContext,
              let repository = selectedRepository else { return }
        await performGitRemoteOperation(kind, repository: repository)
    }

    func pushPreparation(targetRemoteBranch: String?) async throws -> GitPushPreparation {
        guard let repositoryURL = activeRepositoryURL else {
            throw GitRepositoryError.pushPreparationUnavailable
        }
        return try await gitRepositoryReader.pushPreparation(
            repositoryURL: repositoryURL,
            targetRemoteBranch: targetRemoteBranch
        )
    }

    func pushCommitRange(_ commits: [GitCommitSummary]) async throws -> GitPushCommitRange {
        guard let repositoryURL = activeRepositoryURL else {
            throw GitRepositoryError.pushPreparationUnavailable
        }
        return try await gitRepositoryReader.pushCommitRange(
            repositoryURL: repositoryURL,
            commits: commits
        )
    }

    func pushFileDiff(
        range: GitPushCommitRange,
        file: GitCommitFile
    ) async throws -> GitFileDiff {
        guard let repositoryURL = activeRepositoryURL else {
            throw GitRepositoryError.pushPreparationUnavailable
        }
        let target: GitDiffTarget
        if range.commits.count == 1, let commit = range.commits.first {
            target = .commit(hash: commit.hash, file: file)
        } else {
            target = .revisionRange(
                base: range.baseRevision,
                head: range.headRevision,
                file: file
            )
        }
        return try await gitRepositoryReader.fileDiff(
            repositoryURL: repositoryURL,
            target: target,
            ignoringWhitespace: ignoresWhitespaceInDiff
        )
    }

    func push(_ preparation: GitPushPreparation) async -> Bool {
        guard !isGitWriteOperationRunning,
              isRepositoryContext,
              let repository = selectedRepository else { return false }
        return await performPreparedPush(preparation, repository: repository)
    }

    func retryGitRemoteOperation() async {
        guard case .failed(let context, _) = gitRemoteOperationState,
              !isGitWriteOperationRunning,
              let repository = repositories.first(where: { $0.id == context.repositoryID }) else {
            return
        }
        switch context.kind {
        case .stash:
            await performGitStashOperation(.stash, repository: repository, stash: nil, message: context.stashMessage)
        case .unstash:
            guard let reference = context.stashReference else { return }
            let stash = gitStashes.first(where: { $0.reference == reference })
                ?? GitStash(reference: reference, message: reference)
            await performGitStashOperation(.unstash, repository: repository, stash: stash, message: nil)
        case .dropStash:
            guard let reference = context.stashReference else { return }
            let stash = gitStashes.first(where: { $0.reference == reference })
                ?? GitStash(reference: reference, message: reference)
            await performGitStashOperation(.dropStash, repository: repository, stash: stash, message: nil)
        case .rollback:
            await performRollbackOperation(repository: repository, changes: context.rollbackSelections)
        case .push:
            if let remote = context.pushRemote,
               let target = context.pushTargetBranch {
                let preparation = GitPushPreparation(
                    localBranch: context.branch,
                    remote: remote,
                    targetRemoteBranch: target,
                    remoteBranches: [],
                    targetExists: !context.pushSetsUpstream,
                    commits: [],
                    blockingMessage: nil
                )
                _ = await performPreparedPush(preparation, repository: repository)
            } else {
                await performGitRemoteOperation(.push, repository: repository)
            }
        case .fetch, .pull:
            await performGitRemoteOperation(context.kind, repository: repository, pullBranchName: context.pullBranchName)
        }
    }

    func stashChanges(message: String? = nil) async {
        guard isRepositoryContext, let repository = selectedRepository else { return }
        await performGitStashOperation(.stash, repository: repository, stash: nil, message: message)
    }

    func unstashChanges(_ stash: GitStash) async {
        guard isRepositoryContext, let repository = selectedRepository else { return }
        await performGitStashOperation(.unstash, repository: repository, stash: stash, message: nil)
    }

    func dropStash(_ stash: GitStash) async {
        guard isRepositoryContext, let repository = selectedRepository else { return }
        await performGitStashOperation(.dropStash, repository: repository, stash: stash, message: nil)
    }

    func rollbackChanges(
        _ changes: [GitChangeSelection],
        repositoryID: RegisteredRepository.ID
    ) async {
        guard !changes.isEmpty,
              let repository = repositories.first(where: { $0.id == repositoryID }) else { return }
        await performRollbackOperation(repository: repository, changes: changes)
    }

    func dismissGitRemoteOperationResult() {
        guard !gitRemoteOperationState.blocksGitOperations else { return }
        clearGitRemoteOperationState()
    }

    func mergeBranch(_ branch: GitBranch) async {
        guard let repositoryURL = activeRepositoryURL else { return }
        isPerformingBranchOperation = true
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        defer { isPerformingBranchOperation = false }
        do {
            let outcome = try await gitRepositoryOperator.mergeBranch(repositoryURL: repositoryURL, branch: branch)
            branchOperationStatusMessage = outcome == .upToDate
                ? "当前分支已包含该分支的最新代码，无需合并。"
                : "Merge 成功。"
            await refreshAfterBranchOperation()
        } catch {
            let files = (try? await gitRepositoryOperator.conflictFiles(repositoryURL: repositoryURL)) ?? []
            if files.isEmpty {
                branchOperationErrorMessage = error.localizedDescription
            } else {
                conflictFiles = files
                resolvedConflictFiles = []
                mergeSourceBranch = branch.name
            }
            await refreshAfterBranchOperation()
        }
    }

    func renameBranch(_ branch: GitBranch, to newName: String) async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            branchOperationErrorMessage = "请输入新的 Branch 名称。"
            return
        }
        await performBranchOperation {
            try await self.gitRepositoryOperator.renameBranch(repositoryURL: $0, branch: branch, to: name)
        }
    }

    func deleteBranch(_ branch: GitBranch) async {
        await performBranchOperation {
            try await self.gitRepositoryOperator.deleteBranch(repositoryURL: $0, branch: branch)
        }
    }

    func compareBranch(_ branch: GitBranch) async {
        guard let repositoryURL = activeRepositoryURL,
              let current = branches.first(where: \.isCurrent)?.name else { return }
        isLoadingBranchComparison = true
        branchOperationErrorMessage = nil
        defer { isLoadingBranchComparison = false }
        do {
            branchComparison = try await gitRepositoryReader.compareBranches(
                repositoryURL: repositoryURL,
                base: current,
                compared: branch.name
            )
        } catch {
            branchOperationErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func resolveConflict(path: String, result: String, resultData: Data? = nil) async -> Bool {
        guard let file = conflictFiles.first(where: { $0.path == path }),
              let repositoryURL = activeRepositoryURL,
              !isResolvingMergeConflict else { return false }
        guard GitConflictParser.blocks(in: result).isEmpty else {
            branchOperationErrorMessage = "合并结果中仍包含未解决的冲突标记。"
            return false
        }

        isResolvingMergeConflict = true
        branchOperationErrorMessage = nil
        defer { isResolvingMergeConflict = false }

        var resolvedFile = file
        resolvedFile.result = result
        resolvedFile.isResolved = true
        resolvedFile.resultData = resultData
        do {
            try await gitRepositoryOperator.resolveConflict(repositoryURL: repositoryURL, file: resolvedFile)
            conflictFiles.removeAll { $0.path == path }
            resolvedConflictFiles.removeAll { $0.path == path }
            resolvedConflictFiles.append(resolvedFile)
            return true
        } catch {
            branchOperationErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveConflictProgress(path: String, result: String) async -> Bool {
        guard let fileIndex = conflictFiles.firstIndex(where: { $0.path == path }),
              let repositoryURL = activeRepositoryURL,
              !isResolvingMergeConflict else { return false }
        guard GitConflictParser.blocks(in: result).isEmpty == false else {
            branchOperationErrorMessage = "保存进度前仍需保留冲突块，或选择完成当前文件。"
            return false
        }
        isResolvingMergeConflict = true
        branchOperationErrorMessage = nil
        defer { isResolvingMergeConflict = false }
        var savedFile = conflictFiles[fileIndex]
        savedFile.result = result
        do {
            try await gitRepositoryOperator.saveConflictProgress(
                repositoryURL: repositoryURL,
                file: savedFile
            )
            conflictFiles[fileIndex] = savedFile
            return true
        } catch {
            branchOperationErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func revertConflictResolution(path: String) async -> Bool {
        guard let resolvedIndex = resolvedConflictFiles.firstIndex(where: { $0.path == path }),
              let repositoryURL = activeRepositoryURL,
              !isResolvingMergeConflict else { return false }
        isResolvingMergeConflict = true
        branchOperationErrorMessage = nil
        defer { isResolvingMergeConflict = false }
        var file = resolvedConflictFiles[resolvedIndex]
        file.isResolved = false
        do {
            try await gitRepositoryOperator.restoreConflictProgress(
                repositoryURL: repositoryURL,
                file: file
            )
            resolvedConflictFiles.remove(at: resolvedIndex)
            conflictFiles.append(file)
            conflictFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return true
        } catch {
            branchOperationErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func acceptConflictFile(path: String, side: GitConflictSide) async -> Bool {
        guard let file = conflictFiles.first(where: { $0.path == path }) else { return false }
        var selected = file
        selected.result = side == .ours ? file.ours : file.theirs
        selected.resultData = side == .ours ? file.oursData : file.theirsData
        return await resolveConflict(path: path, result: selected.result, resultData: selected.resultData)
    }

    @discardableResult
    func updateResolvedConflict(path: String, result: String) async -> Bool {
        guard let index = resolvedConflictFiles.firstIndex(where: { $0.path == path }) else { return false }
        guard GitConflictParser.blocks(in: result).isEmpty else {
            let didRevert = await revertConflictResolution(path: path)
            guard didRevert else { return false }
            return await saveConflictProgress(path: path, result: result)
        }
        guard let repositoryURL = activeRepositoryURL, !isResolvingMergeConflict else { return false }
        isResolvingMergeConflict = true
        branchOperationErrorMessage = nil
        defer { isResolvingMergeConflict = false }
        var file = resolvedConflictFiles[index]
        file.result = result
        do {
            try await gitRepositoryOperator.resolveConflict(repositoryURL: repositoryURL, file: file)
            resolvedConflictFiles[index] = file
            return true
        } catch {
            branchOperationErrorMessage = error.localizedDescription
            return false
        }
    }

    func acceptConflictBlock(fileIndex: Int, blockIndex: Int, side: GitConflictSide) {
        guard conflictFiles.indices.contains(fileIndex) else { return }
        guard let resolved = GitConflictParser.resolving(
            blockIndex,
            in: conflictFiles[fileIndex].result,
            with: side
        ) else { return }
        conflictFiles[fileIndex].result = resolved
    }

    func closeMergeConflictResolution() async {
        guard !conflictFiles.isEmpty else { return }
        await abortMerge()
    }

    func abortMerge() async {
        guard let repositoryURL = activeRepositoryURL, !isResolvingMergeConflict else { return }
        isResolvingMergeConflict = true
        defer { isResolvingMergeConflict = false }
        let remoteContext: GitRemoteOperationContext?
        if case .requiresConflictResolution(let context, _) = gitRemoteOperationState {
            remoteContext = context
        } else {
            remoteContext = nil
        }
        do {
            try await gitRepositoryOperator.abortMerge(repositoryURL: repositoryURL)
            conflictFiles = []
            resolvedConflictFiles = []
            mergeSourceBranch = nil
            if let remoteContext,
               let repository = repositories.first(where: { $0.id == remoteContext.repositoryID }) {
                clearGitRemoteOperationState()
                await refreshAfterGitRemoteOperation(repository)
            } else {
                await refreshAfterBranchOperation()
            }
        } catch {
            branchOperationErrorMessage = error.localizedDescription
        }
    }

    func continueMerge() async {
        guard conflictFiles.isEmpty,
              let repositoryURL = activeRepositoryURL,
              mergeSourceBranch != nil,
              !isResolvingMergeConflict else { return }
        isResolvingMergeConflict = true
        defer { isResolvingMergeConflict = false }
        let remoteContext: GitRemoteOperationContext?
        if case .requiresConflictResolution(let context, _) = gitRemoteOperationState {
            remoteContext = context
        } else {
            remoteContext = nil
        }
        do {
            try await gitRepositoryOperator.continueMerge(repositoryURL: repositoryURL)
            conflictFiles = []
            resolvedConflictFiles = []
            mergeSourceBranch = nil
            if let remoteContext,
               let repository = repositories.first(where: { $0.id == remoteContext.repositoryID }) {
                await refreshAfterGitRemoteOperation(repository)
                guard case .requiresConflictResolution(let currentContext, _) = gitRemoteOperationState,
                      currentContext == remoteContext else { return }
                setGitRemoteOperationState(
                    .succeeded(
                        GitRemoteOperationResult(context: remoteContext, completedAt: .now)
                    )
                )
            } else {
                branchOperationStatusMessage = "Merge 完成。"
                await refreshAfterBranchOperation()
            }
        } catch {
            branchOperationErrorMessage = error.localizedDescription
        }
    }

    private var activeRepositoryURL: URL? {
        guard isRepositoryContext, let repository = selectedRepository else { return nil }
        return repositoryURL(for: repository)
    }

    private func performBranchOperation(_ operation: (URL) async throws -> Void) async {
        guard !isGitWriteOperationRunning, let repositoryURL = activeRepositoryURL else { return }
        isPerformingBranchOperation = true
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        defer { isPerformingBranchOperation = false }
        do {
            try await operation(repositoryURL)
            branchOperationStatusMessage = "Branch 操作成功。"
            await refreshAfterBranchOperation()
        } catch {
            branchOperationErrorMessage = error.localizedDescription
        }
    }

    private func performGitRemoteOperation(
        _ kind: GitRemoteOperationKind,
        repository: RegisteredRepository,
        pullBranchName: String? = nil
    ) async {
        guard !isGitWriteOperationRunning,
              let repositoryURL = repositoryURL(for: repository) else { return }
        let context: GitRemoteOperationContext
        if let pullBranchName {
            context = GitRemoteOperationContext(
                kind: kind, repositoryID: repository.id, repositoryName: repository.name,
                branch: pullBranchName, pullBranchName: pullBranchName
            )
        } else {
            context = gitRemoteOperationContext(kind: kind, repository: repository)
        }
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        setGitRemoteOperationState(.running(context))
        var pushOutcome: GitPushOutcome?

        do {
            switch kind {
            case .fetch:
                try await gitRepositoryOperator.fetch(repositoryURL: repositoryURL)
            case .pull:
                if let pullBranchName {
                    try await gitRepositoryOperator.pullBranch(repositoryURL: repositoryURL, branchName: pullBranchName)
                } else {
                    try await gitRepositoryOperator.pullCurrentBranch(repositoryURL: repositoryURL)
                }
            case .push:
                pushOutcome = try await gitRepositoryOperator.pushCurrentBranchOutcome(
                    repositoryURL: repositoryURL
                )
            case .stash, .unstash, .dropStash, .rollback:
                return
            }
        } catch {
            guard gitRemoteOperationState == .running(context) else { return }
            let hasCurrentBranchConflict: Bool
            if case .pullCurrentBranchConflict = error as? GitRepositoryOperationError {
                hasCurrentBranchConflict = true
            } else {
                hasCurrentBranchConflict = false
            }
            if kind == .pull && (pullBranchName == nil || hasCurrentBranchConflict) {
                let files = (try? await gitRepositoryOperator.conflictFiles(repositoryURL: repositoryURL)) ?? []
                guard gitRemoteOperationState == .running(context) else { return }
                if !files.isEmpty {
                    conflictFiles = files
                    resolvedConflictFiles = []
                    mergeSourceBranch = "upstream"
                    setGitRemoteOperationState(
                        .requiresConflictResolution(context: context, fileCount: files.count)
                    )
                    await refreshAfterGitRemoteOperation(repository)
                    return
                }
            }
            setGitRemoteOperationState(
                .failed(context: context, message: error.localizedDescription)
            )
            if kind == .pull {
                await refreshAfterGitRemoteOperation(repository)
            }
            return
        }

        guard gitRemoteOperationState == .running(context) else { return }
        await refreshAfterGitRemoteOperation(repository)
        guard gitRemoteOperationState == .running(context) else { return }
        if pushOutcome == .upToDate {
            setGitRemoteOperationState(.noChangesToPush(context))
        } else {
            setGitRemoteOperationState(
                .succeeded(GitRemoteOperationResult(context: context, completedAt: .now))
            )
        }
    }

    private func performPreparedPush(
        _ preparation: GitPushPreparation,
        repository: RegisteredRepository
    ) async -> Bool {
        guard !isGitWriteOperationRunning,
              let repositoryURL = repositoryURL(for: repository) else { return false }
        let context = GitRemoteOperationContext(
            kind: .push,
            repositoryID: repository.id,
            repositoryName: repository.name,
            branch: preparation.localBranch,
            pushRemote: preparation.remote,
            pushTargetBranch: preparation.targetRemoteBranch,
            pushSetsUpstream: preparation.createsRemoteBranch
        )
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        setGitRemoteOperationState(.running(context))
        let outcome: GitPushOutcome
        do {
            outcome = try await gitRepositoryOperator.push(
                repositoryURL: repositoryURL,
                localBranch: preparation.localBranch,
                remote: preparation.remote,
                remoteBranch: preparation.targetRemoteBranch,
                setUpstream: preparation.createsRemoteBranch
            )
        } catch {
            guard gitRemoteOperationState == .running(context) else { return false }
            setGitRemoteOperationState(.failed(context: context, message: error.localizedDescription))
            await refreshAfterGitRemoteOperation(repository)
            return false
        }
        guard gitRemoteOperationState == .running(context) else { return false }
        await refreshAfterGitRemoteOperation(repository)
        guard gitRemoteOperationState == .running(context) else { return false }
        if outcome == .upToDate && !preparation.createsRemoteBranch {
            setGitRemoteOperationState(.noChangesToPush(context))
        } else {
            setGitRemoteOperationState(
                .succeeded(GitRemoteOperationResult(context: context, completedAt: .now))
            )
        }
        return true
    }

    private func performGitStashOperation(
        _ kind: GitRemoteOperationKind,
        repository: RegisteredRepository,
        stash: GitStash?,
        message: String?
    ) async {
        guard !isGitWriteOperationRunning,
              let repositoryURL = repositoryURL(for: repository) else { return }
        guard (kind != .unstash && kind != .dropStash) || stash != nil else { return }
        let context = GitRemoteOperationContext(
            kind: kind,
            repositoryID: repository.id,
            repositoryName: repository.name,
            branch: repositorySnapshots[repository.id]?.branch ?? "当前分支",
            stashReference: stash?.reference,
            stashMessage: message ?? stash?.message
        )
        setGitRemoteOperationState(.running(context))
        do {
            switch kind {
            case .stash:
                try await gitRepositoryOperator.stashChanges(repositoryURL: repositoryURL, message: message)
            case .unstash:
                guard let stash else { return }
                try await gitRepositoryOperator.unstashChanges(repositoryURL: repositoryURL, stash: stash)
            case .dropStash:
                guard let stash else { return }
                try await gitRepositoryOperator.dropStash(repositoryURL: repositoryURL, stash: stash)
            case .fetch, .pull, .push:
                return
            case .rollback:
                return
            }
        } catch {
            guard gitRemoteOperationState == .running(context) else { return }
            setGitRemoteOperationState(.failed(context: context, message: error.localizedDescription))
            await refreshAfterGitRemoteOperation(repository)
            await loadStashes()
            return
        }
        guard gitRemoteOperationState == .running(context) else { return }
        await refreshAfterGitRemoteOperation(repository)
        await loadStashes()
        guard gitRemoteOperationState == .running(context) else { return }
        setGitRemoteOperationState(
            .succeeded(GitRemoteOperationResult(context: context, completedAt: .now))
        )
    }

    private func performRollbackOperation(
        repository: RegisteredRepository,
        changes: [GitChangeSelection]
    ) async {
        guard !isGitWriteOperationRunning,
              !changes.isEmpty,
              let repositoryURL = repositoryURL(for: repository) else { return }
        let context = GitRemoteOperationContext(
            kind: .rollback,
            repositoryID: repository.id,
            repositoryName: repository.name,
            branch: repositorySnapshots[repository.id]?.branch ?? "当前分支",
            rollbackSelections: changes
        )
        setGitRemoteOperationState(.running(context))
        do {
            try await gitRepositoryOperator.rollbackChanges(
                repositoryURL: repositoryURL,
                changes: changes
            )
        } catch {
            guard gitRemoteOperationState == .running(context) else { return }
            setGitRemoteOperationState(.failed(context: context, message: error.localizedDescription))
            await refreshAfterGitRemoteOperation(repository)
            return
        }
        guard gitRemoteOperationState == .running(context) else { return }
        await refreshAfterGitRemoteOperation(repository)
        guard gitRemoteOperationState == .running(context) else { return }
        setGitRemoteOperationState(
            .succeeded(GitRemoteOperationResult(context: context, completedAt: .now))
        )
    }

    private func gitRemoteOperationContext(
        kind: GitRemoteOperationKind,
        repository: RegisteredRepository
    ) -> GitRemoteOperationContext {
        let branch = repositorySnapshots[repository.id]?.branch
            ?? (repository.id == selectedRepositoryID
                ? branches.first(where: { !$0.isRemote && $0.isCurrent })?.name
                : nil)
            ?? "当前分支"
        return GitRemoteOperationContext(
            kind: kind,
            repositoryID: repository.id,
            repositoryName: repository.name,
            branch: branch
        )
    }

    private func setGitRemoteOperationState(_ state: GitRemoteOperationState) {
        gitRemoteOperationSuccessDismissTask?.cancel()
        gitRemoteOperationSuccessDismissTask = nil
        gitRemoteOperationState = state
        let autoDismissState: GitRemoteOperationState
        switch state {
        case .succeeded, .noChangesToPush:
            autoDismissState = state
        default:
            return
        }
        gitRemoteOperationSuccessDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self,
                  gitRemoteOperationState == autoDismissState else { return }
            gitRemoteOperationState = .idle
            gitRemoteOperationSuccessDismissTask = nil
        }
    }

    private func clearGitRemoteOperationState() {
        gitRemoteOperationSuccessDismissTask?.cancel()
        gitRemoteOperationSuccessDismissTask = nil
        gitRemoteOperationState = .idle
    }

    private func refreshAfterGitRemoteOperation(_ repository: RegisteredRepository) async {
        if let repositoryURL = repositoryURL(for: repository) {
            await javaLanguageProvider.notifyFilesChanged([repositoryURL])
        }
        await refreshRepository(repository)
        guard selectedRepositoryID == repository.id else { return }
        if selectedSection == .history {
            await refreshHistory()
        } else {
            await loadBranches()
        }
    }

    private func refreshAfterBranchOperation() async {
        guard let repository = selectedRepository else { return }
        if let repositoryURL = repositoryURL(for: repository) {
            await javaLanguageProvider.notifyFilesChanged([repositoryURL])
        }
        await refreshRepository(repository)
        if selectedSection == .history {
            await refreshHistory()
        } else {
            await loadBranches()
        }
    }

    func setHistoryVerticalSplitFraction(_ fraction: Double) {
        let normalized = HistorySplitLayout.normalizedFraction(
            fraction,
            fallback: HistorySplitLayout.defaultVerticalFraction
        )
        guard abs(normalized - historyVerticalSplitFraction) > 0.001 else { return }
        historyVerticalSplitFraction = normalized
        persistWindowState()
    }

    func setHistoryHorizontalSplitFraction(_ fraction: Double) {
        let normalized = HistorySplitLayout.normalizedFraction(
            fraction,
            fallback: HistorySplitLayout.defaultHorizontalFraction
        )
        guard abs(normalized - historyHorizontalSplitFraction) > 0.001 else { return }
        historyHorizontalSplitFraction = normalized
        persistWindowState()
    }

    func changes(
        for kind: GitChangeKind,
        repositoryID: RegisteredRepository.ID? = nil
    ) -> [GitChangeSelection] {
        let repositoryID = repositoryID ?? selectedRepositoryID
        guard let repositoryID, let snapshot = repositorySnapshots[repositoryID] else {
            return []
        }
        return snapshot.changes.compactMap { change in
            guard change.presentationKind == kind else { return nil }
            return changeSelection(for: change)
        }
    }

    func selectChange(_ selection: GitChangeSelection) {
        if selectedChange != selection {
            diffErrorMessage = nil
            isLoadingDiff = true
        }
        selectedChange = selection
        if let repositoryID = selectedChangeRepositoryID ?? selectedRepositoryID {
            rememberedChangeSelections[repositoryID] = selection
        }
        persistWindowState()
        Task { await loadSelectedDiff() }
    }

    func selectChange(
        _ selection: GitChangeSelection,
        repositoryID: RegisteredRepository.ID
    ) {
        if selectedChangeRepositoryID != repositoryID {
            currentDiff = nil
            diffErrorMessage = nil
            isLoadingDiff = true
        }
        selectedChangeRepositoryID = repositoryID
        selectChange(selection)
    }

    func loadSelectedDiff() async {
        await loadSelectedDiff(presentation: .foreground)
    }

    func blameForSelectedChange(side: GitBlameSide) async throws -> [GitBlameLine] {
        guard let repository = selectedChangeRepository,
              let selection = selectedChange,
              let repositoryURL = repositoryURL(for: repository) else { return [] }
        switch side {
        case .old:
            guard selection.kind != .unversioned,
                  currentDiff?.oldLines.isEmpty == false else { return [] }
            return try await gitRepositoryReader.blame(
                repositoryURL: repositoryURL,
                path: selection.originalPath ?? selection.path,
                revision: "HEAD",
                contentsPath: nil
            )
        case .new:
            guard let newLines = currentDiff?.newLines, !newLines.isEmpty else { return [] }
            if selection.kind == .unversioned {
                return newLines.indices.map {
                    GitBlameLine(
                        lineNumber: $0 + 1,
                        commitHash: String(repeating: "0", count: 40),
                        author: "未提交",
                        authoredAt: nil
                    )
                }
            }
            return try await gitRepositoryReader.blame(
                repositoryURL: repositoryURL,
                path: selection.originalPath ?? selection.path,
                revision: "HEAD",
                contentsPath: selection.path
            )
        }
    }

    func blameForMergeConflict(
        file: GitConflictFile,
        resultContent: String
    ) async throws -> GitMergeConflictBlame {
        guard let repositoryURL = activeRepositoryURL else {
            return GitMergeConflictBlame()
        }

        async let yoursRequest = try? gitRepositoryReader.blame(
            repositoryURL: repositoryURL,
            path: file.path,
            revision: "HEAD",
            contentsPath: nil
        )
        async let theirsRequest = try? gitRepositoryReader.blame(
            repositoryURL: repositoryURL,
            path: file.path,
            revision: "MERGE_HEAD",
            contentsPath: nil
        )

        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-MergeConflict-Blame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        let contentsURL = temporaryDirectoryURL.appendingPathComponent("result")
        try Data(resultContent.utf8).write(to: contentsURL, options: .atomic)
        let resultLines = (try? await gitRepositoryReader.blame(
            repositoryURL: repositoryURL,
            path: file.path,
            revision: "HEAD",
            contentsPath: contentsURL.path
        )) ?? uncommittedBlameLines(for: resultContent)

        return GitMergeConflictBlame(
            yours: (await yoursRequest ?? []).indexedByLineNumber,
            result: resultLines.indexedByLineNumber,
            theirs: (await theirsRequest ?? []).indexedByLineNumber
        )
    }

    var selectedFileGitSnapshot: GitRepositorySnapshot? {
        guard let selectedFileURL, let workspaceURL,
              let target = GitFileBlameTarget.resolve(
                fileURL: selectedFileURL, workspaceURL: workspaceURL, repositories: repositories
              ) else { return nil }
        return repositorySnapshots[target.repositoryID]
    }

    var selectedFileGitChange: GitFileChange? {
        guard let selectedFileURL, let workspaceURL,
              let target = GitFileBlameTarget.resolve(
                fileURL: selectedFileURL, workspaceURL: workspaceURL, repositories: repositories
              ) else { return nil }
        return repositorySnapshots[target.repositoryID]?.changes.first { $0.path == target.path }
    }

    func lineChangeBaselineForSelectedFile() async throws -> String? {
        guard let selectedFileURL, let workspaceURL,
              let target = GitFileBlameTarget.resolve(
                fileURL: selectedFileURL, workspaceURL: workspaceURL, repositories: repositories
              ) else { return nil }
        let change = repositorySnapshots[target.repositoryID]?.changes.first { $0.path == target.path }
        return try await gitRepositoryReader.lineChangeBaseline(
            repositoryURL: target.repositoryURL, path: target.path,
            originalPath: change?.originalPath
        )
    }

    func blameForSelectedFile() async throws -> [GitBlameLine] {
        guard let selectedFileURL,
              let workspaceURL,
              case .text = loadedDocument,
              let target = GitFileBlameTarget.resolve(
                fileURL: selectedFileURL,
                workspaceURL: workspaceURL,
                repositories: repositories
              ) else { return [] }

        let change = repositorySnapshots[target.repositoryID]?.changes.first {
            $0.path == target.path
        }
        if change?.isUntracked == true
            || (change?.indexStatus == .added && change?.originalPath == nil) {
            return uncommittedBlameLines(for: documentText)
        }

        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-FileBlame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let contentsURL = temporaryDirectoryURL.appendingPathComponent("contents")
        try Data(documentText.utf8).write(to: contentsURL, options: .atomic)
        return try await gitRepositoryReader.blame(
            repositoryURL: target.repositoryURL,
            path: change?.originalPath ?? target.path,
            revision: "HEAD",
            contentsPath: contentsURL.path
        )
    }

    private func uncommittedBlameLines(for text: String) -> [GitBlameLine] {
        let lineCount = SourceLineIndex(text: text).lineCount
        return (1...lineCount).map {
            GitBlameLine(
                lineNumber: $0,
                commitHash: String(repeating: "0", count: 40),
                author: "未提交",
                authoredAt: nil
            )
        }
    }

    private func loadSelectedDiff(presentation: DiffLoadPresentation) async {
        guard let repository = selectedChangeRepository,
              let selection = selectedChange,
              let repositoryURL = repositoryURL(for: repository) else {
            if presentation == .foreground {
                currentDiff = nil
                isLoadingDiff = false
            }
            return
        }
        if presentation == .background, isLoadingDiff {
            return
        }
        let requestID = UUID()
        diffRequestID = requestID
        if presentation == .foreground {
            isLoadingDiff = true
            diffErrorMessage = nil
        }

        do {
            let diff = try await gitRepositoryReader.fileDiff(
                repositoryURL: repositoryURL,
                target: .change(selection),
                ignoringWhitespace: ignoresWhitespaceInDiff
            )
            guard diffRequestID == requestID else { return }
            if currentDiff != diff {
                currentDiff = diff
            }
        } catch {
            guard diffRequestID == requestID else { return }
            if presentation == .foreground {
                currentDiff = nil
                diffErrorMessage = error.localizedDescription
            }
        }
        guard diffRequestID == requestID else { return }
        diffRequestID = nil
        if presentation == .foreground {
            isLoadingDiff = false
        }
    }

    func toggleIgnoreWhitespace() {
        setIgnoresWhitespaceInDiff(!ignoresWhitespaceInDiff)
    }

    func setIgnoresWhitespaceInDiff(_ ignoresWhitespace: Bool) {
        guard ignoresWhitespaceInDiff != ignoresWhitespace else { return }
        ignoresWhitespaceInDiff = ignoresWhitespace
        persistAppPreferences()
        Task {
            if selectedSection == .history {
                await loadSelectedCommitDiff()
            } else {
                await loadSelectedDiff()
            }
        }
    }

    func setDiffPresentation(_ presentation: GitDiffPresentation) {
        guard diffPresentation != presentation else { return }
        diffPresentation = presentation
        persistAppPreferences()
    }

    func setChangesAutoExpansionMode(_ mode: ChangesAutoExpansionSettings.Mode) {
        guard changesAutoExpansion.mode != mode else { return }
        changesAutoExpansion.mode = mode
        persistAppPreferences()
    }

    func setChangesAutoExpansionMaximumFileCount(_ count: Int) {
        let settings = ChangesAutoExpansionSettings(
            mode: changesAutoExpansion.mode,
            maximumFileCount: count
        )
        guard changesAutoExpansion != settings else { return }
        changesAutoExpansion = settings
        persistAppPreferences()
    }

    func resetChangesAutoExpansion() {
        changesAutoExpansion = .default
        persistAppPreferences()
    }

    func loadWorkspaceRoot() async {
        guard let visibleWorkspaceRootURL else { return }
        await loadDirectory(visibleWorkspaceRootURL)
    }

    func loadDirectory(_ directoryURL: URL, forceReload: Bool = false) async {
        let directoryURL = directoryURL.standardizedFileURL
        guard (forceReload || fileChildren[directoryURL] == nil),
              !loadingDirectoryURLs.contains(directoryURL) else { return }
        loadingDirectoryURLs.insert(directoryURL)
        defer { loadingDirectoryURLs.remove(directoryURL) }
        do {
            let children = try await workspaceFileBrowser.children(of: directoryURL)
            replaceChildren(children, of: directoryURL)
            directoryLoadErrors[directoryURL] = nil
        } catch {
            directoryLoadErrors[directoryURL] = error.localizedDescription
        }
    }

    func recordDeletedFileSession(
        _ session: WorkspaceFileDeletionSession,
        tabs: [OpenFileTab],
        selectedFileURL: URL?
    ) {
        discardLastDeletedFileSession()
        lastDeletedFileSession = session
        lastDeletedFileTabs = tabs
        lastDeletedSelectedFileURL = selectedFileURL
        fileDeletionRestoreErrorMessage = nil
    }

    private func discardLastDeletedFileSession() {
        if let previousSession = lastDeletedFileSession {
            try? FileManager.default.removeItem(at: previousSession.backupDirectoryURL)
        }
        lastDeletedFileSession = nil
        lastDeletedFileTabs = []
        lastDeletedSelectedFileURL = nil
        fileDeletionRestoreErrorMessage = nil
    }

    func restoreLastDeletedFiles() async {
        guard let session = lastDeletedFileSession else { return }
        guard let visibleWorkspaceRootURL,
              visibleWorkspaceRootURL.standardizedFileURL == session.workspaceRootURL.standardizedFileURL else {
            return
        }
        do {
            try await FileSystemWorkspaceFileDeleter().restore(session)
            lastDeletedFileSession = nil
            fileDeletionRestoreErrorMessage = nil
            let parentDirectories = Set(session.items.map {
                $0.originalURL.deletingLastPathComponent().standardizedFileURL
            })
            for directoryURL in parentDirectories {
                await loadDirectory(directoryURL, forceReload: true)
            }
            let restoredTabs = lastDeletedFileTabs.filter {
                FileManager.default.fileExists(atPath: $0.url.path)
            }
            for tab in restoredTabs where !openFileTabs.contains(where: { $0.id == tab.id }) {
                openFileTabs.append(tab)
            }
            trimOpenFileTabsIfNeeded()
            if let lastDeletedSelectedFileURL,
               let restoredTab = openFileTabs.first(where: { $0.url == lastDeletedSelectedFileURL }) {
                activateFileTab(restoredTab)
            }
            if let firstURL = session.items.first?.originalURL {
                await revealFileTreeItem(firstURL)
            }
        } catch {
            fileDeletionRestoreErrorMessage = error.localizedDescription
        }
    }

    func fileItemWasRenamed(from oldURL: URL, to newURL: URL) {
        let oldURL = oldURL.standardizedFileURL
        let newURL = newURL.standardizedFileURL
        guard oldURL != newURL else {
            persistWindowState()
            return
        }

        syncActiveFileTab()
        let selectedFileWasRenamed = selectedFileURL.map {
            Self.isSameOrDescendant($0, of: oldURL)
        } ?? false
        let selectedDocumentWasLoading = selectedFileWasRenamed && isLoadingDocument
        let shouldResumeDocumentAutoSave = selectedFileWasRenamed && hasUnsavedDocumentChanges

        let autoSaveURLs = documentAutoSaveTasks.keys.filter {
            Self.isSameOrDescendant($0, of: oldURL)
        }
        for fileURL in autoSaveURLs {
            documentAutoSaveTasks[fileURL]?.cancel()
            documentAutoSaveTasks[fileURL] = nil
            documentAutoSaveRequestIDs[fileURL] = nil
        }
        if selectedDocumentWasLoading {
            documentRequestID = nil
        }

        fileChildren = fileChildren.reduce(into: [:]) { result, item in
            let directoryURL = Self.relocatedFileURL(item.key, from: oldURL, to: newURL)
            result[directoryURL] = item.value.map { entry in
                let entryURL = Self.relocatedFileURL(entry.url, from: oldURL, to: newURL)
                return WorkspaceFileEntry(
                    url: entryURL,
                    name: entryURL.lastPathComponent,
                    isDirectory: entry.isDirectory
                )
            }
        }
        directoryLoadErrors = directoryLoadErrors.reduce(into: [:]) { result, item in
            result[Self.relocatedFileURL(item.key, from: oldURL, to: newURL)] = item.value
        }
        expandedDirectoryURLs = Set(
            expandedDirectoryURLs.map { Self.relocatedFileURL($0, from: oldURL, to: newURL) }
        )
        loadingDirectoryURLs = Set(
            loadingDirectoryURLs.map { Self.relocatedFileURL($0, from: oldURL, to: newURL) }
        )
        fileTreeRevealRequest = fileTreeRevealRequest.map {
            FileTreeRevealRequest(fileURL: Self.relocatedFileURL($0.fileURL, from: oldURL, to: newURL))
        }
        fileSearchResults = fileSearchResults.map { entry in
            let entryURL = Self.relocatedFileURL(entry.url, from: oldURL, to: newURL)
            return WorkspaceFileEntry(
                url: entryURL,
                name: entryURL.lastPathComponent,
                isDirectory: entry.isDirectory
            )
        }
        textSearchResults = textSearchResults.map { result in
            WorkspaceTextSearchResult(
                fileURL: Self.relocatedFileURL(result.fileURL, from: oldURL, to: newURL),
                line: result.line,
                lineText: result.lineText
            )
        }

        openFileTabs = openFileTabs.map { tab in
            var relocatedTab = tab
            relocatedTab.url = Self.relocatedFileURL(tab.url, from: oldURL, to: newURL)
            return relocatedTab
        }
        selectedFileURL = selectedFileURL.map {
            Self.relocatedFileURL($0, from: oldURL, to: newURL)
        }
        javaSemanticTokenCacheByFile = javaSemanticTokenCacheByFile.reduce(into: [:]) { result, item in
            result[Self.relocatedFileURL(item.key, from: oldURL, to: newURL)] = item.value
        }
        fileNavigationBackStack = fileNavigationBackStack.map {
            JavaNavigationHistoryEntry(
                fileURL: Self.relocatedFileURL($0.fileURL, from: oldURL, to: newURL),
                range: $0.range
            )
        }
        fileNavigationForwardStack = fileNavigationForwardStack.map {
            JavaNavigationHistoryEntry(
                fileURL: Self.relocatedFileURL($0.fileURL, from: oldURL, to: newURL),
                range: $0.range
            )
        }
        currentFileNavigationLocation = currentFileNavigationLocation.map {
            JavaNavigationHistoryEntry(
                fileURL: Self.relocatedFileURL($0.fileURL, from: oldURL, to: newURL),
                range: $0.range
            )
        }
        javaNavigationResultPresentation = nil
        javaNavigationSourcePresentation = nil
        fileTabSessionsByContext = fileTabSessionsByContext.mapValues { session in
            FileTabSessionState(
                tabs: session.tabs.map { tab in
                    PersistedFileTab(
                        path: Self.relocatedFileURL(
                            URL(fileURLWithPath: tab.path),
                            from: oldURL,
                            to: newURL
                        ).path,
                        showsMarkdownPreview: tab.showsMarkdownPreview,
                        visibleLine: tab.visibleLine
                    )
                },
                selectedFilePath: session.selectedFilePath.map {
                    Self.relocatedFileURL(
                        URL(fileURLWithPath: $0),
                        from: oldURL,
                        to: newURL
                    ).path
                }
            )
        }

        let affectedRepositories = repositories.compactMap { repository -> (old: RegisteredRepository, new: RegisteredRepository, oldURL: URL, newURL: URL)? in
            guard let repositoryURL = repositoryURL(for: repository),
                  Self.isSameOrDescendant(repositoryURL, of: oldURL),
                  let workspaceURL,
                  let newRelativePath = Self.relativePath(of: Self.relocatedFileURL(repositoryURL, from: oldURL, to: newURL), from: workspaceURL)
            else { return nil }
            let relocatedRepository = RegisteredRepository(
                displayName: repository.displayName,
                relativePath: newRelativePath,
                isPinned: repository.isPinned
            )
            return (repository, relocatedRepository, repositoryURL, Self.relocatedFileURL(repositoryURL, from: oldURL, to: newURL))
        }

        if !affectedRepositories.isEmpty {
            repositoryRefreshContextID = UUID()
            for affected in affectedRepositories {
                migrateRepositoryWindowState(
                    from: affected.old.id,
                    to: affected.new.id,
                    previousRepositoryURL: affected.oldURL,
                    relocatedRepositoryURL: affected.newURL
                )
                if let snapshot = repositorySnapshots.removeValue(forKey: affected.old.id) {
                    repositorySnapshots[affected.new.id] = snapshot
                }
                if let error = repositorySnapshotErrors.removeValue(forKey: affected.old.id) {
                    repositorySnapshotErrors[affected.new.id] = error
                }
                if let excluded = excludedCommitChanges.removeValue(forKey: affected.old.id) {
                    excludedCommitChanges[affected.new.id] = excluded
                }
                javaIndexPhases[affected.old.id] = nil
                refreshingRepositoryIDs.remove(affected.old.id)
                if selectedRepositoryID == affected.old.id {
                    selectedRepositoryID = affected.new.id
                }
                if selectedChangeRepositoryID == affected.old.id {
                    selectedChangeRepositoryID = affected.new.id
                }
                if case .repository(let repositoryID) = navigationContext,
                   repositoryID == affected.old.id {
                    navigationContext = .repository(affected.new.id)
                }
                mavenProjectRevisions[affected.oldURL.standardizedFileURL.path] = nil
                mavenProjectRevisions[affected.newURL.standardizedFileURL.path, default: 0] += 1
            }
            repositories = repositories.map { repository in
                affectedRepositories.first(where: { $0.old.id == repository.id })?.new ?? repository
            }
            persistRepositoryState()
            reloadJavaWorkspaceConfiguration()
        }

        if shouldResumeDocumentAutoSave {
            scheduleDocumentAutoSave()
        } else if let selectedFileURL {
            isSavingDocument = documentAutoSaveRequestIDs[selectedFileURL] != nil
        }
        persistWindowState()
        if selectedDocumentWasLoading, let selectedFileURL {
            loadFile(selectedFileURL, preservesMarkdownPreview: true)
        }
        if !affectedRepositories.isEmpty {
            let repositoriesToRefresh = affectedRepositories.map { $0.new }
            Task { await refreshRepositories(repositoriesToRefresh) }
        }
    }

    func retryDirectory(_ directoryURL: URL) {
        Task { await loadDirectory(directoryURL, forceReload: true) }
    }

    func setShowsHiddenFiles(_ showsHiddenFiles: Bool) {
        guard self.showsHiddenFiles != showsHiddenFiles else { return }
        self.showsHiddenFiles = showsHiddenFiles
        persistAppPreferences()
        prepareExpandedCompactDirectoryChains()
    }

    func setCompactsSingleChildDirectories(_ compactsSingleChildDirectories: Bool) {
        guard self.compactsSingleChildDirectories != compactsSingleChildDirectories else { return }
        self.compactsSingleChildDirectories = compactsSingleChildDirectories
        persistAppPreferences()
        prepareExpandedCompactDirectoryChains()
    }

    func setAutomaticallyRefreshesWorkspace(_ automaticallyRefreshesWorkspace: Bool) {
        guard self.automaticallyRefreshesWorkspace != automaticallyRefreshesWorkspace else { return }
        self.automaticallyRefreshesWorkspace = automaticallyRefreshesWorkspace
        workspaceMonitoringErrorMessage = nil
        persistAppPreferences()
    }

    func setRefreshesWhenBecomingActive(_ refreshesWhenBecomingActive: Bool) {
        guard self.refreshesWhenBecomingActive != refreshesWhenBecomingActive else { return }
        self.refreshesWhenBecomingActive = refreshesWhenBecomingActive
        persistAppPreferences()
    }

    func setOpensMarkdownInPreview(_ opensMarkdownInPreview: Bool) {
        guard self.opensMarkdownInPreview != opensMarkdownInPreview else { return }
        self.opensMarkdownInPreview = opensMarkdownInPreview
        persistAppPreferences()
    }

    func setSidebarFontSize(_ fontSize: Double) {
        let fontSize = RepoDeskFontSize.normalized(fontSize)
        guard sidebarFontSize != fontSize else { return }
        sidebarFontSize = fontSize
        persistAppPreferences()
    }

    func setInterfaceFontSize(_ fontSize: Double) {
        let fontSize = RepoDeskFontSize.normalized(fontSize)
        guard interfaceFontSize != fontSize else { return }
        interfaceFontSize = fontSize
        persistAppPreferences()
    }

    func setFileContentFontSize(_ fontSize: Double) {
        let fontSize = RepoDeskFontSize.normalized(fontSize)
        guard fileContentFontSize != fontSize else { return }
        fileContentFontSize = fontSize
        persistAppPreferences()
    }

    func setMaximumOpenFileTabs(_ count: Int) {
        let normalized = min(max(count, 1), 50)
        guard maximumOpenFileTabs != normalized else { return }
        syncActiveFileTab()
        maximumOpenFileTabs = normalized
        trimOpenFileTabsIfNeeded()
        persistAppPreferences()
        persistWindowState()
    }

    func shortcut(for id: AppShortcutID) -> ShortcutBinding {
        shortcuts[id] ?? id.defaultBinding
    }

    func shortcutConflict(for id: AppShortcutID) -> AppShortcutID? {
        let binding = shortcut(for: id)
        return AppShortcutID.allCases.first {
            $0 != id
                && $0.group == id.group
                && shortcut(for: $0) == binding
        }
    }

    func setShortcut(_ binding: ShortcutBinding, for id: AppShortcutID) {
        guard binding != shortcut(for: id) else { return }
        shortcuts[id] = binding
        persistAppPreferences()
    }

    func resetShortcut(_ id: AppShortcutID) {
        setShortcut(id.defaultBinding, for: id)
    }

    func resetAllShortcuts() {
        shortcuts = ShortcutBinding.defaults()
        persistAppPreferences()
    }

    func setJavaIndexSettings(_ settings: JavaIndexSettings) {
        guard javaIndexSettings != settings else { return }
        javaIndexSettings = settings
        persistAppPreferences()
        Task { await javaLanguageProvider.configure(settings) }
    }

    func setJavaBackgroundIndexingPaused(_ paused: Bool) {
        Task { await javaLanguageProvider.setBackgroundIndexingPaused(paused) }
    }

    func rebuildJavaIndex(repositoryID: RegisteredRepository.ID) {
        Task { await javaLanguageProvider.rebuildIndex(repositoryID: repositoryID) }
    }

    func clearUnusedJavaCaches() {
        Task { await javaLanguageProvider.clearUnusedCaches() }
    }

    func performJavaNavigation(
        action: JavaNavigationAction,
        fileURL: URL,
        position: JavaSourcePosition,
        documentText: String,
        anchor: JavaNavigationPopupAnchor? = nil
    ) {
        guard fileURL.pathExtension.lowercased() == "java",
              let repositoryID = repositoryID(containing: fileURL) else { return }
        let requestID = UUID()
        javaNavigationRequestID = requestID
        javaNavigationLoadingTask?.cancel()
        javaNavigationLoadingPresentation = nil
        javaNavigationLoadingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, self.javaNavigationRequestID == requestID else { return }
            self.javaNavigationLoadingPresentation = JavaNavigationLoadingPresentation(
                id: requestID,
                action: action,
                anchor: anchor
            )
        }
        let origin = JavaNavigationHistoryEntry(
            fileURL: fileURL.standardizedFileURL,
            range: JavaSourceRange(start: position, end: position)
        )
        currentFileNavigationLocation = origin
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishJavaNavigation(requestID: requestID) }
            let navigationRequest = JavaNavigationRequest(
                action: action,
                fileURL: fileURL.standardizedFileURL,
                position: position,
                documentText: documentText
            )
            let myBatisTargets: [JavaNavigationTarget]
            if action == .implementation {
                let workspaceURL = self.workspaceURL
                let repositories = self.repositories
                myBatisTargets = await Task.detached(priority: .utility) {
                    MyBatisMapperNavigationResolver.targets(
                        for: navigationRequest,
                        workspaceURL: workspaceURL,
                        repositories: repositories
                    )
                }.value
            } else {
                myBatisTargets = []
            }
            guard javaNavigationRequestID == requestID else { return }
            // A ready semantic session remains authoritative for inheritance,
            // overloads and unsaved working copies. Direct source callers let a
            // cold session navigate without waiting for JVM/project startup.
            let hasReadyJavaSession = javaIndexSnapshot.activeRepositoryID == repositoryID
                && javaIndexSnapshot.runningJVMCount > 0
                && javaIndexSnapshot.repositories.first(where: { $0.repositoryID == repositoryID })?.phase == .ready
            let hasUnsavedJavaTabs = hasUnsavedDocumentChanges || openFileTabs.contains {
                $0.url.pathExtension.lowercased() == "java" && $0.text != $0.originalText
            }
            let sourceCallerTargets = !hasReadyJavaSession && !hasUnsavedJavaTabs
                && JavaWorkspaceNavigationFallback.isMethodDeclaration(navigationRequest)
                ? await JavaWorkspaceNavigationFallback.targets(
                    for: navigationRequest, workspaceURL: workspaceURL, repositories: repositories
                ) : []
            guard javaNavigationRequestID == requestID else { return }
            let targets: [JavaNavigationTarget]
            if !myBatisTargets.isEmpty {
                targets = myBatisTargets
            } else if !sourceCallerTargets.isEmpty {
                targets = sourceCallerTargets
            } else {
                targets = await javaLanguageProvider.navigationTargets(
                    repositoryID: repositoryID,
                    request: navigationRequest
                )
            }
            guard javaNavigationRequestID == requestID else { return }
            let fallbackTargets = targets.isEmpty
                ? await JavaWorkspaceNavigationFallback.targets(
                    for: JavaNavigationRequest(
                        action: action,
                        fileURL: fileURL.standardizedFileURL,
                        position: position,
                        documentText: documentText
                    ),
                    workspaceURL: workspaceURL,
                    repositories: repositories
                )
                : []
            guard javaNavigationRequestID == requestID else { return }
            let resolvedTargets = await annotateJavaNavigationTargets(targets + fallbackTargets)
            let filteredTargets = await filterJavaNavigationTargets(resolvedTargets, action: action)
            guard javaNavigationRequestID == requestID else { return }
            guard !filteredTargets.isEmpty else {
                let indexState = javaIndexSnapshot.repositories.first {
                    $0.repositoryID == repositoryID
                }
                jumpToSourceErrorMessage = Self.javaNavigationFailureMessage(
                    repositoryName: indexState?.displayName
                        ?? repositories.first(where: { $0.id == repositoryID })?.name,
                    phase: indexState?.phase,
                    detail: indexState?.detail,
                    action: action
                )
                return
            }
            if filteredTargets.count == 1, let target = filteredTargets.first {
                handleJavaNavigationTarget(target, origin: origin, anchor: anchor)
            } else {
                javaNavigationResultPresentation = JavaNavigationResultPresentation(
                    title: filteredTargets.first?.kind == .enum
                        ? javaEnumNavigationTitle(documentText: documentText, position: position)
                        : javaNavigationTitle(action),
                    targets: filteredTargets,
                    origin: origin,
                    anchor: anchor
                )
            }
        }
    }

    private func finishJavaNavigation(requestID: UUID) {
        guard javaNavigationRequestID == requestID else { return }
        javaNavigationLoadingTask?.cancel()
        javaNavigationLoadingTask = nil
        javaNavigationLoadingPresentation = nil
        javaNavigationRequestID = nil
    }

    func selectJavaNavigationTarget(_ target: JavaNavigationTarget) {
        let origin = javaNavigationResultPresentation?.origin
        let anchor = javaNavigationResultPresentation?.anchor
        javaNavigationResultPresentation = nil
        handleJavaNavigationTarget(
            annotateJavaNavigationTarget(target),
            origin: origin,
            anchor: anchor
        )
    }

    func searchJavaSymbols(query: String, scope: JavaSymbolSearchScope) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        javaSymbolSearchRequestID = requestID
        guard !query.isEmpty,
              let repositoryID = selectedFileURL.flatMap(repositoryID(containing:))
                ?? selectedRepositoryID else {
            javaSymbolSearchResults = []
            isSearchingJavaSymbols = false
            return
        }
        isSearchingJavaSymbols = true
        Task {
            let targets = await javaLanguageProvider.searchSymbols(
                JavaSymbolSearchRequest(repositoryID: repositoryID, query: query, scope: scope)
            )
            guard javaSymbolSearchRequestID == requestID else { return }
            javaSymbolSearchResults = JavaSymbolMatcher.sorted(targets, query: query)
            isSearchingJavaSymbols = false
        }
    }

    func selectJavaSymbolTarget(_ target: JavaNavigationTarget) {
        let origin = currentJavaNavigationLocation()
        Task {
            let resolvedTarget = await annotateJavaNavigationTargets([target]).first
            guard let resolvedTarget else { return }
            handleJavaNavigationTarget(resolvedTarget, origin: origin, anchor: nil)
        }
    }

    func dismissJavaNavigationSource() {
        javaNavigationSourcePresentation = nil
    }

    func openJavaNavigationSource() {
        guard let presentation = javaNavigationSourcePresentation else { return }
        guard case .workspaceRepository(let repositoryID, _, let fileURL) = presentation.origin else {
            return
        }

        javaNavigationSourcePresentation = nil
        selectRepositoryContext(repositoryID)
        selectSection(.files)
        let sourceTarget = JavaNavigationTarget(
            fileURL: fileURL,
            range: presentation.target.range,
            selectionRange: presentation.target.selectionRange,
            name: presentation.target.name,
            detail: presentation.target.detail,
            containerName: presentation.target.containerName,
            kind: presentation.target.kind,
            origin: presentation.target.origin
        )
        navigateToJavaTarget(sourceTarget, origin: presentation.navigationOrigin)
        Task { await revealFileTreeItem(fileURL) }
    }

    @discardableResult
    func navigateFileBack() -> Bool {
        let current = currentNavigationLocation()
        guard let target = Self.popValidNavigationTarget(
            from: &fileNavigationBackStack,
            excluding: current
        ) else { return false }
        if let current {
            Self.appendNavigationLocation(current, to: &fileNavigationForwardStack)
        }
        navigateToFile(target.fileURL, range: target.range, recordsHistory: false)
        selectSection(.files)
        return true
    }

    @discardableResult
    func navigateFileForward() -> Bool {
        let current = currentNavigationLocation()
        guard let target = Self.popValidNavigationTarget(
            from: &fileNavigationForwardStack,
            excluding: current
        ) else { return false }
        if let current {
            Self.appendNavigationLocation(current, to: &fileNavigationBackStack)
        }
        navigateToFile(target.fileURL, range: target.range, recordsHistory: false)
        selectSection(.files)
        return true
    }

    @discardableResult
    func navigateJavaBack() -> Bool {
        navigateFileBack()
    }

    @discardableResult
    func navigateJavaForward() -> Bool {
        navigateFileForward()
    }

    private func navigateToJavaTarget(
        _ target: JavaNavigationTarget,
        origin: JavaNavigationHistoryEntry?
    ) {
        navigateToFile(
            target.fileURL,
            range: target.selectionRange ?? target.range,
            recordsHistory: true,
            historyOrigin: origin
        )
    }

    private func handleJavaNavigationTarget(
        _ target: JavaNavigationTarget,
        origin: JavaNavigationHistoryEntry?,
        anchor: JavaNavigationPopupAnchor?
    ) {
        guard let targetOrigin = target.origin else {
            navigateToJavaTarget(target, origin: origin)
            return
        }

        if case .workspaceRepository(let repositoryID, _, _) = targetOrigin,
           repositoryID == selectedFileURL.flatMap(repositoryID(containing:)) {
            navigateToJavaTarget(target, origin: origin)
            return
        }

        javaNavigationSourcePresentation = JavaNavigationSourcePresentation(
            target: target,
            origin: targetOrigin,
            navigationOrigin: origin,
            anchor: anchor
        )
    }

    private func annotateJavaNavigationTarget(_ target: JavaNavigationTarget) -> JavaNavigationTarget {
        guard target.origin == nil else { return target }
        var target = target
        target.origin = JavaNavigationTargetSourceResolver.origin(
            for: target,
            workspaceURL: workspaceURL,
            repositories: repositories,
            mavenLocalRepositoryURL: nil
        )
        return target
    }

    private func annotateJavaNavigationTargets(
        _ targets: [JavaNavigationTarget]
    ) async -> [JavaNavigationTarget] {
        let workspaceURL = self.workspaceURL
        let repositories = self.repositories
        let mavenLocalRepositoryURL = javaMavenLocalRepositoryURL
        var resolvedTargets = targets
        var targetsToResolve: [JavaNavigationTarget] = []
        for target in targets where target.origin == nil {
            if let cachedOrigin = javaNavigationOriginCache[target.fileURL.absoluteString] {
                if let index = resolvedTargets.firstIndex(where: { $0.id == target.id }) {
                    resolvedTargets[index].origin = cachedOrigin
                }
            } else {
                targetsToResolve.append(target)
            }
        }
        guard !targetsToResolve.isEmpty else { return resolvedTargets }

        let workspaceMavenProjects = await cachedJavaWorkspaceMavenProjects()
        let jarNames = Set(
            targetsToResolve.compactMap {
                JavaNavigationTargetSourceResolver.jarName(for: $0.fileURL.absoluteString)
            }
        )
        let mavenCoordinates = await Task.detached(priority: .utility) {
            JavaNavigationTargetSourceResolver.mavenCoordinates(
                for: jarNames,
                localRepositoryURL: mavenLocalRepositoryURL
            )
        }.value
        let coordinateLookup = JavaMavenCoordinateLookup(
            coordinates: mavenCoordinates,
            misses: jarNames.subtracting(mavenCoordinates.keys)
        )
        let origins = await Task.detached(priority: .utility) {
            targetsToResolve.reduce(into: [String: JavaNavigationTargetOrigin]()) { result, target in
                result[target.fileURL.absoluteString] = JavaNavigationTargetSourceResolver.origin(
                    for: target,
                    workspaceURL: workspaceURL,
                    repositories: repositories,
                    mavenLocalRepositoryURL: mavenLocalRepositoryURL,
                    workspaceMavenProjectIndex: workspaceMavenProjects,
                    mavenCoordinateLookup: coordinateLookup
                )
            }
        }.value
        javaNavigationOriginCache.merge(origins) { _, new in new }
        let maximumCachedOrigins = 512
        if javaNavigationOriginCache.count > maximumCachedOrigins {
            let keysToRemove = javaNavigationOriginCache.keys.prefix(
                javaNavigationOriginCache.count - maximumCachedOrigins
            )
            for key in keysToRemove {
                javaNavigationOriginCache.removeValue(forKey: key)
            }
        }
        return resolvedTargets.map { target in
            guard target.origin == nil,
                  let origin = origins[target.fileURL.absoluteString]
                    ?? javaNavigationOriginCache[target.fileURL.absoluteString] else {
                return target
            }
            var target = target
            target.origin = origin
            return target
        }
    }

    private func cachedJavaWorkspaceMavenProjects() async -> [JavaWorkspaceMavenProject] {
        guard let workspaceURL else { return [] }
        let cacheKey = workspaceURL.standardizedFileURL.path + "\n"
            + repositories.map { "\($0.id):\($0.name)" }.joined(separator: "\n")
        if javaWorkspaceMavenProjectsCacheKey != cacheKey {
            javaWorkspaceMavenProjectsTask?.cancel()
            let workspaceURL = workspaceURL.standardizedFileURL
            let repositories = repositories
            javaWorkspaceMavenProjectsCacheKey = cacheKey
            javaWorkspaceMavenProjectsTask = Task.detached(priority: .utility) {
                JavaNavigationTargetSourceResolver.workspaceMavenProjects(
                    workspaceURL: workspaceURL,
                    repositories: repositories
                )
            }
        }
        guard let task = javaWorkspaceMavenProjectsTask else { return [] }
        return await task.value
    }

    private func clearJavaNavigationCaches(changedFileURLs: [URL]? = nil) {
        javaWorkspaceMavenProjectsTask?.cancel()
        javaWorkspaceMavenProjectsTask = nil
        javaWorkspaceMavenProjectsCacheKey = nil
        javaNavigationOriginCache.removeAll(keepingCapacity: true)
        if let workspaceURL {
            let workspaceURL = workspaceURL.standardizedFileURL
            let selectedJavaFileURL = selectedFileURL?.pathExtension.lowercased() == "java" ? selectedFileURL : nil
            let repositories = self.repositories
            Task {
                await JavaWorkspaceNavigationFallback.invalidate(
                    workspaceURL: workspaceURL, changedFileURLs: changedFileURLs
                )
                if let selectedJavaFileURL {
                    await JavaWorkspaceNavigationFallback.prepareMethodCallers(
                        fileURL: selectedJavaFileURL, workspaceURL: workspaceURL, repositories: repositories
                    )
                }
            }
        }
    }

    private var javaMavenLocalRepositoryURL: URL? {
        let configuredPath = mavenSettings.localRepository
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configuredPath.isEmpty
            ? "/usr/local/maven/repository"
            : NSString(string: configuredPath).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func currentJavaNavigationLocation() -> JavaNavigationHistoryEntry? {
        currentNavigationLocation()
    }

    private func currentNavigationLocation() -> JavaNavigationHistoryEntry? {
        guard let selectedFileURL else { return nil }
        if currentFileNavigationLocation?.fileURL == selectedFileURL {
            return currentFileNavigationLocation
        }
        let line = max(0, (openFileTabs.first { $0.url == selectedFileURL }?.visibleLine ?? 1) - 1)
        let position = JavaSourcePosition(line: line, character: 0)
        return JavaNavigationHistoryEntry(
            fileURL: selectedFileURL,
            range: JavaSourceRange(start: position, end: position)
        )
    }

    private static func appendNavigationLocation(
        _ location: JavaNavigationHistoryEntry,
        to stack: inout [JavaNavigationHistoryEntry]
    ) {
        guard stack.last != location else { return }
        stack.append(location)
        let maximumHistoryCount = 100
        if stack.count > maximumHistoryCount {
            stack.removeFirst(stack.count - maximumHistoryCount)
        }
    }

    private static func popValidNavigationTarget(
        from stack: inout [JavaNavigationHistoryEntry],
        excluding current: JavaNavigationHistoryEntry?
    ) -> JavaNavigationHistoryEntry? {
        while let target = stack.popLast() {
            guard target != current,
                  FileManager.default.fileExists(atPath: target.fileURL.path) else { continue }
            return target
        }
        return nil
    }

    private func resetFileNavigationHistory() {
        fileNavigationBackStack = []
        fileNavigationForwardStack = []
        currentFileNavigationLocation = nil
    }

    private func javaNavigationTitle(_ action: JavaNavigationAction) -> String {
        switch action {
        case .contextual: "选择跳转目标"
        case .declaration: "选择声明"
        case .implementation: "选择实现"
        case .incomingCalls: "选择调用方或使用位置"
        case .references: "选择使用位置"
        case .superDeclaration: "选择父类、接口或父方法"
        }
    }

    nonisolated static func javaNavigationFailureMessage(
        repositoryName: String?,
        phase: JavaRepositoryIndexPhase?,
        detail: String?,
        action: JavaNavigationAction
    ) -> String {
        let repository = repositoryName ?? "当前项目"
        let target = switch action {
        case .contextual, .declaration, .implementation, .superDeclaration:
            "目标定义"
        case .incomingCalls, .references:
            "目标"
        }

        switch phase {
        case .failed:
            let reason = detail?.isEmpty == false ? detail! : "未知错误"
            return "\(repository) 的 Java 索引失败，暂时无法查找\(target)：\(reason)。请点击顶部的 Java 索引状态查看详情，或重建索引后重试。"
        case .queued, .starting, .indexing, .stale, .paused:
            return "\(repository) 的 Java 索引尚未就绪，暂时无法查找\(target)。请等待索引完成后重试。"
        case .ready, .notRequired, nil:
            return "未找到\(target)。如果它来自依赖包，请确认依赖源码已在当前工作区或 Maven 本地仓库中。"
        }
    }

    private func javaEnumNavigationTitle(
        documentText: String,
        position: JavaSourcePosition
    ) -> String {
        let symbol = javaIdentifier(at: position, in: documentText) ?? "枚举"
        let packageName = documentText
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("package ") else { return nil }
                return trimmed
                    .dropFirst("package ".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
            }
            .first
        if let packageName, !packageName.isEmpty {
            return "Enum \(packageName).\(symbol)"
        }
        return "Enum \(symbol)"
    }

    private func javaIdentifier(
        at position: JavaSourcePosition,
        in text: String
    ) -> String? {
        let source = text as NSString
        let index = SourceLineIndex(text: text)
        guard index.lineStartOffsets.indices.contains(position.line) else { return nil }
        let lineStart = index.lineStartOffsets[position.line]
        let lineEnd = position.line + 1 < index.lineStartOffsets.count
            ? index.lineStartOffsets[position.line + 1]
            : source.length
        let lineRange = NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
        let line = source.substring(with: lineRange)
        let localPosition = min(max(0, position.character), (line as NSString).length)
        let regex = try? NSRegularExpression(pattern: "[A-Za-z_$][A-Za-z0-9_$]*")
        let matches = regex?.matches(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) ?? []
        guard let match = matches.first(where: {
            NSLocationInRange(localPosition, $0.range)
                || localPosition == NSMaxRange($0.range)
        }) else { return nil }
        return (line as NSString).substring(with: match.range)
    }

    private func filterJavaNavigationTargets(
        _ targets: [JavaNavigationTarget],
        action: JavaNavigationAction
    ) async -> [JavaNavigationTarget] {
        guard action == .incomingCalls || action == .references else { return targets }
        return await Task.detached(priority: .utility) {
            targets.filter { target in
                guard let data = try? Data(contentsOf: target.fileURL),
                      let text = String(data: data, encoding: .utf8) else { return true }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                guard lines.indices.contains(target.range.start.line) else { return true }
                let line = lines[target.range.start.line]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return !line.hasPrefix("import ") && !line.hasPrefix("package ")
            }
        }.value
    }

    private func observeJavaLanguageEvents() {
        let events = javaLanguageProvider.events
        javaLanguageEventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .snapshot(let snapshot):
                    let previousPhases = javaIndexPhases
                    javaIndexSnapshot = snapshot
                    javaIndexPhases = snapshot.repositories.reduce(into: [:]) { phases, repository in
                        phases[repository.repositoryID] = repository.phase
                    }
                    if let selectedFileURL,
                       let repositoryID = repositoryID(containing: selectedFileURL),
                       let phase = snapshot.repositories.first(where: { $0.repositoryID == repositoryID })?.phase,
                       Self.shouldScheduleJavaSemanticTokens(
                           previousPhase: previousPhases[repositoryID],
                           currentPhase: phase
                       ) {
                        scheduleJavaSemanticTokens(after: nil)
                    }
                }
            }
        }
    }

    nonisolated static func shouldScheduleJavaSemanticTokens(
        previousPhase: JavaRepositoryIndexPhase?,
        currentPhase: JavaRepositoryIndexPhase
    ) -> Bool {
        currentPhase == .ready && previousPhase != .ready
    }

    private func reloadJavaWorkspaceConfiguration() {
        clearJavaNavigationCaches()
        let workspaceURL = self.workspaceURL
        let repositories = self.repositories
        let javaHome = mavenSettings.javaHome.trimmingCharacters(in: .whitespacesAndNewlines)
        let settingsFile = mavenSettings.userSettingsFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if let repository = selectedRepository, let repositoryURL = repositoryURL(for: repository) {
            Task {
                await JavaWorkspaceNavigationFallback.prepareMethodCallers(
                    fileURL: repositoryURL, workspaceURL: workspaceURL, repositories: repositories
                )
            }
        }
        Task {
            await javaLanguageProvider.configure(javaIndexSettings)
            await javaLanguageProvider.updateWorkspace(
                workspaceURL: workspaceURL,
                repositories: repositories,
                projectJavaHome: javaHome.isEmpty ? nil : NSString(string: javaHome).expandingTildeInPath,
                mavenUserSettingsFile: settingsFile.isEmpty
                    ? nil
                    : NSString(string: settingsFile).expandingTildeInPath
            )
        }
    }

    private func scheduleJavaSemanticTokens(after delay: Duration? = .milliseconds(150)) {
        javaSemanticTokensTask?.cancel()
        javaSemanticTokensTask = nil
        guard let selectedFileURL,
              selectedFileURL.pathExtension.lowercased() == "java",
              let repositoryID = repositoryID(containing: selectedFileURL),
              case .text = loadedDocument else {
            javaSemanticTokens = []
            return
        }
        let fileURL = selectedFileURL.standardizedFileURL
        let text = documentText
        let workspaceURL = self.workspaceURL
        let repositories = self.repositories
        Task {
            await JavaWorkspaceNavigationFallback.prepareMethodCallers(
                fileURL: fileURL, workspaceURL: workspaceURL, repositories: repositories
            )
        }
        if let cached = javaSemanticTokenCacheByFile[fileURL], cached.text == text {
            javaSemanticTokens = cached.tokens
            return
        }
        javaSemanticTokens = []
        javaSemanticTokensTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            let tokens = await javaLanguageProvider.semanticTokens(
                repositoryID: repositoryID,
                fileURL: fileURL,
                text: text
            )
            guard selectedFileURL == fileURL, documentText == text else { return }
            if tokens.isEmpty {
                javaSemanticTokenCacheByFile.removeValue(forKey: fileURL)
            } else {
                javaSemanticTokenCacheByFile[fileURL] = JavaSemanticTokenCacheEntry(
                    text: text,
                    tokens: tokens
                )
            }
            javaSemanticTokens = tokens
        }
    }

    private func clearJavaSemanticTokensForFileTransition() {
        javaSemanticTokensTask?.cancel()
        javaSemanticTokensTask = nil
        javaSemanticTokens = []
    }

    private func repositoryID(containing fileURL: URL) -> RegisteredRepository.ID? {
        let fileURL = fileURL.standardizedFileURL
        return repositories.compactMap { repository -> (RegisteredRepository.ID, Int)? in
            guard let repositoryURL = repositoryURL(for: repository)?.standardizedFileURL,
                  WorkspaceTreeRefreshPlanner.isSameOrDescendant(fileURL, of: repositoryURL) else {
                return nil
            }
            return (repository.id, repositoryURL.path.count)
        }.max { $0.1 < $1.1 }?.0
    }

    func resetFontSizes() {
        setSidebarFontSize(RepoDeskFontSize.default)
        setInterfaceFontSize(RepoDeskFontSize.default)
        setFileContentFontSize(RepoDeskFontSize.default)
    }

    func toggleDirectory(_ directoryURL: URL) {
        let directoryURL = directoryURL.standardizedFileURL
        if expandedDirectoryURLs.remove(directoryURL) == nil {
            expandedDirectoryURLs.insert(directoryURL)
            Task { await loadDirectoryChainForCurrentPresentation(startingAt: directoryURL) }
        }
    }

    func revealSelectedFileInTree() async {
        guard canRevealSelectedFileInTree,
              let selectedFileURL else { return }
        await revealFileTreeItem(selectedFileURL)
    }

    func revealFileTreeItem(_ itemURL: URL) async {
        guard let visibleWorkspaceRootURL else { return }
        let itemURL = itemURL.standardizedFileURL
        let rootURL = visibleWorkspaceRootURL.standardizedFileURL
        guard itemURL != rootURL,
              WorkspaceTreeRefreshPlanner.isSameOrDescendant(itemURL, of: rootURL) else { return }

        await loadDirectory(rootURL)
        for directoryURL in parentDirectories(of: itemURL, relativeTo: rootURL) {
            expandedDirectoryURLs.insert(directoryURL)
            await loadDirectory(directoryURL)
        }
        fileTreeRevealRequest = FileTreeRevealRequest(fileURL: itemURL)
    }

    func selectFile(_ fileURL: URL, line: Int? = nil) {
        let range = line.map { line in
            let position = JavaSourcePosition(line: max(0, line - 1), character: 0)
            return JavaSourceRange(start: position, end: position)
        }
        navigateToFile(fileURL, range: range, recordsHistory: true)
    }

    func selectFile(_ fileURL: URL, range: JavaSourceRange) {
        navigateToFile(fileURL, range: range, recordsHistory: true)
    }

    private func navigateToFile(
        _ fileURL: URL,
        range requestedRange: JavaSourceRange?,
        recordsHistory: Bool,
        historyOrigin: JavaNavigationHistoryEntry? = nil
    ) {
        let fileURL = fileURL.standardizedFileURL
        let destinationRange = requestedRange ?? navigationRange(for: fileURL)
        let destination = JavaNavigationHistoryEntry(fileURL: fileURL, range: destinationRange)
        let current = historyOrigin ?? currentNavigationLocation()
        if recordsHistory, current != destination {
            if let current {
                Self.appendNavigationLocation(current, to: &fileNavigationBackStack)
            }
            fileNavigationForwardStack = []
        }

        if let repositoryID = repositoryID(containing: fileURL) {
            if navigationContext != .repository(repositoryID) {
                selectRepositoryContext(repositoryID)
            }
        } else if let workspaceURL,
                  !isWorkspaceContext,
                  Self.isSameOrDescendant(fileURL, of: workspaceURL) {
            selectWorkspaceContext()
        }

        currentFileNavigationLocation = destination
        if fileURL != selectedFileURL {
            clearJavaSemanticTokensForFileTransition()
        }
        if fileURL.pathExtension.lowercased() == "java",
           let repositoryID = repositoryID(containing: fileURL) {
            Task { await javaLanguageProvider.prioritize(repositoryID: repositoryID) }
        } else {
            clearJavaSemanticTokensForFileTransition()
        }
        let targetLine = requestedRange.map { max(1, $0.start.line + 1) }
        if fileURL == selectedFileURL {
            if let targetLine {
                rememberSelectedFileVisibleLine(targetLine)
                currentFileNavigationLocation = destination
                selectedSourceNavigationRequest = NativeTextNavigationRequest(range: destinationRange)
            }
            return
        }
        syncActiveFileTab()
        if let existingIndex = openFileTabs.firstIndex(where: { $0.url == fileURL }) {
            if let targetLine {
                openFileTabs[existingIndex].visibleLine = targetLine
            }
            activateFileTab(openFileTabs[existingIndex])
            if requestedRange != nil {
                selectedSourceNavigationRequest = NativeTextNavigationRequest(range: destinationRange)
            }
            return
        }
        openFileTabs.append(
            OpenFileTab(
                url: fileURL,
                loadedDocument: nil,
                text: "",
                originalText: "",
                fingerprint: fileFingerprint(fileURL),
                showsMarkdownPreview: fileURL.pathExtension.lowercased() == "md" && opensMarkdownInPreview,
                isLoading: true,
                visibleLine: targetLine ?? 1
            )
        )
        trimOpenFileTabsIfNeeded()
        selectedSourceNavigationRequest = NativeTextNavigationRequest(range: destinationRange)
        loadFile(fileURL)
    }

    private func navigationRange(for fileURL: URL) -> JavaSourceRange {
        if fileURL == selectedFileURL, let current = currentNavigationLocation() {
            return current.range
        }
        let line = max(0, (openFileTabs.first { $0.url == fileURL }?.visibleLine ?? 1) - 1)
        let position = JavaSourcePosition(line: line, character: 0)
        return JavaSourceRange(start: position, end: position)
    }

    func selectFileTab(_ tab: OpenFileTab) {
        guard openFileTabs.contains(where: { $0.id == tab.id }) else { return }
        guard tab.url != selectedFileURL else { return }
        selectFile(tab.url)
    }

    func closeSelectedFileTab() {
        guard let selectedFileURL else { return }
        closeFileTab(id: selectedFileURL)
    }

    func closeAllFileTabs() {
        openFileTabs = []
        selectedFileURL = nil
        currentFileNavigationLocation = nil
        loadedDocument = nil
        resetDocumentEditingState()
        persistWindowState()
    }

    func closeOtherFileTabs(keeping id: URL) {
        guard let targetIndex = openFileTabs.firstIndex(where: { $0.id == id }) else { return }
        syncActiveFileTab()
        let targetTab = openFileTabs[targetIndex]
        openFileTabs = [targetTab]
        trimJavaSemanticTokenCacheToOpenTabs()
        if selectedFileURL != targetTab.url {
            activateFileTab(targetTab)
        } else {
            persistWindowState()
        }
    }

    func closeFileTabs(at itemURL: URL) {
        let itemURL = itemURL.standardizedFileURL
        syncActiveFileTab()
        openFileTabs.removeAll {
            $0.url == itemURL || WorkspaceTreeRefreshPlanner.isSameOrDescendant($0.url, of: itemURL)
        }
        trimJavaSemanticTokenCacheToOpenTabs()
        guard let selectedFileURL else {
            persistWindowState()
            return
        }
        if openFileTabs.contains(where: { $0.url == selectedFileURL }) {
            persistWindowState()
        } else if let replacement = openFileTabs.last {
            activateFileTab(replacement)
        } else {
            self.selectedFileURL = nil
            currentFileNavigationLocation = nil
            loadedDocument = nil
            resetDocumentEditingState()
            persistWindowState()
        }
    }

    func closeFileTab(id: URL) {
        guard let index = openFileTabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedFileURL == id
        openFileTabs.remove(at: index)
        trimJavaSemanticTokenCacheToOpenTabs()
        guard wasSelected else {
            persistWindowState()
            return
        }
        if let nextTab = openFileTabs.last {
            activateFileTab(nextTab)
        } else {
            selectedFileURL = nil
            currentFileNavigationLocation = nil
            loadedDocument = nil
            resetDocumentEditingState()
            persistWindowState()
        }
    }

    func requestReloadSelectedFile() {
        guard let selectedFileURL else { return }
        if hasUnsavedDocumentChanges {
            showsDiscardAndReloadConfirmation = true
        } else {
            loadFile(selectedFileURL, preservesMarkdownPreview: true)
        }
    }

    func discardChangesAndReload() {
        showsDiscardAndReloadConfirmation = false
        guard let selectedFileURL else { return }
        loadFile(selectedFileURL, preservesMarkdownPreview: true)
    }

    func saveSelectedDocument(allowsOverwrite: Bool = false) async {
        guard let selectedFileURL,
              case .text(let document) = loadedDocument,
              !document.isLarge,
              !isSavingDocument else { return }

        let savedText = documentText
        isSavingDocument = true
        documentSaveErrorMessage = nil
        defer { isSavingDocument = false }
        do {
            let revision = try await documentSaver.save(
                DocumentSaveRequest(
                    fileURL: selectedFileURL,
                    text: savedText,
                    encoding: document.encoding,
                    expectedRevision: document.revision,
                    allowsOverwrite: allowsOverwrite
                )
            )
            loadedDocument = .text(
                LoadedTextDocument(
                    text: savedText,
                    isLarge: false,
                    encoding: document.encoding,
                    revision: revision
                )
            )
            documentOriginalText = savedText
            selectedFileFingerprint = fileFingerprint(selectedFileURL)
            syncActiveFileTab()
            hasDocumentConflict = false
            lastDocumentSavedAt = .now
        } catch DocumentSaveError.changedOnDisk {
            hasDocumentConflict = true
        } catch {
            documentSaveErrorMessage = error.localizedDescription
        }
    }

    func updateSelectedDocumentText(_ text: String) {
        guard text != documentText else { return }
        documentText = text
        if let selectedFileURL {
            javaSemanticTokenCacheByFile.removeValue(forKey: selectedFileURL.standardizedFileURL)
        }
        syncActiveFileTab()
        scheduleDocumentAutoSave()
        scheduleJavaSemanticTokens()
    }

    func rememberSelectedFileVisibleLine(_ line: Int) {
        guard let selectedFileURL,
              let index = openFileTabs.firstIndex(where: { $0.url == selectedFileURL }) else { return }
        let line = max(1, line)
        let position = JavaSourcePosition(line: line - 1, character: 0)
        currentFileNavigationLocation = JavaNavigationHistoryEntry(
            fileURL: selectedFileURL,
            range: JavaSourceRange(start: position, end: position)
        )
        guard openFileTabs[index].visibleLine != line else { return }
        openFileTabs[index].visibleLine = line
        scheduleWindowStatePersistence()
    }

    var selectedFileVisibleLine: Int {
        guard let selectedFileURL else { return 1 }
        return openFileTabs.first { $0.url == selectedFileURL }?.visibleLine ?? 1
    }

    func clearSelectedSourceNavigationRequest(_ id: UUID) {
        guard selectedSourceNavigationRequest?.id == id else { return }
        selectedSourceNavigationRequest = nil
    }

    private func loadFile(_ fileURL: URL, preservesMarkdownPreview: Bool = false) {
        clearJavaSemanticTokensForFileTransition()
        let previewWasVisible = showsMarkdownPreview
        if selectedSourceNavigationRequest == nil,
           let tab = openFileTabs.first(where: { $0.url == fileURL }) {
            selectedSourceNavigationRequest = NativeTextNavigationRequest(line: tab.visibleLine)
        }
        selectedFileURL = fileURL
        selectedFileFingerprint = fileFingerprint(fileURL)
        showsMarkdownPreview = fileURL.pathExtension.lowercased() == "md"
            && (preservesMarkdownPreview ? previewWasVisible : opensMarkdownInPreview)
        showsDiscardAndReloadConfirmation = false
        hasDocumentConflict = false
        documentSaveErrorMessage = nil
        lastDocumentSavedAt = nil
        isSavingDocument = documentAutoSaveRequestIDs[fileURL] != nil
        documentText = ""
        documentOriginalText = ""
        let requestID = UUID()
        documentRequestID = requestID
        isLoadingDocument = true
        loadedDocument = nil
        if let index = openFileTabs.firstIndex(where: { $0.url == fileURL }) {
            openFileTabs[index].isLoading = true
            openFileTabs[index].loadedDocument = nil
            openFileTabs[index].text = ""
            openFileTabs[index].originalText = ""
            openFileTabs[index].fingerprint = fileFingerprint(fileURL)
        }
        persistWindowState()

        Task { [weak self] in
            guard let self else { return }
            let document = await documentLoader.load(fileURL)
            guard documentRequestID == requestID else { return }
            loadedDocument = document
            if case .text(let textDocument) = document {
                documentText = textDocument.text
                documentOriginalText = textDocument.text
            }
            if preservesMarkdownPreview {
                showsMarkdownPreview = previewWasVisible
            }
            syncActiveFileTab()
            documentRequestID = nil
            isLoadingDocument = false
            scheduleJavaSemanticTokens(after: nil)
        }
    }

    private func activateFileTab(_ tab: OpenFileTab) {
        clearJavaSemanticTokensForFileTransition()
        selectedFileURL = tab.url
        if currentFileNavigationLocation?.fileURL != tab.url {
            let position = JavaSourcePosition(line: max(0, tab.visibleLine - 1), character: 0)
            currentFileNavigationLocation = JavaNavigationHistoryEntry(
                fileURL: tab.url,
                range: JavaSourceRange(start: position, end: position)
            )
        }
        selectedFileFingerprint = tab.fingerprint
        loadedDocument = tab.loadedDocument
        documentText = tab.text
        documentOriginalText = tab.originalText
        showsMarkdownPreview = tab.showsMarkdownPreview
        isLoadingDocument = tab.isLoading
        showsDiscardAndReloadConfirmation = false
        hasDocumentConflict = false
        documentSaveErrorMessage = nil
        lastDocumentSavedAt = nil
        isSavingDocument = documentAutoSaveRequestIDs[tab.url] != nil
        documentRequestID = nil
        selectedSourceNavigationRequest = NativeTextNavigationRequest(line: tab.visibleLine)
        if tab.loadedDocument == nil && !tab.isLoading {
            loadFile(tab.url, preservesMarkdownPreview: true)
        } else {
            scheduleJavaSemanticTokens(after: nil)
        }
        persistWindowState()
    }

    private func syncActiveFileTab() {
        guard let selectedFileURL,
              let index = openFileTabs.firstIndex(where: { $0.url == selectedFileURL }) else { return }
        openFileTabs[index].loadedDocument = loadedDocument
        openFileTabs[index].text = documentText
        openFileTabs[index].originalText = documentOriginalText
        openFileTabs[index].fingerprint = selectedFileFingerprint
        openFileTabs[index].showsMarkdownPreview = showsMarkdownPreview
        openFileTabs[index].isLoading = isLoadingDocument
    }

    private func trimOpenFileTabsIfNeeded() {
        while openFileTabs.count > maximumOpenFileTabs {
            openFileTabs.removeFirst()
        }
        trimJavaSemanticTokenCacheToOpenTabs()
        if let selectedFileURL,
           !openFileTabs.contains(where: { $0.url == selectedFileURL }) {
            if let replacement = openFileTabs.last {
                activateFileTab(replacement)
            } else {
                self.selectedFileURL = nil
                currentFileNavigationLocation = nil
                loadedDocument = nil
                resetDocumentEditingState()
            }
        }
    }

    private func trimJavaSemanticTokenCacheToOpenTabs() {
        let openURLs = Set(openFileTabs.map { $0.url.standardizedFileURL })
        javaSemanticTokenCacheByFile = javaSemanticTokenCacheByFile.filter {
            openURLs.contains($0.key)
        }
    }

    private func scheduleDocumentAutoSave() {
        guard let fileURL = selectedFileURL,
              case .text(let document) = loadedDocument,
              !document.isLarge else { return }
        documentAutoSaveTasks[fileURL]?.cancel()
        let requestID = UUID()
        documentAutoSaveRequestIDs[fileURL] = requestID
        let text = documentText
        let request = DocumentSaveRequest(
            fileURL: fileURL,
            text: text,
            encoding: document.encoding,
            expectedRevision: document.revision,
            allowsOverwrite: false
        )
        isSavingDocument = true
        documentAutoSaveTasks[fileURL] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                guard let self else { return }
                guard self.documentAutoSaveRequestIDs[fileURL] == requestID else { return }
                self.documentAutoSaveRequestIDs[fileURL] = nil
                self.documentAutoSaveTasks[fileURL] = nil
                if self.selectedFileURL == fileURL { self.isSavingDocument = false }
                return
            }
            guard let self else { return }
            do {
                let revision = try await self.documentSaver.save(request)
                guard self.documentAutoSaveRequestIDs[fileURL] == requestID else { return }
                self.documentAutoSaveRequestIDs[fileURL] = nil
                self.documentAutoSaveTasks[fileURL] = nil
                guard let index = self.openFileTabs.firstIndex(where: { $0.url == fileURL }) else { return }
                self.openFileTabs[index].loadedDocument = .text(
                    LoadedTextDocument(
                        text: text,
                        isLarge: false,
                        encoding: document.encoding,
                        revision: revision
                    )
                )
                self.openFileTabs[index].text = text
                self.openFileTabs[index].originalText = text
                self.openFileTabs[index].fingerprint = self.fileFingerprint(fileURL)
                self.openFileTabs[index].isLoading = false
                if self.selectedFileURL == fileURL {
                    self.loadedDocument = self.openFileTabs[index].loadedDocument
                    self.documentOriginalText = text
                    self.selectedFileFingerprint = self.openFileTabs[index].fingerprint
                    self.isSavingDocument = false
                }
            } catch {
                guard self.documentAutoSaveRequestIDs[fileURL] == requestID else { return }
                self.documentAutoSaveRequestIDs[fileURL] = nil
                self.documentAutoSaveTasks[fileURL] = nil
                if self.selectedFileURL == fileURL {
                    self.isSavingDocument = false
                    self.documentSaveErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func toggleMarkdownPreview() {
        setMarkdownPreview(!showsMarkdownPreview)
    }

    func setMarkdownPreview(_ showsPreview: Bool) {
        guard showsMarkdownPreview != showsPreview else { return }
        if !showsPreview {
            selectedSourceNavigationRequest = NativeTextNavigationRequest(
                line: selectedFileVisibleLine
            )
        }
        showsMarkdownPreview = showsPreview
        syncActiveFileTab()
        persistWindowState()
    }

    private func reloadSelectedFileIfChanged(force: Bool = false) {
        guard let selectedFileURL else { return }
        let fingerprint = fileFingerprint(selectedFileURL)
        if hasUnsavedDocumentChanges {
            guard fingerprint != selectedFileFingerprint else { return }
            hasDocumentConflict = true
            selectedFileFingerprint = fingerprint
        } else {
            guard force || fingerprint != selectedFileFingerprint else { return }
            loadFile(selectedFileURL, preservesMarkdownPreview: true)
        }
    }

    private func applyWorkspaceChanges(
        _ batch: WorkspaceChangeBatch,
        workspaceURL: URL,
        traceID: String?
    ) async {
        if let monitoringError = batch.monitoringError {
            workspaceMonitoringErrorMessage = monitoringError
            await diagnosticLogger.record(
                "workspace-monitor error=\(monitoringError)"
            )
            return
        }
        workspaceMonitoringErrorMessage = nil
        clearJavaNavigationCaches(changedFileURLs: batch.requiresFullRescan ? nil : Array(batch.changedURLs))
        await refreshLoadedDirectories(for: batch, workspaceURL: workspaceURL)
        if let traceID {
            await diagnosticLogger.record(
                "workspace-batch directories-complete id=\(traceID)"
            )
        }
        reloadSelectedFileIfChanged()
        await javaLanguageProvider.notifyFilesChanged(Array(batch.changedURLs))

        let changeScope = WorkspaceChangeScope(batch)
        markMavenProjectRevisions(for: changeScope)

        let affectedRepositories = repositories.filter { repository in
            repositoryURL(for: repository).map {
                changeScope.affectsRepository(at: $0)
            } ?? false
        }
        if let traceID {
            await diagnosticLogger.record(
                "workspace-batch repositories id=\(traceID) count=\(affectedRepositories.count)"
            )
        }
        await refreshRepositories(affectedRepositories)
        if selectedSection == .history,
           let selectedRepositoryID,
           affectedRepositories.contains(where: { $0.id == selectedRepositoryID }) {
            await refreshHistory()
        }
    }

    private func refreshLoadedDirectories(
        for batch: WorkspaceChangeBatch,
        workspaceURL: URL
    ) async {
        let directories = WorkspaceTreeRefreshPlanner.directoriesToRefresh(
            for: batch,
            workspaceURL: workspaceURL,
            loadedDirectoryURLs: Set(fileChildren.keys).union(directoryLoadErrors.keys)
        )
        for directoryURL in directories {
            await loadDirectory(directoryURL, forceReload: true)
        }
        if compactsSingleChildDirectories {
            for directoryURL in directories where expandedDirectoryURLs.contains(directoryURL) {
                await loadCompactedDirectoryChain(startingAt: directoryURL)
            }
        }
    }

    private func markMavenProjectRevisions(for batch: WorkspaceChangeBatch) {
        markMavenProjectRevisions(for: WorkspaceChangeScope(batch))
    }

    private func markMavenProjectRevisions(for scope: WorkspaceChangeScope) {
        for repository in repositories {
            guard let repositoryURL = repositoryURL(for: repository),
                  MavenProjectRefreshPlanner.shouldRefresh(
                    for: scope,
                    repositoryURL: repositoryURL
                  ) else { continue }
            let key = repositoryURL.standardizedFileURL.path
            mavenProjectRevisions[key, default: 0] += 1
        }
    }

    private func prepareExpandedCompactDirectoryChains() {
        guard compactsSingleChildDirectories else { return }
        let expandedURLs = expandedDirectoryURLs
        Task {
            for directoryURL in expandedURLs {
                await loadCompactedDirectoryChain(startingAt: directoryURL)
            }
        }
    }

    private func loadDirectoryChainForCurrentPresentation(startingAt directoryURL: URL) async {
        if compactsSingleChildDirectories {
            await loadCompactedDirectoryChain(startingAt: directoryURL)
        } else {
            await loadDirectory(directoryURL)
        }
    }

    private func parentDirectories(of fileURL: URL, relativeTo rootURL: URL) -> [URL] {
        var directories: [URL] = []
        var directoryURL = fileURL.deletingLastPathComponent().standardizedFileURL
        while directoryURL != rootURL,
              WorkspaceTreeRefreshPlanner.isSameOrDescendant(directoryURL, of: rootURL) {
            directories.append(directoryURL)
            directoryURL = directoryURL.deletingLastPathComponent().standardizedFileURL
        }
        return directories.reversed()
    }

    private func loadCompactedDirectoryChain(startingAt directoryURL: URL) async {
        var currentURL = directoryURL.standardizedFileURL
        for _ in 0..<32 {
            await loadDirectory(currentURL)
            guard compactsSingleChildDirectories,
                  expandedDirectoryURLs.contains(directoryURL.standardizedFileURL),
                  directoryLoadErrors[currentURL] == nil,
                  let children = fileChildren[currentURL] else { return }
            let visibleChildren = showsHiddenFiles
                ? children
                : children.filter { !$0.name.hasPrefix(".") }
            guard visibleChildren.count == 1,
                  let child = visibleChildren.first,
                  child.isDirectory else { return }
            currentURL = child.url.standardizedFileURL
        }
    }

    private func replaceChildren(_ children: [WorkspaceFileEntry], of directoryURL: URL) {
        let oldDirectoryURLs = Set(
            (fileChildren[directoryURL] ?? [])
                .filter(\.isDirectory)
                .map { $0.url.standardizedFileURL }
        )
        let newDirectoryURLs = Set(
            children
                .filter(\.isDirectory)
                .map { $0.url.standardizedFileURL }
        )
        fileChildren[directoryURL] = children

        for removedDirectoryURL in oldDirectoryURLs.subtracting(newDirectoryURLs) {
            let cachedDescendants = fileChildren.keys.filter {
                WorkspaceTreeRefreshPlanner.isSameOrDescendant($0, of: removedDirectoryURL)
            }
            for cachedURL in cachedDescendants {
                fileChildren[cachedURL] = nil
                directoryLoadErrors[cachedURL] = nil
                expandedDirectoryURLs.remove(cachedURL)
            }
        }
    }

    func searchFiles(query: String) {
        guard let searchRootURL = visibleWorkspaceRootURL else { return }
        let requestID = UUID()
        fileSearchRequestID = requestID
        if query.isEmpty {
            fileSearchResults = []
            isSearchingFiles = false
            return
        }
        fileSearchResults = []
        isSearchingFiles = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard fileSearchRequestID == requestID else { return }
            let results = await workspaceFileSearch.search(in: searchRootURL, query: query, limit: 100)
            guard fileSearchRequestID == requestID else { return }
            fileSearchResults = results
            isSearchingFiles = false
        }
    }

    func searchWorkspaceText(query: String) {
        guard let searchRootURL = visibleWorkspaceRootURL else { return }
        let requestID = UUID()
        textSearchRequestID = requestID
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textSearchResults = []
            isSearchingText = false
            return
        }
        textSearchResults = []
        isSearchingText = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard textSearchRequestID == requestID else { return }
            let results = await workspaceTextSearch.search(in: searchRootURL, query: query, limit: 300)
            guard textSearchRequestID == requestID else { return }
            textSearchResults = results
            isSearchingText = false
        }
    }

    func refreshHistory() async {
        await loadBranches()
        await loadHistoryAuthors()
        await loadHistory()
    }

    func loadBranches() async {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository) else { return }
        let repositoryID = repository.id
        let requestID = UUID()
        branchesRequestID = requestID
        isLoadingBranches = true
        branchesErrorMessage = nil

        do {
            let loadedBranches = try await gitRepositoryReader.branches(repositoryURL: repositoryURL)
            guard branchesRequestID == requestID,
                  selectedRepositoryID == repositoryID else { return }
            branches = loadedBranches
            if case .branch(let name) = historyBranchFilter,
               !branches.contains(where: { $0.name == name }) {
                historyBranchFilter = .current
                rememberedHistoryBranchFilters[repositoryID] = .current
            }
        } catch {
            guard branchesRequestID == requestID,
                  selectedRepositoryID == repositoryID else { return }
            branches = []
            branchesErrorMessage = error.localizedDescription
        }
        guard branchesRequestID == requestID else { return }
        branchesRequestID = nil
        isLoadingBranches = false
    }

    func loadStashes() async {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository) else { return }
        let repositoryID = repository.id
        do {
            let loadedStashes = try await gitRepositoryOperator.listStashes(repositoryURL: repositoryURL)
            guard selectedRepositoryID == repositoryID else { return }
            gitStashes = loadedStashes
            stashesErrorMessage = nil
        } catch {
            guard selectedRepositoryID == repositoryID else { return }
            gitStashes = []
            stashesErrorMessage = error.localizedDescription
        }
    }

    func loadHistoryAuthors() async {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository) else { return }
        let repositoryID = repository.id
        let requestID = UUID()
        historyAuthorsRequestID = requestID
        isLoadingHistoryAuthors = true
        historyAuthorsErrorMessage = nil
        historyCurrentUserName = nil
        historyCurrentUserErrorMessage = nil

        do {
            let loadedAuthors = try await gitRepositoryReader.authors(repositoryURL: repositoryURL)
            guard historyAuthorsRequestID == requestID,
                  selectedRepositoryID == repositoryID else { return }
            historyAuthors = loadedAuthors
            if case .author(let author) = historyAuthorFilter,
               !historyAuthors.contains(author) {
                historyAuthorFilter = .all
                if selectedRepositoryID == repositoryID {
                    rememberedHistoryAuthorFilters[repositoryID] = nil
                }
            }
        } catch {
            guard historyAuthorsRequestID == requestID,
                  selectedRepositoryID == repositoryID else { return }
            historyAuthors = []
            historyAuthorsErrorMessage = error.localizedDescription
        }

        do {
            let userName = try await gitRepositoryReader.currentUserName(repositoryURL: repositoryURL)
            guard historyAuthorsRequestID == requestID,
                  selectedRepositoryID == repositoryID else { return }
            historyCurrentUserName = userName
            if userName == nil {
                historyCurrentUserErrorMessage = "当前 Repository 未配置 Git user.name。"
            }
        } catch {
            guard historyAuthorsRequestID == requestID,
                  selectedRepositoryID == repositoryID else { return }
            historyCurrentUserErrorMessage = error.localizedDescription
        }

        guard historyAuthorsRequestID == requestID else { return }
        historyAuthorsRequestID = nil
        isLoadingHistoryAuthors = false
    }

    func loadHistory(reset: Bool = true) async {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository) else { return }
        let repositoryID = repository.id
        let requestID = UUID()
        historyRequestID = requestID
        isLoadingHistory = true
        historyErrorMessage = nil
        let skip = reset ? 0 : commitHistory.count
        let author = resolvedHistoryAuthorName
        let hashPrefix = normalizedHistoryHashQuery

        if historyAuthorFilter == .me, author == nil {
            if reset {
                commitHistory = []
                selectedCommitHash = nil
                selectedCommitDetail = nil
                selectedCommitFile = nil
                historyBlame.reset()
                commitFileDiff = nil
                mergeCommitFileDiff = nil
            }
            hasMoreHistory = false
            historyRequestID = nil
            isLoadingHistory = false
            return
        }

        do {
            let history: [GitCommitSummary]
            if !hashPrefix.isEmpty {
                history = try await gitRepositoryReader.searchHistory(
                    repositoryURL: repositoryURL,
                    hashPrefix: hashPrefix,
                    path: historyFileRepositoryID == repositoryID ? historyFilePath : nil,
                    limit: 50,
                    skip: skip,
                    revision: historyRevision,
                    author: author
                )
            } else if let historyFilePath,
               historyFileRepositoryID == repositoryID {
                history = try await gitRepositoryReader.fileHistory(
                    repositoryURL: repositoryURL,
                    path: historyFilePath,
                    limit: 50,
                    skip: skip,
                    revision: historyRevision,
                    author: author
                )
            } else {
                history = try await gitRepositoryReader.history(
                    repositoryURL: repositoryURL,
                    limit: 50,
                    skip: skip,
                    revision: historyRevision,
                    author: author
                )
            }
            guard historyRequestID == requestID else { return }
            if reset {
                commitHistory = history
            } else {
                let existingHashes = Set(commitHistory.map(\.hash))
                commitHistory.append(contentsOf: history.filter { !existingHashes.contains($0.hash) })
            }
            hasMoreHistory = history.count == 50
            if reset {
                let rememberedHash = selectedRepositoryID.flatMap { rememberedCommitHashes[$0] }
                let preferredHash = rememberedHash ?? selectedCommitHash
                let targetHash = preferredHash.flatMap { preferredHash in
                    history.contains(where: { $0.hash == preferredHash }) ? preferredHash : nil
                } ?? history.first?.hash
                if let targetHash {
                    let hasVisibleDetail = selectedCommitHash == targetHash
                        && selectedCommitDetail?.summary.hash == targetHash
                    if hasVisibleDetail {
                        let containingBranches = try await gitRepositoryReader.containingBranches(
                            repositoryURL: repositoryURL,
                            hash: targetHash
                        )
                        guard historyRequestID == requestID else { return }
                        if selectedCommitHash == targetHash,
                           let refreshedSummary = history.first(where: { $0.hash == targetHash }),
                           let selectedCommitDetail,
                           selectedCommitDetail.summary.hash == targetHash {
                            self.selectedCommitDetail = GitCommitDetail(
                                summary: refreshedSummary,
                                files: selectedCommitDetail.files,
                                parentHashes: selectedCommitDetail.parentHashes,
                                containingBranches: containingBranches
                            )
                        }
                    } else if selectedCommitHash != targetHash || !isLoadingCommit {
                        selectCommit(targetHash)
                    }
                } else {
                    selectedCommitHash = nil
                    selectedCommitDetail = nil
                    selectedCommitFile = nil
                    historyBlame.reset()
                    commitFileDiff = nil
                    mergeCommitFileDiff = nil
                }
            }
        } catch {
            guard historyRequestID == requestID else { return }
            historyErrorMessage = error.localizedDescription
        }
        guard historyRequestID == requestID else { return }
        historyRequestID = nil
        isLoadingHistory = false
    }

    func selectCommit(_ hash: String) {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository) else { return }
        selectedCommitHash = hash
        historyBlame.reset()
        commitDiffRequestID = nil
        isLoadingCommitDiff = false
        commitDiffErrorMessage = nil
        commitErrorMessage = nil
        if let repositoryID = selectedRepositoryID {
            rememberedCommitHashes[repositoryID] = hash
            if rememberedCommitFileSelections[repositoryID]?.commitHash != hash {
                rememberedCommitFileSelections[repositoryID] = nil
            }
        }
        persistWindowState()
        let requestID = UUID()
        commitRequestID = requestID
        isLoadingCommit = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await gitRepositoryReader.commit(
                    repositoryURL: repositoryURL,
                    hash: hash
                )
                guard commitRequestID == requestID else { return }
                selectedCommitDetail = detail
                let rememberedFile: GitCommitFile? = selectedRepositoryID
                    .flatMap { self.rememberedCommitFileSelections[$0] }
                    .flatMap { (selection: HistoryCommitFileSelection) -> GitCommitFile? in
                        guard selection.commitHash == hash else { return nil }
                        return detail.files.first { $0.path == selection.path }
                    }
                selectedCommitFile = rememberedFile ?? preferredHistoryFile(in: detail) ?? detail.files.first
                if let repositoryID = selectedRepositoryID,
                   let selectedCommitFile {
                    rememberedCommitFileSelections[repositoryID] = HistoryCommitFileSelection(
                        commitHash: hash,
                        path: selectedCommitFile.path
                    )
                    persistWindowState()
                }
                commitFileDiff = nil
                mergeCommitFileDiff = nil
                if selectedCommitFile != nil {
                    isLoadingCommitDiff = true
                    Task { await self.loadSelectedCommitDiff() }
                } else {
                    commitDiffRequestID = nil
                    isLoadingCommitDiff = false
                }
            } catch {
                guard commitRequestID == requestID else { return }
                commitErrorMessage = error.localizedDescription
            }
            guard commitRequestID == requestID else { return }
            commitRequestID = nil
            isLoadingCommit = false
        }
    }

    func selectCommitFile(_ file: GitCommitFile, annotate: Bool = false) {
        guard selectedCommitDetail?.files.contains(file) == true else { return }
        selectedCommitFile = file
        commitDiffRequestID = nil
        historyBlame.reset()
        if let repositoryID = selectedRepositoryID,
           let commitHash = selectedCommitHash {
            rememberedCommitFileSelections[repositoryID] = HistoryCommitFileSelection(
                commitHash: commitHash,
                path: file.path
            )
            persistWindowState()
        }
        commitDiffErrorMessage = nil
        isLoadingCommitDiff = true
        let repositoryID = selectedRepositoryID
        let hash = selectedCommitHash
        Task {
            guard selectedRepositoryID == repositoryID,
                  selectedCommitHash == hash,
                  selectedCommitFile == file else { return }
            await loadSelectedCommitDiff(annotate: annotate)
        }
    }

    func annotateHistoryCommitFile(_ file: GitCommitFile) {
        guard !isLoadingCommit, !isLoadingCommitDiff else { return }
        if selectedCommitFile == file, isHistoryBlameCurrent {
            historyBlame.toggleAll(using: gitRepositoryReader)
        } else {
            selectCommitFile(file, annotate: true)
        }
    }

    var isHistoryBlameCurrent: Bool {
        guard let repository = selectedRepository,
              let context = historyBlame.context else { return false }
        return context.repositoryURL == repositoryURL(for: repository)
            && context.commitHash == selectedCommitHash
            && context.path == selectedCommitFile?.path
            && !isLoadingCommit && !isLoadingCommitDiff
            && commitDiffErrorMessage == nil
    }

    func toggleHistoryBlame(_ side: GitHistoryBlameSide) {
        guard isHistoryBlameCurrent else { return }
        historyBlame.toggle(side, using: gitRepositoryReader)
    }

    private func preferredHistoryFile(in detail: GitCommitDetail) -> GitCommitFile? {
        guard let historyFilePath,
              historyFileRepositoryID == selectedRepositoryID else { return nil }
        return detail.files.first {
            $0.path == historyFilePath || $0.originalPath == historyFilePath
        } ?? (detail.files.count == 1 ? detail.files.first : nil)
    }

    func loadSelectedCommitDiff(annotate: Bool = false) async {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository),
              let hash = selectedCommitHash,
              let detail = selectedCommitDetail,
              detail.summary.hash == hash,
              let file = selectedCommitFile else {
            commitFileDiff = nil
            mergeCommitFileDiff = nil
            historyBlame.reset()
            return
        }
        let requestID = UUID()
        commitDiffRequestID = requestID
        isLoadingCommitDiff = true
        commitDiffErrorMessage = nil
        if (file.path as NSString).pathExtension.lowercased() == "jar" {
            commitFileDiff = nil
            mergeCommitFileDiff = nil
            historyBlame.reset()
            isLoadingCommitDiff = false
            return
        }
        do {
            if detail.isTwoParentMerge {
                let diff = try await gitRepositoryReader.mergeFileDiff(
                    repositoryURL: repositoryURL,
                    hash: hash,
                    parentHashes: detail.parentHashes,
                    file: file,
                    ignoringWhitespace: ignoresWhitespaceInDiff
                )
                guard commitDiffRequestID == requestID else { return }
                mergeCommitFileDiff = diff
                commitFileDiff = nil
                historyBlame.configure(HistoryGitBlameContext(
                    repositoryURL: repositoryURL,
                    detail: detail,
                    diff: diff.target,
                    source: diff.source
                ))
            } else if detail.parentHashes.count > 2 {
                throw GitRepositoryError.unsupportedMergeParentCount(detail.parentHashes.count)
            } else {
                let diff = try await gitRepositoryReader.fileDiff(
                    repositoryURL: repositoryURL,
                    target: .commit(hash: hash, file: file),
                    ignoringWhitespace: ignoresWhitespaceInDiff
                )
                guard commitDiffRequestID == requestID else { return }
                commitFileDiff = diff
                mergeCommitFileDiff = nil
                historyBlame.configure(HistoryGitBlameContext(
                    repositoryURL: repositoryURL,
                    detail: detail,
                    diff: diff
                ))
            }
        } catch {
            guard commitDiffRequestID == requestID else { return }
            commitDiffErrorMessage = error.localizedDescription
        }
        guard commitDiffRequestID == requestID else { return }
        commitDiffRequestID = nil
        isLoadingCommitDiff = false
        if annotate, isHistoryBlameCurrent {
            historyBlame.toggleAll(using: gitRepositoryReader)
        }
    }

    func jumpToSource(
        repositoryID: RegisteredRepository.ID,
        path: String,
        line: Int?
    ) {
        guard let repository = repositories.first(where: { $0.id == repositoryID }),
              let repositoryURL = repositoryURL(for: repository) else {
            jumpToSourceErrorMessage = "无法定位 Repository。"
            return
        }
        let fileURL = repositoryURL.appendingPathComponent(path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            jumpToSourceErrorMessage = "文件不存在或已删除：\(path)"
            return
        }
        selectFile(fileURL, line: line)
        selectSection(.files)
    }

    func selectHistoryBranchFilter(_ filter: GitHistoryBranchFilter) {
        historyBranchFilter = filter
        if let repositoryID = selectedRepositoryID {
            rememberedHistoryBranchFilters[repositoryID] = filter
            rememberedCommitHashes[repositoryID] = nil
        }
        resetHistorySelectionAndReload()
    }

    func setHistoryHashQuery(_ query: String) {
        let previousQuery = normalizedHistoryHashQuery
        historyHashQuery = query
        guard normalizedHistoryHashQuery != previousQuery else { return }
        resetHistorySelectionAndReload(debounce: !normalizedHistoryHashQuery.isEmpty)
    }

    func selectHistoryAuthorFilter(_ filter: GitHistoryAuthorFilter) {
        historyAuthorFilter = filter
        if let repositoryID = selectedRepositoryID {
            rememberedHistoryAuthorFilters[repositoryID] = filter == .all ? nil : filter
            rememberedCommitHashes[repositoryID] = nil
        }
        resetHistorySelectionAndReload()
    }

    private var resolvedHistoryAuthorName: String? {
        switch historyAuthorFilter {
        case .all:
            nil
        case .me:
            historyCurrentUserName
        case .author(let author):
            author
        }
    }

    private var historyRevision: String? {
        switch historyBranchFilter {
        case .current: nil
        case .all: "--all"
        case .branch(let name): name
        }
    }

    private func resetHistoryHashSearch() {
        historyReloadTask?.cancel()
        historyReloadTask = nil
        historyRequestID = nil
        commitRequestID = nil
        commitDiffRequestID = nil
        historyHashQuery = ""
        isLoadingHistory = false
        isLoadingCommit = false
        isLoadingCommitDiff = false
        hasMoreHistory = true
    }

    private func resetHistorySelectionAndReload(debounce: Bool = false) {
        historyReloadTask?.cancel()
        historyRequestID = nil
        commitRequestID = nil
        commitDiffRequestID = nil
        isLoadingCommit = false
        isLoadingCommitDiff = false
        isLoadingHistory = true
        hasMoreHistory = false
        commitHistory = []
        selectedCommitHash = nil
        selectedCommitDetail = nil
        selectedCommitFile = nil
        historyBlame.reset()
        commitFileDiff = nil
        mergeCommitFileDiff = nil
        if let repositoryID = selectedRepositoryID {
            rememberedCommitFileSelections[repositoryID] = nil
        }
        historyErrorMessage = nil
        commitErrorMessage = nil
        commitDiffErrorMessage = nil
        persistWindowState()
        historyReloadTask = Task { [weak self] in
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            await self.loadHistory()
        }
    }

    func loadTaskCatalog() {
        guard let workspaceURL = workspaceURL else { return }
        taskCatalog = taskStore.catalog(
            workspaceURL: workspaceURL,
            repositoryURL: selectedRepository.flatMap(repositoryURL(for:))
        )
        if !taskCatalog.effectiveTasks.contains(where: { $0.id == selectedTaskID }) {
            selectedTaskID = taskCatalog.effectiveTasks.first?.id
        }
        resolveSelectedTask()
    }

    func selectTask(_ id: RepoTaskDefinition.ID) {
        selectedTaskID = id
        resolveSelectedTask()
    }

    func saveTask(_ task: RepoTaskDefinition, scope: RepoTaskScope) {
        guard let workspaceURL else { return }
        taskStore.save(
            task,
            scope: scope,
            workspaceURL: workspaceURL,
            repositoryURL: selectedRepository.flatMap(repositoryURL(for:))
        )
        selectedTaskID = task.id
        loadTaskCatalog()
    }

    func removeTask(_ id: String, scope: RepoTaskScope) {
        guard let workspaceURL else { return }
        taskStore.remove(
            taskID: id,
            scope: scope,
            workspaceURL: workspaceURL,
            repositoryURL: selectedRepository.flatMap(repositoryURL(for:))
        )
        loadTaskCatalog()
    }

    func runSelectedTask() {
        guard runningTaskID == nil, !mavenQueue.hasRunningCommands else { return }
        resolveSelectedTask()
        guard let task = resolvedSelectedTask else { return }
        runningTaskID = task.definitionID
        taskLog = "$ \(([task.executableURL.path] + task.arguments).joined(separator: " "))\n\n"
        taskErrorMessage = nil
        lastTaskRunResult = nil
        let outputBuffer = StreamingTaskOutputBuffer()

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await taskRunner.run(task) { chunk in
                    guard outputBuffer.append(chunk.text) else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(32))
                        let pending = outputBuffer.take()
                        if !pending.isEmpty {
                            self?.taskLog.append(pending)
                        }
                    }
                }
                taskLog.append(outputBuffer.take())
                lastTaskRunResult = result
                let record = TaskRunRecord(
                    id: UUID(),
                    taskID: task.definitionID,
                    taskName: task.name,
                    terminationStatus: result.terminationStatus,
                    startedAt: result.startedAt,
                    finishedAt: result.finishedAt
                )
                taskStore.record(record)
                recentTaskRuns = taskStore.recentRuns()
                taskLog.append("\nProcess exited with status \(result.terminationStatus) in \(result.duration.formatted(.number.precision(.fractionLength(2))))s.\n")
            } catch {
                taskErrorMessage = error.localizedDescription
                taskLog.append("\nTask failed: \(error.localizedDescription)\n")
            }
            runningTaskID = nil
        }
    }

    func stopRunningTask() {
        Task { await taskRunner.stop() }
    }

    func clearTaskLog() {
        taskLog = ""
    }

    func updateMavenSettings(_ settings: MavenSettings) {
        let previousPolicy = mavenSettings.runHistoryPolicy
        let environmentChanged = mavenSettings.mavenHome != settings.mavenHome
            || mavenSettings.javaHome != settings.javaHome
        mavenSettings = settings
        guard let workspaceURL else { return }
        if environmentChanged {
            mavenEnvironmentValidationStore.invalidate(workspaceURL: workspaceURL)
            reloadJavaWorkspaceConfiguration()
        }
        do {
            try mavenSettingsStore.save(settings, for: workspaceURL)
            mavenSettingsErrorMessage = nil
        } catch {
            mavenSettingsErrorMessage = error.localizedDescription
        }
        if previousPolicy != settings.runHistoryPolicy {
            mavenRunHistoryStore.applyPolicy(settings.runHistoryPolicy, for: workspaceURL)
            persistedMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
        }
    }

    func mavenSelection(for repositoryID: RegisteredRepository.ID) -> MavenWindowSelection? {
        rememberedMavenSelections[repositoryID]
    }

    func updateMavenSelection(
        _ selection: MavenWindowSelection?,
        for repositoryID: RegisteredRepository.ID
    ) {
        guard repositories.contains(where: { $0.id == repositoryID }) else { return }
        if let selection {
            rememberedMavenSelections[repositoryID] = selection
        } else {
            rememberedMavenSelections[repositoryID] = nil
        }
        persistWindowState()
    }

    func mavenProjectRevision(for repositoryURL: URL?) -> Int {
        guard let repositoryURL else { return 0 }
        return mavenProjectRevisions[repositoryURL.standardizedFileURL.path, default: 0]
    }

    func runMaven(_ request: MavenRunRequest) {
        guard runningTaskID == nil, let workspaceURL else { return }
        let repositoryURL = request.command.workingDirectoryURL.standardizedFileURL
        mavenQueue.onFinish = { [weak self] record, workspaceURL in
            guard let self else { return }
            mavenRunHistoryStore.record(
                record,
                for: workspaceURL,
                policy: mavenSettings.runHistoryPolicy
            )
            persistedMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
            sessionMavenRuns[record.id] = record
            let retainedIDs = Set(persistedMavenRuns.map(\.id))
            sessionMavenRuns = sessionMavenRuns.filter { retainedIDs.contains($0.key) }
        }
        mavenQueue.submit(request, repositoryURL: repositoryURL, workspaceURL: workspaceURL)
    }

    func stopMaven() {
        guard let repositoryURL = activeRepositoryURL else { return }
        mavenQueue.stop(repositoryURL: repositoryURL)
    }

    func clearMavenLog() {
        guard let repositoryURL = activeRepositoryURL else { return }
        mavenQueue.clearLog(repositoryURL: repositoryURL)
    }

    func removeMavenRun(_ id: MavenRunRecord.ID) {
        if mavenQueue.activeRecords.contains(where: { $0.id == id }) {
            mavenQueue.remove(id)
            return
        }
        guard let workspaceURL else { return }
        sessionMavenRuns[id] = nil
        mavenRunHistoryStore.remove(runID: id, for: workspaceURL)
        persistedMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
    }

    func clearPersistedMavenLogs() {
        guard let workspaceURL else { return }
        sessionMavenRuns.removeAll()
        mavenRunHistoryStore.clearPersistedLogs(for: workspaceURL)
        persistedMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
    }

    func clearMavenRunHistory() {
        guard let workspaceURL else { return }
        sessionMavenRuns.removeAll()
        mavenRunHistoryStore.clearHistory(for: workspaceURL)
        persistedMavenRuns = []
    }

    private func resolveSelectedTask() {
        guard let definition = taskCatalog.effectiveTasks.first(where: { $0.id == selectedTaskID }),
              let workspaceURL else {
            resolvedSelectedTask = nil
            return
        }
        do {
            resolvedSelectedTask = try RepoTaskResolver.resolve(
                definition,
                context: TaskResolutionContext(
                    workspaceURL: workspaceURL,
                    repositoryURL: selectedRepository.flatMap(repositoryURL(for:)),
                    selectedFileURL: selectedFileURL,
                    userHomeURL: FileManager.default.homeDirectoryForCurrentUser,
                    processEnvironment: ProcessInfo.processInfo.environment
                )
            )
            taskErrorMessage = nil
        } catch {
            resolvedSelectedTask = nil
            taskErrorMessage = error.localizedDescription
        }
    }

    private func loadMavenSettings(for workspaceURL: URL) {
        mavenSettings = mavenSettingsStore.settings(for: workspaceURL)
        persistedMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
    }

    private func persistAppPreferences() {
        appPreferencesStore.save(
            AppPreferences(
                automaticallyRefreshesWorkspace: automaticallyRefreshesWorkspace,
                refreshesWhenBecomingActive: refreshesWhenBecomingActive,
                showsHiddenFiles: showsHiddenFiles,
                compactsSingleChildDirectories: compactsSingleChildDirectories,
                opensMarkdownInPreview: opensMarkdownInPreview,
                diffPresentation: diffPresentation,
                ignoresWhitespaceInDiff: ignoresWhitespaceInDiff,
                changesAutoExpansion: changesAutoExpansion,
                sidebarFontSize: sidebarFontSize,
                interfaceFontSize: interfaceFontSize,
                fileContentFontSize: fileContentFontSize,
                maximumOpenFileTabs: maximumOpenFileTabs,
                javaIndexSettings: javaIndexSettings,
                shortcuts: shortcuts
            )
        )
    }

    func removeRepository(_ id: RegisteredRepository.ID) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let removesActiveContext = navigationContext == .repository(id)
        if removesActiveContext {
            persistWindowState()
        }
        let removedRepositoryURL = repositoryURL(for: repositories[index])
        repositories.remove(at: index)
        if selectedRepositoryID == id {
            selectedRepositoryID = repositories.first?.id
        }
        if selectedChangeRepositoryID == id {
            selectedChangeRepositoryID = nil
            selectedChange = nil
            currentDiff = nil
        }
        if case .repository(let contextID) = navigationContext, contextID == id {
            navigationContext = .workspace
            selectedSection = .overview
            restoreFileTabsForCurrentContext()
        }
        persistRepositoryState()
        repositorySnapshots[id] = nil
        repositorySnapshotErrors[id] = nil
        refreshingRepositoryIDs.remove(id)
        rememberedChangeSelections[id] = nil
        rememberedHistoryBranchFilters[id] = nil
        rememberedHistoryAuthorFilters[id] = nil
        rememberedCommitHashes[id] = nil
        commitMessageDrafts[id] = nil
        if let removedRepositoryURL {
            mavenProjectRevisions[removedRepositoryURL.standardizedFileURL.path] = nil
        }
        persistWindowState()
        reloadJavaWorkspaceConfiguration()
    }

    func relocateRepository(_ id: RegisteredRepository.ID) {
        guard let workspaceURL = availableWorkspaceURL(),
              let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let existingRepository = repositories[index]
        guard let repositoryURL = repositoryPicker.chooseRepository(
            in: workspaceURL,
            purpose: .relocate(existingRepository.name)
        ) else { return }

        do {
            let relocatesActiveContext = navigationContext == .repository(id)
            if relocatesActiveContext {
                persistWindowState()
            }
            var relocatedRepository = try RepositoryRegistration.make(
                directoryURL: repositoryURL,
                workspaceURL: workspaceURL
            )
            if relocatedRepository.id != id,
               repositories.contains(where: { $0.id == relocatedRepository.id }) {
                throw RepositoryRegistrationError.alreadyRegistered(relocatedRepository.relativePath)
            }
            relocatedRepository.displayName = existingRepository.displayName
            relocatedRepository.isPinned = existingRepository.isPinned
            let previousRepositoryURL = self.repositoryURL(for: existingRepository)
            repositories[index] = relocatedRepository
            migrateRepositoryWindowState(
                from: id,
                to: relocatedRepository.id,
                previousRepositoryURL: previousRepositoryURL,
                relocatedRepositoryURL: repositoryURL
            )
            repositorySnapshots[id] = nil
            repositorySnapshotErrors[id] = nil
            refreshingRepositoryIDs.remove(id)
            if selectedRepositoryID == id {
                selectedRepositoryID = relocatedRepository.id
                historyBranchFilter = rememberedHistoryBranchFilters[relocatedRepository.id] ?? .current
                historyAuthorFilter = rememberedHistoryAuthorFilters[relocatedRepository.id] ?? .all
                selectedCommitHash = rememberedCommitHashes[relocatedRepository.id]
                loadTaskCatalog()
            }
            if selectedChangeRepositoryID == id {
                selectedChangeRepositoryID = relocatedRepository.id
            }
            if case .repository(let contextID) = navigationContext, contextID == id {
                navigationContext = .repository(relocatedRepository.id)
                restoreFileTabsForCurrentContext()
            }
            if let previousRepositoryURL {
                mavenProjectRevisions[previousRepositoryURL.standardizedFileURL.path] = nil
            }
            mavenProjectRevisions[repositoryURL.standardizedFileURL.path, default: 0] += 1
            persistRepositoryState()
            persistWindowState()
            reloadJavaWorkspaceConfiguration()
            Task { await refreshRepository(relocatedRepository) }
        } catch let error as RepositoryRegistrationError {
            presentedRepositoryError = error
        } catch {
            presentedRepositoryError = .directoryUnavailable(repositoryURL.path)
        }
    }

    func repositoryUnavailableMessage(for repository: RegisteredRepository) -> String? {
        guard let repositoryURL = repositoryURL(for: repository) else {
            return "The workspace directory is unavailable."
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "\(repository.relativePath) was moved, renamed, or removed."
        }
        guard FileManager.default.fileExists(
            atPath: repositoryURL.appendingPathComponent(".git").path
        ) else {
            return "\(repository.relativePath) is no longer a Git repository."
        }
        return nil
    }

    func toggleRepositoryPin(_ id: RegisteredRepository.ID) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        repositories[index].isPinned.toggle()
        normalizeRepositoryOrder()
        persistRepositoryState()
    }

    func renameRepository(_ id: RegisteredRepository.ID, displayName: String) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        repositories[index].displayName = trimmedName
        persistRepositoryState()
    }

    func moveRepository(_ id: RegisteredRepository.ID, by offset: Int) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard repositories.indices.contains(target),
              repositories[index].isPinned == repositories[target].isPinned else { return }
        repositories.swapAt(index, target)
        persistRepositoryState()
    }

    func canMoveRepository(_ id: RegisteredRepository.ID, by offset: Int) -> Bool {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        return repositories.indices.contains(target)
            && repositories[index].isPinned == repositories[target].isPinned
    }

    private func registerRepositories(_ newRepositories: [RegisteredRepository]) {
        let existingIDs = Set(repositories.map(\.id))
        let uniqueRepositories = newRepositories.filter { !existingIDs.contains($0.id) }
        repositories.append(contentsOf: uniqueRepositories)
        normalizeRepositoryOrder()
        if selectedRepositoryID == nil || !uniqueRepositories.isEmpty {
            selectedRepositoryID = uniqueRepositories.first?.id ?? repositories.first?.id
        }
        persistRepositoryState()
        let repositoriesNeedingSnapshot = uniqueRepositories.filter {
            repositorySnapshots[$0.id] == nil
        }
        Task { await refreshRepositories(repositoriesNeedingSnapshot) }
        reloadJavaWorkspaceConfiguration()
    }

    private func loadRepositoryState(for workspaceURL: URL) {
        let state = repositoryStore.state(for: workspaceURL)
        repositories = state.repositories
        repositoryDiscoverySettings = state.discoverySettings
        normalizeRepositoryOrder()
        selectedRepositoryID = repositories.contains { $0.id == state.selectedRepositoryID }
            ? state.selectedRepositoryID
            : repositories.first?.id
    }

    private func persistRepositoryState() {
        guard let workspace else { return }
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        repositoryStore.save(
            RepositoryWorkspaceState(
                repositories: repositories,
                selectedRepositoryID: selectedRepositoryID,
                discoverySettings: repositoryDiscoverySettings
            ),
            for: workspaceURL
        )
    }

    private func normalizeRepositoryOrder() {
        repositories = repositories.filter(\.isPinned) + repositories.filter { !$0.isPinned }
    }

    private func availableWorkspaceURL() -> URL? {
        guard let workspace, workspace.isAvailable else {
            presentedRepositoryError = .workspaceUnavailable
            return nil
        }
        return URL(fileURLWithPath: workspace.path, isDirectory: true)
    }

    private func refreshRepository(_ repository: RegisteredRepository) async {
        guard let workspace else { return }
        let refreshContextID = repositoryRefreshContextID
        if activeRepositoryRefreshIDs.contains(repository.id) {
            await withCheckedContinuation { continuation in
                repositoryRefreshWaiters[repository.id, default: []].append(continuation)
            }
            if repositorySnapshots[repository.id] == nil,
               repositorySnapshotErrors[repository.id] == nil,
               isCurrentRepositoryRefresh(
                   repository,
                   workspacePath: workspace.path,
                   refreshContextID: refreshContextID
               ),
               !Task.isCancelled {
                await refreshRepository(repository)
            }
            return
        }
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        let repositoryURL = repository.relativePath == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
        let previousSnapshot = repositorySnapshots[repository.id]
        activeRepositoryRefreshIDs.insert(repository.id)
        if previousSnapshot == nil {
            if repositorySnapshotErrors[repository.id] != nil {
                repositorySnapshotErrors[repository.id] = nil
            }
            refreshingRepositoryIDs.insert(repository.id)
        }

        var shouldRefreshSelectedDiff = false
        var attempt = 1
        while !Task.isCancelled {
            guard isCurrentRepositoryRefresh(
                repository,
                workspacePath: workspace.path,
                refreshContextID: refreshContextID
            ) else {
                await recordRepositoryRefreshDiagnostic(
                    repository,
                    attempt: attempt,
                    event: "discarded-context"
                )
                break
            }

            await repositoryRefreshLimiter.acquire()
            if Task.isCancelled {
                await repositoryRefreshLimiter.release()
                break
            }

            do {
                let snapshot = try await gitRepositoryReader.snapshot(
                    repositoryURL: repositoryURL
                )
                await repositoryRefreshLimiter.release()
                guard isCurrentRepositoryRefresh(
                    repository,
                    workspacePath: workspace.path,
                    refreshContextID: refreshContextID
                ) else {
                    await recordRepositoryRefreshDiagnostic(
                        repository,
                        attempt: attempt,
                        event: "discarded-context"
                    )
                    break
                }
                if previousSnapshot != snapshot {
                    repositorySnapshots[repository.id] = snapshot
                }
                if let excluded = excludedCommitChanges[repository.id], !excluded.isEmpty {
                    let currentSelections = Set(snapshot.changes.map(changeSelection(for:)))
                    let retained = excluded.intersection(currentSelections)
                    excludedCommitChanges[repository.id] = retained.isEmpty ? nil : retained
                }
                if repositorySnapshotErrors[repository.id] != nil {
                    repositorySnapshotErrors[repository.id] = nil
                }
                lastRefreshed = .now
                if attempt > 1 {
                    await recordRepositoryRefreshDiagnostic(
                        repository,
                        attempt: attempt,
                        event: "recovered"
                    )
                }
                if repository.id == selectedChangeRepositoryID, let selectedChange {
                    if let refreshedChange = gitChange(
                        for: selectedChange,
                        repositoryID: repository.id
                    ) {
                        let canonicalSelection = changeSelection(for: refreshedChange)
                        if canonicalSelection != selectedChange {
                            self.selectedChange = canonicalSelection
                            rememberedChangeSelections[repository.id] = canonicalSelection
                            persistWindowState()
                        }
                        shouldRefreshSelectedDiff = true
                    } else {
                        self.selectedChange = nil
                        selectedChangeRepositoryID = nil
                        rememberedChangeSelections[repository.id] = nil
                        currentDiff = nil
                        persistWindowState()
                    }
                }
                break
            } catch is CancellationError {
                await repositoryRefreshLimiter.release()
                await recordRepositoryRefreshDiagnostic(
                    repository,
                    attempt: attempt,
                    event: "cancelled"
                )
                break
            } catch {
                await repositoryRefreshLimiter.release()
                guard isCurrentRepositoryRefresh(
                    repository,
                    workspacePath: workspace.path,
                    refreshContextID: refreshContextID
                ) else {
                    await recordRepositoryRefreshDiagnostic(
                        repository,
                        attempt: attempt,
                        event: "discarded-context"
                    )
                    break
                }
                let retryIndex = attempt - 1
                guard repositorySnapshotRetryDelays.indices.contains(retryIndex) else {
                    if previousSnapshot == nil,
                       repositorySnapshotErrors[repository.id] != error.localizedDescription {
                        repositorySnapshotErrors[repository.id] = error.localizedDescription
                    }
                    await recordRepositoryRefreshDiagnostic(
                        repository,
                        attempt: attempt,
                        event: previousSnapshot == nil ? "exhausted" : "exhausted-cached",
                        error: error
                    )
                    break
                }

                let delay = repositorySnapshotRetryDelays[retryIndex]
                await recordRepositoryRefreshDiagnostic(
                    repository,
                    attempt: attempt,
                    event: "retry-scheduled",
                    error: error
                )
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    await recordRepositoryRefreshDiagnostic(
                        repository,
                        attempt: attempt,
                        event: "cancelled"
                    )
                    break
                }
                attempt += 1
            }
        }
        finishRepositoryRefresh(repository.id)
        if shouldRefreshSelectedDiff {
            await loadSelectedDiff(presentation: .background)
        }
    }

    private func isCurrentRepositoryRefresh(
        _ repository: RegisteredRepository,
        workspacePath: String,
        refreshContextID: UUID
    ) -> Bool {
        guard repositoryRefreshContextID == refreshContextID else { return false }
        guard workspaceURL?.standardizedFileURL.path
                == URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL.path
        else { return false }
        return repositories.contains { currentRepository in
            currentRepository.id == repository.id
                && currentRepository.relativePath == repository.relativePath
        }
    }

    private func recordRepositoryRefreshDiagnostic(
        _ repository: RegisteredRepository,
        attempt: Int,
        event: String,
        error: Error? = nil
    ) async {
        let errorField = error.map {
            " failure=\(repositoryRefreshFailureKind($0)) "
                + "errorType=\(String(reflecting: type(of: $0)))"
        } ?? ""
        await diagnosticLogger.record(
            "repository-refresh event=\(event) repository=\(repository.id) "
                + "attempt=\(attempt)\(errorField)"
        )
    }

    private func repositoryRefreshFailureKind(_ error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if case CommandRunnerError.timedOut = error {
            return "timeout"
        }
        if error is GitRepositoryError {
            return "command-failed"
        }
        return "unexpected"
    }

    private func finishRepositoryRefresh(_ repositoryID: RegisteredRepository.ID) {
        activeRepositoryRefreshIDs.remove(repositoryID)
        refreshingRepositoryIDs.remove(repositoryID)
        let waiters = repositoryRefreshWaiters.removeValue(forKey: repositoryID) ?? []
        waiters.forEach { $0.resume() }
    }

    func repositoryURL(for repository: RegisteredRepository) -> URL? {
        guard let workspaceURL else { return nil }
        return repository.relativePath == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
    }

    private var workspaceURL: URL? {
        workspace.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    func gitChange(
        for selection: GitChangeSelection,
        repositoryID: RegisteredRepository.ID? = nil
    ) -> GitFileChange? {
        guard let repositoryID = repositoryID ?? selectedChangeRepositoryID ?? selectedRepositoryID else {
            return nil
        }
        return repositorySnapshots[repositoryID]?.changes.first { $0.path == selection.path }
    }

    private func changeSelection(for change: GitFileChange) -> GitChangeSelection {
        GitChangeSelection(
            path: change.path,
            kind: change.presentationKind,
            originalPath: change.originalPath
        )
    }

    func modulePath(
        for selection: GitChangeSelection,
        repositoryID: RegisteredRepository.ID
    ) -> String {
        guard let repository = repositories.first(where: { $0.id == repositoryID }),
              let repositoryURL = repositoryURL(for: repository) else { return "." }
        let directoryComponents = Array(selection.path.split(separator: "/").dropLast()).map(String.init)
        let markers = [
            "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
            "settings.gradle.kts", "Package.swift", "package.json", "project.yml"
        ]
        for depth in stride(from: directoryComponents.count, through: 0, by: -1) {
            let relativePath = directoryComponents.prefix(depth).joined(separator: "/")
            let directoryURL = relativePath.isEmpty
                ? repositoryURL
                : repositoryURL.appendingPathComponent(relativePath, isDirectory: true)
            if markers.contains(where: {
                FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0).path)
            }) {
                return relativePath.isEmpty ? "." : relativePath
            }
        }
        return directoryComponents.first ?? "."
    }

    private func migrateRepositoryWindowState(
        from oldID: RegisteredRepository.ID,
        to newID: RegisteredRepository.ID,
        previousRepositoryURL: URL?,
        relocatedRepositoryURL: URL
    ) {
        guard oldID != newID else { return }
        if let selection = rememberedChangeSelections.removeValue(forKey: oldID) {
            rememberedChangeSelections[newID] = selection
        }
        if let filter = rememberedHistoryBranchFilters.removeValue(forKey: oldID) {
            rememberedHistoryBranchFilters[newID] = filter
        }
        if let author = rememberedHistoryAuthorFilters.removeValue(forKey: oldID) {
            rememberedHistoryAuthorFilters[newID] = author
        }
        if let hash = rememberedCommitHashes.removeValue(forKey: oldID) {
            rememberedCommitHashes[newID] = hash
        }
        if let selection = rememberedCommitFileSelections.removeValue(forKey: oldID) {
            rememberedCommitFileSelections[newID] = selection
        }
        if let selection = rememberedMavenSelections.removeValue(forKey: oldID) {
            rememberedMavenSelections[newID] = selection
        }
        if let message = commitMessageDrafts.removeValue(forKey: oldID) {
            commitMessageDrafts[newID] = message
        }
        let oldContextKey = fileTabContextKey(for: .repository(oldID))
        let newContextKey = fileTabContextKey(for: .repository(newID))
        if var session = fileTabSessionsByContext.removeValue(forKey: oldContextKey) {
            if let previousRepositoryURL {
                session.tabs = session.tabs.map { tab in
                    PersistedFileTab(
                        path: relocatedFilePath(
                            tab.path,
                            from: previousRepositoryURL,
                            to: relocatedRepositoryURL
                        ),
                        showsMarkdownPreview: tab.showsMarkdownPreview,
                        visibleLine: tab.visibleLine
                    )
                }
                session.selectedFilePath = session.selectedFilePath.map {
                    relocatedFilePath(
                        $0,
                        from: previousRepositoryURL,
                        to: relocatedRepositoryURL
                    )
                }
            }
            fileTabSessionsByContext[newContextKey] = session
        }
    }

    private func relocatedFilePath(_ path: String, from oldRoot: URL, to newRoot: URL) -> String {
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let oldRoot = oldRoot.standardizedFileURL
        guard Self.isSameOrDescendant(fileURL, of: oldRoot) else {
            return fileURL.path
        }
        let prefix = oldRoot.path.hasSuffix("/") ? oldRoot.path : oldRoot.path + "/"
        guard fileURL.path.hasPrefix(prefix) else { return fileURL.path }
        let relativePath = String(fileURL.path.dropFirst(prefix.count))
        return newRoot.appendingPathComponent(relativePath).standardizedFileURL.path
    }

    private static func relocatedFileURL(_ fileURL: URL, from oldRoot: URL, to newRoot: URL) -> URL {
        let fileURL = fileURL.standardizedFileURL
        let oldRoot = oldRoot.standardizedFileURL
        let newRoot = newRoot.standardizedFileURL
        guard fileURL != oldRoot else { return newRoot }
        let prefix = oldRoot.path.hasSuffix("/") ? oldRoot.path : oldRoot.path + "/"
        guard fileURL.path.hasPrefix(prefix) else { return fileURL }
        let relativePath = String(fileURL.path.dropFirst(prefix.count))
        return newRoot.appendingPathComponent(relativePath).standardizedFileURL
    }

    private static func isSameOrDescendant(_ fileURL: URL, of rootURL: URL) -> Bool {
        let fileURL = fileURL.standardizedFileURL
        let rootURL = rootURL.standardizedFileURL
        guard fileURL != rootURL else { return true }
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return fileURL.path.hasPrefix(prefix)
    }

    private static func relativePath(of itemURL: URL, from rootURL: URL) -> String? {
        let itemURL = itemURL.standardizedFileURL
        let rootURL = rootURL.standardizedFileURL
        if itemURL == rootURL { return "." }
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard itemURL.path.hasPrefix(prefix) else { return nil }
        return String(itemURL.path.dropFirst(prefix.count))
    }

    private func selectedFilePath(relativeTo repositoryURL: URL) -> String? {
        guard let selectedFileURL else { return nil }
        let prefix = repositoryURL.path.hasSuffix("/") ? repositoryURL.path : repositoryURL.path + "/"
        guard selectedFileURL.path.hasPrefix(prefix) else { return nil }
        return String(selectedFileURL.path.dropFirst(prefix.count))
    }

    private func fileFingerprint(_ fileURL: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size):\(modifiedAt)"
    }

    private func resetDocumentEditingState() {
        openFileTabs = []
        clearJavaSemanticTokensForFileTransition()
        javaSemanticTokenCacheByFile = [:]
        documentRequestID = nil
        documentText = ""
        documentOriginalText = ""
        isLoadingDocument = false
        isSavingDocument = false
        showsMarkdownPreview = false
        selectedSourceNavigationRequest = nil
        showsDiscardAndReloadConfirmation = false
        hasDocumentConflict = false
        documentSaveErrorMessage = nil
        lastDocumentSavedAt = nil
        pendingWorkspaceURL = nil
        showsDiscardAndCloseWorkspaceConfirmation = false
    }

    private func fileTabContextKey(for context: NavigationContext) -> String {
        switch context {
        case .workspace:
            return "workspace"
        case .repository(let repositoryID):
            return "repository:\(repositoryID)"
        }
    }

    private var currentFileTabContextKey: String {
        fileTabContextKey(for: navigationContext)
    }

    private func syncCurrentFileTabSession() {
        fileTabSessionsByContext[currentFileTabContextKey] = FileTabSessionState(
            tabs: openFileTabs.map {
                PersistedFileTab(
                    path: $0.url.standardizedFileURL.path,
                    showsMarkdownPreview: $0.showsMarkdownPreview,
                    visibleLine: $0.visibleLine
                )
            },
            selectedFilePath: selectedFileURL?.standardizedFileURL.path
        )
    }

    private func restoreFileTabsForCurrentContext() {
        selectedFileURL = nil
        openFileTabs = []
        currentFileNavigationLocation = nil
        selectedFileFingerprint = nil
        loadedDocument = nil
        resetDocumentEditingState()
        guard let session = fileTabSessionsByContext[currentFileTabContextKey] else { return }

        var seenPaths: Set<String> = []
        let validTabs = session.tabs.filter { persistedTab in
            let fileURL = URL(fileURLWithPath: persistedTab.path).standardizedFileURL
            return seenPaths.insert(fileURL.path).inserted
        }
        let restoredTabs = validTabs.suffix(maximumOpenFileTabs)
        openFileTabs = restoredTabs.map { persistedTab in
            let fileURL = URL(fileURLWithPath: persistedTab.path).standardizedFileURL
            return OpenFileTab(
                url: fileURL,
                loadedDocument: nil,
                text: "",
                originalText: "",
                fingerprint: fileFingerprint(fileURL),
                showsMarkdownPreview: fileURL.pathExtension.lowercased() == "md"
                    && persistedTab.showsMarkdownPreview,
                isLoading: false,
                visibleLine: persistedTab.visibleLine
            )
        }

        let selectedPath = session.selectedFilePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let selectedTab = selectedPath.flatMap { path in
            openFileTabs.first(where: { $0.url.path == path })
        } ?? openFileTabs.last
        if let selectedTab {
            activateFileTab(selectedTab)
        }
    }

    private func restoreWindowState(for workspaceURL: URL) {
        let state = windowStateStore.state(for: workspaceURL)
        if let repositoryID = state.navigationRepositoryID,
           repositories.contains(where: { $0.id == repositoryID }) {
            navigationContext = .repository(repositoryID)
            selectedRepositoryID = repositoryID
        } else {
            navigationContext = .workspace
        }
        fileTabSessionsByContext = state.fileTabSessionsByContext
        if fileTabSessionsByContext[currentFileTabContextKey] == nil,
           let selectedFilePath = state.selectedFilePath {
            fileTabSessionsByContext[currentFileTabContextKey] = FileTabSessionState(
                tabs: [
                    PersistedFileTab(
                        path: selectedFilePath,
                        showsMarkdownPreview: state.selectedFileShowsMarkdownPreview
                    )
                ],
                selectedFilePath: selectedFilePath
            )
        }
        let sections = isWorkspaceContext ? AppSection.workspaceSections : AppSection.repositorySections
        selectedSection = sections.contains(state.selectedSection) ? state.selectedSection : sections[0]
        changesRepositoryScopeID = state.changesRepositoryScopeID.flatMap { id in
            repositories.contains(where: { $0.id == id }) ? id : nil
        }
        changesGrouping = state.changesGrouping
        historyGrouping = state.historyGrouping
        rememberedChangeSelections = state.selectedChangesByRepository
        rememberedHistoryBranchFilters = state.historyBranchFiltersByRepository
        rememberedHistoryAuthorFilters = state.historyAuthorFiltersByRepository
        rememberedCommitHashes = state.selectedCommitHashesByRepository
        rememberedCommitFileSelections = state.selectedCommitFilesByRepository
        rememberedMavenSelections = state.mavenSelectionsByRepository
        if isRepositoryContext, let selectedRepositoryID {
            selectedChangeRepositoryID = selectedRepositoryID
            selectedChange = state.selectedChangesByRepository[selectedRepositoryID]
        } else {
            let restoredChangeRepositoryID: RegisteredRepository.ID? = state.selectedChangeRepositoryID.flatMap { id in
                guard repositories.contains(where: { $0.id == id }),
                      state.changesRepositoryScopeID == nil || state.changesRepositoryScopeID == id else {
                    return nil
                }
                return id
            }
            selectedChangeRepositoryID = restoredChangeRepositoryID
            selectedChange = restoredChangeRepositoryID.flatMap {
                state.selectedChangesByRepository[$0]
            }
        }
        historyBranchFilter = selectedRepositoryID.flatMap {
            state.historyBranchFiltersByRepository[$0]
        } ?? .current
        historyAuthorFilter = selectedRepositoryID.flatMap {
            state.historyAuthorFiltersByRepository[$0]
        } ?? .all
        selectedCommitHash = selectedRepositoryID.flatMap {
            state.selectedCommitHashesByRepository[$0]
        }
        historyVerticalSplitFraction = state.historyVerticalSplitFraction
        historyHorizontalSplitFraction = state.historyHorizontalSplitFraction
        restoreFileTabsForCurrentContext()
    }

    private func persistWindowState() {
        guard let workspaceURL else { return }
        windowStatePersistenceTask?.cancel()
        windowStatePersistenceTask = nil
        syncCurrentFileTabSession()
        windowStateStore.save(windowStateSnapshot(), for: workspaceURL)
    }

    private func scheduleWindowStatePersistence() {
        guard let workspaceURL else { return }
        syncCurrentFileTabSession()
        let state = windowStateSnapshot()
        windowStatePersistenceTask?.cancel()
        windowStatePersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            windowStateStore.save(state, for: workspaceURL)
            windowStatePersistenceTask = nil
        }
    }

    private func windowStateSnapshot() -> WorkspaceWindowState {
        let navigationRepositoryID: RegisteredRepository.ID?
        if case .repository(let repositoryID) = navigationContext {
            navigationRepositoryID = repositoryID
        } else {
            navigationRepositoryID = nil
        }
        return WorkspaceWindowState(
            selectedSection: selectedSection,
            selectedFilePath: selectedFileURL?.path,
            selectedFileShowsMarkdownPreview: showsMarkdownPreview,
            fileTabSessionsByContext: fileTabSessionsByContext,
            selectedChangesByRepository: rememberedChangeSelections,
            selectedChangeRepositoryID: selectedChangeRepositoryID,
            historyBranchFiltersByRepository: rememberedHistoryBranchFilters,
            historyAuthorFiltersByRepository: rememberedHistoryAuthorFilters,
            selectedCommitHashesByRepository: rememberedCommitHashes,
            selectedCommitFilesByRepository: rememberedCommitFileSelections,
            mavenSelectionsByRepository: rememberedMavenSelections,
            changesRepositoryScopeID: changesRepositoryScopeID,
            changesGrouping: changesGrouping,
            historyGrouping: historyGrouping,
            navigationRepositoryID: navigationRepositoryID,
            historyVerticalSplitFraction: historyVerticalSplitFraction,
            historyHorizontalSplitFraction: historyHorizontalSplitFraction
        )
    }

    func persistStateBeforeTermination() {
        persistWindowState()
    }

    func shutdownJavaLanguage() async {
        javaSemanticTokensTask?.cancel()
        javaLanguageEventTask?.cancel()
        javaIndexPhases = [:]
        await javaLanguageProvider.shutdown()
    }
}

extension AppState {
    static let preview = AppState(
        workspace: WorkspaceSummary(name: "pangmaoyun", path: "/Users/you/workspaces/pangmaoyun"),
        repositories: [
            RegisteredRepository(displayName: "inventorycore", relativePath: "inventorycore", isPinned: true),
            RegisteredRepository(displayName: "saasbusinesscenter", relativePath: "services/saasbusinesscenter", isPinned: false),
            RegisteredRepository(displayName: "platform-common", relativePath: "platform/common", isPinned: false)
        ],
        selectedRepositoryID: "inventorycore",
        workspaceStore: PreviewWorkspaceStore(),
        workspacePicker: PreviewWorkspacePicker(),
        repositoryStore: PreviewRepositoryStore(),
        repositoryPicker: PreviewRepositoryPicker(),
        repositoryDiscoverer: PreviewRepositoryDiscoverer(),
        gitRepositoryReader: PreviewGitRepositoryReader(),
        workspaceFileBrowser: PreviewWorkspaceFileBrowser(),
        documentLoader: PreviewDocumentLoader(),
        taskStore: PreviewTaskStore(),
        taskRunner: PreviewTaskRunner(),
        workspaceFileSearch: PreviewWorkspaceFileSearch(),
        windowStateStore: PreviewWindowStateStore(),
        restoresWorkspaceOnLaunch: false
    )
}

@MainActor
private final class PreviewWorkspaceStore: WorkspaceStoring {
    func restoreLastWorkspace() -> URL? { nil }
    func recentWorkspaces() -> [RecentWorkspace] { [] }
    func rememberWorkspace(_ url: URL) {}
    func removeWorkspace(_ workspace: RecentWorkspace) {}
    func resolve(_ workspace: RecentWorkspace) -> URL {
        URL(fileURLWithPath: workspace.path, isDirectory: true)
    }
}

@MainActor
private struct PreviewWorkspacePicker: WorkspacePicking {
    func chooseWorkspace() -> URL? { nil }
}

@MainActor
private final class PreviewRepositoryStore: RepositoryStoring {
    func state(for workspaceURL: URL) -> RepositoryWorkspaceState { .empty }
    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {}
}

@MainActor
private struct PreviewRepositoryPicker: RepositoryPicking {
    func chooseRepository(in workspaceURL: URL, purpose: RepositoryPickerPurpose) -> URL? { nil }
}

private struct PreviewRepositoryDiscoverer: RepositoryDiscovering {
    func discoverRepositories(
        in workspaceURL: URL,
        settings: RepositoryDiscoverySettings
    ) async -> [RegisteredRepository] { [] }
}

private struct PreviewGitRepositoryReader: GitRepositoryReading {
    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 1,
            behindCount: 0,
            changes: [],
            lastCommit: GitCommitSummary(
                hash: "f8a72bc",
                subject: "Add RepoDesk workspace shell",
                author: "RepoDesk",
                authoredAt: .now
            )
        )
    }

    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        GitFileDiff(
            path: "example.txt",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: ["before"],
            newLines: ["after"],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 1,
                    newStart: 1,
                    newCount: 1,
                    lines: [
                        GitPatchLine(kind: .deletion, text: "before"),
                        GitPatchLine(kind: .addition, text: "after")
                    ]
                )
            ],
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
        []
    }

    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { ["RepoDesk"] }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        GitCommitDetail(
            summary: GitCommitSummary(
                hash: hash,
                subject: "Preview commit",
                author: "RepoDesk",
                authoredAt: .now
            ),
            files: []
        )
    }
}

extension GitChangeKind {
    static let allDisplayCases: [GitChangeKind] = [.changes, .unversioned]
}

final class StreamingTaskOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var flushScheduled = false

    @discardableResult
    func append(_ text: String) -> Bool {
        lock.withLock {
            pending.append(text)
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
        }
    }

    func take() -> String {
        lock.withLock {
            let value = pending
            pending = ""
            flushScheduled = false
            return value
        }
    }
}

private struct PreviewWorkspaceFileBrowser: WorkspaceFileBrowsing {
    func children(of directoryURL: URL) async throws -> [WorkspaceFileEntry] { [] }
}

private struct PreviewDocumentLoader: DocumentLoading {
    func load(_ fileURL: URL) async -> LoadedDocument {
        let text = "# RepoDesk\n\nPreview document"
        let data = Data(text.utf8)
        return .text(
            LoadedTextDocument(
                text: text,
                isLarge: false,
                encoding: .utf8,
                revision: FileSystemDocumentStore.revision(for: data)
            )
        )
    }
}

@MainActor
private final class PreviewTaskStore: RepoTaskStoring {
    func catalog(workspaceURL: URL, repositoryURL: URL?) -> TaskCatalog {
        TaskCatalog(global: [], workspace: [], repository: [])
    }
    func save(_ task: RepoTaskDefinition, scope: RepoTaskScope, workspaceURL: URL, repositoryURL: URL?) {}
    func remove(taskID: String, scope: RepoTaskScope, workspaceURL: URL, repositoryURL: URL?) {}
    func recentRuns() -> [TaskRunRecord] { [] }
    func record(_ run: TaskRunRecord) {}
}

private actor PreviewTaskRunner: RepoTaskRunning {
    func run(
        _ task: ResolvedRepoTask,
        output: @escaping @Sendable (TaskOutputChunk) -> Void
    ) async throws -> TaskRunResult {
        output(TaskOutputChunk(channel: .standardOutput, text: "Preview task\n"))
        return TaskRunResult(terminationStatus: 0, startedAt: .now, finishedAt: .now)
    }
    func stop() async {}
}

private struct PreviewWorkspaceFileSearch: WorkspaceFileSearching {
    func search(in workspaceURL: URL, query: String, limit: Int) async -> [WorkspaceFileEntry] { [] }
}

private struct PreviewWorkspaceTextSearch: WorkspaceTextSearching {
    func search(in workspaceURL: URL, query: String, limit: Int) async -> [WorkspaceTextSearchResult] { [] }
}

@MainActor
private final class PreviewWindowStateStore: WindowStateStoring {
    func state(for workspaceURL: URL) -> WorkspaceWindowState { .initial }
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {}
}
