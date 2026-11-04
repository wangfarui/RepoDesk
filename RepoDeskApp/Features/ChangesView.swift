import AppKit
import SwiftUI

private struct ChangesRollbackRequest: Identifiable {
    let id = UUID()
    let repository: RegisteredRepository
    let selections: [GitChangeSelection]
    let title: String

    var includesUntracked: Bool {
        selections.contains { $0.kind == .unversioned }
    }
}

private struct PendingDiffComparison: Equatable {
    let repositoryID: RegisteredRepository.ID
    let selection: GitChangeSelection
}

@MainActor
struct ChangesView: View {
    @Bindable var appState: AppState
    @State private var collapsedRepositoryIDs: Set<String> = []
    @State private var expandedNodeIDs: Set<String> = []
    @State private var automaticExpansionSession = ChangesAutoExpansionSession()
    @State private var contextMenuOutlineRowID: String?
    @State private var diffComparisonWindow = GitDiffWindowController(
        frameAutosaveName: "RepoDesk.GitDiffComparison"
    )
    @State private var rollbackRequest: ChangesRollbackRequest?
    @State private var pendingDiffComparison: PendingDiffComparison?
    @State private var pendingOutlineScrollID: String?
    @State private var fileSearch = ChangesFileSearch()
    @State private var arrowKeyMonitor = ChangesArrowKeyMonitor()

