import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class BranchComparisonSession {
    let id = UUID()
    let repositoryURL: URL
    let current: String
    let selected: String
    let reader: any GitRepositoryReading
    var comparison: GitBranchComparison?
    var error: String?
    var isLoading = true
    var title: String {
        let currentName = current.hasPrefix("refs/heads/") ? String(current.dropFirst(11)) : current
        let prefix = selected.hasPrefix("refs/remotes/") ? "refs/remotes/" : "refs/heads/"
        let selectedName = selected.hasPrefix(prefix) ? String(selected.dropFirst(prefix.count)) : selected
        return "\(currentName) 独有 · 相对 \(selectedName)"
    }

    init(repositoryURL: URL, current: String, selected: String, reader: any GitRepositoryReading) {
        self.repositoryURL = repositoryURL; self.current = current; self.selected = selected; self.reader = reader
    }

    func load() async {
        do {
            let result = try await reader.compareBranches(repositoryURL: repositoryURL, base: current, compared: selected)
            try Task.checkCancellation()
            comparison = result
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

@MainActor
struct BranchComparisonSheet: View {
    @Bindable var session: BranchComparisonSession
    let dismiss: () -> Void
    @State private var showsCommits = false
    @State private var selectedCommit: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.comparison?.title ?? session.title).font(.headline)
                    if let comparison = session.comparison {
                        HStack {
                            Button("\(comparison.commits.count) 个提交", systemImage: showsCommits ? "chevron.down" : "chevron.right") {
                                showsCommits.toggle()
                            }
                            .accessibilityIdentifier("RepoDesk.BranchComparison.Commits")
                            Text("\(comparison.files.count) 个文件").foregroundStyle(.secondary)
                            if selectedCommit != nil { Button("全部文件汇总") { selectedCommit = nil } }
                        }
                    }
                }
                Spacer()
                Button("关闭", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
            }.padding(.horizontal, 18).padding(.top, 36).padding(.bottom, 12).background(WindowDragArea())
            Divider()
            if session.isLoading {
                ProgressView("正在读取独有提交和文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.error {
                ContentUnavailableView("分支比较失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let comparison = session.comparison {
                if comparison.commits.isEmpty {
                    ContentUnavailableView("没有独有提交", systemImage: "checkmark.circle", description: Text(comparison.title))
                } else {
                    HSplitView {
                        if showsCommits {
                            List(comparison.commits.reversed()) { commit in
                                Button { selectedCommit = commit.hash } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(commit.subject).lineLimit(2)
                                        Text("\(commit.hash.prefix(8)) · \(commit.author)").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                                }.buttonStyle(.plain)
                                .listRowBackground(selectedCommit == commit.hash ? Color.accentColor.opacity(0.15) : Color.clear)
                            }.frame(minWidth: 220, idealWidth: 260, maxWidth: 380)
                        }
                        if let selectedCommit {
                            BranchComparisonCommitView(session: session, hash: selectedCommit).id(selectedCommit)
                        } else {
                            BranchComparisonFileBrowser(
                                session: session, files: comparison.files.map(\.file),
                                emptyMessage: "有独有提交，但汇总没有文件变化", commit: nil,
                                summaryFiles: comparison.files,
                                openCommit: { selectedCommit = $0; showsCommits = true }
                            )
                        }
                    }
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .task { await session.load() }
    }
}

@MainActor
private struct BranchComparisonCommitView: View {
    let session: BranchComparisonSession
    let hash: String
    @State private var detail: GitCommitDetail?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail {
                Text("\(hash.prefix(8)) · \(detail.summary.subject)").font(.headline).padding(10)
                BranchComparisonFileBrowser(session: session, files: detail.files,
                    emptyMessage: "该提交没有文件变化", commit: detail, summaryFiles: [], openCommit: { _ in })
            } else if let error {
                ContentUnavailableView("读取提交失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else { ProgressView("正在读取提交…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task {
            do {
                let result = try await session.reader.commit(repositoryURL: session.repositoryURL, hash: hash)
                try Task.checkCancellation()
                detail = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
private struct BranchComparisonFileBrowser: View {
    let session: BranchComparisonSession
    let files: [GitCommitFile]
    let emptyMessage: String
    let commit: GitCommitDetail?
    let summaryFiles: [GitBranchComparisonFile]
    let openCommit: (String) -> Void
    @State private var expanded = Set<String>()
    @State private var selectedFile: GitCommitFile?
    @State private var ignoresWhitespace = false
    @State private var diffState = BranchComparisonDiffState()

    private var rows: [HistoryFileOutlineRow] {
        HistoryFileOutlineBuilder.rows(files: files, namespace: "comparison", repositoryName: session.repositoryURL.lastPathComponent,
            grouping: .directory, expandedNodeIDs: expanded, modulePath: { _ in "." })
    }

    var body: some View {
        HSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in outlineRow(row) }
                }.padding(8)
            }.frame(minWidth: 230, idealWidth: 300, maxWidth: 480)
            VStack(spacing: 0) {
                if let selectedFile {
                    if let summary = summaryFiles.first(where: { $0.file == selectedFile }) {
                        HStack {
                            Text("关联提交").font(.caption).foregroundStyle(.secondary)
                            ScrollView(.horizontal) {
                                HStack { ForEach(summary.contributions, id: \.self) { hash in
                                    Button(String(hash.prefix(8))) { openCommit(hash) }.font(.caption.monospaced())
                                } }
                            }
                        }.padding(8)
                    }
                    BranchComparisonFileDiff(session: session, file: selectedFile, commit: commit,
                        target: summaryFiles.first(where: { $0.file == selectedFile })?.target,
                        ignoresWhitespace: $ignoresWhitespace, state: diffState)
                        .id("\(commit?.summary.hash ?? "summary"):\(selectedFile.id)")
                } else {
                    ContentUnavailableView(files.isEmpty ? emptyMessage : "选择文件查看 Diff", systemImage: "doc.text.magnifyingglass")
                }
            }.frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { diffState.cancel() }
        .onAppear {
            expanded = HistoryFileOutlineBuilder.expandableNodeIDs(files: files, namespace: "comparison", grouping: .directory, modulePath: { _ in "." })
        }
    }

    @ViewBuilder private func outlineRow(_ row: HistoryFileOutlineRow) -> some View {
        switch row {
        case .directory(let id, let name, _, let depth, let count, _):
            Button { if expanded.remove(id) == nil { expanded.insert(id) } } label: {
                HStack {
                    Image(systemName: expanded.contains(id) ? "chevron.down" : "chevron.right")
                    Image(systemName: "folder"); Text(name); Text("\(count)").foregroundStyle(.secondary); Spacer()
                }.contentShape(.rect)
            }.buttonStyle(.plain).padding(.leading, CGFloat(depth) * 14).frame(height: 26)
        case .file(_, let file, let depth, _):
            Button { selectFile(file) } label: {
                HStack {
                    FileTypeIcon(path: file.path)
                    Text((file.path as NSString).lastPathComponent).lineLimit(1)
                    Spacer()
                    Text(String(file.status.rawValue)).font(.caption.monospaced()).foregroundStyle(file.status == .deleted ? .red : .secondary)
                }.padding(5).contentShape(.rect)
            }.buttonStyle(.plain).padding(.leading, CGFloat(depth) * 14)
                .background(selectedFile == file ? Color.accentColor.opacity(0.15) : Color.clear)
                .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                .accessibilityIdentifier("RepoDesk.BranchComparison.File.\(file.path)")
                .fileSystemPathCopyMenu(nil,
                    annotateGitBlameItem: annotationAction(for: file),
                    isGitBlameAnnotated: selectedFile == file && diffState.blame.allSidesVisible)
        case .module: EmptyView()
        }
    }
    private func selectFile(_ file: GitCommitFile) {
        if selectedFile != file {
            diffState.cancel()
            selectedFile = file
        }
    }

    private func annotationAction(for file: GitCommitFile) -> (() -> Void)? {
        guard (file.path as NSString).pathExtension.lowercased() != "jar" else { return nil }
        if selectedFile == file, !diffState.isLoading, diffState.blame.availableSides.isEmpty { return nil }
        return {
            selectFile(file)
            diffState.annotate(using: session.reader)
        }
    }

}

/// Every load clears the previous result and owns a generation, even when a reader
/// ignores cancellation. The view also cancels its task when its identity changes.
@MainActor @Observable
final class BranchComparisonDiffState {
    var diff: GitFileDiff?
    var mergeDiff: GitMergeFileDiff?
    var error: String?
    let blame = HistoryGitBlame()
    private(set) var isLoading = true
    private var wantsAnnotation = false
    private var generation = UUID()
    private var context: Context?

    private struct Context: Equatable {
        let repositoryURL: URL
        let file: GitCommitFile
        let commit: GitCommitDetail?
        let target: GitDiffTarget?
    }

    func cancel() {
        generation = UUID()
        blame.reset()
        context = nil
        wantsAnnotation = false
        diff = nil; mergeDiff = nil; error = nil; isLoading = true
    }

    func annotate(using reader: any GitRepositoryReading) {
        if blame.context != nil {
            blame.toggleAll(using: reader)
        } else {
            wantsAnnotation = true
        }
    }

    func load(session: BranchComparisonSession, file: GitCommitFile, commit: GitCommitDetail?,
              target: GitDiffTarget?, ignoringWhitespace: Bool) async {
        guard !Task.isCancelled else { return }
        let nextContext = Context(repositoryURL: session.repositoryURL, file: file, commit: commit, target: target)
        if context != nextContext {
            blame.reset()
            context = nextContext
        }
        let request = UUID(); generation = request
        diff = nil; mergeDiff = nil; error = nil; isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            if let commit, commit.parentHashes.count > 1 {
                let loaded = try await session.reader.mergeFileDiff(repositoryURL: session.repositoryURL,
                    hash: commit.summary.hash, parentHashes: commit.parentHashes, file: file, ignoringWhitespace: ignoringWhitespace)
                try Task.checkCancellation()
                guard generation == request else { return }
                mergeDiff = loaded
                blame.configure(HistoryGitBlameContext(repositoryURL: session.repositoryURL,
                    detail: commit, diff: loaded.target, source: loaded.source))
            } else {
                guard let target = target ?? commit.map({ .commit(hash: $0.summary.hash, file: file) }) else { return }
                let loaded = try await session.reader.fileDiff(repositoryURL: session.repositoryURL,
                    target: target, ignoringWhitespace: ignoringWhitespace)
                try Task.checkCancellation()
                guard generation == request else { return }
                diff = loaded
                if let commit {
                    blame.configure(HistoryGitBlameContext(repositoryURL: session.repositoryURL, detail: commit, diff: loaded))
                } else if case .revisionRange(let base, let head, let file, _) = target {
                    blame.configure(HistoryGitBlameContext(repositoryURL: session.repositoryURL,
                        before: file.status == .added ? nil : base.map { GitFileRevision(commit: $0, path: file.originalPath ?? file.path) },
                        after: file.status == .deleted ? nil : GitFileRevision(commit: head, path: file.path), diff: loaded))
                }
            }
            if wantsAnnotation {
                wantsAnnotation = false
                blame.toggleAll(using: session.reader)
            }
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            blame.reset()
            wantsAnnotation = false
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private struct BranchComparisonFileDiff: View {
    let session: BranchComparisonSession
    let file: GitCommitFile
    let commit: GitCommitDetail?
    let target: GitDiffTarget?
    @Binding var ignoresWhitespace: Bool
    @Bindable var state: BranchComparisonDiffState

    var body: some View {
        VStack(spacing: 0) {
            if let error = state.error {
                ContentUnavailableView("读取文件失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let mergeDiff = state.mergeDiff {
                GitMergeDiffView(diff: mergeDiff, ignoresWhitespace: ignoresWhitespace,
                    toggleIgnoreWhitespace: { ignoresWhitespace.toggle() }, jumpToSource: { _ in }, canJumpToSource: false,
                    blame: annotations, toggleBlame: toggleBlame)
            } else if let diff = state.diff {
                if diff.hunks.isEmpty && !diff.isBinary {
                    Text("无净行差异").font(.callout).foregroundStyle(.secondary).padding(8)
                }
                GitDiffView(diff: diff, ignoresWhitespace: ignoresWhitespace,
                    toggleIgnoreWhitespace: { ignoresWhitespace.toggle() }, presentation: .sideBySide,
                    jumpToSource: { _ in }, canJumpToSource: false, lockedPresentation: .sideBySide,
                    oldBlame: state.blame.annotations(for: .target), newBlame: state.blame.annotations(for: .result),
                    toggleOldBlame: toggleBlame(.target), toggleNewBlame: toggleBlame(.result))
            } else { ProgressView("正在读取文件 Diff…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !state.blame.loadingSides.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在加载 Git Blame…").font(.caption)
                    Spacer()
                }.padding(6)
                Divider()
            }
            ForEach(GitHistoryBlameSide.allCases, id: \.self) { side in
                if let error = state.blame.errors[side] {
                    HStack {
                        Label("\(sideTitle(side))：\(error)", systemImage: "exclamationmark.triangle")
                        Button("重试") { state.blame.toggle(side, using: session.reader) }
                    }.font(.caption).foregroundStyle(.red).padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: ignoresWhitespace) {
            await state.load(session: session, file: file, commit: commit, target: target, ignoringWhitespace: ignoresWhitespace)
        }
    }

    private var annotations: [GitHistoryBlameSide: [Int: GitBlameLine]] {
        GitHistoryBlameSide.allCases.reduce(into: [:]) { $0[$1] = state.blame.annotations(for: $1) }
    }

    private func toggleBlame(_ side: GitHistoryBlameSide) -> (() -> Void)? {
        guard state.blame.availableSides.contains(side) else { return nil }
        return { state.blame.toggle(side, using: session.reader) }
    }

    private func sideTitle(_ side: GitHistoryBlameSide) -> String {
        switch side {
        case .target: commit?.isTwoParentMerge == true ? "目标父版本" : "变更前"
        case .result: commit?.isTwoParentMerge == true ? "合并结果" : "变更后"
        case .source: "来源父版本"
        }
    }
}
