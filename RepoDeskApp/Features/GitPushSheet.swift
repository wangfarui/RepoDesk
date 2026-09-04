import AppKit
import SwiftUI

@MainActor
struct GitPushSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var targetFieldFocused: Bool

    @State private var preparation: GitPushPreparation?
    @State private var targetBranch = ""
    @State private var selectedCommitHashes: Set<String> = []
    @State private var commitRange: GitPushCommitRange?
    @State private var selectedFile: GitCommitFile?
    @State private var pushDiffWindow = GitDiffWindowController(
        frameAutosaveName: "RepoDesk.GitPushDiff"
    )
    @State private var expandedFileNodeIDs: Set<String> = []
    @State private var preparationError: String?
    @State private var rangeError: String?
    @State private var isLoadingPreparation = false
    @State private var isLoadingRange = false
    @State private var isPushing = false
    @State private var didLoadInitialPreparation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                pushContents
                    .frame(
                        minWidth: 370,
                        idealWidth: 430,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                changedFiles
                    .frame(
                        minWidth: 620,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(
            minWidth: 1_040,
            idealWidth: 1_120,
            maxWidth: .infinity,
            minHeight: 680,
            idealHeight: 680,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            pushDiffWindow.close()
        }
        .task {
            await loadPreparation(target: nil)
        }
        .task(id: targetBranch) {
            guard didLoadInitialPreparation,
                  targetBranch != preparation?.targetRemoteBranch else { return }
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            await loadPreparation(target: targetBranch)
        }
        .task(id: selectedCommitSelectionID) {
            await loadSelectedCommitRange()
        }
        .onChange(of: targetBranch) { oldValue, newValue in
            guard oldValue != newValue else { return }
            pushDiffWindow.close()
        }
        .onChange(of: selectedCommitSelectionID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            pushDiffWindow.close()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Push Commits")
                    .font(.headline)
                if let repository = appState.selectedRepository {
                    Text(repository.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isLoadingPreparation || isLoadingRange {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private var pushContents: some View {
        VStack(spacing: 0) {
            targetEditor
            Divider()
            HStack {
                Text("Commits")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let preparation {
                    Text("\(selectedCommitHashes.count)/\(preparation.commits.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()
            commitList
        }
    }

    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preparation {
                HStack(spacing: 6) {
                    Text(preparation.localBranch)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Text(preparation.remote)
                        .foregroundStyle(.secondary)
                    Text("/")
                        .foregroundStyle(.tertiary)
                    TextField("远程 Branch", text: $targetBranch)
                        .textFieldStyle(.roundedBorder)
                        .focused($targetFieldFocused)
                        .onSubmit {
                            Task { await loadPreparation(target: targetBranch) }
                        }
                }

                if targetFieldFocused, !filteredRemoteBranches.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredRemoteBranches, id: \.self) { branch in
                                Button {
                                    targetBranch = branch
                                    targetFieldFocused = false
                                    Task { await loadPreparation(target: branch) }
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.triangle.branch")
                                        Text(branch)
                                            .lineLimit(1)
                                        Spacer()
                                        if branch == preparation.targetRemoteBranch {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8)
                                .frame(height: 27)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 126)
                    .background(.background, in: .rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: preparation.createsRemoteBranch ? "plus.circle" : "link")
                    Text(
                        preparation.createsRemoteBranch
                            ? "Push 时创建远程 Branch，并设置为当前本地 Branch 的 upstream。"
                            : "Push 到已有远程 Branch。"
                    )
                }
                .font(.caption)
                .foregroundStyle(preparation.createsRemoteBranch ? .blue : .secondary)
            } else if isLoadingPreparation {
                ProgressView("正在读取 Push 信息…")
                    .controlSize(.small)
            }

            if let message = preparation?.blockingMessage ?? preparationError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var commitList: some View {
        if let preparation, !preparation.commits.isEmpty {
            List(preparation.commits, selection: $selectedCommitHashes) { commit in
                VStack(alignment: .leading, spacing: 4) {
                    Text(commit.subject)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(String(commit.hash.prefix(8)))
                            .font(.caption.monospaced())
                        Text(commit.author)
                            .lineLimit(1)
                        if let date = commit.authoredAt {
                            Text(date, style: .relative)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(commit.hash)
            }
        } else if let preparation, preparation.createsRemoteBranch {
            ContentUnavailableView(
                "创建远程 Branch",
                systemImage: "arrow.triangle.branch",
                description: Text("当前提交对象已存在于远程仓库；Push 将创建新的远程 Branch 引用。")
            )
        } else if preparation != nil, !isLoadingPreparation {
            ContentUnavailableView(
                "没有需要 Push 的 Commit",
                systemImage: "checkmark.circle",
                description: Text("本地 Branch 与目标远程 Branch 已同步。")
            )
        } else if let preparationError {
            ContentUnavailableView(
                "Push 信息不可用",
                systemImage: "exclamationmark.triangle",
                description: Text(preparationError)
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var changedFiles: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let commitRange {
                    Text("\(commitRange.files.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()
            fileTree
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var fileTree: some View {
        if isLoadingRange {
            ProgressView("正在合并 Commit 改动…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let rangeError {
            ContentUnavailableView(
                "文件列表不可用",
                systemImage: "exclamationmark.triangle",
                description: Text(rangeError)
            )
        } else if let commitRange, !commitRange.files.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(fileOutlineRows) { row in
                        fileOutlineRow(row)
                    }
                }
                .padding(6)
            }
        } else {
            ContentUnavailableView(
                selectedCommitHashes.isEmpty ? "选择 Commit" : "没有文件变化",
                systemImage: "doc.text.magnifyingglass",
                description: Text("选择一个或多个 Commit 后合并展示累计改动。")
            )
        }
    }

    @ViewBuilder
    private func fileOutlineRow(_ row: HistoryFileOutlineRow) -> some View {
        switch row {
        case .directory(let id, let name, _, let depth, let count, _):
            Button {
                if expandedFileNodeIDs.remove(id) == nil {
                    expandedFileNodeIDs.insert(id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expandedFileNodeIDs.contains(id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(name)
                        .lineLimit(1)
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(depth) * 14)
            .frame(height: 25)
        case .module:
            EmptyView()
        case .file(_, let file, let depth, _):
            HStack(spacing: 6) {
                FileTypeIcon(path: file.path)
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .lineLimit(1)
                Spacer()
                GitPushStatusBadge(status: file.status)
            }
            .contentShape(.rect)
            .onTapGesture(count: 2) {
                selectedFile = file
                if let commitRange {
                    pushDiffWindow.present(title: "Push Diff - \(fileName(file.path))") {
                        GitPushFileDiffWindowContent(
                            appState: appState,
                            range: commitRange,
                            file: file,
                            close: { pushDiffWindow.close() }
                        )
                    }
                }
            }
            .onTapGesture {
                selectedFile = file
            }
            .padding(.horizontal, 5)
            .padding(.leading, CGFloat(depth) * 14)
            .frame(height: 27)
            .background(
                selectedFile == file ? Color.accentColor.opacity(0.14) : .clear,
                in: .rect(cornerRadius: 5)
            )
            .help(file.path)
        }
    }

    private var footer: some View {
        HStack {
            if let preparation {
                Text("\(preparation.localBranch) → \(preparation.remote)/\(preparation.targetRemoteBranch)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                pushDiffWindow.close()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button {
                guard let preparation else { return }
                isPushing = true
                Task {
                    let succeeded = await appState.push(preparation)
                    isPushing = false
                    if succeeded {
                        pushDiffWindow.close()
                        dismiss()
                    }
                }
            } label: {
                if isPushing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Push", systemImage: "arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(preparation?.canPush != true || isLoadingPreparation || isPushing)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private var filteredRemoteBranches: [String] {
        guard let preparation else { return [] }
        let query = targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return preparation.remoteBranches }
        return preparation.remoteBranches.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedCommits: [GitCommitSummary] {
        preparation?.commits.filter { selectedCommitHashes.contains($0.hash) } ?? []
    }

    private var selectedCommitSelectionID: GitPushCommitSelectionID {
        GitPushCommitSelectionID(hashes: selectedCommits.map(\.hash))
    }

    private var fileOutlineRows: [HistoryFileOutlineRow] {
        guard let commitRange else { return [] }
        return HistoryFileOutlineBuilder.rows(
            files: commitRange.files,
            namespace: "push",
            repositoryName: appState.selectedRepository?.name ?? "Repository",
            grouping: .directory,
            expandedNodeIDs: expandedFileNodeIDs,
            modulePath: { _ in "." }
        )
    }

    private func loadPreparation(target: String?) async {
        pushDiffWindow.close()
        isLoadingPreparation = true
        preparationError = nil
        do {
            let loaded = try await appState.pushPreparation(targetRemoteBranch: target)
            try Task.checkCancellation()
            preparation = loaded
            targetBranch = loaded.targetRemoteBranch
            selectedCommitHashes = Set(loaded.commits.first.map { [$0.hash] } ?? [])
            didLoadInitialPreparation = true
        } catch is CancellationError {
            return
        } catch {
            preparation = nil
            commitRange = nil
            selectedFile = nil
            preparationError = error.localizedDescription
            didLoadInitialPreparation = true
        }
        isLoadingPreparation = false
    }

    private func loadSelectedCommitRange() async {
        pushDiffWindow.close()
        guard didLoadInitialPreparation, !selectedCommits.isEmpty else {
            commitRange = nil
            selectedFile = nil
            rangeError = nil
            return
        }
        isLoadingRange = true
        rangeError = nil
        do {
            let loaded = try await appState.pushCommitRange(selectedCommits)
            try Task.checkCancellation()
            commitRange = loaded
            expandedFileNodeIDs = HistoryFileOutlineBuilder.expandableNodeIDs(
                files: loaded.files,
                namespace: "push",
                grouping: .directory,
                modulePath: { _ in "." }
            )
            if let selectedFile, loaded.files.contains(selectedFile) {
                self.selectedFile = selectedFile
            } else {
                selectedFile = loaded.files.first
            }
        } catch is CancellationError {
            return
        } catch {
            commitRange = nil
            selectedFile = nil
            rangeError = error.localizedDescription
        }
        isLoadingRange = false
    }

}

private struct GitPushCommitSelectionID: Hashable {
    let hashes: [String]
}

@MainActor
struct GitPushFileDiffWindowContent: View {
    @Bindable var appState: AppState
    let range: GitPushCommitRange
    let file: GitCommitFile
    let close: () -> Void

    @State private var diff: GitFileDiff?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var loadRequestID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FileTypeIcon(path: file.path)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                        .font(.headline)
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("关闭", systemImage: "xmark") {
                    close()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(WindowDragArea())
            Divider()

            Group {
                if isLoading {
                    ProgressView("正在加载 Diff…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Diff 不可用",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if let diff {
                    GitDiffView(
                        diff: diff,
                        ignoresWhitespace: appState.ignoresWhitespaceInDiff,
                        toggleIgnoreWhitespace: appState.toggleIgnoreWhitespace,
                        jumpToSource: { _ in },
                        lockedPresentation: .sideBySide,
                        fontSize: CGFloat(appState.fileContentFontSize)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .repoDeskFontSize(appState.interfaceFontSize)
        .frame(minWidth: 1_050, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: loadID) {
            await loadDiff(for: loadID)
        }
    }

    private var loadID: GitPushDiffLoadID {
        GitPushDiffLoadID(
            baseRevision: range.baseRevision,
            headRevision: range.headRevision,
            filePath: file.path,
            originalPath: file.originalPath,
            ignoresWhitespace: appState.ignoresWhitespaceInDiff
        )
    }

    private func loadDiff(for loadID: GitPushDiffLoadID) async {
        let requestID = UUID()
        loadRequestID = requestID
        isLoading = true
        errorMessage = nil
        diff = nil
        defer {
            if loadRequestID == requestID {
                isLoading = false
            }
        }
        do {
            let loaded = try await Self.loadWithTimeout {
                try await appState.pushFileDiff(range: range, file: file)
            }
            try Task.checkCancellation()
            guard loadRequestID == requestID else { return }
            diff = loaded
        } catch is CancellationError {
            return
        } catch {
            guard loadRequestID == requestID else { return }
            diff = nil
            errorMessage = error.localizedDescription
        }
    }

    private nonisolated static func loadWithTimeout(
        operation: @escaping @Sendable () async throws -> GitFileDiff
    ) async throws -> GitFileDiff {
        try await withThrowingTaskGroup(of: GitFileDiff.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw GitPushDiffLoadError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}

private struct GitPushDiffLoadID: Hashable, Sendable {
    let baseRevision: String?
    let headRevision: String
    let filePath: String
    let originalPath: String?
    let ignoresWhitespace: Bool
}

private enum GitPushDiffLoadError: LocalizedError, Sendable {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Diff 加载超时。Git 命令已取消，请稍后重试或先检查文件是否过大。"
        }
    }
}

private func fileName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

private struct GitPushStatusBadge: View {
    let status: GitStatusCode

    var body: some View {
        Text(String(status.rawValue))
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 18)
            .background(color.opacity(0.12), in: .rect(cornerRadius: 4))
    }

    private var color: Color {
        switch status {
        case .added, .copied: .green
        case .modified, .typeChanged: .blue
        case .deleted, .updatedButUnmerged: .red
        case .renamed: .purple
        case .untracked: .orange
        default: .secondary
        }
    }
}
