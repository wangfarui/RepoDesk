import AppKit
import SwiftUI

@MainActor
struct HistoryJarDiffView: View {
    let repositoryURL: URL
    let hash: String
    let file: GitCommitFile
    let parentHashes: [String]
    let ignoresWhitespace: Bool
    let fontSize: CGFloat

    @State private var selectedParentHash = ""
    @State private var showsUnchangedEntries = false
    @State private var selectedEntryPath: String?
    @State private var comparison: HistoryJarComparison?
    @State private var loadedComparisonRequest: ComparisonRequest?
    @State private var content: HistoryJarContent?
    @State private var loadedContentRequest: ContentRequest?
    @State private var comparisonError: String?
    @State private var contentError: String?
    @State private var isLoadingComparison = false
    @State private var isLoadingContent = false
    @State private var localIgnoresWhitespace = false
    @State private var retryGeneration = 0

    private let service = HistoryJarComparisonService()

    var body: some View {
        VStack(spacing: 0) {
            archiveToolbar
            Divider()
            if isLoadingComparison || loadedComparisonRequest != comparisonRequest {
                if let comparisonError {
                    failureView(comparisonError)
                } else {
                    ProgressView("正在比较 JAR 包内文件…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let comparisonError {
                failureView(comparisonError)
            } else if let comparison {
                VSplitView {
                    entriesPanel(comparison)
                        .frame(minHeight: 76, idealHeight: 150, maxHeight: 280)
                    entryContent
                        .frame(minHeight: 140, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: comparisonRequest) {
            await loadComparison(comparisonRequest)
        }
        .task(id: contentRequest) {
            await loadContent(contentRequest)
        }
        .onAppear {
            localIgnoresWhitespace = ignoresWhitespace
        }
        .onChange(of: ignoresWhitespace) { _, value in
            localIgnoresWhitespace = value
        }
        .onChange(of: showsUnchangedEntries) { _, _ in
            if !visibleEntries.contains(where: { $0.path == selectedEntryPath }) {
                selectedEntryPath = visibleEntries.first?.path
            }
        }
    }

    private var archiveToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            Text(file.path)
                .font(.callout.monospaced().weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)
            Spacer(minLength: 4)
            if parentHashes.count > 1 {
                Picker("对比父提交", selection: Binding(
                    get: { effectiveParentHash ?? "" },
                    set: { selectedParentHash = $0 }
                )) {
                    ForEach(Array(parentHashes.enumerated()), id: \.element) { index, parent in
                        Text("父提交 \(index + 1)：\(parent.prefix(8))").tag(parent)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 225)
                .help("分别查看该提交相对于所选父提交的 JAR 改动")
            }
            Toggle("显示未改动文件", isOn: $showsUnchangedEntries)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func entriesPanel(_ comparison: HistoryJarComparison) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("包内文件")
                    .font(.caption.weight(.semibold))
                Text("\(comparison.entries.filter { $0.change != .unchanged }.count) 个改动 / \(comparison.entries.count) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(comparison.oldLabel) → \(comparison.newLabel)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            HStack(spacing: 10) {
                Text("路径").frame(maxWidth: .infinity, alignment: .leading)
                Text("状态").frame(width: 44, alignment: .leading)
                Text("之前").frame(width: 72, alignment: .trailing)
                Text("之后").frame(width: 72, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 3)
            Divider()

            if visibleEntries.isEmpty {
                Text(comparison.entries.isEmpty
                     ? "JAR 中没有可查看的文件。"
                     : "包内文件内容没有变化，可能仅 JAR 打包元数据发生变化。可勾选“显示未改动文件”查看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedEntryPath) {
                    ForEach(visibleEntries) { entry in
                        entryRow(entry).tag(entry.path)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func entryRow(_ entry: HistoryJarEntry) -> some View {
        HStack(spacing: 10) {
            Label(entry.path, systemImage: entry.path.lowercased().hasSuffix(".class") ? "curlybraces" : "doc.text")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(changeTitle(entry.change))
                .font(.caption)
                .foregroundStyle(changeColor(entry.change))
                .frame(width: 44, alignment: .leading)
            Text(sizeLabel(entry.oldSize))
                .frame(width: 72, alignment: .trailing)
            Text(sizeLabel(entry.newSize))
                .frame(width: 72, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .help(entry.path)
        .contextMenu {
            Button("复制包内路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
    }

    private var entryContent: some View {
        Group {
            if selectedEntryPath == nil {
                ContentUnavailableView("选择一个包内文件", systemImage: "doc.text.magnifyingglass")
            } else if isLoadingContent || loadedContentRequest != contentRequest {
                ProgressView(selectedEntryPath?.lowercased().hasSuffix(".class") == true
                             ? "正在反编译并比较 Java 代码…" : "正在加载文件内容…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let contentError {
                ContentUnavailableView("包内文件不可用", systemImage: "exclamationmark.triangle", description: Text(contentError))
            } else if let content {
                VStack(spacing: 0) {
                    if let message = content.message, content.diff != nil {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    if let diff = content.diff {
                        GitDiffView(
                            diff: diff,
                            ignoresWhitespace: localIgnoresWhitespace,
                            toggleIgnoreWhitespace: { localIgnoresWhitespace.toggle() },
                            jumpToSource: { _ in },
                            canJumpToSource: false,
                            lockedPresentation: .sideBySide,
                            fontSize: fontSize
                        )
                    } else {
                        ContentUnavailableView(
                            "文件内容",
                            systemImage: "doc.badge.ellipsis",
                            description: Text(content.message ?? "该文件无法显示文本内容。")
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("JAR 对比不可用", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            Button("重试") { retryGeneration += 1 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var effectiveParentHash: String? {
        parentHashes.contains(selectedParentHash) ? selectedParentHash : parentHashes.first
    }

    private var comparisonRequest: ComparisonRequest {
        ComparisonRequest(
            repositoryURL: repositoryURL,
            hash: hash,
            path: file.path,
            originalPath: file.originalPath,
            parentHash: effectiveParentHash,
            retryGeneration: retryGeneration
        )
    }

    private var contentRequest: ContentRequest {
        ContentRequest(comparison: loadedComparisonRequest, path: selectedEntryPath, ignoresWhitespace: localIgnoresWhitespace)
    }

    private var visibleEntries: [HistoryJarEntry] {
        guard loadedComparisonRequest == comparisonRequest else { return [] }
        return (comparison?.entries ?? []).filter { showsUnchangedEntries || $0.change != .unchanged }
    }

    private func loadComparison(_ request: ComparisonRequest) async {
        guard !Task.isCancelled else { return }
        isLoadingComparison = true
        comparisonError = nil
        comparison = nil
        loadedComparisonRequest = nil
        selectedEntryPath = nil
        content = nil
        do {
            let result = try await service.compare(
                repositoryURL: request.repositoryURL,
                hash: request.hash,
                file: file,
                parentHash: request.parentHash
            )
            guard !Task.isCancelled, comparisonRequest == request else { return }
            comparison = result
            loadedComparisonRequest = request
            selectedEntryPath = visibleEntries.first?.path
            isLoadingComparison = false
        } catch {
            guard !Task.isCancelled, comparisonRequest == request else { return }
            comparisonError = error.localizedDescription
            loadedComparisonRequest = request
            isLoadingComparison = false
        }
    }

    private func loadContent(_ request: ContentRequest) async {
        guard !Task.isCancelled else { return }
        content = nil
        contentError = nil
        loadedContentRequest = nil
        guard request.comparison == comparisonRequest,
              let comparison,
              let entry = comparison.entries.first(where: { $0.path == request.path }) else {
            isLoadingContent = false
            return
        }
        isLoadingContent = true
        do {
            let result = try await service.content(
                comparison: comparison,
                entry: entry,
                ignoringWhitespace: request.ignoresWhitespace
            )
            guard !Task.isCancelled, contentRequest == request else { return }
            content = result
            loadedContentRequest = request
            isLoadingContent = false
        } catch {
            guard !Task.isCancelled, contentRequest == request else { return }
            contentError = error.localizedDescription
            loadedContentRequest = request
            isLoadingContent = false
        }
    }

    private func changeTitle(_ change: HistoryJarChange) -> String {
        switch change {
        case .added: "新增"
        case .deleted: "删除"
        case .modified: "修改"
        case .unchanged: "未改动"
        }
    }

    private func changeColor(_ change: HistoryJarChange) -> Color {
        switch change {
        case .added: .green
        case .deleted: .red
        case .modified: .orange
        case .unchanged: .secondary
        }
    }

    private func sizeLabel(_ size: Int?) -> String {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    }

    private struct ComparisonRequest: Hashable {
        let repositoryURL: URL
        let hash: String
        let path: String
        let originalPath: String?
        let parentHash: String?
        let retryGeneration: Int
    }

    private struct ContentRequest: Hashable {
        let comparison: ComparisonRequest?
        let path: String?
        let ignoresWhitespace: Bool
    }
}
