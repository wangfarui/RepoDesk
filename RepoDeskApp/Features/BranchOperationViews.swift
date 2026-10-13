import AppKit
import SwiftUI

@MainActor
struct BranchComparisonSheet: View {
    let comparison: GitBranchComparison
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare Branches").font(.headline)
                    Text("\(comparison.comparedBranch) with \(comparison.baseBranch)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
            }
            .padding()
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Commits").font(.caption.weight(.semibold)).padding(10)
                    Divider()
                    List(comparison.commits) { commit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.subject).lineLimit(2)
                            Text("\(commit.author)  \(commit.hash.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .overlay {
                        if comparison.commits.isEmpty { ContentUnavailableView("没有仅存在于该分支的 Commit", systemImage: "checkmark") }
                    }
                }
                .frame(minWidth: 260)
                VStack(alignment: .leading, spacing: 0) {
                    Text("File Diff").font(.caption.weight(.semibold)).padding(10)
                    Divider()
                    ScrollView([.vertical, .horizontal]) {
                        Text(comparison.diffText.isEmpty ? "没有文件差异" : comparison.diffText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(minWidth: 520)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

@MainActor
struct MergeConflictResolverSheet: View {
    @Bindable var appState: AppState
    @State private var selectedPath: String?
    @State private var groupsFilesByDirectory = false
    @State private var showsResolvedFiles = false
    @State private var editorSelection: MergeConflictEditorSelection?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Conflicts")
                    .font(.headline)
                Text(mergeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()

            HStack(spacing: 16) {
                conflictFileList

                VStack(spacing: 10) {
                    Button("Accept Yours") {
                        resolveSelected(with: .ours)
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(selectedUnresolvedFile == nil || appState.isResolvingMergeConflict)

                    Button("Accept Theirs") {
                        resolveSelected(with: .theirs)
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(selectedUnresolvedFile == nil || appState.isResolvingMergeConflict)

                    Button("Merge...", systemImage: "arrow.triangle.merge") {
                        presentEditor()
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFile == nil || selectedFile?.isBinary == true || appState.isResolvingMergeConflict)
                    .accessibilityIdentifier("RepoDesk.MergeConflicts.Merge")

                    Button("Revert Resolution", systemImage: "arrow.uturn.backward") {
                        revertSelectedResolution()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(selectedResolvedFile == nil || appState.isResolvingMergeConflict)

                    Spacer()
                }
                .controlSize(.large)
                .frame(width: 132)
            }
            .padding(16)

            Divider()
            HStack {
                Toggle("Group files by directory", isOn: $groupsFilesByDirectory)
                    .toggleStyle(.checkbox)
                    .disabled(appState.conflictFiles.isEmpty && appState.resolvedConflictFiles.isEmpty)
                Toggle("显示已解决文件", isOn: $showsResolvedFiles)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("RepoDesk.MergeConflicts.ShowResolved")
                Spacer()
                if appState.isResolvingMergeConflict {
                    ProgressView()
                        .controlSize(.small)
                }
                if appState.conflictFiles.isEmpty {
                    Button("Continue Merge", systemImage: "checkmark.circle") {
                        performFooterAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isResolvingMergeConflict)
                } else {
                    Button("Close", systemImage: "xmark") {
                        Task { await appState.closeMergeConflictResolution() }
                    }
                    .disabled(appState.isResolvingMergeConflict)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
        }
        .frame(width: 780, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(true)
        .onAppear { selectFirstFileIfNeeded() }
        .onChange(of: visibleFilePaths) { _, _ in
            selectFirstFileIfNeeded()
        }
        .sheet(item: $editorSelection) { selection in
            MergeConflictEditorSheet(
                file: selection.file,
                yoursBranch: targetBranchName,
                theirsBranch: appState.mergeSourceBranch ?? "Incoming Branch",
                fontSize: appState.fileContentFontSize,
                apply: { result in
                    if appState.conflictFiles.contains(where: { $0.path == selection.file.path }) {
                        return await appState.resolveConflict(path: selection.file.path, result: result)
                    }
                    return await appState.updateResolvedConflict(path: selection.file.path, result: result)
                },
                saveProgress: { result in
                    if appState.conflictFiles.contains(where: { $0.path == selection.file.path }) {
                        return await appState.saveConflictProgress(path: selection.file.path, result: result)
                    }
                    return await appState.updateResolvedConflict(path: selection.file.path, result: result)
                },
                loadBlame: { result in
                    try await appState.blameForMergeConflict(
                        file: selection.file,
                        resultContent: result
                    )
                }
            )
        }
    }

    private var conflictFileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Yours")
                    .frame(width: 92, alignment: .leading)
                Text("Theirs")
                    .frame(width: 92, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()

            if visibleFilePaths.isEmpty {
                ContentUnavailableView(
                    appState.resolvedConflictFiles.isEmpty ? "No conflict files" : "所有冲突已解决",
                    systemImage: "checkmark.circle",
                    description: Text(appState.resolvedConflictFiles.isEmpty
                        ? "The merge operation has no files to review."
                        : "勾选「显示已解决文件」可查看已解决的文件。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedPath) {
                    if groupsFilesByDirectory {
                        if !appState.conflictFiles.isEmpty {
                            ForEach(conflictFileGroups) { group in
                                Section("Unresolved · \(group.directory)") {
                                    ForEach(group.files) { file in
                                        conflictFileRow(file, showsDirectory: false, isResolved: false)
                                    }
                                }
                            }
                        }
                        if !sortedResolvedConflictFiles.isEmpty {
                            ForEach(resolvedConflictFileGroups) { group in
                                Section("Resolved · \(group.directory)") {
                                    ForEach(group.files) { file in
                                        conflictFileRow(file, showsDirectory: false, isResolved: true)
                                    }
                                }
                            }
                        }
                    } else {
                        if !sortedConflictFiles.isEmpty {
                            Section("Unresolved") {
                                ForEach(sortedConflictFiles) { file in
                                    conflictFileRow(file, showsDirectory: true, isResolved: false)
                                }
                            }
                        }
                        if !sortedResolvedConflictFiles.isEmpty {
                            Section("Resolved") {
                                ForEach(sortedResolvedConflictFiles) { file in
                                    conflictFileRow(file, showsDirectory: true, isResolved: true)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func conflictFileRow(
        _ file: GitConflictFile,
        showsDirectory: Bool,
        isResolved: Bool
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                FileTypeIcon(path: file.path)
                Text(fileName(file.path))
                    .lineLimit(1)
                if showsDirectory, let directory = directoryName(file.path) {
                    Text(directory)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(isResolved ? "Resolved" : "Modified")
                .frame(width: 92, alignment: .leading)
            Text(isResolved ? "Resolved" : "Modified")
                .frame(width: 92, alignment: .leading)
        }
        .font(.callout)
        .contentShape(.rect)
        .tag(file.path)
        .onTapGesture(count: 2) {
            selectedPath = file.path
            editorSelection = MergeConflictEditorSelection(file: file)
        }
        .onTapGesture {
            selectedPath = file.path
        }
        .help(file.path)
        .accessibilityIdentifier("RepoDesk.MergeConflicts.Row.\(file.path)")
    }

    private var sortedConflictFiles: [GitConflictFile] {
        appState.conflictFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var sortedResolvedConflictFiles: [GitConflictFile] {
        guard showsResolvedFiles else { return [] }
        return appState.resolvedConflictFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var visibleFilePaths: [String] {
        sortedConflictFiles.map(\.path) + sortedResolvedConflictFiles.map(\.path)
    }

    private var conflictFileGroups: [MergeConflictFileGroup] {
        Dictionary(grouping: sortedConflictFiles) { directoryName($0.path) ?? "." }
            .map { MergeConflictFileGroup(directory: $0.key, files: $0.value) }
            .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }

    private var resolvedConflictFileGroups: [MergeConflictFileGroup] {
        Dictionary(grouping: sortedResolvedConflictFiles) { directoryName($0.path) ?? "." }
            .map { MergeConflictFileGroup(directory: $0.key, files: $0.value) }
            .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }

    private var selectedFile: GitConflictFile? {
        guard let selectedPath else { return nil }
        return appState.conflictFiles.first { $0.path == selectedPath }
            ?? sortedResolvedConflictFiles.first { $0.path == selectedPath }
    }

    private var selectedResolvedFile: GitConflictFile? {
        guard let selectedPath else { return nil }
        return sortedResolvedConflictFiles.first { $0.path == selectedPath }
    }

    private var selectedUnresolvedFile: GitConflictFile? {
        guard let selectedPath else { return nil }
        return appState.conflictFiles.first { $0.path == selectedPath }
    }

    private var targetBranchName: String {
        guard let repositoryID = appState.selectedRepositoryID else { return "Current Branch" }
        if let snapshot = appState.repositorySnapshots[repositoryID] {
            return snapshot.isDetachedHEAD ? "Detached HEAD" : snapshot.branch
        }
        return appState.branches.first(where: \.isCurrent)?.name ?? "Current Branch"
    }

    private var mergeDescription: String {
        "Merging branch \(appState.mergeSourceBranch ?? "incoming") into branch \(targetBranchName)"
    }

    private func selectFirstFileIfNeeded() {
        guard !visibleFilePaths.isEmpty else {
            selectedPath = nil
            return
        }
        if selectedFile == nil {
            selectedPath = sortedConflictFiles.first?.path ?? sortedResolvedConflictFiles.first?.path
        }
    }

    private func resolveSelected(with side: GitConflictSide) {
        guard let path = selectedPath else { return }
        Task {
            _ = await appState.acceptConflictFile(path: path, side: side)
        }
    }

    private func revertSelectedResolution() {
        guard let path = selectedResolvedFile?.path else { return }
        Task { _ = await appState.revertConflictResolution(path: path) }
    }

    private func presentEditor() {
        guard let selectedFile else { return }
        editorSelection = MergeConflictEditorSelection(file: selectedFile)
    }

    private func performFooterAction() {
        Task { await appState.continueMerge() }
    }

    private func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func directoryName(_ path: String) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}

private struct MergeConflictFileGroup: Identifiable {
    let directory: String
    let files: [GitConflictFile]

    var id: String { directory }
}

private struct MergeConflictEditorSelection: Identifiable {
    let file: GitConflictFile

    var id: String { file.path }
}

@MainActor
struct MergeConflictEditorSheet: View {
    let file: GitConflictFile
    let yoursBranch: String
    let theirsBranch: String
    let fontSize: CGFloat
    let apply: (String) async -> Bool
    let saveProgress: (String) async -> Bool
    let loadBlame: (String) async throws -> GitMergeConflictBlame

    @Environment(\.dismiss) private var dismiss
    @State private var document: GitConflictResolutionDocument
    @State private var customDrafts: [Int: String] = [:]
    @State private var selectedConflictID: Int?
    @State private var navigationScope = MergeConflictNavigationScope.unresolved
    @State private var expandedUnchangedSegments: Set<Int> = []
    @State private var horizontalScroll = GitDiffHorizontalScrollSynchronization()
    @State private var horizontalOffset: CGFloat = 0
    @State private var resultContentWidth: CGFloat
    @State private var blameAnnotations: GitMergeConflictBlame?
    @State private var isLoadingBlame = false
    private let yoursContentWidth: CGFloat
    private let theirsContentWidth: CGFloat
    @State private var isApplying = false

    init(
        file: GitConflictFile,
        yoursBranch: String,
        theirsBranch: String,
        fontSize: CGFloat,
        apply: @escaping (String) async -> Bool,
        saveProgress: @escaping (String) async -> Bool = { _ in false },
        loadBlame: @escaping (String) async throws -> GitMergeConflictBlame = { _ in GitMergeConflictBlame() }
    ) {
        self.file = file
        self.yoursBranch = yoursBranch
        self.theirsBranch = theirsBranch
        self.fontSize = fontSize
        self.apply = apply
        self.saveProgress = saveProgress
        self.loadBlame = loadBlame
        let document = GitConflictResolutionDocument(text: file.result, base: file.base)
        let contentWidths = Self.initialContentWidths(
            document: document,
            fontSize: fontSize
        )
        yoursContentWidth = contentWidths.yours
        theirsContentWidth = contentWidths.theirs
        _document = State(initialValue: document)
        _selectedConflictID = State(initialValue: document.unresolvedBlockIDs.first)
        _resultContentWidth = State(initialValue: contentWidths.result)
    }

    var body: some View {
        GeometryReader { geometry in
            let editorHeight = max(
                0,
                geometry.size.height
                    - 46
                    - 32
                    - horizontalScrollerHeight
                    - 58
                    - 4
            )
            let visibleLineCounts = automaticVisibleLineCounts(
                viewportHeight: editorHeight
            )

            ScrollViewReader { scrollProxy in
                VStack(alignment: .leading, spacing: 0) {
                    editorToolbar(scrollProxy: scrollProxy)
                    Divider()
                    paneHeaders
                    Divider()
                    ZStack {
                        paneBackground
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(
                                    Array(document.segments.enumerated()),
                                    id: \.offset
                                ) { index, segment in
                                    switch segment {
                                    case .unchanged(let id, let text):
                                        unchangedSegment(
                                            id: id,
                                            text: text,
                                            segmentIndex: index,
                                            visibleLineCount: visibleLineCounts[id] ?? 0
                                        )
                                    case .conflict(let block):
                                        conflictSegment(block, segmentIndex: index)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier(
                            "RepoDesk.MergeConflictEditor.SynchronizedScroll"
                        )
                    }
                    paneHorizontalScrollers
                    Divider()
                    editorFooter
                }
                .onChange(of: selectedConflictID) { _, conflictID in
                    guard let conflictID else { return }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        scrollProxy.scrollTo(conflictAnchor(conflictID), anchor: .center)
                    }
                }
                .onChange(of: navigationScope) { _, _ in
                    selectAvailableConflict()
                }
                .onAppear {
                    horizontalScroll.onOffsetChange = { offset in
                        horizontalOffset = offset
                    }
                    selectAvailableConflict()
                    guard let selectedConflictID else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollProxy.scrollTo(
                            conflictAnchor(selectedConflictID),
                            anchor: .center
                        )
                    }
                }
                .onDisappear {
                    horizontalScroll.onOffsetChange = nil
                }
            }
        }
        .frame(minWidth: 1240, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isApplying)
    }

    private func editorToolbar(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Merge Revisions")
                    .font(.callout.weight(.semibold))
                Text(file.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(document.unresolvedBlockIDs.count) / \(document.blocks.count) unresolved")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Conflict navigation", selection: $navigationScope) {
                ForEach(MergeConflictNavigationScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 154)
            Button("Previous conflict", systemImage: "chevron.up") {
                navigateConflict(offset: -1, scrollProxy: scrollProxy)
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(previousConflictID == nil)
            .help(navigationScope == .unresolved ? "Previous unresolved conflict" : "Previous conflict")
            Button("Next conflict", systemImage: "chevron.down") {
                navigateConflict(offset: 1, scrollProxy: scrollProxy)
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(nextConflictID == nil)
            .help(navigationScope == .unresolved ? "Next unresolved conflict" : "Next conflict")
            Button(
                expandedUnchangedSegments.isEmpty ? "Expand unchanged lines" : "Collapse unchanged lines",
                systemImage: expandedUnchangedSegments.isEmpty
                    ? "rectangle.expand.vertical"
                    : "rectangle.compress.vertical"
            ) {
                toggleAllUnchangedSegments()
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .help(expandedUnchangedSegments.isEmpty
                ? "Expand all unchanged lines"
                : "Collapse all unchanged lines")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var paneHeaders: some View {
        HStack(spacing: 0) {
            paneHeader(
                title: "Yours",
                subtitle: yoursBranch,
                icon: "arrow.left",
                color: .blue
            )
            Divider()
            paneHeader(
                title: "Result",
                subtitle: file.base == nil ? file.path : "Base → \(file.path)",
                icon: "arrow.triangle.merge",
                color: .orange
            )
            Divider()
            paneHeader(
                title: "Theirs",
                subtitle: theirsBranch,
                icon: "arrow.right",
                color: .purple
            )
        }
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func paneHeader(
        title: String,
        subtitle: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(subtitle)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private var paneBackground: some View {
        HStack(spacing: 0) {
            Color(nsColor: .textBackgroundColor)
            Divider()
            Color(nsColor: .textBackgroundColor)
            Divider()
            Color(nsColor: .textBackgroundColor)
        }
        .allowsHitTesting(false)
    }

    private var paneHorizontalScrollers: some View {
        HStack(spacing: 0) {
            paneHorizontalScroller(.yours)
            Divider()
            paneHorizontalScroller(.result)
            Divider()
            paneHorizontalScroller(.theirs)
        }
        .frame(height: horizontalScrollerHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("RepoDesk.MergeConflictEditor.HorizontalScrollers")
    }

    private func paneHorizontalScroller(_ pane: MergeConflictPane) -> some View {
        MergeConflictHorizontalBar(
            offset: horizontalOffsetBinding(for: pane),
            contentWidth: paneContentWidth(pane)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func unchangedSegment(
        id: Int,
        text: String,
        segmentIndex: Int,
        visibleLineCount: Int
    ) -> some View {
        let lines = Self.lines(in: text)
        let parts = unchangedDisplayParts(
            id: id,
            lineCount: lines.count,
            segmentIndex: segmentIndex,
            visibleLineCount: visibleLineCount
        )
        let starts = lineStarts(for: segmentIndex)
        ForEach(parts) { part in
            switch part {
            case .line(let index):
                synchronizedRow(
                    left: lines[index],
                    result: lines[index],
                    right: lines[index],
                    leftLine: starts.left + index,
                    resultLine: starts.result + index,
                    rightLine: starts.right + index
                )
            case .fold(let hiddenRange):
                foldRow(
                    segmentID: id,
                    hiddenLineCount: hiddenRange.count
                )
            }
        }
    }

    private func synchronizedRow(
        left: String,
        result: String,
        right: String,
        leftLine: Int,
        resultLine: Int,
        rightLine: Int
    ) -> some View {
        HStack(spacing: 0) {
            codeLine(left, lineNumber: leftLine, pane: .yours)
            Divider()
            codeLine(result, lineNumber: resultLine, pane: .result)
            Divider()
            codeLine(right, lineNumber: rightLine, pane: .theirs)
        }
        .frame(height: codeLineHeight)
    }

    private func foldRow(segmentID: Int, hiddenLineCount: Int) -> some View {
        Button {
            expandedUnchangedSegments.insert(segmentID)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.up.chevron.down")
                Text("\(hiddenLineCount) unchanged lines")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .buttonStyle(.plain)
        .help("Expand unchanged lines")
        .accessibilityIdentifier("RepoDesk.MergeConflictEditor.Fold.\(segmentID)")
    }

    private func conflictSegment(
        _ block: GitConflictDocumentBlock,
        segmentIndex: Int
    ) -> some View {
        let isResolved = document.resolution(for: block.id) != nil
        let starts = lineStarts(for: segmentIndex)
        let resultText = displayedResult(for: block)
        let height = conflictContentHeight(block)

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Conflict \(block.id + 1)")
                    .font(.caption2.weight(.semibold))
                Label(
                    isResolved ? "Resolved" : "Unresolved",
                    systemImage: isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(isResolved ? Color.green : Color.orange)
                Spacer()
                if isResolved {
                    Button("Mark unresolved", systemImage: "arrow.uturn.backward") {
                        reopen(block.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Mark this conflict unresolved")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(isResolved
                ? Color.green.opacity(0.08)
                : Color.orange.opacity(0.10))

            HStack(spacing: 0) {
                conflictCodeCell(
                    block.ours,
                    startingLine: starts.left,
                    background: isResolved
                        ? Color(nsColor: .textBackgroundColor)
                        : Color.red.opacity(0.07),
                    pane: .yours,
                    blockID: block.id,
                    height: height
                )
                .overlay(alignment: .trailing) {
                    applyBlockButton(block.id, side: .ours)
                        .offset(x: 13)
                        .zIndex(2)
                }
                Divider()
                resultEditor(
                    block,
                    text: resultText,
                    startingLine: starts.result,
                    height: height
                )
                Divider()
                conflictCodeCell(
                    block.theirs,
                    startingLine: starts.right,
                    background: isResolved
                        ? Color(nsColor: .textBackgroundColor)
                        : Color.red.opacity(0.07),
                    pane: .theirs,
                    blockID: block.id,
                    height: height
                )
                .overlay(alignment: .leading) {
                    applyBlockButton(block.id, side: .theirs)
                        .offset(x: -13)
                        .zIndex(2)
                }
            }
            .frame(height: height)
        }
        .id(conflictAnchor(block.id))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(selectedConflictID == block.id ? Color.accentColor : Color.clear)
                .frame(width: 2)
        }
        .overlay(alignment: .top) {
            Divider()
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
        .contentShape(.rect)
        .onTapGesture {
            selectedConflictID = block.id
        }
        .accessibilityIdentifier("RepoDesk.MergeConflictEditor.Conflict.\(block.id)")
    }

    private func conflictCodeCell(
        _ text: String,
        startingLine: Int,
        background: Color,
        pane: MergeConflictPane,
        blockID: Int,
        height: CGFloat
    ) -> some View {
        let lines = Self.lines(in: text)
        let displayLines = lines.isEmpty ? [""] : lines
        return GitDiffHorizontalScrollView(
            identifier: "RepoDesk.MergeConflictEditor.\(pane.rawValue).Conflict.\(blockID)",
            contentWidth: paneContentWidth(pane),
            contentHeight: height,
            synchronization: horizontalSynchronization(for: pane),
            showsHorizontalScroller: false
        ) {
            HStack(spacing: 0) {
                if blameIsVisible {
                    VStack(spacing: 0) {
                        ForEach(displayLines.indices, id: \.self) { index in
                            blameCell(startingLine + index, pane: pane)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayLines.indices, id: \.self) { index in
                        HStack(spacing: 9) {
                            Text(String(startingLine + index))
                                .font(.system(size: max(9, fontSize - 2), design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 38, alignment: .trailing)
                            Divider()
                            Text(displayLines[index].isEmpty ? " " : displayLines[index])
                                .font(.system(size: fontSize, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(height: codeLineHeight, alignment: .leading)
                        .contextMenu { blameContextMenu() }
                    }
                }
            }
            .padding(.horizontal, 7)
                .frame(
                    width: paneContentWidth(pane),
                    height: height,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
    }

    private func resultEditor(
        _ block: GitConflictDocumentBlock,
        text: String,
        startingLine: Int,
        height: CGFloat
    ) -> some View {
        let contentWidth = paneContentWidth(.result)
        let resultText = customDrafts[block.id] ?? text
        let resultLines = Self.lines(in: resultText)
        let displayLines = resultLines.isEmpty ? [""] : resultLines
        let blameWidth = blameIsVisible ? GitBlameAnnotationCell.width : 0
        let editorWidth = max(1, contentWidth - blameWidth)
        return GitDiffHorizontalScrollView(
            identifier: "RepoDesk.MergeConflictEditor.Result.Conflict.\(block.id)",
            contentWidth: contentWidth,
            contentHeight: height,
            synchronization: horizontalSynchronization(for: .result),
            showsHorizontalScroller: false
        ) {
            ZStack(alignment: .topLeading) {
                if blameIsVisible {
                    VStack(spacing: 0) {
                        ForEach(displayLines.indices, id: \.self) { index in
                            blameCell(startingLine + index, pane: .result)
                        }
                    }
                    .frame(width: blameWidth, alignment: .topLeading)
                }
                TextField("", text: customDraftBinding(for: block), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, design: .monospaced))
                    .padding(.leading, 56)
                    .padding(.trailing, 7)
                    .padding(.vertical, 7)
                    .frame(
                        width: editorWidth,
                        height: height,
                        alignment: .topLeading
                    )
                    .offset(x: blameWidth)
                VStack(spacing: 0) {
                    ForEach(displayLines.indices, id: \.self) { index in
                        Text(String(startingLine + index))
                            .font(.system(size: max(9, fontSize - 2), design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 42, height: codeLineHeight, alignment: .trailing)
                            .contextMenu { blameContextMenu() }
                    }
                }
                .padding(.top, 7)
                .offset(x: blameWidth)
                if text.isEmpty {
                        Text("Base revision")
                        .font(.system(size: max(11, fontSize - 1), design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 58 + blameWidth)
                        .padding(.top, 7)
                        .allowsHitTesting(false)
                }
                if customDrafts[block.id] != nil {
                    Button("Use edited result", systemImage: "checkmark") {
                        acceptCustomDraft(block.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(
                        width: contentWidth,
                        height: height,
                        alignment: .bottomTrailing
                    )
                    .padding(8)
                    .help("Use edited result")
                }
            }
            .frame(width: contentWidth, height: height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(document.resolution(for: block.id) == nil
            ? Color.orange.opacity(0.06)
            : Color.green.opacity(0.06))
    }

    private func codeLine(
        _ text: String,
        lineNumber: Int,
        pane: MergeConflictPane
    ) -> some View {
        let contentWidth = paneContentWidth(pane)
        return GitDiffHorizontalScrollView(
            identifier: "RepoDesk.MergeConflictEditor.\(pane.rawValue).Line.\(lineNumber)",
            contentWidth: contentWidth,
            contentHeight: codeLineHeight,
            synchronization: horizontalSynchronization(for: pane),
            showsHorizontalScroller: false
        ) {
            HStack(spacing: 9) {
                blameCell(lineNumber, pane: pane)
                Text(String(lineNumber))
                    .font(.system(size: max(9, fontSize - 2), design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
                Divider()
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 7)
            .frame(
                width: contentWidth,
                height: codeLineHeight,
                alignment: .leading
            )
            .contextMenu { blameContextMenu() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func applyBlockButton(
        _ blockID: Int,
        side: GitConflictSide
    ) -> some View {
        Button(
            side == .ours ? "Apply Yours" : "Apply Theirs",
            systemImage: side == .ours ? "chevron.right.2" : "chevron.left.2"
        ) {
            accept(blockID, side: side)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .controlSize(.small)
        .frame(width: 24, height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .help(side == .ours ? "Apply Yours to Result" : "Apply Theirs to Result")
        .accessibilityIdentifier(
            "RepoDesk.MergeConflictEditor.Apply.\(blockID).\(side == .ours ? "Yours" : "Theirs")"
        )
    }

    private var editorFooter: some View {
        HStack(spacing: 10) {
            Label(
                footerStatus,
                systemImage: canApply ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if isApplying {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Cancel", role: .cancel) { dismiss() }
                .disabled(isApplying)
            Button("Save Progress", systemImage: "square.and.arrow.down") {
                saveCurrentProgress()
            }
            .disabled(isApplying)
            Button("Apply", systemImage: "checkmark") {
                applyResult()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isApplying || !canApply)
            .accessibilityIdentifier("RepoDesk.MergeConflictEditor.Apply")
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    private var codeLineHeight: CGFloat {
        max(22, ceil(fontSize + 8))
    }

    private var horizontalScrollerHeight: CGFloat {
        max(
            14,
            GitDiffLayoutMetrics.horizontalScrollerReserve
        )
    }

    private func horizontalSynchronization(
        for _: MergeConflictPane
    ) -> GitDiffHorizontalScrollSynchronization {
        horizontalScroll
    }

    private func horizontalOffsetBinding(
        for _: MergeConflictPane
    ) -> Binding<CGFloat> {
        Binding(
            get: {
                horizontalOffset
            },
            set: { offset in
                horizontalOffset = offset
                horizontalScroll.scroll(to: offset)
            }
        )
    }

    private func paneContentWidth(_ pane: MergeConflictPane) -> CGFloat {
        let baseWidth: CGFloat
        switch pane {
        case .yours: baseWidth = yoursContentWidth
        case .result: baseWidth = resultContentWidth
        case .theirs: baseWidth = theirsContentWidth
        }
        return baseWidth + (blameIsVisible ? GitBlameAnnotationCell.width : 0)
    }

    private var blameIsVisible: Bool {
        blameAnnotations != nil
    }

    private func blame(for pane: MergeConflictPane) -> [Int: GitBlameLine] {
        switch pane {
        case .yours: blameAnnotations?.yours ?? [:]
        case .result: blameAnnotations?.result ?? [:]
        case .theirs: blameAnnotations?.theirs ?? [:]
        }
    }

    @ViewBuilder
    private func blameContextMenu() -> some View {
        Button {
            toggleBlame()
        } label: {
            if blameIsVisible {
                Label("Close Annotations", systemImage: "checkmark")
            } else if isLoadingBlame {
                Label("Loading Git Blame…", systemImage: "hourglass")
            } else {
                Label("Annotation With Git Blame", systemImage: "person.text.rectangle")
            }
        }
        .disabled(isLoadingBlame)
    }

    private func toggleBlame() {
        guard !isLoadingBlame else { return }
        if blameIsVisible {
            blameAnnotations = nil
            return
        }
        isLoadingBlame = true
        Task {
            let annotations = try? await loadBlame(document.renderedText(overrides: customDrafts))
            await MainActor.run {
                if let annotations {
                    blameAnnotations = annotations
                }
                isLoadingBlame = false
            }
        }
    }

    @ViewBuilder
    private func blameCell(_ lineNumber: Int, pane: MergeConflictPane) -> some View {
        if blameIsVisible {
            GitBlameAnnotationCell(
                blame: blame(for: pane)[lineNumber],
                height: codeLineHeight
            )
        }
    }

    private static func initialContentWidths(
        document: GitConflictResolutionDocument,
        fontSize: CGFloat
    ) -> MergeConflictPaneWidths {
        func paneLines(_ pane: MergeConflictPane) -> [String] {
            document.segments.flatMap { segment -> [String] in
                switch segment {
                case .unchanged(_, let text):
                    return lines(in: text)
                case .conflict(let block):
                    switch pane {
                    case .yours:
                        return lines(in: block.ours)
                    case .result:
                        return lines(in: document.resolution(for: block.id) ?? block.base)
                    case .theirs:
                        return lines(in: block.theirs)
                    }
                }
            }
        }
        return MergeConflictPaneWidths(
            yours: measuredContentWidth(lines: paneLines(.yours), fontSize: fontSize),
            result: measuredContentWidth(lines: paneLines(.result), fontSize: fontSize),
            theirs: measuredContentWidth(lines: paneLines(.theirs), fontSize: fontSize)
        )
    }

    private static func measuredContentWidth(
        lines: [String],
        fontSize: CGFloat
    ) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let width = lines.reduce(CGFloat.zero) { maximum, line in
            max(maximum, ceil((line as NSString).size(withAttributes: attributes).width))
        }
        return max(GitDiffLayoutMetrics.minimumSidePaneWidth, width + 92)
    }

    private func expandResultContentWidth(toFit text: String) {
        let requiredWidth = Self.measuredContentWidth(
            lines: Self.lines(in: text),
            fontSize: fontSize
        )
        if requiredWidth > resultContentWidth {
            resultContentWidth = requiredWidth
        }
    }

    private func automaticVisibleLineCounts(
        viewportHeight: CGFloat
    ) -> [Int: Int] {
        let unchanged = document.segments.enumerated().compactMap {
            index,
            segment -> (id: Int, count: Int, minimum: Int)? in
            guard case .unchanged(let id, let text) = segment else { return nil }
            let count = Self.lines(in: text).count
            let edgeSegment = index == 0 || index == document.segments.count - 1
            return (id, count, edgeSegment ? min(3, count) : min(6, count))
        }
        var allocations = Dictionary(uniqueKeysWithValues: unchanged.map { segment in
            (
                segment.id,
                expandedUnchangedSegments.contains(segment.id)
                    ? segment.count
                    : segment.minimum
            )
        })
        let conflictsHeight = document.blocks.reduce(CGFloat.zero) {
            $0 + 24 + conflictContentHeight($1)
        }

        func targetLineCount(foldCount: Int) -> Int {
            let availableHeight = max(
                0,
                viewportHeight - conflictsHeight - CGFloat(foldCount) * 26
            )
            return Int(floor(availableHeight / codeLineHeight))
        }

        func distribute(to target: Int, allocations: inout [Int: Int]) {
            while allocations.values.reduce(0, +) < target {
                var addedLine = false
                for segment in unchanged
                where !expandedUnchangedSegments.contains(segment.id) {
                    let current = allocations[segment.id] ?? 0
                    guard current < segment.count else { continue }
                    allocations[segment.id] = current + 1
                    addedLine = true
                    if allocations.values.reduce(0, +) >= target { break }
                }
                if !addedLine { break }
            }
        }

        let initialFoldCount = unchanged.filter {
            !expandedUnchangedSegments.contains($0.id)
                && (allocations[$0.id] ?? 0) < $0.count
        }.count
        distribute(
            to: targetLineCount(foldCount: initialFoldCount),
            allocations: &allocations
        )
        let finalFoldCount = unchanged.filter {
            (allocations[$0.id] ?? 0) < $0.count
        }.count
        distribute(
            to: targetLineCount(foldCount: finalFoldCount),
            allocations: &allocations
        )
        return allocations
    }

    private func conflictContentHeight(_ block: GitConflictDocumentBlock) -> CGFloat {
        let resultText = displayedResult(for: block)
        let lineCount = max(
            1,
            Self.lines(in: block.ours).count,
            Self.lines(in: block.theirs).count,
            Self.lines(in: resultText).count
        )
        return max(48, CGFloat(lineCount) * codeLineHeight + 14)
    }

    private var canApply: Bool {
        document.isResolved && customDrafts.isEmpty
    }

    private var footerStatus: String {
        if !document.isResolved {
            return "Resolve every conflict before applying"
        }
        if !customDrafts.isEmpty {
            return "Confirm edited results before applying"
        }
        return "All conflicts resolved"
    }

    private var navigationBlockIDs: [Int] {
        navigationScope.blockIDs(
            allBlockIDs: document.blocks.map(\.id),
            unresolvedBlockIDs: document.unresolvedBlockIDs
        )
    }

    private var previousConflictID: Int? {
        adjacentConflictID(offset: -1)
    }

    private var nextConflictID: Int? {
        adjacentConflictID(offset: 1)
    }

    private func adjacentConflictID(offset: Int) -> Int? {
        let ids = navigationBlockIDs
        guard !ids.isEmpty else { return nil }
        guard let selectedConflictID,
              let index = ids.firstIndex(of: selectedConflictID) else {
            return offset > 0 ? ids.first : ids.last
        }
        let nextIndex = index + offset
        guard ids.indices.contains(nextIndex) else { return nil }
        return ids[nextIndex]
    }

    private func navigateConflict(offset: Int, scrollProxy: ScrollViewProxy) {
        guard let conflictID = adjacentConflictID(offset: offset) else { return }
        if selectedConflictID == conflictID {
            withAnimation(.easeInOut(duration: 0.16)) {
                scrollProxy.scrollTo(conflictAnchor(conflictID), anchor: .center)
            }
        } else {
            selectedConflictID = conflictID
        }
    }

    private func accept(_ blockID: Int, side: GitConflictSide) {
        let previousIDs = navigationBlockIDs
        let previousIndex = previousIDs.firstIndex(of: blockID) ?? 0
        customDrafts.removeValue(forKey: blockID)
        document.resolve(blockID, with: side)
        if let block = document.blocks.first(where: { $0.id == blockID }) {
            expandResultContentWidth(toFit: side == .ours ? block.ours : block.theirs)
        }
        selectAfterResolution(previousIndex: previousIndex, resolvedID: blockID)
    }

    private func acceptCustomDraft(_ blockID: Int) {
        guard let draft = customDrafts.removeValue(forKey: blockID) else { return }
        let previousIDs = navigationBlockIDs
        let previousIndex = previousIDs.firstIndex(of: blockID) ?? 0
        document.resolve(blockID, with: draft)
        expandResultContentWidth(toFit: draft)
        selectAfterResolution(previousIndex: previousIndex, resolvedID: blockID)
    }

    private func reopen(_ blockID: Int) {
        if customDrafts[blockID] == nil {
            customDrafts[blockID] = document.resolution(for: blockID) ?? ""
        }
        expandResultContentWidth(toFit: customDrafts[blockID] ?? "")
        document.markUnresolved(blockID)
        selectedConflictID = blockID
    }

    private func selectAfterResolution(previousIndex: Int, resolvedID: Int) {
        guard navigationScope == .unresolved else {
            selectedConflictID = resolvedID
            return
        }
        let remaining = navigationBlockIDs
        selectedConflictID = remaining.isEmpty
            ? nil
            : remaining[min(previousIndex, remaining.count - 1)]
    }

    private func selectAvailableConflict() {
        let ids = navigationBlockIDs
        guard !ids.isEmpty else {
            selectedConflictID = nil
            return
        }
        if let selectedConflictID, ids.contains(selectedConflictID) { return }
        self.selectedConflictID = ids.first
    }

    private func displayedResult(for block: GitConflictDocumentBlock) -> String {
        customDrafts[block.id] ?? document.resolution(for: block.id) ?? block.base
    }

    private func customDraftBinding(for block: GitConflictDocumentBlock) -> Binding<String> {
        Binding(
            get: { displayedResult(for: block) },
            set: {
                customDrafts[block.id] = $0
                expandResultContentWidth(toFit: $0)
            }
        )
    }

    private func toggleAllUnchangedSegments() {
        if expandedUnchangedSegments.isEmpty {
            expandedUnchangedSegments = Set(
                document.segments.compactMap { segment in
                    guard case .unchanged(let id, let text) = segment,
                          Self.lines(in: text).count > 8 else { return nil }
                    return id
                }
            )
        } else {
            expandedUnchangedSegments.removeAll()
        }
    }

    private func unchangedDisplayParts(
        id: Int,
        lineCount: Int,
        segmentIndex: Int,
        visibleLineCount: Int
    ) -> [MergeUnchangedDisplayPart] {
        let visibleLineCount = expandedUnchangedSegments.contains(id)
            ? lineCount
            : min(lineCount, max(0, visibleLineCount))
        guard visibleLineCount < lineCount else {
            return (0..<lineCount).map(MergeUnchangedDisplayPart.line)
        }
        if segmentIndex == 0 {
            let visible = max(0, lineCount - visibleLineCount)..<lineCount
            return [.fold(0..<visible.lowerBound)] + visible.map(MergeUnchangedDisplayPart.line)
        }
        if segmentIndex == document.segments.count - 1 {
            let visible = 0..<visibleLineCount
            return visible.map(MergeUnchangedDisplayPart.line)
                + [.fold(visible.upperBound..<lineCount)]
        }
        let leadingCount = (visibleLineCount + 1) / 2
        let trailingCount = visibleLineCount / 2
        let leading = 0..<leadingCount
        let trailing = (lineCount - trailingCount)..<lineCount
        return leading.map(MergeUnchangedDisplayPart.line)
            + [.fold(leading.upperBound..<trailing.lowerBound)]
            + trailing.map(MergeUnchangedDisplayPart.line)
    }

    private func lineStarts(for segmentIndex: Int) -> MergeConflictLineStarts {
        var starts = MergeConflictLineStarts(left: 1, result: 1, right: 1)
        for segment in document.segments.prefix(segmentIndex) {
            switch segment {
            case .unchanged(_, let text):
                let count = Self.lines(in: text).count
                starts.left += count
                starts.result += count
                starts.right += count
            case .conflict(let block):
                starts.left += Self.lines(in: block.ours).count
                starts.right += Self.lines(in: block.theirs).count
                let result = displayedResult(for: block)
                starts.result += max(1, Self.lines(in: result).count)
            }
        }
        return starts
    }

    private func numberedText(_ text: String, startingLine: Int) -> String {
        Self.lines(in: text).enumerated().map { index, line in
            let number = String(startingLine + index)
            let padding = String(repeating: " ", count: max(0, 4 - number.count))
            return "\(padding)\(number)  \(line)"
        }.joined(separator: "\n")
    }

    private func conflictAnchor(_ blockID: Int) -> String {
        "merge-conflict-\(blockID)"
    }

    private static func lines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private func applyResult() {
        isApplying = true
        Task {
            let didApply = await apply(document.renderedText())
            isApplying = false
            if didApply { dismiss() }
        }
    }

    private func saveCurrentProgress() {
        isApplying = true
        Task {
            let didSave = await saveProgress(document.renderedText(overrides: customDrafts))
            isApplying = false
            if didSave { dismiss() }
        }
    }
}

private enum MergeConflictPane: String {
    case yours
    case result
    case theirs
}

private struct MergeConflictPaneWidths {
    var yours: CGFloat
    var result: CGFloat
    var theirs: CGFloat
}

@MainActor
private struct MergeConflictHorizontalBar: View {
    @Binding var offset: CGFloat
    let contentWidth: CGFloat

    @State private var dragStartOffset: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let horizontalInset: CGFloat = 5
            let trackWidth = max(1, geometry.size.width - horizontalInset * 2)
            let maximumOffset = max(0, contentWidth - geometry.size.width)
            let visibleFraction = min(1, geometry.size.width / max(1, contentWidth))
            let thumbWidth = min(
                trackWidth,
                max(44, floor(trackWidth * visibleFraction))
            )
            let thumbTravel = max(0, trackWidth - thumbWidth)
            let thumbOffset = maximumOffset > 0
                ? min(thumbTravel, max(0, offset / maximumOffset * thumbTravel))
                : 0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .secondaryLabelColor).opacity(
                        maximumOffset > 0 ? 0.72 : 0.24
                    ))
                    .frame(width: thumbWidth, height: 8)
                    .offset(x: thumbOffset)
            }
            .frame(width: trackWidth, height: geometry.size.height)
            .padding(.horizontal, horizontalInset)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard maximumOffset > 0, thumbTravel > 0 else { return }
                        if dragStartOffset == nil {
                            let localX = value.startLocation.x - horizontalInset
                            if localX < thumbOffset || localX > thumbOffset + thumbWidth {
                                offset = min(
                                    maximumOffset,
                                    max(
                                        0,
                                        (localX - thumbWidth / 2)
                                            / thumbTravel
                                            * maximumOffset
                                    )
                                )
                            }
                            dragStartOffset = offset
                        }
                        let start = dragStartOffset ?? offset
                        offset = min(
                            maximumOffset,
                            max(
                                0,
                                start
                                    + value.translation.width
                                        / thumbTravel
                                        * maximumOffset
                            )
                        )
                    }
                    .onEnded { _ in
                        dragStartOffset = nil
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Horizontal scroll")
        .accessibilityValue(
            contentWidth <= 0
                ? "0%"
                : "\(Int(min(100, max(0, offset / contentWidth * 100))))%"
        )
    }
}

enum MergeConflictNavigationScope: String, CaseIterable, Identifiable {
    case unresolved
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unresolved: "Unresolved"
        case .all: "All"
        }
    }

    func blockIDs(
        allBlockIDs: [Int],
        unresolvedBlockIDs: [Int]
    ) -> [Int] {
        switch self {
        case .unresolved:
            unresolvedBlockIDs
        case .all:
            allBlockIDs
        }
    }
}

private enum MergeUnchangedDisplayPart: Identifiable {
    case line(Int)
    case fold(Range<Int>)

    var id: String {
        switch self {
        case .line(let index): "line-\(index)"
        case .fold(let range): "fold-\(range.lowerBound)-\(range.upperBound)"
        }
    }
}

private struct MergeConflictLineStarts {
    var left: Int
    var result: Int
    var right: Int
}
