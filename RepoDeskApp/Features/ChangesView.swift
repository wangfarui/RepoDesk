import SwiftUI

@MainActor
struct ChangesView: View {
    @Bindable var appState: AppState
    @State private var collapsedRepositoryIDs: Set<String> = []
    @State private var expandedNodeIDs: Set<String> = []
    @State private var diffComparisonWindow = GitDiffComparisonWindowController()

    var body: some View {
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("上一个改动", systemImage: "chevron.up") {
                    appState.selectAdjacentChange(offset: -1)
                }
                .disabled(appState.selectedChange == nil)
                .help("上一个改动")
                Button("下一个改动", systemImage: "chevron.down") {
                    appState.selectAdjacentChange(offset: 1)
                }
                .disabled(appState.selectedChange == nil)
                .help("下一个改动")
            }
        }
        .onChange(of: appState.selectedChange) { _, _ in
            resetDiffComparison()
        }
        .onChange(of: appState.currentDiff) { _, diff in
            if diff == nil { resetDiffComparison() }
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
                            .keyboardShortcut("p", modifiers: .control)
                        Toggle("Module", isOn: groupingOptionBinding(.module))
                            .keyboardShortcut("m", modifiers: .control)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .help("Group By")

                if !appState.changesGrouping.isEmpty {
                    Button("展开全部", systemImage: "arrow.up.left.and.arrow.down.right") {
                        expandAllChanges()
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                    .disabled(visibleRepositories.isEmpty)
                    .help("Expand All")

                    Button("折叠全部", systemImage: "arrow.down.right.and.arrow.up.left") {
                        collapseAllChanges()
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                    .disabled(visibleRepositories.isEmpty)
                    .help("Collapse All")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleRepositories) { repository in
                        if showsRepositoryGroups {
                            repositoryGroup(repository)
                        } else {
                            repositoryContents(repository, leadingInset: 0)
                        }
                    }
                }
                .padding(8)
            }
            .id(changesListIdentity)
            .overlay {
                if visibleRepositories.isEmpty, appState.refreshingRepositoryIDs.isEmpty {
                    ContentUnavailableView(
                        cleanScopeTitle,
                        systemImage: "checkmark.circle",
                        description: Text("当前范围内没有未提交改动。")
                    )
                }
            }

            Divider()
            commitPanel
        }
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
                .keyboardShortcut(.return, modifiers: .command)
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

    @ViewBuilder
    private func repositoryGroup(_ repository: RegisteredRepository) -> some View {
        let isExpanded = !collapsedRepositoryIDs.contains(repository.id)
        let selections = GitChangeKind.allDisplayCases.flatMap {
            appState.changes(for: $0, repositoryID: repository.id)
        }
        VStack(alignment: .leading, spacing: 0) {
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
                        Text(repository.name).font(.callout.weight(.semibold))
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
            }
            .padding(.vertical, 3)
            .help(isExpanded ? "折叠 \(repository.name)" : "展开 \(repository.name)")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")

            if isExpanded {
                repositoryContents(repository, leadingInset: 14)
            }
        }
    }

    @ViewBuilder
    private func repositoryContents(_ repository: RegisteredRepository, leadingInset: CGFloat) -> some View {
        if let message = appState.repositoryUnavailableMessage(for: repository) {
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
        } else if appState.repositorySnapshots[repository.id] == nil,
                  let error = appState.repositorySnapshotErrors[repository.id] {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.leading, leadingInset + 4)
                .padding(.vertical, 4)
        } else {
            ForEach(statusSections(for: repository)) { section in
                statusGroup(section, repository: repository, leadingInset: leadingInset)
            }
        }
    }

    @ViewBuilder
    private func statusGroup(
        _ section: ChangeStatusSection,
        repository: RegisteredRepository,
        leadingInset: CGFloat
    ) -> some View {
        let statusID = "repository:\(repository.id):group:\(section.kind.rawValue)"
        let isExpanded = expandedNodeIDs.contains(statusID)
        VStack(alignment: .leading, spacing: 0) {
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
            }
            .font(.callout.weight(.semibold))
            .padding(.vertical, 2)
            .help(isExpanded ? "折叠 \(section.kind.rawValue)" : "展开 \(section.kind.rawValue)")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(outlineRows(for: section, repository: repository, statusID: statusID)) { row in
                        outlineRow(row, repository: repository, kind: section.kind)
                    }
                }
            }
        }
        .padding(.leading, leadingInset)
    }

    private func outlineRows(
        for section: ChangeStatusSection,
        repository: RegisteredRepository,
        statusID: String
    ) -> [ChangeOutlineRow] {
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
                statusIsExpanded: expandedNodeIDs.contains(statusID),
                operationCode: code
            )
        }
        if grouping == .directory {
            return ChangesOutlineBuilder.directoryRows(
                selections: section.selections,
                namespace: statusID,
                statusIsExpanded: expandedNodeIDs.contains(statusID),
                expandedNodeIDs: expandedNodeIDs,
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
                statusIsExpanded: expandedNodeIDs.contains(statusID),
                expandedNodeIDs: expandedNodeIDs,
                operationCode: code
            ) { selection in
                resolver.modulePath(for: selection.path)
            }
        }
        return ChangesOutlineBuilder.moduleDirectoryRows(
            selections: section.selections,
            namespace: statusID,
            repositoryName: repository.name,
            statusIsExpanded: expandedNodeIDs.contains(statusID),
            expandedNodeIDs: expandedNodeIDs,
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
                selections: directorySelections(
                    path: path,
                    modulePath: modulePath,
                    selections: statusSections(for: repository).first(where: { $0.kind == kind })?.selections ?? [],
                    repository: repository
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
        repository: RegisteredRepository
    ) -> some View {
        let isExpanded = expandedNodeIDs.contains(id)
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
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .padding(.leading, 12 + CGFloat(depth) * 14)
        .help(isExpanded ? "折叠 \(title)" : "展开 \(title)")
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
    }

    private func outlineFileRow(
        _ selection: GitChangeSelection,
        depth: Int,
        modulePath: String?,
        operationCode: String,
        repository: RegisteredRepository,
        kind: GitChangeKind
    ) -> some View {
        HStack(spacing: 7) {
            commitCheckbox(selections: [selection], repository: repository)
            Button {
                appState.selectChange(selection, repositoryID: repository.id)
            } label: {
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
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selectionBackground(selection, repository: repository), in: .rect(cornerRadius: 5))
        .padding(.leading, 18 + CGFloat(depth) * 14)
        .help(selection.path)
    }

    @ViewBuilder
    private var diffDetail: some View {
        if let selection = appState.selectedChange,
           let repository = appState.selectedChangeRepository,
           let diff = appState.currentDiff {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    FileTypeIcon(path: selection.path)
                    Text(repository.name).font(.callout.weight(.semibold))
                    Text(selection.kind.rawValue).font(.caption).foregroundStyle(color(for: selection.kind))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                Divider()
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
                    }
                )
                .id("\(repository.id):\(selection.id)")
            }
            .overlay {
                if appState.isLoadingDiff {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 6))
                        .allowsHitTesting(false)
                }
            }
        } else if appState.isLoadingDiff {
            ProgressView("正在加载 Diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let includedCount = selections.filter {
            appState.isIncludedInCommit($0, repositoryID: repository.id)
        }.count
        let state: CommitCheckboxState = includedCount == 0
            ? .unchecked
            : (includedCount == selections.count ? .checked : .mixed)
        return Button {
            appState.setCommitInclusion(
                selections,
                repositoryID: repository.id,
                included: includedCount != selections.count
            )
        } label: {
            Image(systemName: state.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(state == .unchecked ? Color.secondary : Color.accentColor)
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
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

    private func directorySelections(
        path: String,
        modulePath: String?,
        selections: [GitChangeSelection],
        repository: RegisteredRepository
    ) -> [GitChangeSelection] {
        selections.filter { selection in
            var candidate = selection.path
            if let modulePath, modulePath != ".", candidate.hasPrefix(modulePath + "/") {
                candidate.removeFirst(modulePath.count + 1)
            }
            return candidate.hasPrefix(path + "/")
        }
    }

    private var visibleRepositories: [RegisteredRepository] {
        appState.repositories.filter { repository in
            (effectiveRepositoryScopeID == nil || effectiveRepositoryScopeID == repository.id)
                && (selectionCount(for: repository) > 0
                    || appState.refreshingRepositoryIDs.contains(repository.id)
                    || appState.repositorySnapshotErrors[repository.id] != nil
                    || appState.repositoryUnavailableMessage(for: repository) != nil)
        }
    }

    private func statusSections(for repository: RegisteredRepository) -> [ChangeStatusSection] {
        GitChangeKind.allDisplayCases.compactMap { kind in
            let selections = appState.changes(for: kind, repositoryID: repository.id)
            return selections.isEmpty ? nil : ChangeStatusSection(kind: kind, selections: selections)
        }
    }

    private func selectionCount(for repository: RegisteredRepository) -> Int {
        GitChangeKind.allDisplayCases.reduce(0) {
            $0 + appState.changes(for: $1, repositoryID: repository.id).count
        }
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

    private var visibleChangeCount: Int {
        visibleRepositories.reduce(0) { $0 + selectionCount(for: $1) }
    }

    private var automaticExpansionTaskID: String {
        let context = appState.isWorkspaceContext ? "workspace" : "repository"
        let scope = effectiveRepositoryScopeID ?? "all"
        let prefix = "\(context)|\(scope)|\(appState.changesGrouping.rawValue)|\(visibleChangeCount)"
        guard ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: visibleChangeCount) else {
            return prefix
        }
        let selections = visibleRepositories.flatMap { repository in
            statusSections(for: repository).flatMap { section in
                section.selections.map { "\(repository.id):\(section.kind.rawValue):\($0.id)" }
            }
        }
        return "\(prefix)|\(selections.sorted().joined(separator: "|"))"
    }

    private func applyAutomaticExpansionIfNeeded() {
        guard ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: visibleChangeCount) else { return }
        expandAllChanges()
    }

    private func toggleRepositoryExpansion(_ id: String) {
        if collapsedRepositoryIDs.remove(id) == nil {
            collapsedRepositoryIDs.insert(id)
        }
    }

    private func toggleNodeExpansion(_ id: String) {
        if expandedNodeIDs.remove(id) == nil {
            expandedNodeIDs.insert(id)
        }
    }

    private func expandAllChanges() {
        collapsedRepositoryIDs.subtract(visibleRepositories.map(\.id))
        for repository in visibleRepositories {
            expandedNodeIDs.formUnion(expandableNodeIDs(for: repository))
        }
    }

    private func collapseAllChanges() {
        if showsRepositoryGroups {
            collapsedRepositoryIDs.formUnion(visibleRepositories.map(\.id))
        }
        expandedNodeIDs.removeAll()
    }

    private func expandableNodeIDs(for repository: RegisteredRepository) -> Set<String> {
        var nodeIDs: Set<String> = []
        var moduleResolver = changeModulePathResolver(for: repository)

        for section in statusSections(for: repository) {
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
        guard let workspace = appState.workspace else { return nil }
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        let repositoryURL = repository.relativePath == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
        return ChangeModulePathResolver(repositoryURL: repositoryURL)
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

    private func selectionBackground(_ selection: GitChangeSelection, repository: RegisteredRepository) -> Color {
        appState.selectedChangeRepositoryID == repository.id && appState.selectedChange == selection
            ? Color.accentColor.opacity(0.14) : .clear
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
                    .font(.headline)
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
                renderModel: renderModel
            )
        }
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

private struct ChangeStatusSection: Identifiable {
    let kind: GitChangeKind
    let selections: [GitChangeSelection]
    var id: GitChangeKind { kind }
}

private enum CommitCheckboxState {
    case checked
    case unchecked
    case mixed

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
