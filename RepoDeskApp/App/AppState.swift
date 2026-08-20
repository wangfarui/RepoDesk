import Foundation
import Observation

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
    var changesRepositoryScopeID: RegisteredRepository.ID?
    var changesGrouping: GitChangesGrouping = .directory
    var commitMessageDrafts: [RegisteredRepository.ID: String] = [:]
    var excludedCommitChanges: [RegisteredRepository.ID: Set<GitChangeSelection>] = [:]
    var commitExecutionState: GitCommitExecutionState = .idle
    var isSwitchingBranch = false
    var branchSwitchErrorMessage: String?
    var isPerformingBranchOperation = false
    var branchOperationErrorMessage: String?
    var branchOperationStatusMessage: String?
    var branchComparison: GitBranchComparison?
    var isLoadingBranchComparison = false
    var conflictFiles: [GitConflictFile] = []
    var mergeSourceBranch: String?
    var fileChildren: [URL: [WorkspaceFileEntry]] = [:]
    var expandedDirectoryURLs: Set<URL> = []
    var loadingDirectoryURLs: Set<URL> = []
    var directoryLoadErrors: [URL: String] = [:]
    var workspaceMonitoringErrorMessage: String?
    var automaticallyRefreshesWorkspace = true
    var refreshesWhenBecomingActive = true
    var showsHiddenFiles = false
    var compactsSingleChildDirectories = true
    var opensMarkdownInPreview = false
    var selectedFileURL: URL?
    var loadedDocument: LoadedDocument?
    var documentText = ""
    var documentOriginalText = ""
    var isLoadingDocument = false
    var isSavingDocument = false
    var showsMarkdownPreview = false
    var selectedFileFingerprint: String?
    var pendingFileSelectionURL: URL?
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
    var isLoadingCommitDiff = false
    var commitDiffErrorMessage: String?
    var isLoadingHistory = false
    var isLoadingBranches = false
    var isLoadingHistoryAuthors = false
    var isLoadingCommit = false
    var historyErrorMessage: String?
    var branchesErrorMessage: String?
    var historyAuthorsErrorMessage: String?
    var commitErrorMessage: String?
    var hasMoreHistory = true
    var historyBranchFilter: GitHistoryBranchFilter = .current
    var historyAuthorFilter: String?
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
    var mavenExecution = MavenExecutionPresentation.idle
    var recentMavenRuns: [MavenRunRecord] = []
    var mavenSettingsErrorMessage: String?
    var mavenProjectRevisions: [String: Int] = [:]
    var fileSearchResults: [WorkspaceFileEntry] = []
    var isSearchingFiles = false
    var rememberedChangeSelections: [RegisteredRepository.ID: GitChangeSelection] = [:]
    var rememberedHistoryBranchFilters: [RegisteredRepository.ID: GitHistoryBranchFilter] = [:]
    var rememberedHistoryAuthorFilters: [RegisteredRepository.ID: String] = [:]
    var rememberedCommitHashes: [RegisteredRepository.ID: String] = [:]
    var rememberedCommitFileSelections: [RegisteredRepository.ID: HistoryCommitFileSelection] = [:]
    var rememberedMavenSelections: [RegisteredRepository.ID: MavenWindowSelection] = [:]
    var pendingSourceLine: Int?
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
    private let windowStateStore: WindowStateStoring
    private let appPreferencesStore: AppPreferencesStoring
    private let diagnosticLogger: AppDiagnosticLogger
    private var repositoryDiscoveryID: UUID?
    private var diffRequestID: UUID?
    private var documentRequestID: UUID?
    private var historyRequestID: UUID?
    private var branchesRequestID: UUID?
    private var commitRequestID: UUID?
    private var commitDiffRequestID: UUID?
    private var fileSearchRequestID: UUID?
    private var mavenRunID: UUID?
    private var repositoryRefreshContextID = UUID()
    private let repositoryRefreshLimiter = RepositoryRefreshLimiter(limit: 4)
    private let repositorySnapshotRetryDelays: [Duration]
    private var activeRepositoryRefreshIDs: Set<RegisteredRepository.ID> = []
    private var repositoryRefreshWaiters: [RegisteredRepository.ID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var commitSuccessDismissTask: Task<Void, Never>?

    private enum DiffLoadPresentation {
        case foreground
        case background
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
        mavenSettingsStore: MavenSettingsStoring? = nil,
        mavenRunHistoryStore: MavenRunHistoryStoring? = nil,
        workspaceFileSearch: (any WorkspaceFileSearching)? = nil,
        windowStateStore: WindowStateStoring? = nil,
        appPreferencesStore: AppPreferencesStoring? = nil,
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
        self.mavenSettingsStore = mavenSettingsStore ?? UserDefaultsMavenSettingsStore()
        self.mavenRunHistoryStore = mavenRunHistoryStore ?? UserDefaultsMavenRunHistoryStore()
        self.workspaceFileSearch = workspaceFileSearch ?? FileSystemWorkspaceSearch()
        self.windowStateStore = windowStateStore ?? UserDefaultsWindowStateStore()
        self.appPreferencesStore = appPreferencesStore
        self.diagnosticLogger = diagnosticLogger
        self.repositorySnapshotRetryDelays = repositorySnapshotRetryDelays
        automaticallyRefreshesWorkspace = appPreferences.automaticallyRefreshesWorkspace
        refreshesWhenBecomingActive = appPreferences.refreshesWhenBecomingActive
        showsHiddenFiles = appPreferences.showsHiddenFiles
        compactsSingleChildDirectories = appPreferences.compactsSingleChildDirectories
        opensMarkdownInPreview = appPreferences.opensMarkdownInPreview
        diffPresentation = appPreferences.diffPresentation
        ignoresWhitespaceInDiff = appPreferences.ignoresWhitespaceInDiff
        recentTaskRuns = self.taskStore.recentRuns()
        repositoryDiscoveryID = nil
        diffRequestID = nil
        documentRequestID = nil
        historyRequestID = nil
        branchesRequestID = nil
        commitRequestID = nil
        commitDiffRequestID = nil
        fileSearchRequestID = nil
        mavenRunID = nil
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
            recentMavenRuns = self.mavenRunHistoryStore.recentRuns(for: workspaceURL)
        }
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
        isCommittingChanges || isSwitchingBranch || isPerformingBranchOperation
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

    var hasUnsavedDocumentChanges: Bool {
        guard case .text(let document) = loadedDocument, !document.isLarge else { return false }
        return documentText != documentOriginalText
    }

    var canEditSelectedDocument: Bool {
        guard case .text(let document) = loadedDocument else { return false }
        return !document.isLarge
    }

    var selectedDocumentEncoding: DocumentTextEncoding? {
        guard case .text(let document) = loadedDocument else { return nil }
        return document.encoding
    }

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
        guard let url = workspacePicker.chooseWorkspace() else { return }
        requestOpenWorkspace(at: url)
    }

    func openWorkspace(at url: URL) {
        if mavenExecution.runningRequestID != nil {
            stopMaven()
        }
        mavenRunID = nil
        repositoryRefreshContextID = UUID()
        workspaceStore.rememberWorkspace(url)
        recentWorkspaces = workspaceStore.recentWorkspaces()
        workspace = WorkspaceSummary(url: url)
        selectedSection = .overview
        lastRefreshed = nil
        discoveredRepositories = []
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
        commitHistory = []
        branches = []
        historyAuthors = []
        selectedCommitHash = nil
        selectedCommitDetail = nil
        selectedCommitFile = nil
        commitFileDiff = nil
        commitDiffRequestID = nil
        isLoadingCommitDiff = false
        taskCatalog = TaskCatalog(global: [], workspace: [], repository: [])
        selectedTaskID = nil
        resolvedSelectedTask = nil
        mavenExecution = .idle
        recentMavenRuns = []
        mavenSettingsErrorMessage = nil
        mavenProjectRevisions = [:]
        historyVerticalSplitFraction = HistorySplitLayout.defaultVerticalFraction
        historyHorizontalSplitFraction = HistorySplitLayout.defaultHorizontalFraction
        fileSearchResults = []
        rememberedChangeSelections = [:]
        rememberedHistoryBranchFilters = [:]
        rememberedHistoryAuthorFilters = [:]
        rememberedCommitHashes = [:]
        rememberedCommitFileSelections = [:]
        rememberedMavenSelections = [:]
        commitMessageDrafts = [:]
        excludedCommitChanges = [:]
        clearCommitExecutionState()
        isSwitchingBranch = false
        branchSwitchErrorMessage = nil
        isPerformingBranchOperation = false
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        branchComparison = nil
        isLoadingBranchComparison = false
        conflictFiles = []
        mergeSourceBranch = nil
        changesRepositoryScopeID = nil
        changesGrouping = .directory
        navigationContext = .workspace
        repositoryDiscoveryID = nil
        isDiscoveringRepositories = false
        isShowingDiscoveryResults = false
        loadRepositoryState(for: url)
        restoreWindowState(for: url)
        loadTaskCatalog()
        loadMavenSettings(for: url)
        Task { await loadDirectory(url.standardizedFileURL) }
    }

    func openRecentWorkspace(_ recentWorkspace: RecentWorkspace) {
        requestOpenWorkspace(at: workspaceStore.resolve(recentWorkspace))
    }

    func closeWorkspace() {
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
        if runningTaskID != nil {
            stopRunningTask()
        }
        if mavenExecution.runningRequestID != nil {
            stopMaven()
        }
        mavenRunID = nil
        repositoryRefreshContextID = UUID()
        workspace = nil
        repositories = []
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
        commitHistory = []
        branches = []
        historyAuthors = []
        selectedCommitDetail = nil
        selectedCommitFile = nil
        commitFileDiff = nil
        taskCatalog = TaskCatalog(global: [], workspace: [], repository: [])
        mavenSettings = .empty
        mavenExecution = .idle
        recentMavenRuns = []
        mavenSettingsErrorMessage = nil
        mavenProjectRevisions = [:]
        historyVerticalSplitFraction = HistorySplitLayout.defaultVerticalFraction
        historyHorizontalSplitFraction = HistorySplitLayout.defaultHorizontalFraction
        rememberedCommitFileSelections = [:]
        rememberedMavenSelections = [:]
        commitMessageDrafts = [:]
        excludedCommitChanges = [:]
        clearCommitExecutionState()
        isSwitchingBranch = false
        branchSwitchErrorMessage = nil
        isPerformingBranchOperation = false
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        branchComparison = nil
        isLoadingBranchComparison = false
        conflictFiles = []
        mergeSourceBranch = nil
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
        repositoryDiscoveryID = discoveryID
        isDiscoveringRepositories = true

        Task { [weak self] in
            guard let self else { return }
            let discovered = await repositoryDiscoverer.discoverRepositories(in: workspaceURL)
            guard repositoryDiscoveryID == discoveryID else { return }
            let registeredIDs = Set(repositories.map(\.id))
            discoveredRepositories = discovered.filter { !registeredIDs.contains($0.id) }
            repositoryDiscoveryID = nil
            isDiscoveringRepositories = false
            isShowingDiscoveryResults = true
        }
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
        commitHistory = []
        branches = []
        branchesRequestID = nil
        isLoadingBranches = false
        branchSwitchErrorMessage = nil
        selectedCommitHash = nil
        selectedCommitDetail = nil
        selectedCommitFile = nil
        commitFileDiff = nil
        historyErrorMessage = nil
        branchesErrorMessage = nil
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        branchComparison = nil
        conflictFiles = []
        mergeSourceBranch = nil
        historyAuthorsErrorMessage = nil
        commitErrorMessage = nil
        historyBranchFilter = rememberedHistoryBranchFilters[id] ?? .current
        historyAuthorFilter = rememberedHistoryAuthorFilters[id]
        selectedCommitHash = rememberedCommitHashes[id]
        persistRepositoryState()
        persistWindowState()
        loadTaskCatalog()
    }

    func selectRepositoryContext(_ id: RegisteredRepository.ID) {
        guard repositories.contains(where: { $0.id == id }) else { return }
        selectRepository(id)
        navigationContext = .repository(id)
        changesRepositoryScopeID = id
        if selectedSection == .overview {
            selectedSection = .changes
        }
        persistWindowState()
    }

    func selectWorkspaceContext() {
        navigationContext = .workspace
        changesRepositoryScopeID = nil
        selectedChange = nil
        selectedChangeRepositoryID = nil
        currentDiff = nil
        diffErrorMessage = nil
        if selectedSection == .history {
            selectedSection = .overview
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

    func fetchCurrentRepository() async {
        await performBranchOperation {
            try await self.gitRepositoryOperator.fetch(repositoryURL: $0)
        }
    }

    func pullCurrentRepository() async {
        guard let repositoryURL = activeRepositoryURL else { return }
        isPerformingBranchOperation = true
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        defer { isPerformingBranchOperation = false }
        do {
            try await gitRepositoryOperator.pullCurrentBranch(repositoryURL: repositoryURL)
            branchOperationStatusMessage = "Pull 成功。"
            await refreshAfterBranchOperation()
        } catch {
            let files = (try? await gitRepositoryOperator.conflictFiles(repositoryURL: repositoryURL)) ?? []
            if files.isEmpty {
                branchOperationErrorMessage = error.localizedDescription
            } else {
                conflictFiles = files
                mergeSourceBranch = "upstream"
            }
            await refreshAfterBranchOperation()
        }
    }

    func pushCurrentRepository() async {
        await performBranchOperation {
            try await self.gitRepositoryOperator.pushCurrentBranch(repositoryURL: $0)
        }
    }

    func mergeBranch(_ branch: GitBranch) async {
        guard let repositoryURL = activeRepositoryURL else { return }
        isPerformingBranchOperation = true
        branchOperationErrorMessage = nil
        branchOperationStatusMessage = nil
        defer { isPerformingBranchOperation = false }
        do {
            try await gitRepositoryOperator.mergeBranch(repositoryURL: repositoryURL, branch: branch)
            branchOperationStatusMessage = "Merge 成功。"
            await refreshAfterBranchOperation()
        } catch {
            let files = (try? await gitRepositoryOperator.conflictFiles(repositoryURL: repositoryURL)) ?? []
            if files.isEmpty {
                branchOperationErrorMessage = error.localizedDescription
            } else {
                conflictFiles = files
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

    func resolveConflict(at index: Int) async {
        guard conflictFiles.indices.contains(index), let repositoryURL = activeRepositoryURL else { return }
        do {
            try await gitRepositoryOperator.resolveConflict(repositoryURL: repositoryURL, file: conflictFiles[index])
            conflictFiles[index].isResolved = true
        } catch {
            branchOperationErrorMessage = error.localizedDescription
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

    func abortMerge() async {
        guard let repositoryURL = activeRepositoryURL else { return }
        do {
            try await gitRepositoryOperator.abortMerge(repositoryURL: repositoryURL)
            conflictFiles = []
            mergeSourceBranch = nil
            await refreshAfterBranchOperation()
        } catch {
            branchOperationErrorMessage = error.localizedDescription
        }
    }

    func continueMerge() async {
        guard conflictFiles.allSatisfy(\.isResolved), let repositoryURL = activeRepositoryURL else { return }
        do {
            try await gitRepositoryOperator.continueMerge(repositoryURL: repositoryURL)
            conflictFiles = []
            mergeSourceBranch = nil
            branchOperationStatusMessage = "Merge 完成。"
            await refreshAfterBranchOperation()
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

    private func refreshAfterBranchOperation() async {
        guard let repository = selectedRepository else { return }
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
            currentDiff = nil
            diffErrorMessage = nil
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

    private func loadSelectedDiff(presentation: DiffLoadPresentation) async {
        guard let repository = selectedChangeRepository,
              let selection = selectedChange,
              let repositoryURL = repositoryURL(for: repository) else {
            if presentation == .foreground {
                currentDiff = nil
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

    func selectAdjacentChange(offset: Int) {
        let scopedRepositories = repositories.filter {
            changesRepositoryScopeID == nil || changesRepositoryScopeID == $0.id
        }
        let entries = scopedRepositories.flatMap { repository in
            GitChangeKind.allDisplayCases.flatMap { kind in
                changes(for: kind, repositoryID: repository.id).map { (repository.id, $0) }
            }
        }
        guard !entries.isEmpty else { return }
        let currentIndex = entries.firstIndex {
            $0.0 == selectedChangeRepositoryID && $0.1 == selectedChange
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), entries.count - 1)
        selectChange(entries[nextIndex].1, repositoryID: entries[nextIndex].0)
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

    func toggleDirectory(_ directoryURL: URL) {
        let directoryURL = directoryURL.standardizedFileURL
        if expandedDirectoryURLs.remove(directoryURL) == nil {
            expandedDirectoryURLs.insert(directoryURL)
            Task { await loadDirectoryChainForCurrentPresentation(startingAt: directoryURL) }
        }
    }

    func selectFile(_ fileURL: URL) {
        let fileURL = fileURL.standardizedFileURL
        guard fileURL != selectedFileURL else { return }
        if hasUnsavedDocumentChanges {
            pendingFileSelectionURL = fileURL
            return
        }
        loadFile(fileURL)
    }

    func discardChangesAndOpenPendingFile() {
        guard let pendingFileSelectionURL else { return }
        self.pendingFileSelectionURL = nil
        loadFile(pendingFileSelectionURL)
    }

    func cancelPendingFileSelection() {
        pendingFileSelectionURL = nil
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
            hasDocumentConflict = false
            lastDocumentSavedAt = .now
        } catch DocumentSaveError.changedOnDisk {
            hasDocumentConflict = true
        } catch {
            documentSaveErrorMessage = error.localizedDescription
        }
    }

    private func loadFile(_ fileURL: URL, preservesMarkdownPreview: Bool = false) {
        let previewWasVisible = showsMarkdownPreview
        selectedFileURL = fileURL
        selectedFileFingerprint = fileFingerprint(fileURL)
        showsMarkdownPreview = fileURL.pathExtension.lowercased() == "md" && opensMarkdownInPreview
        pendingFileSelectionURL = nil
        showsDiscardAndReloadConfirmation = false
        hasDocumentConflict = false
        documentSaveErrorMessage = nil
        lastDocumentSavedAt = nil
        documentText = ""
        documentOriginalText = ""
        let requestID = UUID()
        documentRequestID = requestID
        isLoadingDocument = true
        loadedDocument = nil
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
            documentRequestID = nil
            isLoadingDocument = false
        }
    }

    func toggleMarkdownPreview() {
        showsMarkdownPreview.toggle()
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
        await refreshLoadedDirectories(for: batch, workspaceURL: workspaceURL)
        if let traceID {
            await diagnosticLogger.record(
                "workspace-batch directories-complete id=\(traceID)"
            )
        }
        reloadSelectedFileIfChanged()

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

    func searchWorkspaceFiles(query: String) {
        guard let searchRootURL = visibleWorkspaceRootURL else { return }
        let requestID = UUID()
        fileSearchRequestID = requestID
        if query.isEmpty {
            fileSearchResults = []
            isSearchingFiles = false
            return
        }
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

    func loadHistoryAuthors() async {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository) else { return }
        isLoadingHistoryAuthors = true
        historyAuthorsErrorMessage = nil
        defer { isLoadingHistoryAuthors = false }

        do {
            historyAuthors = try await gitRepositoryReader.authors(repositoryURL: repositoryURL)
            if let historyAuthorFilter, !historyAuthors.contains(historyAuthorFilter) {
                self.historyAuthorFilter = nil
                if let repositoryID = selectedRepositoryID {
                    rememberedHistoryAuthorFilters[repositoryID] = nil
                }
            }
        } catch {
            historyAuthors = []
            historyAuthorsErrorMessage = error.localizedDescription
        }
    }

    func loadHistory(reset: Bool = true) async {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository) else { return }
        let requestID = UUID()
        historyRequestID = requestID
        isLoadingHistory = true
        historyErrorMessage = nil
        let skip = reset ? 0 : commitHistory.count

        do {
            let history = try await gitRepositoryReader.history(
                repositoryURL: repositoryURL,
                limit: 50,
                skip: skip,
                revision: historyRevision,
                author: historyAuthorFilter
            )
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
                if let rememberedHash, history.contains(where: { $0.hash == rememberedHash }) {
                    selectCommit(rememberedHash)
                } else if let first = history.first {
                    selectCommit(first.hash)
                } else {
                    selectedCommitHash = nil
                    selectedCommitDetail = nil
                    selectedCommitFile = nil
                    commitFileDiff = nil
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
                selectedCommitFile = rememberedFile ?? detail.files.first
                if let repositoryID = selectedRepositoryID,
                   let selectedCommitFile {
                    rememberedCommitFileSelections[repositoryID] = HistoryCommitFileSelection(
                        commitHash: hash,
                        path: selectedCommitFile.path
                    )
                    persistWindowState()
                }
                commitFileDiff = nil
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

    func selectCommitFile(_ file: GitCommitFile) {
        guard selectedCommitDetail?.files.contains(file) == true else { return }
        selectedCommitFile = file
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
        Task { await loadSelectedCommitDiff() }
    }

    func loadSelectedCommitDiff() async {
        guard let repository = selectedRepository,
              let repositoryURL = repositoryURL(for: repository),
              let hash = selectedCommitHash,
              let file = selectedCommitFile else {
            commitFileDiff = nil
            return
        }
        let requestID = UUID()
        commitDiffRequestID = requestID
        isLoadingCommitDiff = true
        commitDiffErrorMessage = nil
        do {
            let diff = try await gitRepositoryReader.fileDiff(
                repositoryURL: repositoryURL,
                target: .commit(hash: hash, file: file),
                ignoringWhitespace: ignoresWhitespaceInDiff
            )
            guard commitDiffRequestID == requestID else { return }
            commitFileDiff = diff
        } catch {
            guard commitDiffRequestID == requestID else { return }
            commitDiffErrorMessage = error.localizedDescription
        }
        guard commitDiffRequestID == requestID else { return }
        commitDiffRequestID = nil
        isLoadingCommitDiff = false
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
        pendingSourceLine = line
        selectFile(fileURL)
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

    func selectHistoryAuthorFilter(_ author: String?) {
        historyAuthorFilter = author
        if let repositoryID = selectedRepositoryID {
            rememberedHistoryAuthorFilters[repositoryID] = author
            rememberedCommitHashes[repositoryID] = nil
        }
        resetHistorySelectionAndReload()
    }

    private var historyRevision: String? {
        switch historyBranchFilter {
        case .current: nil
        case .all: "--all"
        case .branch(let name): name
        }
    }

    private func resetHistorySelectionAndReload() {
        commitHistory = []
        selectedCommitHash = nil
        selectedCommitDetail = nil
        selectedCommitFile = nil
        commitFileDiff = nil
        if let repositoryID = selectedRepositoryID {
            rememberedCommitFileSelections[repositoryID] = nil
        }
        historyErrorMessage = nil
        commitErrorMessage = nil
        persistWindowState()
        Task { await loadHistory() }
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
        guard runningTaskID == nil, mavenExecution.runningRequestID == nil else { return }
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
        }
        do {
            try mavenSettingsStore.save(settings, for: workspaceURL)
            mavenSettingsErrorMessage = nil
        } catch {
            mavenSettingsErrorMessage = error.localizedDescription
        }
        if previousPolicy != settings.runHistoryPolicy {
            mavenRunHistoryStore.applyPolicy(settings.runHistoryPolicy, for: workspaceURL)
            recentMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
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
        guard runningTaskID == nil,
              mavenExecution.runningRequestID == nil,
              let workspaceURL else { return }
        let runID = UUID()
        let repositoryURL = request.command.workingDirectoryURL.standardizedFileURL
        let startedAt = Date()
        mavenRunID = runID
        let resolvedTask = ResolvedRepoTask(
            definitionID: request.id,
            name: "Maven \(request.goal.rawValue)",
            executableURL: request.command.executableURL,
            arguments: request.command.arguments,
            workingDirectoryURL: request.command.workingDirectoryURL,
            environment: request.command.environment,
            confirmation: request.requiresConfirmation ? .required : .none
        )
        mavenExecution = MavenExecutionPresentation(
            runningRequestID: request.id,
            log: "$ \(request.command.displayComponents.joined(separator: " "))\n\n",
            terminationStatus: nil,
            duration: nil,
            finishedAt: nil,
            errorMessage: nil
        )
        let outputBuffer = StreamingTaskOutputBuffer()

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await taskRunner.run(resolvedTask) { chunk in
                    guard outputBuffer.append(chunk.text) else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(32))
                        guard self?.mavenRunID == runID else {
                            _ = outputBuffer.take()
                            return
                        }
                        let pending = outputBuffer.take()
                        if !pending.isEmpty {
                            self?.mavenExecution.log.append(pending)
                        }
                    }
                }
                guard mavenRunID == runID else { return }
                mavenExecution.log.append(outputBuffer.take())
                mavenRunID = nil
                mavenExecution.runningRequestID = nil
                mavenExecution.terminationStatus = result.terminationStatus
                mavenExecution.duration = result.duration
                mavenExecution.finishedAt = result.finishedAt
                recordMavenRun(
                    request,
                    repositoryURL: repositoryURL,
                    workspaceURL: workspaceURL,
                    terminationStatus: result.terminationStatus,
                    startedAt: result.startedAt,
                    finishedAt: result.finishedAt
                )
            } catch {
                guard mavenRunID == runID else { return }
                mavenExecution.log.append(outputBuffer.take())
                mavenRunID = nil
                mavenExecution.runningRequestID = nil
                mavenExecution.errorMessage = error.localizedDescription
                mavenExecution.log.append("\nMaven 执行失败：\(error.localizedDescription)\n")
                let finishedAt = Date()
                mavenExecution.duration = finishedAt.timeIntervalSince(startedAt)
                mavenExecution.finishedAt = finishedAt
                recordMavenRun(
                    request,
                    repositoryURL: repositoryURL,
                    workspaceURL: workspaceURL,
                    terminationStatus: nil,
                    startedAt: startedAt,
                    finishedAt: finishedAt
                )
            }
        }
    }

    func stopMaven() {
        Task { await taskRunner.stop() }
    }

    func clearMavenLog() {
        mavenExecution.log = ""
    }

    func removeMavenRun(_ id: MavenRunRecord.ID) {
        guard let workspaceURL else { return }
        mavenRunHistoryStore.remove(runID: id, for: workspaceURL)
        recentMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
    }

    func clearPersistedMavenLogs() {
        guard let workspaceURL else { return }
        mavenRunHistoryStore.clearPersistedLogs(for: workspaceURL)
        recentMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
    }

    func clearMavenRunHistory() {
        guard let workspaceURL else { return }
        mavenRunHistoryStore.clearHistory(for: workspaceURL)
        recentMavenRuns = []
    }

    private func recordMavenRun(
        _ request: MavenRunRequest,
        repositoryURL: URL,
        workspaceURL: URL,
        terminationStatus: Int32?,
        startedAt: Date,
        finishedAt: Date
    ) {
        let record = MavenRunRecord(
            repositoryURL: repositoryURL,
            module: request.module,
            goal: request.goal,
            command: request.command,
            terminationStatus: terminationStatus,
            startedAt: startedAt,
            finishedAt: finishedAt,
            log: mavenExecution.log
        )
        mavenRunHistoryStore.record(
            record,
            for: workspaceURL,
            policy: mavenSettings.runHistoryPolicy
        )
        recentMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
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
        recentMavenRuns = mavenRunHistoryStore.recentRuns(for: workspaceURL)
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
                ignoresWhitespaceInDiff: ignoresWhitespaceInDiff
            )
        )
    }

    func removeRepository(_ id: RegisteredRepository.ID) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
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
            migrateRepositoryWindowState(from: id, to: relocatedRepository.id)
            repositorySnapshots[id] = nil
            repositorySnapshotErrors[id] = nil
            refreshingRepositoryIDs.remove(id)
            if selectedRepositoryID == id {
                selectedRepositoryID = relocatedRepository.id
                historyBranchFilter = rememberedHistoryBranchFilters[relocatedRepository.id] ?? .current
                historyAuthorFilter = rememberedHistoryAuthorFilters[relocatedRepository.id]
                selectedCommitHash = rememberedCommitHashes[relocatedRepository.id]
                loadTaskCatalog()
            }
            if selectedChangeRepositoryID == id {
                selectedChangeRepositoryID = relocatedRepository.id
            }
            if case .repository(let contextID) = navigationContext, contextID == id {
                navigationContext = .repository(relocatedRepository.id)
            }
            if let previousRepositoryURL {
                mavenProjectRevisions[previousRepositoryURL.standardizedFileURL.path] = nil
            }
            mavenProjectRevisions[repositoryURL.standardizedFileURL.path, default: 0] += 1
            persistRepositoryState()
            persistWindowState()
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
    }

    private func loadRepositoryState(for workspaceURL: URL) {
        let state = repositoryStore.state(for: workspaceURL)
        repositories = state.repositories
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
                selectedRepositoryID: selectedRepositoryID
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

    private func repositoryURL(for repository: RegisteredRepository) -> URL? {
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
        to newID: RegisteredRepository.ID
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
        documentRequestID = nil
        documentText = ""
        documentOriginalText = ""
        isLoadingDocument = false
        isSavingDocument = false
        showsMarkdownPreview = false
        pendingFileSelectionURL = nil
        showsDiscardAndReloadConfirmation = false
        hasDocumentConflict = false
        documentSaveErrorMessage = nil
        lastDocumentSavedAt = nil
        pendingWorkspaceURL = nil
        showsDiscardAndCloseWorkspaceConfirmation = false
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
        let sections = isWorkspaceContext ? AppSection.workspaceSections : AppSection.repositorySections
        selectedSection = sections.contains(state.selectedSection) ? state.selectedSection : sections[0]
        changesRepositoryScopeID = state.changesRepositoryScopeID.flatMap { id in
            repositories.contains(where: { $0.id == id }) ? id : nil
        }
        changesGrouping = state.changesGrouping
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
        }
        selectedCommitHash = selectedRepositoryID.flatMap {
            state.selectedCommitHashesByRepository[$0]
        }
        historyVerticalSplitFraction = state.historyVerticalSplitFraction
        historyHorizontalSplitFraction = state.historyHorizontalSplitFraction
        if let path = state.selectedFilePath {
            selectFile(URL(fileURLWithPath: path))
            if URL(fileURLWithPath: path).pathExtension.lowercased() == "md" {
                showsMarkdownPreview = state.selectedFileShowsMarkdownPreview
                persistWindowState()
            }
        }
    }

    private func persistWindowState() {
        guard let workspaceURL else { return }
        windowStateStore.save(
            WorkspaceWindowState(
                selectedSection: selectedSection,
                selectedFilePath: selectedFileURL?.path,
                selectedFileShowsMarkdownPreview: showsMarkdownPreview,
                selectedChangesByRepository: rememberedChangeSelections,
                selectedChangeRepositoryID: selectedChangeRepositoryID,
                historyBranchFiltersByRepository: rememberedHistoryBranchFilters,
                historyAuthorFiltersByRepository: rememberedHistoryAuthorFilters,
                selectedCommitHashesByRepository: rememberedCommitHashes,
                selectedCommitFilesByRepository: rememberedCommitFileSelections,
                mavenSelectionsByRepository: rememberedMavenSelections,
                changesRepositoryScopeID: changesRepositoryScopeID,
                changesGrouping: changesGrouping,
                navigationRepositoryID: isRepositoryContext ? selectedRepositoryID : nil,
                historyVerticalSplitFraction: historyVerticalSplitFraction,
                historyHorizontalSplitFraction: historyHorizontalSplitFraction
            ),
            for: workspaceURL
        )
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
    func discoverRepositories(in workspaceURL: URL) async -> [RegisteredRepository] { [] }
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

@MainActor
private final class PreviewWindowStateStore: WindowStateStoring {
    func state(for workspaceURL: URL) -> WorkspaceWindowState { .initial }
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {}
}