    var body: some View {
        let _ = prepareArrowKeyMonitor()
        Group {
            if appState.repositories.isEmpty {
                ContentUnavailableView {
                    Label("没有 Git 仓库", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("发现 Git 仓库后可查看尚未提交的改动。")
                } actions: {
                    Button("发现 Repository", systemImage: "magnifyingglass") {
                        appState.discoverRepositories()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HSplitView {
                    changeBrowser
                        .frame(minWidth: 330, idealWidth: 410, maxWidth: 580)
                    diffDetail
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: appState.repositories.map(\.id).joined(separator: "|")) {
            await appState.ensureRepositorySnapshots()
        }
        .task(id: automaticExpansionTaskID) {
            applyAutomaticExpansionIfNeeded()
        }
        .onChange(of: automaticExpansionContextID) { _, _ in
            fileSearch.resetExpansion()
        }
        .onAppear {
            arrowKeyMonitor.start()
            selectFirstChangeIfNeeded()
        }
        .onDisappear {
            automaticExpansionSession = ChangesAutoExpansionSession()
            arrowKeyMonitor.stop()
        }
        .onChange(of: changeSelectionRefreshID) { _, _ in
            selectFirstChangeIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("上一个改动", systemImage: "chevron.up") {
                    selectAdjacentChangeFromKeyboard(offset: -1)
                }
                .disabled(visibleChangeFiles().isEmpty)
                .help("上一个改动")
                Button("下一个改动", systemImage: "chevron.down") {
                    selectAdjacentChangeFromKeyboard(offset: 1)
                }
                .disabled(visibleChangeFiles().isEmpty)
                .help("下一个改动")
            }
        }
        .onChange(of: appState.selectedChange) { _, selection in
            resetDiffComparison()
            if let pendingDiffComparison,
               pendingDiffComparison.selection != selection
                || pendingDiffComparison.repositoryID != appState.selectedChangeRepositoryID {
                self.pendingDiffComparison = nil
            }
        }
        .onChange(of: appState.currentDiff) { _, diff in
            if diff == nil {
                resetDiffComparison()
                return
            }
            openPendingDiffComparisonIfReady(with: diff)
        }
        .alert(item: $rollbackRequest) { request in
            Alert(
                title: Text("Rollback \(request.title)?"),
                message: Text(
                    request.includesUntracked
                        ? "将回滚 \(request.selections.count) 项改动，并从磁盘删除其中的未跟踪文件。此操作无法撤销。"
                        : "将回滚 \(request.selections.count) 项改动，包括已暂存和未暂存内容。此操作无法撤销。"
                ),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text("Rollback")) {
                    let request = request
                    rollbackRequest = nil
                    Task {
                        await appState.rollbackChanges(
                            request.selections,
                            repositoryID: request.repository.id
                        )
                    }
                }
            )
        }
    }

    private var changeBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("刷新改动", systemImage: "arrow.clockwise") {
                    Task { await appState.refreshChangesScope() }
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .disabled(isRefreshingChangesScope)
                .help("刷新当前范围的仓库改动")

                if appState.isWorkspaceContext {
                    Picker("Repository", selection: repositoryScopeBinding) {
                        Text("全部仓库").tag(String?.none)
                        Divider()
                        ForEach(appState.repositories) { repository in
                            Text(repository.name).tag(Optional(repository.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(minWidth: 90, maxWidth: 160)
                    .help("选择一个 Repository，或同时查看全部仓库")
                }

                Menu("Group By", systemImage: "eye") {
                    Section("Group By") {
                        Toggle("Directory", isOn: groupingOptionBinding(.directory))
                            .keyboardShortcut(appState.shortcut(for: .changesGroupDirectory).keyEquivalent, modifiers: appState.shortcut(for: .changesGroupDirectory).eventModifiers)
                        Toggle("Module", isOn: groupingOptionBinding(.module))
                            .keyboardShortcut(appState.shortcut(for: .changesGroupModule).keyEquivalent, modifiers: appState.shortcut(for: .changesGroupModule).eventModifiers)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .help("Group By")

                Button("展开全部", systemImage: "arrow.up.left.and.arrow.down.right") {
                    if !fileSearch.isActive { automaticExpansionSession.recordManualInteraction() }
                    expandAllChanges()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .disabled(visibleRepositories.isEmpty)
                .help("Expand All")

                Button("折叠全部", systemImage: "arrow.down.right.and.arrow.up.left") {
                    if !fileSearch.isActive { automaticExpansionSession.recordManualInteraction() }
                    collapseAllChanges()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .disabled(visibleRepositories.isEmpty)
                .help("Collapse All")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            fileSearchField

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(browserEntries) { entry in
                            browserEntry(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: pendingOutlineScrollID) { _, scrollID in
                    guard let scrollID else { return }
                    proxy.scrollTo(scrollID)
                    pendingOutlineScrollID = nil
                }
            }
            .id(changesListIdentity)
            .background {
                ChangesWindowAnchor { window in
                    arrowKeyMonitor.window = window
                }
            }
            .overlay {
                if visibleRepositories.isEmpty, appState.refreshingRepositoryIDs.isEmpty {
                    ContentUnavailableView(
                        fileSearch.isActive ? "没有匹配的改动文件" : cleanScopeTitle,
                        systemImage: fileSearch.isActive ? "doc.text.magnifyingglass" : "checkmark.circle",
                        description: Text(fileSearch.isActive
                            ? "请尝试其他文件名，或清空搜索查看全部改动。"
                            : "当前范围内没有未提交改动。")
                    )
                }
            }

            Divider()
            commitPanel
        }
    }

    private var fileSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索改动文件名", text: $fileSearch.query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("changes.fileNameSearch")
                .help("按文件名搜索，忽略大小写")
            if !fileSearch.query.isEmpty {
                Button {
                    fileSearch.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空文件名搜索")
                .accessibilityLabel("清空文件名搜索")
            }
        }
        .padding(7)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var commitPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: commitMessageBinding)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .disabled(appState.changesCommitRepository == nil || appState.isGitWriteOperationRunning)
                if appState.changesCommitMessage.isEmpty {
                    Text(commitMessagePlaceholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 72)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            if appState.commitExecutionState != .idle {
                CommitExecutionStatusView(
                    state: appState.commitExecutionState,
                    retryCommit: { andPush in
                        Task { await appState.commitChanges(andPush: andPush) }
                    },
                    retryPush: {
                        Task { await appState.retryCommitPush() }
                    },
                    showInHistory: appState.showCommitInHistory,
                    dismiss: appState.dismissCommitExecutionResult
                )
            }

            HStack(spacing: 8) {
                Button {
                    Task { await appState.commitChanges(andPush: false) }
                } label: {
                    commitButtonLabel(pushes: false)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(appState.shortcut(for: .commit).keyEquivalent, modifiers: appState.shortcut(for: .commit).eventModifiers)
                .disabled(!appState.canCommitChanges)
                .help("提交勾选的改动")

                Button {
                    Task { await appState.commitChanges(andPush: true) }
                } label: {
                    commitButtonLabel(pushes: true)
                }
                .buttonStyle(.bordered)
                .disabled(!appState.canCommitChanges)
                .help("提交勾选的改动并 Push")

                Spacer(minLength: 0)
            }
        }
        .padding(10)
    }

    private func commitButtonLabel(pushes: Bool) -> some View {
        let isActive: Bool
        let title: String
        switch appState.commitExecutionState {
        case .committing(let context) where context.shouldPush == pushes:
            isActive = true
            title = pushes ? "正在提交…" : "正在 Commit…"
        case .pushing where pushes:
            isActive = true
            title = "正在 Push…"
        default:
            isActive = false
            title = pushes ? "Commit And Push" : "Commit"
        }
        return HStack(spacing: 6) {
            if isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: pushes ? "arrow.up.circle" : "checkmark.circle")
            }
            Text(title)
        }
        .frame(minWidth: pushes ? 132 : 78)
    }

    private var commitMessageBinding: Binding<String> {
        Binding(
            get: { appState.changesCommitMessage },
            set: { appState.updateChangesCommitMessage($0) }
        )
    }

    private var commitMessagePlaceholder: String {
        appState.changesCommitRepository == nil
            ? "选择单个 Git 仓库后输入 Commit 信息"
            : "Commit 信息"
    }

    private var browserEntries: [ChangesBrowserEntry] {
        visibleRepositories.flatMap { repository -> [ChangesBrowserEntry] in
            var entries: [ChangesBrowserEntry] = []
            let leadingInset: CGFloat = showsRepositoryGroups ? 14 : 0
            if showsRepositoryGroups {
                entries.append(.repository(repository))
                if isRepositoryCollapsed(repository.id) {
                    return entries
                }
            }
            if let message = appState.repositoryUnavailableMessage(for: repository) {
                entries.append(.unavailable(repository, message, leadingInset))
                return entries
            }
            if appState.repositorySnapshots[repository.id] == nil,
               let error = appState.repositorySnapshotErrors[repository.id] {
                entries.append(.snapshotError(repository, error, leadingInset))
                return entries
            }
            for section in statusSections(for: repository) {
                entries.append(.status(section, repository, leadingInset))
                let statusID = "repository:\(repository.id):group:\(section.kind.rawValue)"
                entries.append(contentsOf: outlineRows(
                    for: section,
                    repository: repository,
                    statusID: statusID
                ).map { row in
                    .outline(row, repository, section.kind, leadingInset)
                })
            }
            return entries
        }
    }

    @ViewBuilder
    private func browserEntry(_ entry: ChangesBrowserEntry) -> some View {
        switch entry {
        case .repository(let repository):
            repositoryGroup(repository)
        case .unavailable(let repository, let message, let leadingInset):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("重新定位 Repository…", systemImage: "folder.badge.questionmark") {
                    appState.relocateRepository(repository.id)
                }
                .buttonStyle(.bordered)
            }
            .padding(.leading, leadingInset + 4)
            .padding(.vertical, 4)
        case .snapshotError(_, let error, let leadingInset):
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.leading, leadingInset + 4)
                .padding(.vertical, 4)
        case .status(let section, let repository, let leadingInset):
            statusGroup(section, repository: repository, leadingInset: leadingInset)
        case .outline(let row, let repository, let kind, let leadingInset):
            outlineRow(row, repository: repository, kind: kind)
                .padding(.leading, leadingInset)
        }
    }

    @ViewBuilder
    private func repositoryGroup(_ repository: RegisteredRepository) -> some View {
        let isExpanded = !isRepositoryCollapsed(repository.id)
        let selections = statusSections(for: repository).flatMap(\.selections)
        HStack(spacing: 7) {
            commitCheckbox(selections: selections, repository: repository)
            Button {
                toggleRepositoryExpansion(repository.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repository.name).fontWeight(.semibold)
                        Text(repository.relativePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if appState.refreshingRepositoryIDs.contains(repository.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(selectionCount(for: repository))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.vertical, 3)
        .help(isExpanded ? "折叠 \(repository.name)" : "展开 \(repository.name)")
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
    }

    @ViewBuilder
    private func statusGroup(
        _ section: ChangeStatusSection,
        repository: RegisteredRepository,
        leadingInset: CGFloat
    ) -> some View {
        let statusID = "repository:\(repository.id):group:\(section.kind.rawValue)"
        let isExpanded = isNodeExpanded(statusID)
        HStack(spacing: 6) {
            commitCheckbox(selections: section.selections, repository: repository)
            Button {
                toggleNodeExpansion(statusID)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Text(section.kind.rawValue)
                    Spacer()
                    Text("\(section.selections.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .fontWeight(.semibold)
        .padding(.vertical, 2)
        .padding(.leading, leadingInset)
        .help(isExpanded ? "折叠 \(section.kind.rawValue)" : "展开 \(section.kind.rawValue)")
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
        .fileSystemPathCopyMenu(
            nil,
            rollbackItem: {
                requestRollback(
                    title: section.kind.rawValue,
                    repository: repository,
                    selections: section.selections
                )
            },
            isContextMenuPresented: contextMenuPresentationBinding(for: statusID)
        )
    }

    private func outlineRows(
        for section: ChangeStatusSection,
        repository: RegisteredRepository,
        statusID: String,
        forcedExpandedNodeIDs: Set<String>? = nil
    ) -> [ChangeOutlineRow] {
        let activeExpandedNodeIDs = forcedExpandedNodeIDs ?? fileSearch.expandedNodeIDs(
            allIDs: fileSearch.isActive ? expandableNodeIDs(for: repository) : [],
            normalExpandedIDs: expandedNodeIDs
        )
        let changesByPath = Dictionary(
            uniqueKeysWithValues: (appState.repositorySnapshots[repository.id]?.changes ?? []).map {
                ($0.path, $0)
            }
        )
        let code: (GitChangeSelection) -> String = { selection in
            operationCode(for: changesByPath[selection.path])
        }
        let grouping = appState.changesGrouping
        if grouping.isEmpty {
            return ChangesOutlineBuilder.flatRows(
                selections: section.selections,
                namespace: statusID,
                statusIsExpanded: activeExpandedNodeIDs.contains(statusID),
                operationCode: code
            )
        }
        if grouping == .directory {
            return ChangesOutlineBuilder.directoryRows(
                selections: section.selections,
                namespace: statusID,
                statusIsExpanded: activeExpandedNodeIDs.contains(statusID),
                expandedNodeIDs: activeExpandedNodeIDs,
                operationCode: code
            )
        }

        guard let workspace = appState.workspace else { return [] }
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        let repositoryURL = repository.relativePath == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
        var resolver = ChangeModulePathResolver(repositoryURL: repositoryURL)
        if grouping == .module {
            return ChangesOutlineBuilder.moduleRows(
                selections: section.selections,
                namespace: statusID,
                repositoryName: repository.name,
                statusIsExpanded: activeExpandedNodeIDs.contains(statusID),
                expandedNodeIDs: activeExpandedNodeIDs,
                operationCode: code
            ) { selection in
                resolver.modulePath(for: selection.path)
            }
        }
        return ChangesOutlineBuilder.moduleDirectoryRows(
            selections: section.selections,
            namespace: statusID,
            repositoryName: repository.name,
            statusIsExpanded: activeExpandedNodeIDs.contains(statusID),
            expandedNodeIDs: activeExpandedNodeIDs,
            operationCode: code
        ) { selection in
            resolver.modulePath(for: selection.path)
        }
    }

    @ViewBuilder
    private func outlineRow(
        _ row: ChangeOutlineRow,
        repository: RegisteredRepository,
        kind: GitChangeKind
    ) -> some View {
        switch row {
        case .directory(let id, let name, let path, let depth, let count, let modulePath):
            outlineGroupRow(
                id: id,
                title: name,
                subtitle: nil,
                count: count,
                depth: depth,
                icon: "folder",
                selections: ChangesCommitSelectionScope.directorySelections(
                    path: path,
                    modulePath: modulePath,
                    selections: statusSections(for: repository).first(where: { $0.kind == kind })?.selections ?? []
                ),
                pathCopyValues: pathCopyValues(
                    repository: repository,
                    relativePath: FileSystemPathCopyValues.repositoryDirectoryPath(
                        path: path,
                        modulePath: modulePath
                    )
                ),
                repository: repository
            )
        case .module(let id, let name, let path, let count):
            outlineGroupRow(
                id: id,
                title: name,
                subtitle: path == "." ? "Repository 根目录" : path,
                count: count,
                depth: 0,
                icon: path == "." ? "shippingbox" : "shippingbox.fill",
                selections: moduleSelections(
                    path: path,
                    selections: statusSections(for: repository).first(where: { $0.kind == kind })?.selections ?? [],
                    repository: repository
                ),
                pathCopyValues: nil,
                repository: repository
            )
        case .file(_, let selection, let depth, let modulePath, let operationCode):
            outlineFileRow(
                selection,
                depth: depth,
                modulePath: modulePath,
                operationCode: operationCode,
                repository: repository,
                kind: kind
            )
        }
    }

    private func outlineGroupRow(
        id: String,
        title: String,
        subtitle: String?,
        count: Int,
        depth: Int,
        icon: String,
        selections: [GitChangeSelection],
        pathCopyValues: FileSystemPathCopyValues?,
        repository: RegisteredRepository
    ) -> some View {
        let isExpanded = isNodeExpanded(id)
        return HStack(spacing: 6) {
            commitCheckbox(selections: selections, repository: repository)
            Button {
                toggleNodeExpansion(id)
            } label: {
                HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .frame(width: 10)
                Image(systemName: icon == "folder" && isExpanded ? "folder.fill" : icon)
                    .foregroundStyle(icon.hasPrefix("shippingbox") ? .orange : .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .padding(.leading, 12 + CGFloat(depth) * 14)
        .background(contextMenuBackground(for: id), in: .rect(cornerRadius: 5))
        .help(isExpanded ? "折叠 \(title)" : "展开 \(title)")
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
        .fileSystemPathCopyMenu(
            pathCopyValues,
            rollbackItem: {
                requestRollback(title: title, repository: repository, selections: selections)
            },
            isContextMenuPresented: contextMenuPresentationBinding(for: id)
        )
    }

    private func outlineFileRow(
        _ selection: GitChangeSelection,
        depth: Int,
        modulePath: String?,
        operationCode: String,
        repository: RegisteredRepository,
        kind: GitChangeKind
    ) -> some View {
        let rowID = "file:\(repository.id):\(selection.id)"
        return HStack(spacing: 7) {
            commitCheckbox(selections: [selection], repository: repository)
            HStack(spacing: 7) {
                FileTypeIcon(path: selection.path)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName(selection.path)).lineLimit(1)
                    if let modulePath {
                        Text(moduleRelativePackage(selection.path, modulePath: modulePath))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let originalPath = selection.originalPath {
                        Text("来自 \(originalPath)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if appState.changesGrouping.isEmpty,
                              let parentPath = parentPath(selection.path) {
                        Text(parentPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                GitStatusBadge(code: operationCode, kind: kind)
            }
            .contentShape(.rect)
            .onTapGesture {
                appState.selectChange(selection, repositoryID: repository.id)
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        requestDiffComparison(for: selection, repository: repository)
                    }
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            selectionBackground(selection, repository: repository, rowID: rowID),
            in: .rect(cornerRadius: 5)
        )
        .padding(.leading, 18 + CGFloat(depth) * 14)
        .focusable(false)
        .help(selection.path)
        .fileSystemPathCopyMenu(
            pathCopyValues(repository: repository, relativePath: selection.path),
            rollbackItem: {
                requestRollback(title: fileName(selection.path), repository: repository, selections: [selection])
            },
            isContextMenuPresented: contextMenuPresentationBinding(for: rowID)
        )
    }

    @ViewBuilder
    private var diffDetail: some View {
        if let selection = appState.selectedChange,
           let repository = appState.selectedChangeRepository {
            diffPane(selection: selection, repository: repository)
        } else if let error = appState.diffErrorMessage {
            ContentUnavailableView("Diff 不可用", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ContentUnavailableView(
                "选择一个改动文件",
                systemImage: "doc.text.magnifyingglass",
                description: Text("从左侧选择文件后查看内容 Diff。")
            )
        }
    }

    private func diffPane(
        selection: GitChangeSelection,
        repository: RegisteredRepository
    ) -> some View {
        let diff = diffMatching(selection)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                FileTypeIcon(path: selection.path)
                Text(repository.name).fontWeight(.semibold)
                Text(selection.kind.rawValue).font(.caption).foregroundStyle(color(for: selection.kind))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            Group {
                if let diff {
                    GitDiffView(
                        diff: diff,
                        ignoresWhitespace: appState.ignoresWhitespaceInDiff,
                        toggleIgnoreWhitespace: appState.toggleIgnoreWhitespace,
                        presentation: appState.diffPresentation,
                        setPresentation: appState.setDiffPresentation,
                        jumpToSource: { line in
                            appState.jumpToSource(repositoryID: repository.id, path: selection.path, line: line)
                        },
                        openComparison: { renderModel in
                            openDiffComparison(
                                selection: selection,
                                repository: repository,
                                diff: diff,
                                renderModel: renderModel
                            )
                        },
                        fontSize: CGFloat(appState.fileContentFontSize)
                    )
                    .id("\(repository.id):\(selection.id)")
                } else if let error = appState.diffErrorMessage, !appState.isLoadingDiff {
                    ContentUnavailableView(
                        "Diff 不可用",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("正在加载 Diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if diff != nil, appState.isLoadingDiff {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 6))
                    .allowsHitTesting(false)
            }
        }
    }

    private func diffMatching(_ selection: GitChangeSelection) -> GitFileDiff? {
        guard let diff = appState.currentDiff, diff.path == selection.path else { return nil }
        return diff
    }

    private func prepareArrowKeyMonitor() {
        arrowKeyMonitor.isBlocked = rollbackRequest != nil
        arrowKeyMonitor.move = { offset in
            selectAdjacentChangeFromKeyboard(offset: offset)
        }
    }

    private var changeSelectionRefreshID: String {
        let query = fileSearch.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = appState.selectedChange?.id ?? ""
        let repositoryID = appState.selectedChangeRepositoryID ?? ""
        let scope = effectiveRepositoryScopeID ?? "all"
        let files = scopedRepositories.map { repository in
            statusSections(for: repository, matchingSearch: false)
                .flatMap { section in
                    section.selections.map { "\(repository.id):\($0.id)" }
                }
                .joined(separator: ",")
        }.joined(separator: "|")
        let pendingSnapshots = scopedRepositories
            .filter(isAwaitingSnapshot)
            .map(\.id)
            .joined(separator: ",")
        return "\(query)|\(scope)|\(repositoryID)|\(selection)|\(appState.changesGrouping.rawValue)|\(pendingSnapshots)|\(files)"
    }

    private var currentChangeSelectionIsAvailable: Bool {
        guard let selection = appState.selectedChange,
              let repositoryID = appState.selectedChangeRepositoryID else {
            return false
        }
        if let scope = effectiveRepositoryScopeID, scope != repositoryID {
            return false
        }
        guard appState.repositorySnapshots[repositoryID] != nil else {
            guard let repository = appState.repositories.first(where: { $0.id == repositoryID }) else {
                return false
            }
            return appState.repositorySnapshotErrors[repositoryID] == nil
                && appState.repositoryUnavailableMessage(for: repository) == nil
        }
        return appState.changes(for: selection.kind, repositoryID: repositoryID).contains(selection)
    }

    private var isAwaitingInitialChangeSnapshots: Bool {
        scopedRepositories.contains(where: isAwaitingSnapshot)
    }

    private func isAwaitingSnapshot(_ repository: RegisteredRepository) -> Bool {
        appState.repositorySnapshots[repository.id] == nil
            && appState.repositorySnapshotErrors[repository.id] == nil
            && appState.repositoryUnavailableMessage(for: repository) == nil
    }

    private func selectFirstChangeIfNeeded() {
        guard !currentChangeSelectionIsAvailable else { return }
        guard !isAwaitingInitialChangeSnapshots else { return }
        if visibleChangeFiles().isEmpty {
            revealFirstPresentationFile()
        }
        guard let first = visibleChangeFiles().first else { return }
        appState.selectChange(first.selection, repositoryID: first.repositoryID)
        pendingOutlineScrollID = first.rowID
    }

    private func revealFirstPresentationFile() {
        guard let file = firstPresentationFile() else { return }
        if fileSearch.isActive {
            fileSearch.collapsedRepositoryIDs.remove(file.repositoryID)
            fileSearch.collapsedNodeIDs.remove(file.statusID)
            fileSearch.collapsedNodeIDs.subtract(file.ancestorNodeIDs)
            return
        }
        collapsedRepositoryIDs.remove(file.repositoryID)
        var expanded = expandedNodeIDs
        expanded.insert(file.statusID)
        expanded.formUnion(file.ancestorNodeIDs)
        if expanded != expandedNodeIDs {
            expandedNodeIDs = expanded
        }
    }

    private func firstPresentationFile() -> PresentationChangeFile? {
        for repository in visibleRepositories {
            for section in statusSections(for: repository) {
                let statusID = "repository:\(repository.id):group:\(section.kind.rawValue)"
                let rows = outlineRows(
                    for: section,
                    repository: repository,
                    statusID: statusID,
                    forcedExpandedNodeIDs: expandableNodeIDs(for: repository)
                )
                guard let location = ChangesOutlineNavigation.fileLocations(in: rows).first else {
                    continue
                }
                return PresentationChangeFile(
                    repositoryID: repository.id,
                    selection: location.selection,
                    rowID: location.rowID,
                    statusID: statusID,
                    ancestorNodeIDs: location.ancestorNodeIDs
                )
            }
        }
        return nil
    }

    private func selectAdjacentChangeFromKeyboard(offset: Int) {
        let entries = visibleChangeFiles()
        let current = entries.firstIndex {
            $0.repositoryID == appState.selectedChangeRepositoryID && $0.selection == appState.selectedChange
        }
        guard let index = ChangesFileNavigation.destinationIndex(
            current: current,
            offset: offset,
            count: entries.count
        ) else { return }
        let target = entries[index]
        if appState.selectedChangeRepositoryID != target.repositoryID || appState.selectedChange != target.selection {
            appState.selectChange(target.selection, repositoryID: target.repositoryID)
        }
        pendingOutlineScrollID = target.rowID
    }

    private func visibleChangeFiles() -> [VisibleChangeFile] {
        browserEntries.compactMap { entry in
            guard case .outline(let row, let repository, _, _) = entry,
                  case .file(let id, let selection, _, _, _) = row else {
                return nil
            }
            return VisibleChangeFile(
                repositoryID: repository.id,
                selection: selection,
                rowID: id
            )
        }
    }

    private func openDiffComparison(
        selection: GitChangeSelection,
        repository: RegisteredRepository,
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel
    ) {
        diffComparisonWindow.present(title: "对比 \(fileName(selection.path))") {
            GitDiffComparisonContent(
                appState: appState,
                selection: selection,
                repository: repository,
                diff: diff,
                renderModel: renderModel,
                close: { diffComparisonWindow.close() }
            )
        }
    }

    private func requestDiffComparison(
        for selection: GitChangeSelection,
        repository: RegisteredRepository
    ) {
        let pending = PendingDiffComparison(
            repositoryID: repository.id,
            selection: selection
        )
        pendingDiffComparison = pending

        guard appState.selectedChangeRepositoryID == repository.id,
              appState.selectedChange == selection,
              let diff = diffMatching(selection) else {
            appState.selectChange(selection, repositoryID: repository.id)
            return
        }
        pendingDiffComparison = nil
        openDiffComparison(
            selection: selection,
            repository: repository,
            diff: diff,
            renderModel: GitDiffRenderModel(diff: diff)
        )
    }

    private func openPendingDiffComparisonIfReady(with diff: GitFileDiff?) {
        guard let pending = pendingDiffComparison,
              let diff,
              diff.path == pending.selection.path,
              appState.selectedChangeRepositoryID == pending.repositoryID,
              appState.selectedChange == pending.selection else {
            return
        }
        guard let repository = appState.repositories.first(where: { $0.id == pending.repositoryID }) else {
            pendingDiffComparison = nil
            return
        }
        pendingDiffComparison = nil
        openDiffComparison(
            selection: pending.selection,
            repository: repository,
            diff: diff,
            renderModel: GitDiffRenderModel(diff: diff)
        )
    }

    private func resetDiffComparison() {
        diffComparisonWindow.close()
    }

    private var repositoryScopeBinding: Binding<String?> {
        Binding(
            get: { appState.changesRepositoryScopeID },
            set: { appState.selectChangesRepositoryScope($0) }
        )
    }

    private func groupingOptionBinding(_ grouping: GitChangesGrouping) -> Binding<Bool> {
        Binding(
            get: { appState.changesGrouping.contains(grouping) },
            set: { isEnabled in
                guard isEnabled != appState.changesGrouping.contains(grouping) else { return }
                appState.toggleChangesGrouping(grouping)
            }
        )
    }

    private func commitCheckbox(
        selections: [GitChangeSelection],
        repository: RegisteredRepository
    ) -> some View {
        let state = CommitCheckboxState.resolve(selections: selections) {
            appState.isIncludedInCommit($0, repositoryID: repository.id)
        }
        return Button {
            appState.setCommitInclusion(
                selections,
                repositoryID: repository.id,
                included: state.includesSelectionsAfterToggle
            )
        } label: {
            Image(systemName: state.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(state == .unchecked ? Color.secondary : Color.accentColor)
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(selections.isEmpty || appState.isGitWriteOperationRunning)
        .help(state == .checked ? "从本次 Commit 中排除" : "加入本次 Commit")
    }

    private func moduleSelections(
        path: String,
        selections: [GitChangeSelection],
        repository: RegisteredRepository
    ) -> [GitChangeSelection] {
        guard var resolver = changeModulePathResolver(for: repository) else { return selections }
        return selections.filter { resolver.modulePath(for: $0.path) == path }
    }

    private var visibleRepositories: [RegisteredRepository] {
        guard fileSearch.isActive else { return scopedRepositories }
        return scopedRepositories.filter {
            selectionCount(for: $0) > 0
                || appState.refreshingRepositoryIDs.contains($0.id)
                || appState.repositorySnapshotErrors[$0.id] != nil
                || appState.repositoryUnavailableMessage(for: $0) != nil
        }
    }

    private var scopedRepositories: [RegisteredRepository] {
        appState.repositories.filter { repository in
            (effectiveRepositoryScopeID == nil || effectiveRepositoryScopeID == repository.id)
                && (!statusSections(for: repository, matchingSearch: false).isEmpty
                    || appState.refreshingRepositoryIDs.contains(repository.id)
                    || appState.repositorySnapshotErrors[repository.id] != nil
                    || appState.repositoryUnavailableMessage(for: repository) != nil)
        }
    }

    private func statusSections(
        for repository: RegisteredRepository,
        matchingSearch: Bool = true
    ) -> [ChangeStatusSection] {
        GitChangeKind.allDisplayCases.compactMap { kind in
            let allSelections = appState.changes(for: kind, repositoryID: repository.id)
            let selections = matchingSearch ? fileSearch.filter(allSelections) : allSelections
            return selections.isEmpty ? nil : ChangeStatusSection(kind: kind, selections: selections)
        }
    }

    private func selectionCount(for repository: RegisteredRepository) -> Int {
        statusSections(for: repository).reduce(0) { $0 + $1.selections.count }
    }

    private var effectiveRepositoryScopeID: RegisteredRepository.ID? {
        appState.isWorkspaceContext ? appState.changesRepositoryScopeID : appState.selectedRepositoryID
    }

    private var changesListIdentity: String {
        let context = appState.isWorkspaceContext ? "workspace" : "repository"
        return "\(context):\(effectiveRepositoryScopeID ?? "all")"
    }

    private var isRefreshingChangesScope: Bool {
        guard let repositoryID = effectiveRepositoryScopeID else {
            return !appState.refreshingRepositoryIDs.isEmpty
        }
        return appState.refreshingRepositoryIDs.contains(repositoryID)
    }

    private var showsRepositoryGroups: Bool {
        appState.isWorkspaceContext && appState.changesRepositoryScopeID == nil
    }

    private var cleanScopeTitle: String {
        appState.isWorkspaceContext ? "工作区干净" : "Repository 干净"
    }

    private var scopedChangeCount: Int {
        scopedRepositories.reduce(0) { count, repository in
            count + statusSections(for: repository, matchingSearch: false)
                .reduce(0) { $0 + $1.selections.count }
        }
    }

    private var automaticExpansionContextID: String {
        "\(appState.workspace?.path ?? "")|\(changesListIdentity)|\(appState.changesGrouping.rawValue)"
    }

    private var automaticExpansionTaskID: String {
        let prefix = "\(automaticExpansionContextID)|\(scopedChangeCount)"
        let settings = automaticExpansionSession.contextID == automaticExpansionContextID
            ? automaticExpansionSession.settings : appState.changesAutoExpansion
        guard ChangesAutoExpansionPolicy.shouldExpandAll(
            fileCount: scopedChangeCount,
            settings: settings
        ) else {
            return prefix
        }
        let selections = scopedRepositories.flatMap { repository in
            statusSections(for: repository, matchingSearch: false).flatMap { section in
                section.selections.map { "\(repository.id):\(section.kind.rawValue):\($0.id)" }
            }
        }
        return "\(prefix)|\(selections.sorted().joined(separator: "|"))"
    }

    private func applyAutomaticExpansionIfNeeded() {
        automaticExpansionSession.beginIfNeeded(
            contextID: automaticExpansionContextID,
            settings: appState.changesAutoExpansion
        )
        guard automaticExpansionSession.shouldExpandAll(fileCount: scopedChangeCount) else { return }
        expandUnfilteredChanges()
    }

    private func isRepositoryCollapsed(_ id: String) -> Bool {
        (fileSearch.isActive ? fileSearch.collapsedRepositoryIDs : collapsedRepositoryIDs).contains(id)
    }

    private func isNodeExpanded(_ id: String) -> Bool {
        fileSearch.isNodeExpanded(id, normalExpandedIDs: expandedNodeIDs)
    }

    private func toggleRepositoryExpansion(_ id: String) {
        if fileSearch.isActive {
            if fileSearch.collapsedRepositoryIDs.remove(id) == nil {
                fileSearch.collapsedRepositoryIDs.insert(id)
            }
            return
        }
        automaticExpansionSession.recordManualInteraction()
        if collapsedRepositoryIDs.remove(id) == nil {
            collapsedRepositoryIDs.insert(id)
        }
    }

    private func toggleNodeExpansion(_ id: String) {
        if fileSearch.isActive {
            if fileSearch.collapsedNodeIDs.remove(id) == nil {
                fileSearch.collapsedNodeIDs.insert(id)
            }
            return
        }
        automaticExpansionSession.recordManualInteraction()
        if expandedNodeIDs.remove(id) == nil {
            expandedNodeIDs.insert(id)
        }
    }

    private func expandAllChanges() {
        if fileSearch.isActive {
            fileSearch.resetExpansion()
            return
        }
        expandUnfilteredChanges()
    }

    private func expandUnfilteredChanges() {
        collapsedRepositoryIDs.subtract(scopedRepositories.map(\.id))
        for repository in scopedRepositories {
            expandedNodeIDs.formUnion(expandableNodeIDs(for: repository, matchingSearch: false))
        }
    }

    private func collapseAllChanges() {
        if fileSearch.isActive {
            if showsRepositoryGroups {
                fileSearch.collapsedRepositoryIDs.formUnion(visibleRepositories.map(\.id))
            }
            for repository in visibleRepositories {
                fileSearch.collapsedNodeIDs.formUnion(expandableNodeIDs(for: repository))
            }
            return
        }
        if showsRepositoryGroups {
            collapsedRepositoryIDs.formUnion(visibleRepositories.map(\.id))
        }
        expandedNodeIDs.removeAll()
    }

    private func expandableNodeIDs(
        for repository: RegisteredRepository,
        matchingSearch: Bool = true
    ) -> Set<String> {
        var nodeIDs: Set<String> = []
        var moduleResolver = changeModulePathResolver(for: repository)

        for section in statusSections(for: repository, matchingSearch: matchingSearch) {
            let statusID = "repository:\(repository.id):group:\(section.kind.rawValue)"
            nodeIDs.insert(statusID)
            let grouping = appState.changesGrouping
            if grouping == .directory {
                nodeIDs.formUnion(
                    ChangesOutlineBuilder.directoryExpandableNodeIDs(
                        selections: section.selections,
                        namespace: statusID
                    )
                )
            } else if grouping == .module {
                guard moduleResolver != nil else { continue }
                nodeIDs.formUnion(
                    ChangesOutlineBuilder.moduleExpandableNodeIDs(
                        selections: section.selections,
                        namespace: statusID
                    ) { selection in
                        moduleResolver?.modulePath(for: selection.path) ?? "."
                    }
                )
            } else if grouping == .all {
                guard moduleResolver != nil else { continue }
                nodeIDs.formUnion(
                    ChangesOutlineBuilder.moduleDirectoryExpandableNodeIDs(
                        selections: section.selections,
                        namespace: statusID
                    ) { selection in
                        moduleResolver?.modulePath(for: selection.path) ?? "."
                    }
                )
            }
        }
        return nodeIDs
    }

    private func changeModulePathResolver(for repository: RegisteredRepository) -> ChangeModulePathResolver? {
        guard let repositoryURL = repositoryURL(for: repository) else { return nil }
        return ChangeModulePathResolver(repositoryURL: repositoryURL)
    }

    private func pathCopyValues(
        repository: RegisteredRepository,
        relativePath: String
    ) -> FileSystemPathCopyValues? {
        guard let repositoryURL = repositoryURL(for: repository) else { return nil }
        return FileSystemPathCopyValues(
            relativePath: relativePath,
            rootURL: repositoryURL
        )
    }

    private func repositoryURL(for repository: RegisteredRepository) -> URL? {
        guard let workspace = appState.workspace else { return nil }
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        return repository.relativePath == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
    }

    private func moduleRelativePackage(_ path: String, modulePath: String) -> String {
        var relative = path
        if modulePath != ".", relative.hasPrefix(modulePath + "/") {
            relative.removeFirst(modulePath.count + 1)
        }
        let directory = relative.split(separator: "/").dropLast().map(String.init)
        let sourceRoots = ["src/main/java", "src/test/java", "src/main/kotlin", "src/test/kotlin"]
        var display = directory.joined(separator: "/")
        for root in sourceRoots where display == root || display.hasPrefix(root + "/") {
            display = String(display.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return display.isEmpty ? root : display.replacingOccurrences(of: "/", with: ".")
        }
        return display.isEmpty ? "Module 根目录" : display
    }

    private func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func parentPath(_ path: String) -> String? {
        let components = path.split(separator: "/").dropLast()
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private func operationCode(for change: GitFileChange?) -> String {
        guard let change else { return "?" }
        if change.isConflicted { return "U" }
        if change.isUntracked { return "?" }
        if change.indexStatus == .added { return "A" }
        if change.indexStatus == .renamed { return "R" }
        if change.indexStatus == .copied { return "C" }
        if change.workTreeStatus == .deleted || change.indexStatus == .deleted { return "D" }
        if change.workTreeStatus == .typeChanged || change.indexStatus == .typeChanged { return "T" }
        if change.workTreeStatus == .modified || change.indexStatus == .modified { return "M" }
        return "·"
    }

    private func selectionBackground(
        _ selection: GitChangeSelection,
        repository: RegisteredRepository,
        rowID: String
    ) -> Color {
        if appState.selectedChangeRepositoryID == repository.id && appState.selectedChange == selection {
            return Color.accentColor.opacity(0.14)
        }
        return contextMenuBackground(for: rowID)
    }

    private func contextMenuBackground(for rowID: String) -> Color {
        contextMenuOutlineRowID == rowID ? Color.accentColor.opacity(0.06) : .clear
    }

    private func contextMenuPresentationBinding(for rowID: String) -> Binding<Bool> {
        Binding(
            get: { contextMenuOutlineRowID == rowID },
            set: { isPresented in
                if isPresented {
                    contextMenuOutlineRowID = rowID
                } else if contextMenuOutlineRowID == rowID {
                    contextMenuOutlineRowID = nil
                }
            }
        )
    }

    private func requestRollback(
        title: String,
        repository: RegisteredRepository,
        selections: [GitChangeSelection]
    ) {
        guard !selections.isEmpty, !appState.isGitWriteOperationRunning else { return }
        rollbackRequest = ChangesRollbackRequest(
            repository: repository,
            selections: selections,
            title: title
        )
    }

    private func color(for kind: GitChangeKind) -> Color {
        switch kind {
        case .changes: .orange
        case .unversioned: .blue
        }
    }
}

@MainActor
struct CommitExecutionStatusView: View {
    let state: GitCommitExecutionState
    let retryCommit: (Bool) -> Void
    let retryPush: () -> Void
    let showInHistory: (GitCommitExecutionResult) -> Void
    let dismiss: () -> Void

    @State private var showsErrorDetails = false

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .committing(let context):
                statusPanel(
                    tint: .accentColor,
                    showsProgress: true,
                    systemImage: "checkmark.circle",
                    title: "正在提交 \(context.fileCount) 个文件…",
                    detail: contextDetail(context)
                ) { EmptyView() }
            case .pushing(let context, let commitHash):
                statusPanel(
                    tint: .accentColor,
                    showsProgress: true,
                    systemImage: "arrow.up.circle",
                    title: "Commit \(shortHash(commitHash)) 已完成，正在 Push…",
                    detail: "\(context.repositoryName) · \(context.pushTarget)"
                ) { EmptyView() }
            case .succeeded(let result):
                statusPanel(
                    tint: .green,
                    showsProgress: false,
                    systemImage: "checkmark.circle.fill",
                    title: result.wasPushed
                        ? "已提交并 Push 到 \(result.context.pushTarget)"
                        : "Commit 成功",
                    detail: "\(contextDetail(result.context)) · \(result.shortHash)",
                    canDismiss: true
                ) {
                    Button("在 History 查看", systemImage: "clock.arrow.circlepath") {
                        showInHistory(result)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            case .commitFailed(let context, let message):
                failurePanel(
                    tint: .red,
                    title: "Commit 失败",
                    message: message
                ) {
                    Button("重试", systemImage: "arrow.clockwise") {
                        retryCommit(context.shouldPush)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            case .pushFailed(let result, let message):
                failurePanel(
                    tint: .orange,
                    title: "Commit \(result.shortHash) 已完成，但 Push 失败",
                    message: message
                ) {
                    Button("重新 Push", systemImage: "arrow.up.circle") {
                        retryPush()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Button("在 History 查看", systemImage: "clock.arrow.circlepath") {
                        showInHistory(result)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .onChange(of: state) { _, _ in
            showsErrorDetails = false
        }
    }

    private func failurePanel<Actions: View>(
        tint: Color,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        statusPanel(
            tint: tint,
            showsProgress: false,
            systemImage: "exclamationmark.triangle.fill",
            title: title,
            detail: message,
            detailLineLimit: showsErrorDetails ? nil : 2,
            canDismiss: true
        ) {
            actions()
            Button(
                showsErrorDetails ? "收起详情" : "查看详情",
                systemImage: "info.circle"
            ) {
                showsErrorDetails.toggle()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func statusPanel<Actions: View>(
        tint: Color,
        showsProgress: Bool,
        systemImage: String,
        title: String,
        detail: String,
        detailLineLimit: Int? = 1,
        canDismiss: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(detailLineLimit)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    actions()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if canDismiss {
                Button("关闭", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("关闭提交结果")
            }
        }
        .padding(8)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        }
    }

    private func contextDetail(_ context: GitCommitExecutionContext) -> String {
        "\(context.repositoryName) · \(context.branch) · \(context.fileCount) 个文件"
    }

    private func shortHash(_ hash: String) -> String {
        String(hash.prefix(8))
    }
}

@MainActor
private struct GitDiffComparisonContent: View {
    @Bindable var appState: AppState
    let selection: GitChangeSelection
    let repository: RegisteredRepository
    let diff: GitFileDiff
    let renderModel: GitDiffRenderModel
    let close: () -> Void

    @State private var visibleBlameSides: Set<GitBlameSide> = []
    @State private var oldBlameCache: [Int: GitBlameLine]?
    @State private var newBlameCache: [Int: GitBlameLine]?
    @State private var loadingBlameSides: Set<GitBlameSide> = []
    @State private var blameErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundStyle(.secondary)
                Text("对比 \(fileName)")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if !loadingBlameSides.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("关闭", systemImage: "xmark") {
                    close()
                }
                .labelStyle(.iconOnly)
                .help("关闭对比")
            }
            .padding(.top, 20)
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(WindowDragArea())

            if let blameErrorMessage {
                Label(blameErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            Divider()
            GitDiffView(
                diff: diff,
                ignoresWhitespace: appState.ignoresWhitespaceInDiff,
                toggleIgnoreWhitespace: appState.toggleIgnoreWhitespace,
                jumpToSource: { line in
                    appState.jumpToSource(
                        repositoryID: repository.id,
                        path: selection.path,
                        line: line
                    )
                },
                lockedPresentation: .sideBySide,
                oldBlame: visibleBlameSides.contains(.old) ? (oldBlameCache ?? [:]) : nil,
                newBlame: visibleBlameSides.contains(.new) ? (newBlameCache ?? [:]) : nil,
                toggleOldBlame: { toggleBlame(.old) },
                toggleNewBlame: { toggleBlame(.new) },
                fontSize: CGFloat(appState.fileContentFontSize),
                renderModel: renderModel
            )
        }
        .repoDeskFontSize(appState.interfaceFontSize)
        .frame(minWidth: 1_050, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: appState.currentDiff) { _, updatedDiff in
            if updatedDiff != diff {
                close()
            }
        }
    }

    private var fileName: String {
        selection.path.split(separator: "/").last.map(String.init) ?? selection.path
    }

    private func toggleBlame(_ side: GitBlameSide) {
        if visibleBlameSides.remove(side) != nil {
            return
        }
        visibleBlameSides.insert(side)
        let cached = side == .old ? oldBlameCache : newBlameCache
        guard cached == nil, !loadingBlameSides.contains(side) else { return }

        loadingBlameSides.insert(side)
        blameErrorMessage = nil
        Task {
            defer { loadingBlameSides.remove(side) }
            do {
                let lines = try await appState.blameForSelectedChange(side: side)
                guard !lines.isEmpty else {
                    visibleBlameSides.remove(side)
                    blameErrorMessage = "当前版本没有可显示的 Git Blame 信息。"
                    return
                }
                let mapped = await Task.detached(priority: .userInitiated) {
                    lines.indexedByLineNumber
                }.value
                if side == .old {
                    oldBlameCache = mapped
                } else {
                    newBlameCache = mapped
                }
            } catch {
                visibleBlameSides.remove(side)
                blameErrorMessage = error.localizedDescription
            }
        }
    }
}

private enum ChangesBrowserEntry: Identifiable {
    case repository(RegisteredRepository)
    case unavailable(RegisteredRepository, String, CGFloat)
    case snapshotError(RegisteredRepository, String, CGFloat)
    case status(ChangeStatusSection, RegisteredRepository, CGFloat)
    case outline(ChangeOutlineRow, RegisteredRepository, GitChangeKind, CGFloat)

    var id: String {
        switch self {
        case .repository(let repository):
            "browser-repository:\(repository.id)"
        case .unavailable(let repository, _, _):
            "browser-unavailable:\(repository.id)"
        case .snapshotError(let repository, _, _):
            "browser-snapshot-error:\(repository.id)"
        case .status(let section, let repository, _):
            "repository:\(repository.id):group:\(section.kind.rawValue)"
        case .outline(let row, _, _, _):
            row.id
        }
    }
}

private struct ChangeStatusSection: Identifiable {
    let kind: GitChangeKind
    let selections: [GitChangeSelection]
    var id: GitChangeKind { kind }
}

private extension CommitCheckboxState {
    var systemImage: String {
        switch self {
        case .checked: "checkmark.square.fill"
        case .unchecked: "square"
        case .mixed: "minus.square.fill"
        }
    }
}

private struct GitStatusBadge: View {
    let code: String
    let kind: GitChangeKind

    var body: some View {
        Text(code)
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 18)
            .background(color.opacity(0.12), in: .rect(cornerRadius: 4))
            .help(kind.rawValue)
    }

    private var color: Color {
        switch code {
        case "A", "C": .green
        case "M", "T": .blue
        case "D", "U": .red
        case "R": .purple
        case "?": .orange
        default: .secondary
        }
    }
}

private struct VisibleChangeFile: Equatable {
    let repositoryID: RegisteredRepository.ID
    let selection: GitChangeSelection
    let rowID: String
}

private struct PresentationChangeFile {
    let repositoryID: RegisteredRepository.ID
    let selection: GitChangeSelection
    let rowID: String
    let statusID: String
    let ancestorNodeIDs: [String]
}

@MainActor
private final class ChangesArrowKeyMonitor {
    weak var window: NSWindow?
    var isBlocked = false
    var move: ((Int) -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let offset = Self.offset(for: event) else { return event }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        guard modifiers.isEmpty else { return event }
        guard let window, event.window === window, window.attachedSheet == nil else { return event }
        guard !isBlocked, !Self.menuIsVisible, !Self.keepsArrowKeys(in: window) else { return event }
        move?(offset)
        return nil
    }

    private static func offset(for event: NSEvent) -> Int? {
        switch event.specialKey {
        case .upArrow: -1
        case .downArrow: 1
        default: nil
        }
    }

    private static func keepsArrowKeys(in window: NSWindow) -> Bool {
        if window.firstResponder is NSTextField { return true }
        guard let textView = window.firstResponder as? NSTextView else { return false }
        return !(textView is GitDiffSelectableTextViewSurface)
    }

    private static var menuIsVisible: Bool {
        NSApp.windows.contains { candidate in
            candidate.isVisible
                && NSStringFromClass(type(of: candidate)).localizedCaseInsensitiveContains("Menu")
        }
    }
}

private struct ChangesWindowAnchor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ChangesWindowAnchorView {
        let view = ChangesWindowAnchorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ChangesWindowAnchorView, context: Context) {
        view.onWindow = onWindow
        onWindow(view.window)
    }
}

private final class ChangesWindowAnchorView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}
