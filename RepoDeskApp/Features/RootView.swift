import AppKit
import SwiftUI

struct RepositorySnapshotTaskID: Equatable {
    let workspacePath: String?
    let repositoryIDs: [RegisteredRepository.ID]
}

private extension View {
    func repoDeskToolbarControlChrome() -> some View {
        padding(.horizontal, 10)
            .frame(height: 28)
            .background(.quaternary, in: .capsule)
            .overlay {
                Capsule()
                    .stroke(.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

struct WorkspaceMonitorTaskID: Equatable {
    let workspacePath: String?
    let isEnabled: Bool
}

@MainActor
struct RootView: View {
    @Bindable var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasOpenedFiles = false
    @State private var showsFileSearch = false
    @State private var showsFullTextSearch = false
    @State private var showsPushSheet = false
    @State private var showsRepositoryPicker = false
    @State private var showsBranchPicker = false
    @State private var repositoryQuery = ""
    @State private var branchQuery = ""
    @State private var branchToRename: GitBranch?
    @State private var branchToDelete: GitBranch?
    @State private var branchWithOpenActions: GitBranch?
    @State private var renamedBranchName = ""
    @State private var showsStashMessagePrompt = false
    @State private var stashMessage = ""
    @State private var stashToDelete: GitStash?
    @State private var showsJavaSymbolSearch = false
    @State private var javaSymbolSearchScope = JavaSymbolSearchScope.types

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(appState: appState)
                .repoDeskFontSize(appState.sidebarFontSize)
        } detail: {
            VStack(spacing: 0) {
                if appState.workspace != nil {
                    sectionNavigationBar
                    Divider()
                    if let message = appState.branchOperationStatusMessage {
                        GitOperationStatusBand(
                            tint: .blue,
                            systemImage: "info.circle.fill",
                            title: message,
                            dismiss: { appState.branchOperationStatusMessage = nil }
                        ) { EmptyView() }
                        .accessibilityIdentifier("RepoDesk.BranchOperation.Status")
                        Divider()
                    }
                    if appState.gitRemoteOperationState != .idle {
                        GitRemoteOperationStatusView(
                            state: appState.gitRemoteOperationState,
                            retry: {
                                Task { await appState.retryGitRemoteOperation() }
                            },
                            dismiss: appState.dismissGitRemoteOperationResult
                        )
                        Divider()
                    }
                }

                Group {
                    if let workspace = appState.workspace {
                        if workspace.isAvailable {
                            sectionContent
                        } else {
                            ContentUnavailableView {
                                Label("Workspace 不可用", systemImage: "externaldrive.badge.exclamationmark")
                            } description: {
                                Text("\(workspace.path) 已被移动、重命名或删除。")
                            } actions: {
                                Button("重新选择 Workspace…", systemImage: "folder.badge.questionmark") {
                                    appState.chooseWorkspace()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(appState.isGitWriteOperationRunning)
                                Button("关闭 Workspace") {
                                    appState.closeWorkspace()
                                }
                                .disabled(appState.isGitWriteOperationRunning)
                            }
                        }
                    } else {
                        WorkspaceWelcomeView(openWorkspace: appState.chooseWorkspace)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .repoDeskFontSize(appState.interfaceFontSize)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $appState.isShowingDiscoveryResults) {
            RepositoryDiscoverySheet(
                repositories: appState.discoveredRepositories,
                register: appState.registerDiscoveredRepositories
            )
        }
        .sheet(isPresented: $showsFileSearch) {
            FileNameSearchSheet(appState: appState)
        }
        .sheet(isPresented: $showsFullTextSearch) {
            FullTextSearchSheet(appState: appState)
        }
        .sheet(isPresented: $showsJavaSymbolSearch) {
            JavaSymbolSearchSheet(appState: appState, initialScope: javaSymbolSearchScope)
        }
        .sheet(isPresented: $showsPushSheet) {
            GitPushSheet(appState: appState)
        }
        .sheet(isPresented: branchComparisonPresented) {
            if let comparison = appState.branchComparison {
                BranchComparisonSheet(comparison: comparison) { appState.branchComparison = nil }
            }
        }
        .sheet(isPresented: mergeConflictPresented) {
            MergeConflictResolverSheet(appState: appState)
        }
        .alert("Rename Branch", isPresented: renameBranchPresented) {
            TextField("新的 Branch 名称", text: $renamedBranchName)
            Button("取消", role: .cancel) { branchToRename = nil }
            Button("Rename") {
                guard let branch = branchToRename else { return }
                Task { await appState.renameBranch(branch, to: renamedBranchName) }
                branchToRename = nil
            }
        } message: {
            Text(branchToRename.map { "将 '\($0.name)' 重命名" } ?? "")
        }
        .alert("Delete Branch", isPresented: deleteBranchPresented) {
            Button("取消", role: .cancel) { branchToDelete = nil }
            Button("Delete", role: .destructive) {
                guard let branch = branchToDelete else { return }
                Task { await appState.deleteBranch(branch) }
                branchToDelete = nil
            }
        } message: {
            Text(branchToDelete.map { "安全删除 '\($0.name)'。未合并的 Branch 不会被删除。" } ?? "")
        }
        .alert("暂存改动", isPresented: $showsStashMessagePrompt) {
            TextField("备注（可选）", text: $stashMessage)
            Button("取消", role: .cancel) { stashMessage = "" }
            Button("暂存") {
                let message = stashMessage
                stashMessage = ""
                Task { await appState.stashChanges(message: message) }
            }
        } message: {
            Text("当前 Repository 的已跟踪和未跟踪改动都会被暂存。")
        }
        .alert("删除暂存？", isPresented: stashDeletePresented) {
            Button("取消", role: .cancel) { stashToDelete = nil }
            Button("删除", role: .destructive) {
                guard let stash = stashToDelete else { return }
                stashToDelete = nil
                Task { await appState.dropStash(stash) }
            }
        } message: {
            Text(stashToDelete.map { "将删除 \($0.reference) · \($0.message)，此操作无法撤销。" } ?? "")
        }
        .alert(item: $appState.presentedRepositoryError) { error in
            Alert(
                title: Text("Repository 操作失败"),
                message: Text(error.localizedDescription),
                dismissButton: .default(Text("确定"))
            )
        }
        .alert("打开另一个 Workspace？", isPresented: pendingWorkspaceAlertBinding) {
            Button("继续编辑", role: .cancel) {
                appState.cancelPendingWorkspaceOpen()
            }
            Button("放弃改动并打开", role: .destructive) {
                appState.discardChangesAndOpenPendingWorkspace()
            }
        } message: {
            Text("当前文件还有未保存的改动。")
        }
        .alert(
            "关闭 Workspace？",
            isPresented: $appState.showsDiscardAndCloseWorkspaceConfirmation
        ) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃改动并关闭", role: .destructive) {
                appState.discardChangesAndCloseWorkspace()
            }
        } message: {
            Text("当前文件还有未保存的改动。")
        }
        .alert("磁盘文件已变化", isPresented: $appState.hasDocumentConflict) {
            Button("取消", role: .cancel) {}
            Button("从磁盘重新加载", role: .destructive) {
                appState.discardChangesAndReload()
            }
            Button("覆盖磁盘文件") {
                Task { await appState.saveSelectedDocument(allowsOverwrite: true) }
            }
        } message: {
            Text("RepoDesk 打开文件后，另一个进程修改了它。请重新加载或明确覆盖磁盘版本。")
        }
        .alert("文件无法保存", isPresented: saveErrorAlertBinding) {
            Button("确定", role: .cancel) {
                appState.documentSaveErrorMessage = nil
            }
        } message: {
            Text(appState.documentSaveErrorMessage ?? "未知错误")
        }
        .alert("Maven 配置无法保存", isPresented: mavenSettingsErrorAlertBinding) {
            Button("确定", role: .cancel) {
                appState.mavenSettingsErrorMessage = nil
            }
        } message: {
            Text(appState.mavenSettingsErrorMessage ?? "未知错误")
        }
        .alert("无法跳转到源文件", isPresented: jumpToSourceAlertBinding) {
            Button("确定", role: .cancel) { appState.jumpToSourceErrorMessage = nil }
        } message: {
            Text(appState.jumpToSourceErrorMessage ?? "文件不可用")
        }
        .alert("Git 操作失败", isPresented: gitOperationErrorAlertBinding) {
            Button("确定", role: .cancel) { appState.branchOperationErrorMessage = nil }
        } message: {
            Text(appState.branchOperationErrorMessage ?? "未知错误")
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                repositoryNavigationControls
            }
            ToolbarItem(placement: .principal) {
                JavaIndexStatusView(appState: appState)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task {
                        if appState.selectedSection == .overview || appState.selectedSection == .changes {
                            await appState.refreshAllRepositories()
                        } else {
                            await appState.refreshWorkspaceConsistency()
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(appState.workspace == nil || appState.isGitWriteOperationRunning)
                .keyboardShortcut(appState.shortcut(for: .refresh).keyEquivalent, modifiers: appState.shortcut(for: .refresh).eventModifiers)
                .help("刷新 Repository 和文件状态")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("文件名搜索", systemImage: "doc.text.magnifyingglass") {
                    showsFileSearch = true
                }
                .labelStyle(.iconOnly)
                .disabled(appState.workspace == nil)
                .help("文件名搜索（双击 Shift）")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("全文检索", systemImage: "text.magnifyingglass") {
                    showsFullTextSearch = true
                }
                .keyboardShortcut(appState.shortcut(for: .fullTextSearch).keyEquivalent, modifiers: appState.shortcut(for: .fullTextSearch).eventModifiers)
                .labelStyle(.iconOnly)
                .disabled(appState.workspace == nil)
                .help("全文检索（Command+Shift+F）")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .help("设置")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("工作区", systemImage: "folder") {
                    Button("打开 Workspace…", systemImage: "folder.badge.plus") {
                        appState.chooseWorkspace()
                    }
                    .disabled(appState.isGitWriteOperationRunning)

                    Button("关闭 Workspace", systemImage: "xmark.circle") {
                        appState.closeWorkspace()
                    }
                    .disabled(appState.workspace == nil || appState.isGitWriteOperationRunning)

                    Button("查看诊断日志", systemImage: "doc.text.magnifyingglass") {
                        revealDiagnosticLog()
                    }

                    if !appState.recentWorkspaces.isEmpty {
                        Divider()
                        Section("最近的 Workspace") {
                            ForEach(appState.recentWorkspaces) { workspace in
                                Button(workspace.name) {
                                    appState.openRecentWorkspace(workspace)
                                }
                                .disabled(appState.isGitWriteOperationRunning)
                            }
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .help("工作区")
            }
        }
        .task(id: appState.selectedRepositoryID) {
            async let snapshot: Void = appState.monitorCurrentRepository()
            async let branches: Void = appState.loadBranches()
            async let stashes: Void = appState.loadStashes()
            _ = await (snapshot, branches, stashes)
        }
        .task(id: workspaceMonitorTaskID) {
            guard appState.automaticallyRefreshesWorkspace else { return }
            await appState.monitorWorkspace()
        }
        .task(id: repositorySnapshotTaskID) {
            await ensureWorkspaceRepositorySnapshots()
        }
        .task(id: appState.branchOperationStatusMessage) {
            guard let message = appState.branchOperationStatusMessage else { return }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            if appState.branchOperationStatusMessage == message {
                appState.branchOperationStatusMessage = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, appState.refreshesWhenBecomingActive {
                appState.refreshAfterReturningToForeground()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoDeskFileSearchRequested)) { _ in
            guard appState.workspace != nil else { return }
            showsFullTextSearch = false
            showsFileSearch = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoDeskJavaTypeSearchRequested)) { _ in
            guard appState.workspace != nil else { return }
            javaSymbolSearchScope = .types
            showsJavaSymbolSearch = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoDeskJavaSymbolSearchRequested)) { _ in
            guard appState.workspace != nil else { return }
            javaSymbolSearchScope = .all
            showsJavaSymbolSearch = true
        }
    }

    private var gitOperationsButton: some View {
        Menu {
            Button {
                Task { await appState.performGitRemoteOperation(.fetch) }
            } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                Task { await appState.performGitRemoteOperation(.pull) }
            } label: {
                Label("Pull", systemImage: "arrow.down.circle")
            }
            Button {
                showsPushSheet = true
            } label: {
                Label("Push", systemImage: "arrow.up.circle")
            }
            Divider()
            Button {
                showsStashMessagePrompt = true
            } label: {
                Label("暂存改动…", systemImage: "archivebox")
            }
            Menu {
                if appState.gitStashes.isEmpty {
                    Text(appState.stashesErrorMessage ?? "没有可恢复的暂存")
                } else {
                    ForEach(appState.gitStashes) { stash in
                        Menu {
                            Button {
                                Task { await appState.unstashChanges(stash) }
                            } label: {
                                Label("恢复暂存", systemImage: "tray.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                stashToDelete = stash
                            } label: {
                                Label("删除暂存", systemImage: "trash")
                            }
                        } label: {
                            Text("\(stash.reference)  \(stash.message)")
                        }
                    }
                }
                Divider()
                Button {
                    Task { await appState.loadStashes() }
                } label: {
                    Label("刷新暂存列表", systemImage: "arrow.clockwise")
                }
            } label: {
                Label("恢复暂存", systemImage: "tray.and.arrow.down")
            }
        } label: {
            Text("Git")
                .fontWeight(.semibold)
                .repoDeskToolbarControlChrome()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(appState.selectedRepository == nil || appState.isGitWriteOperationRunning)
        .help(gitOperationsHelp)
        .accessibilityIdentifier("RepoDesk.GitOperations")
        .accessibilityLabel("Git 操作")
    }

    private var gitOperationsHelp: String {
        switch appState.gitRemoteOperationState {
        case .running(let context):
            "正在 \(context.kind.rawValue) \(context.repositoryName)"
        case .requiresConflictResolution:
            "Pull 需要解决冲突"
        default:
            "Git 操作"
        }
    }

    private var gitOperationErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.branchOperationErrorMessage != nil },
            set: { if !$0 { appState.branchOperationErrorMessage = nil } }
        )
    }

    private var stashDeletePresented: Binding<Bool> {
        Binding(
            get: { stashToDelete != nil },
            set: { if !$0 { stashToDelete = nil } }
        )
    }

    var repositorySnapshotTaskID: RepositorySnapshotTaskID {
        RepositorySnapshotTaskID(
            workspacePath: appState.workspace?.path,
            repositoryIDs: appState.repositories.map(\.id)
        )
    }

    var workspaceMonitorTaskID: WorkspaceMonitorTaskID {
        WorkspaceMonitorTaskID(
            workspacePath: appState.workspace?.path,
            isEnabled: appState.automaticallyRefreshesWorkspace
        )
    }

    func ensureWorkspaceRepositorySnapshots() async {
        await appState.ensureRepositorySnapshots()
    }

    private var sectionNavigationBar: some View {
        HStack(spacing: 4) {
            ForEach(appState.availableSections) { section in
                sectionNavigationButton(section)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sectionNavigationButton(_ section: AppSection) -> some View {
        let isSelected = appState.selectedSection == section
        return Button {
            appState.selectSection(section)
        } label: {
            Text(section.displayName)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(
                    isSelected ? Color.accentColor.opacity(0.12) : .clear,
                    in: .rect(cornerRadius: 5)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(
            appState.shortcut(for: shortcutID(for: section)).keyEquivalent,
            modifiers: appState.shortcut(for: shortcutID(for: section)).eventModifiers
        )
        .help("\(section.displayName) (\(appState.shortcut(for: shortcutID(for: section)).displayName))")
        .accessibilityValue(isSelected ? "已选择" : "")
    }

    private func shortcutID(for section: AppSection) -> AppShortcutID {
        let index = appState.availableSections.firstIndex(of: section) ?? 0
        return [.section1, .section2, .section3, .section4][min(index, 3)]
    }

    @ViewBuilder
    private var sectionContent: some View {
        if appState.isRepositoryContext,
           let repository = appState.selectedRepository,
           let message = appState.repositoryUnavailableMessage(for: repository) {
            ContentUnavailableView {
                Label("Repository 不可用", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重新定位 Repository…", systemImage: "folder.badge.questionmark") {
                    appState.relocateRepository(repository.id)
                }
                .buttonStyle(.borderedProminent)
                Button("返回 Workspace") {
                    appState.selectWorkspaceContext()
                }
            }
        } else {
            ZStack {
                if hasOpenedFiles || appState.selectedSection == .files {
                    FilesView(appState: appState)
                        .id(appState.workspace?.path)
                        .opacity(appState.selectedSection == .files ? 1 : 0)
                        .disabled(appState.selectedSection != .files)
                        .allowsHitTesting(appState.selectedSection == .files)
                        .accessibilityHidden(appState.selectedSection != .files)
                        .onAppear { hasOpenedFiles = true }
                }
                if appState.selectedSection != .files {
                    nonFilesSectionContent
                }
            }
        }
    }

    @ViewBuilder
    private var nonFilesSectionContent: some View {
        switch appState.selectedSection {
        case .overview: RepositoryOverviewView(appState: appState)
        case .changes: ChangesView(appState: appState)
        case .files: EmptyView()
        case .history: HistoryView(appState: appState)
        case .tasks:
            if let workspaceURL = visibleWorkspaceURL {
                MavenView(
                    workspaceURL: workspaceURL,
                    repositoryURL: selectedRepositoryURL,
                    settings: Binding(
                        get: { appState.mavenSettings },
                        set: { appState.updateMavenSettings($0) }
                    ),
                    projectRevision: appState.mavenProjectRevision(for: selectedRepositoryURL),
                    validationStore: appState.mavenEnvironmentValidationStore,
                    execution: appState.mavenExecution,
                    recentRuns: appState.recentMavenRuns,
                    run: { appState.runMaven($0) },
                    stop: { appState.stopMaven() },
                    clearLog: { appState.clearMavenLog() },
                    removeRun: { appState.removeMavenRun($0) },
                    clearPersistedLogs: { appState.clearPersistedMavenLogs() },
                    clearHistory: { appState.clearMavenRunHistory() },
                    queueMessage: appState.mavenQueueMessage,
                    duplicateMessage: { appState.mavenQueue.duplicateMessage(for: $0, repositoryURL: $1) },
                    persistedSelection: selectedMavenRepositoryID.flatMap {
                        appState.mavenSelection(for: $0)
                    },
                    updatePersistedSelection: { selection in
                        guard let repositoryID = selectedMavenRepositoryID else { return }
                        appState.updateMavenSelection(selection, for: repositoryID)
                    }
                )
            } else {
                ContentUnavailableView("没有工作区", systemImage: "folder")
            }
        }
    }

    private func sectionShortcutNumber(for section: AppSection) -> Int {
        (appState.availableSections.firstIndex(of: section) ?? 0) + 1
    }

    private var repositoryContextButton: some View {
        Button {
            showsBranchPicker = false
            repositoryQuery = ""
            showsRepositoryPicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(repositoryContextTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .fontWeight(.semibold)
            .frame(maxWidth: 280)
            .repoDeskToolbarControlChrome()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(appState.workspace == nil)
        .help("切换工作区范围或 Git 仓库")
        .accessibilityIdentifier("RepoDesk.RepositoryContextPicker")
        .accessibilityLabel("Git 仓库")
        .accessibilityValue(repositoryContextTitle)
        .popover(isPresented: $showsRepositoryPicker, arrowEdge: .bottom) {
            repositoryPickerPopover
        }
    }

    private var repositoryPickerPopover: some View {
        SearchableFilterPopover(
            query: $repositoryQuery,
            placeholder: "搜索 Git 仓库",
            autoFocus: true
        ) {
            repositoryPickerRow(
                title: "全部 Git 仓库",
                isSelected: appState.isWorkspaceContext
            ) {
                showsRepositoryPicker = false
                appState.selectWorkspaceContext()
            }

            if !appState.repositories.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                ForEach(filteredRepositories) { repository in
                    repositoryPickerRow(
                        title: repository.name,
                        isSelected: appState.isRepositoryContext
                            && appState.selectedRepositoryID == repository.id
                    ) {
                        showsRepositoryPicker = false
                        appState.selectRepositoryContext(repository.id)
                    }
                }

                if filteredRepositories.isEmpty {
                    Text("没有匹配的 Git 仓库")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                }
            }
        }
    }

    private func repositoryPickerRow(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .contentShape(.rect)
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
    }

    private var selectedMavenRepositoryID: RegisteredRepository.ID? {
        appState.isRepositoryContext ? appState.selectedRepositoryID : nil
    }

    private var filteredRepositories: [RegisteredRepository] {
        FuzzySearch.filteredAndSorted(
            appState.repositories,
            query: repositoryQuery,
            text: \.name
        )
    }

    private var repositoryNavigationControls: some View {
        HStack(spacing: 8) {
            repositoryContextButton
            if appState.isRepositoryContext {
                branchPickerButton
                gitOperationsButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var branchPickerButton: some View {
        Button {
            branchQuery = ""
            appState.branchSwitchErrorMessage = nil
            showsBranchPicker.toggle()
            if showsBranchPicker {
                Task { await appState.loadBranches() }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentBranchTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .repoDeskToolbarControlChrome()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(appState.selectedRepository == nil)
        .help("切换 Git Branch")
        .accessibilityIdentifier("RepoDesk.BranchPicker")
        .popover(isPresented: $showsBranchPicker, arrowEdge: .bottom) {
            branchPickerPopover
        }
        .onChange(of: showsBranchPicker) { _, isPresented in
            if !isPresented { branchWithOpenActions = nil }
        }
    }

    private var branchPickerPopover: some View {
        SearchableFilterPopover(query: $branchQuery, placeholder: "搜索 Branch", width: 400) {
            if appState.isLoadingBranches {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在加载 Branch…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            if let error = appState.branchOperationErrorMessage ?? appState.branchSwitchErrorMessage ?? appState.branchesErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            if !filteredLocalBranches.isEmpty {
                branchSectionTitle("本地 Branch", systemImage: "folder")
                ForEach(filteredLocalBranches) { branch in
                    branchOption(branch)
                }
            }
            if !filteredRemoteBranches.isEmpty {
                branchSectionTitle("远程 Branch", systemImage: "cloud")
                ForEach(filteredRemoteBranches) { branch in
                    branchOption(branch)
                }
            }
            if !appState.isLoadingBranches,
               filteredLocalBranches.isEmpty,
               filteredRemoteBranches.isEmpty,
               appState.branchesErrorMessage == nil {
                Text("没有匹配的 Branch")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            }
        }
    }

    private func branchOption(_ branch: GitBranch) -> some View {
        Button {
            branchWithOpenActions = branchWithOpenActions?.id == branch.id ? nil : branch
        } label: {
            HStack(spacing: 7) {
                Image(systemName: branch.isCurrent ? "checkmark" : "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 13)
                Image(systemName: branch.isRemote ? "cloud.fill" : "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(branch.isRemote ? Color.blue : Color.secondary)
                    .frame(width: 15)
                Text(branch.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .background(BranchNameHoverHint(text: branch.name))
                Spacer(minLength: 7)
                if !branch.isRemote, let upstream = branch.upstream, !upstream.isEmpty {
                    Text(upstream)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 130, alignment: .trailing)
                        .background(BranchNameHoverHint(text: upstream))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 24)
            .padding(.trailing, 8)
            .frame(height: max(27, appState.interfaceFontSize + 12))
            .background(
                branchWithOpenActions?.id == branch.id
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(appState.isGitWriteOperationRunning)
        .popover(
            isPresented: branchActionsPresented(for: branch),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .trailing
        ) {
            branchActionsPopover(branch)
        }
    }

    private func branchActionsPopover(_ branch: GitBranch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if branch.isRemote {
                branchAction("Checkout", systemImage: "arrow.right.circle") {
                    closeBranchPopovers()
                    Task { _ = await appState.switchBranch(branch) }
                }
                branchAction("Compare With '\(currentBranchTitle)'", systemImage: "arrow.left.arrow.right") {
                    closeBranchPopovers()
                    Task { await appState.compareBranch(branch) }
                }
            } else {
                if !branch.isCurrent {
                    branchAction("Checkout", systemImage: "arrow.right.circle") {
                        closeBranchPopovers()
                        Task { _ = await appState.switchBranch(branch) }
                    }
                    branchAction("Merge '\(branch.name)' into '\(currentBranchTitle)'", systemImage: "arrow.triangle.merge") {
                        closeBranchPopovers()
                        Task { await appState.mergeBranch(branch) }
                    }
                    Divider().padding(.vertical, 3)
                }
                branchAction("Pull", systemImage: "arrow.down.circle") {
                    closeBranchPopovers()
                    Task { await appState.pullBranch(branch) }
                }
                .disabled(appState.isGitWriteOperationRunning)
                .accessibilityIdentifier("RepoDesk.Branch.Pull")
                branchAction("Push", systemImage: "arrow.up.circle") {
                    closeBranchPopovers()
                    Task { await appState.pushBranch(branch) }
                }
                branchAction("Rename", systemImage: "pencil") {
                    closeBranchPopovers()
                    renamedBranchName = branch.name
                    branchToRename = branch
                }
                if !branch.isCurrent {
                    Divider().padding(.vertical, 3)
                    branchAction("Delete", systemImage: "trash", role: .destructive) {
                        closeBranchPopovers()
                        branchToDelete = branch
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 310)
    }

    private func branchAction(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 27)
    }

    private func branchActionsPresented(for branch: GitBranch) -> Binding<Bool> {
        Binding(
            get: { branchWithOpenActions?.id == branch.id },
            set: { isPresented in
                if isPresented {
                    branchWithOpenActions = branch
                } else if branchWithOpenActions?.id == branch.id {
                    branchWithOpenActions = nil
                }
            }
        )
    }

    private func closeBranchPopovers() {
        branchWithOpenActions = nil
        showsBranchPicker = false
    }

    private var branchComparisonPresented: Binding<Bool> {
        Binding(
            get: { appState.branchComparison != nil },
            set: { if !$0 { appState.branchComparison = nil } }
        )
    }

    private var mergeConflictPresented: Binding<Bool> {
        Binding(
            get: { appState.mergeSourceBranch != nil },
            set: { _ in }
        )
    }

    private var renameBranchPresented: Binding<Bool> {
        Binding(get: { branchToRename != nil }, set: { if !$0 { branchToRename = nil } })
    }

    private var deleteBranchPresented: Binding<Bool> {
        Binding(get: { branchToDelete != nil }, set: { if !$0 { branchToDelete = nil } })
    }

    private func branchSectionTitle(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .frame(width: 10)
            Image(systemName: systemImage)
                .font(.caption)
            Text(title)
                .font(.system(
                    size: max(9, appState.interfaceFontSize - 2),
                    weight: .semibold
                ))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }

    private var filteredLocalBranches: [GitBranch] {
        FuzzySearch.filteredAndSorted(
            appState.branches.filter { !$0.isRemote },
            query: branchQuery,
            text: \.name
        )
    }

    private var filteredRemoteBranches: [GitBranch] {
        FuzzySearch.filteredAndSorted(
            appState.branches.filter { $0.isRemote && !$0.name.hasSuffix("/HEAD") },
            query: branchQuery,
            text: \.name
        )
    }

    private var currentBranchTitle: String {
        guard let repositoryID = appState.selectedRepositoryID else { return "未选择 Branch" }
        if let snapshot = appState.repositorySnapshots[repositoryID] {
            return snapshot.isDetachedHEAD ? "Detached HEAD" : snapshot.branch
        }
        return appState.branches.first(where: \.isCurrent)?.name
            ?? (appState.isLoadingBranches ? "正在加载 Branch" : "当前 Branch")
    }

    private var repositoryContextTitle: String {
        if appState.isRepositoryContext, let repository = appState.selectedRepository {
            return repository.name
        }
        if appState.repositories.isEmpty {
            return appState.workspace == nil ? "未打开工作区" : "未发现 Git 仓库"
        }
        return "全部 Git 仓库"
    }

    private func revealDiagnosticLog() {
        Task {
            guard let logURL = try? await AppDiagnosticLogger.shared.prepareLogFile() else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
    }

    private var visibleWorkspaceURL: URL? {
        appState.workspace.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    private var selectedRepositoryURL: URL? {
        guard appState.isRepositoryContext,
              let workspaceURL = visibleWorkspaceURL,
              let repository = appState.selectedRepository else {
            return nil
        }
        return repository.relativePath == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
    }

    private var pendingWorkspaceAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.pendingWorkspaceURL != nil },
            set: { if !$0 { appState.cancelPendingWorkspaceOpen() } }
        )
    }

    private var saveErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.documentSaveErrorMessage != nil },
            set: { if !$0 { appState.documentSaveErrorMessage = nil } }
        )
    }

    private var jumpToSourceAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.jumpToSourceErrorMessage != nil },
            set: { if !$0 { appState.jumpToSourceErrorMessage = nil } }
        )
    }

    private var mavenSettingsErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.mavenSettingsErrorMessage != nil },
            set: { if !$0 { appState.mavenSettingsErrorMessage = nil } }
        )
    }
}

private struct WorkspaceWelcomeView: View {
    let openWorkspace: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("打开 Workspace", systemImage: "folder.badge.plus")
        } description: {
            Text("选择一个工作目录，其中的 Repository 可以分别注册和管理。")
        } actions: {
            Button("打开 Workspace…", action: openWorkspace)
                .buttonStyle(.borderedProminent)
        }
    }
}
