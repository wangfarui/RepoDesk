import AppKit
import SwiftUI

@MainActor
struct HistoryView: View {
    @Bindable var appState: AppState
    @State private var showsBranchFilter = false
    @State private var showsUserFilter = false
    @State private var branchQuery = ""
    @State private var userQuery = ""

    var body: some View {
        Group {
            if appState.selectedRepository == nil {
                ContentUnavailableView {
                    Label("选择一个 Repository", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("History 仅展示当前选中 Repository 的 Git Log。")
                } actions: {
                    Button("发现 Repository", systemImage: "magnifyingglass") {
                        appState.discoverRepositories()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("注册 Repository…", systemImage: "folder.badge.plus") {
                        appState.chooseRepository()
                    }
                }
            } else if let repository = appState.selectedRepository,
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
                }
            } else {
                PersistentHistorySplitView(
                    axis: .verticalStack,
                    fraction: Binding(
                        get: { appState.historyVerticalSplitFraction },
                        set: { appState.setHistoryVerticalSplitFraction($0) }
                    ),
                    minimumLeadingLength: 260,
                    minimumTrailingLength: 230
                ) {
                    commitFileDiff
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } trailing: {
                    PersistentHistorySplitView(
                        axis: .horizontalStack,
                        fraction: Binding(
                            get: { appState.historyHorizontalSplitFraction },
                            set: { appState.setHistoryHorizontalSplitFraction($0) }
                        ),
                        minimumLeadingLength: 340,
                        minimumTrailingLength: 360
                    ) {
                        historySidebar
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } trailing: {
                        commitFilesPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .transaction { $0.animation = nil }
            }
        }
        .task(id: appState.selectedRepositoryID) {
            await appState.refreshHistory()
        }
        .toolbar {
            ToolbarItem {
                Button("刷新 History", systemImage: "arrow.clockwise") {
                    Task { await appState.refreshHistory() }
                }
                .disabled(appState.isLoadingHistory || appState.isLoadingBranches || appState.isLoadingHistoryAuthors)
                .help("刷新 History")
            }
        }
    }

    private var historySidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label("Commit 记录", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    if let repository = appState.selectedRepository {
                        Text(repository.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    filterButton(title: branchFilterTitle, icon: "arrow.triangle.branch") {
                        branchQuery = ""
                        showsBranchFilter.toggle()
                    }
                    .popover(isPresented: $showsBranchFilter, arrowEdge: .bottom) {
                        branchFilterPopover
                    }

                    filterButton(title: appState.historyAuthorFilter ?? "全部 User", icon: "person") {
                        userQuery = ""
                        showsUserFilter.toggle()
                    }
                    .popover(isPresented: $showsUserFilter, arrowEdge: .bottom) {
                        userFilterPopover
                    }
                }

                if appState.isLoadingBranches || appState.isLoadingHistoryAuthors {
                    ProgressView().controlSize(.small)
                }
                if let error = appState.branchesErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let error = appState.historyAuthorsErrorMessage {
                    Label(error, systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(appState.commitHistory) { commit in
                        commitRow(commit)
                    }
                    if appState.isLoadingHistory {
                        ProgressView("正在加载 Commit…").padding(8)
                    } else if appState.hasMoreHistory {
                        Button("加载更多", systemImage: "arrow.down.circle") {
                            Task { await appState.loadHistory(reset: false) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                    }
                }
                .padding(8)
            }
            .overlay {
                if let error = appState.historyErrorMessage, appState.commitHistory.isEmpty {
                    ContentUnavailableView("History 不可用", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if !appState.isLoadingHistory,
                          appState.commitHistory.isEmpty,
                          appState.historyErrorMessage == nil {
                    ContentUnavailableView(
                        "没有匹配的 Commit",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("没有 Commit 符合当前 Branch 和 User 筛选。")
                    )
                }
            }
        }
    }

    private var branchFilterPopover: some View {
        SearchableFilterPopover(query: $branchQuery, placeholder: "搜索 Branch") {
            filterOption("当前：\(currentBranchName)", isSelected: appState.historyBranchFilter == .current) {
                appState.selectHistoryBranchFilter(.current)
                showsBranchFilter = false
            }
            filterOption("全部 Branch", isSelected: appState.historyBranchFilter == .all) {
                appState.selectHistoryBranchFilter(.all)
                showsBranchFilter = false
            }
            if !filteredLocalBranches.isEmpty {
                filterSection("本地 Branch")
                ForEach(filteredLocalBranches) { branch in
                    filterOption(branch.name, isSelected: appState.historyBranchFilter == .branch(branch.name)) {
                        appState.selectHistoryBranchFilter(.branch(branch.name))
                        showsBranchFilter = false
                    }
                }
            }
            if !filteredRemoteBranches.isEmpty {
                filterSection("远程 Branch")
                ForEach(filteredRemoteBranches) { branch in
                    filterOption(branch.name, isSelected: appState.historyBranchFilter == .branch(branch.name)) {
                        appState.selectHistoryBranchFilter(.branch(branch.name))
                        showsBranchFilter = false
                    }
                }
            }
        }
    }

    private var userFilterPopover: some View {
        SearchableFilterPopover(query: $userQuery, placeholder: "搜索 User") {
            filterOption("全部 User", isSelected: appState.historyAuthorFilter == nil) {
                appState.selectHistoryAuthorFilter(nil)
                showsUserFilter = false
            }
            ForEach(filteredAuthors, id: \.self) { author in
                filterOption(author, isSelected: appState.historyAuthorFilter == author) {
                    appState.selectHistoryAuthorFilter(author)
                    showsUserFilter = false
                }
            }
        }
    }

    private func filterButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .help("点击后输入关键词筛选")
    }

    private func filterOption(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "checkmark" : "")
                    .frame(width: 12)
                Text(title).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func filterSection(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
    }

    private func commitRow(_ commit: GitCommitSummary) -> some View {
        Button {
            appState.selectCommit(commit.hash)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.subject).lineLimit(2)
                HStack(spacing: 7) {
                    Text(String(commit.hash.prefix(8))).monospaced()
                    Text(commit.author).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = commit.authoredAt {
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !commit.refs.isEmpty {
                    Text(commit.refs.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            appState.selectedCommitHash == commit.hash ? Color.accentColor.opacity(0.14) : .clear,
            in: .rect(cornerRadius: 6)
        )
        .contextMenu {
            Button("复制 Hash") { copy(commit.hash) }
            Button("复制 Commit 信息") { copy(commit.subject) }
        }
    }

    private var commitFilesPanel: some View {
        ZStack {
            Group {
                if let detail = appState.selectedCommitDetail {
                    VStack(alignment: .leading, spacing: 0) {
                        commitHeader(detail)
                        Divider()
                        commitFiles(detail)
                    }
                } else {
                    ContentUnavailableView(
                        "选择一个 Commit",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("选择 Commit 后查看对应的改动文件。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!appState.isLoadingCommit)

            if appState.isLoadingCommit {
                loadingOverlay("正在加载 Commit…")
            } else if let error = appState.commitErrorMessage {
                ContentUnavailableView {
                    Label("Commit 不可用", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    if let hash = appState.selectedCommitHash {
                        Button("重试", systemImage: "arrow.clockwise") { appState.selectCommit(hash) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commitHeader(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(detail.summary.subject)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(detail.summary.author)
                Text(String(detail.summary.hash.prefix(12))).monospaced()
                if let date = detail.summary.authoredAt { Text(date, format: .dateTime) }
            }
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            if !detail.summary.refs.isEmpty {
                Text(detail.summary.refs.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
    }

    private func commitFiles(_ detail: GitCommitDetail) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("改动文件").font(.headline)
                Spacer()
                Text("\(detail.files.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(detail.files) { file in
                        Button {
                            appState.selectCommitFile(file)
                        } label: {
                            HStack(spacing: 7) {
                                FileTypeIcon(path: file.path)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(URL(fileURLWithPath: file.path).lastPathComponent).lineLimit(1)
                                    Text(filePathDetail(file))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                CommitStatusBadge(status: file.status)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .background(
                            appState.selectedCommitFile == file ? Color.accentColor.opacity(0.14) : .clear,
                            in: .rect(cornerRadius: 5)
                        )
                        .help(file.path)
                    }
                }
                .padding(6)
            }
        }
    }

    private var commitFileDiff: some View {
        ZStack {
            Group {
                if let repository = appState.selectedRepository,
                   let file = appState.selectedCommitFile,
                   let diff = appState.commitFileDiff {
                    GitDiffView(
                        diff: diff,
                        ignoresWhitespace: appState.ignoresWhitespaceInDiff,
                        toggleIgnoreWhitespace: appState.toggleIgnoreWhitespace,
                        jumpToSource: { line in
                            appState.jumpToSource(repositoryID: repository.id, path: file.path, line: line)
                        },
                        lockedPresentation: .sideBySide
                    )
                } else {
                    ContentUnavailableView(
                        appState.selectedCommitHash == nil ? "选择一个 Commit" : "选择一个改动文件",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("每次只加载并显示一个文件的 Side-by-side Diff。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!appState.isLoadingCommit && !appState.isLoadingCommitDiff)

            if appState.isLoadingCommit {
                loadingOverlay("正在加载 Commit…")
            } else if appState.isLoadingCommitDiff {
                loadingOverlay("正在加载文件 Diff…")
            } else if let error = appState.commitDiffErrorMessage {
                ContentUnavailableView(
                    "Diff 不可用",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingOverlay(_ title: String) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
            ProgressView(title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredLocalBranches: [GitBranch] {
        FuzzySearch.filteredAndSorted(localBranches, query: branchQuery, text: \.name)
    }

    private var filteredRemoteBranches: [GitBranch] {
        FuzzySearch.filteredAndSorted(remoteBranches, query: branchQuery, text: \.name)
    }

    private var filteredAuthors: [String] {
        FuzzySearch.filteredAndSorted(appState.historyAuthors, query: userQuery) { $0 }
    }

    private var localBranches: [GitBranch] { appState.branches.filter { !$0.isRemote } }
    private var remoteBranches: [GitBranch] {
        appState.branches.filter { $0.isRemote && !$0.name.hasSuffix("/HEAD") }
    }
    private var currentBranchName: String { localBranches.first(where: \.isCurrent)?.name ?? "当前 Branch" }

    private var branchFilterTitle: String {
        switch appState.historyBranchFilter {
        case .current: "当前：\(currentBranchName)"
        case .all: "全部 Branch"
        case .branch(let name): name
        }
    }

    private func filePathDetail(_ file: GitCommitFile) -> String {
        if let originalPath = file.originalPath { return "\(originalPath) → \(file.path)" }
        return file.path
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct CommitStatusBadge: View {
    let status: GitStatusCode

    var body: some View {
        Text(code)
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 18)
            .background(color.opacity(0.12), in: .rect(cornerRadius: 4))
            .help(label)
    }

    private var code: String { String(status.rawValue) }
    private var label: String {
        switch status {
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .updatedButUnmerged: "Conflict"
        case .modified: "Modified"
        default: "Changed"
        }
    }
    private var color: Color {
        switch status {
        case .added, .copied: .green
        case .deleted: .red
        case .renamed: .blue
        case .updatedButUnmerged: .orange
        default: .yellow
        }
    }
}

private enum HistorySplitAxis {
    case verticalStack
    case horizontalStack
}

private struct PersistentHistorySplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let axis: HistorySplitAxis
    @Binding var fraction: Double
    let minimumLeadingLength: CGFloat
    let minimumTrailingLength: CGFloat
    let leading: Leading
    let trailing: Trailing

    init(
        axis: HistorySplitAxis,
        fraction: Binding<Double>,
        minimumLeadingLength: CGFloat,
        minimumTrailingLength: CGFloat,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.axis = axis
        _fraction = fraction
        self.minimumLeadingLength = minimumLeadingLength
        self.minimumTrailingLength = minimumTrailingLength
        self.leading = leading()
        self.trailing = trailing()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fraction: $fraction)
    }

    func makeNSView(context: Context) -> HistoryNSSplitView {
        let splitView = HistoryNSSplitView()
        splitView.isVertical = axis == .horizontalStack
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.addSubview(NSHostingView(rootView: leading))
        splitView.addSubview(NSHostingView(rootView: trailing))
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        context.coordinator.configure(
            fraction: $fraction,
            minimumLeadingLength: minimumLeadingLength,
            minimumTrailingLength: minimumTrailingLength
        )
        splitView.applyStoredPosition = { [weak splitView, weak coordinator = context.coordinator] in
            guard let splitView, let coordinator else { return false }
            return coordinator.applyFraction(to: splitView)
        }
        return splitView
    }

    func updateNSView(_ splitView: HistoryNSSplitView, context: Context) {
        if let leadingHost = splitView.subviews.first as? NSHostingView<Leading> {
            leadingHost.rootView = leading
        }
        if let trailingHost = splitView.subviews.dropFirst().first as? NSHostingView<Trailing> {
            trailingHost.rootView = trailing
        }
        context.coordinator.configure(
            fraction: $fraction,
            minimumLeadingLength: minimumLeadingLength,
            minimumTrailingLength: minimumTrailingLength
        )
        if context.coordinator.applyFraction(to: splitView) {
            splitView.needsStoredPositionRestore = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        private var fraction: Binding<Double>
        private var minimumLeadingLength: CGFloat = 0
        private var minimumTrailingLength: CGFloat = 0
        private var isApplyingFraction = false

        init(fraction: Binding<Double>) {
            self.fraction = fraction
        }

        func configure(
            fraction: Binding<Double>,
            minimumLeadingLength: CGFloat,
            minimumTrailingLength: CGFloat
        ) {
            self.fraction = fraction
            self.minimumLeadingLength = minimumLeadingLength
            self.minimumTrailingLength = minimumTrailingLength
        }

        @discardableResult
        func applyFraction(to splitView: NSSplitView) -> Bool {
            guard splitView.subviews.count == 2 else { return false }
            let availableLength = availableLength(in: splitView)
            guard availableLength > 0 else { return false }
            let position = constrainedPosition(
                CGFloat(fraction.wrappedValue) * availableLength,
                in: splitView
            )
            let currentPosition = leadingLength(in: splitView)
            guard abs(currentPosition - position) > 0.5 else { return true }
            isApplyingFraction = true
            splitView.setPosition(position, ofDividerAt: 0)
            isApplyingFraction = false
            return true
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isApplyingFraction,
                  let splitView = notification.object as? NSSplitView,
                  splitView.subviews.count == 2 else { return }
            let availableLength = availableLength(in: splitView)
            guard availableLength > 0 else { return }
            let updatedFraction = Double(leadingLength(in: splitView) / availableLength)
            let normalized = HistorySplitLayout.normalizedFraction(
                updatedFraction,
                fallback: fraction.wrappedValue
            )
            guard abs(normalized - fraction.wrappedValue) > 0.001 else { return }
            fraction.wrappedValue = normalized
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            max(proposedMinimumPosition, minimumLeadingLength)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            min(
                proposedMaximumPosition,
                max(
                    minimumLeadingLength,
                    totalLength(in: splitView) - splitView.dividerThickness - minimumTrailingLength
                )
            )
        }

        private func constrainedPosition(_ proposedPosition: CGFloat, in splitView: NSSplitView) -> CGFloat {
            let maximum = max(
                minimumLeadingLength,
                totalLength(in: splitView) - splitView.dividerThickness - minimumTrailingLength
            )
            return min(max(proposedPosition, minimumLeadingLength), maximum)
        }

        private func totalLength(in splitView: NSSplitView) -> CGFloat {
            splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        }

        private func availableLength(in splitView: NSSplitView) -> CGFloat {
            max(0, totalLength(in: splitView) - splitView.dividerThickness)
        }

        private func leadingLength(in splitView: NSSplitView) -> CGFloat {
            guard let firstSubview = splitView.subviews.first else { return 0 }
            return splitView.isVertical ? firstSubview.frame.width : firstSubview.frame.height
        }
    }
}

@MainActor
private final class HistoryNSSplitView: NSSplitView {
    var applyStoredPosition: (() -> Bool)?
    var needsStoredPositionRestore = true

    override func layout() {
        super.layout()
        if needsStoredPositionRestore,
           applyStoredPosition?() == true {
            needsStoredPositionRestore = false
        }
    }
}
