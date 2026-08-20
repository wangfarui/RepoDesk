import SwiftUI

@MainActor
struct FilesView: View {
    @Bindable var appState: AppState

    var body: some View {
        HSplitView {
            fileTree
                .frame(minWidth: 240, idealWidth: 310, maxWidth: 440)
            documentView
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                if appState.canEditSelectedDocument {
                    Button("保存", systemImage: "square.and.arrow.down") {
                        Task { await appState.saveSelectedDocument() }
                    }
                    .disabled(!appState.hasUnsavedDocumentChanges || appState.isSavingDocument)
                    .help("保存当前文件")
                }

                if appState.selectedFileURL != nil {
                    Button("重新加载", systemImage: "arrow.clockwise") {
                        appState.requestReloadSelectedFile()
                    }
                    .disabled(appState.isLoadingDocument || appState.isSavingDocument)
                    .help("从磁盘重新加载当前文件")

                }

                if appState.selectedFileURL?.pathExtension.lowercased() == "md" {
                    Picker("Markdown 视图", selection: $appState.showsMarkdownPreview) {
                        Text("源码").tag(false)
                        Text("预览").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("切换 Markdown 源码和预览")
                }
            }
        }
        .alert("打开另一个文件？", isPresented: pendingFileAlertBinding) {
            Button("继续编辑", role: .cancel) {
                appState.cancelPendingFileSelection()
            }
            Button("放弃改动并打开", role: .destructive) {
                appState.discardChangesAndOpenPendingFile()
            }
        } message: {
            Text("当前文件还有未保存的改动。")
        }
        .alert("从磁盘重新加载？", isPresented: $appState.showsDiscardAndReloadConfirmation) {
            Button("取消", role: .cancel) {}
            Button("放弃改动并重新加载", role: .destructive) {
                appState.discardChangesAndReload()
            }
        } message: {
            Text("重新加载会丢弃当前未保存的改动。")
        }
        .task(id: appState.visibleWorkspaceRootURL?.path) {
            guard let rootURL = appState.visibleWorkspaceRootURL else { return }
            await appState.loadDirectory(rootURL)
        }
    }

    @ViewBuilder
    private var fileTree: some View {
        if let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(visibleRootName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Menu("文件树选项", systemImage: "ellipsis.circle") {
                        Toggle(
                            "显示隐藏文件",
                            isOn: Binding(
                                get: { appState.showsHiddenFiles },
                                set: { appState.setShowsHiddenFiles($0) }
                            )
                        )
                        Toggle(
                            "折叠单子目录",
                            isOn: Binding(
                                get: { appState.compactsSingleChildDirectories },
                                set: { appState.setCompactsSingleChildDirectories($0) }
                            )
                        )
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("文件树选项")
                }
                .padding(.horizontal, 10)
                .frame(height: 38)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if let message = appState.workspaceMonitoringErrorMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                        if appState.loadingDirectoryURLs.contains(rootURL) {
                            ProgressView("正在加载文件…")
                                .padding(12)
                        }
                        if let message = appState.directoryLoadErrors[rootURL] {
                            DirectoryLoadErrorView(
                                message: message,
                                retry: { appState.retryDirectory(rootURL) }
                            )
                        }
                        ForEach(visibleEntries(appState.fileChildren[rootURL] ?? [])) { entry in
                            FileTreeEntryView(entry: entry, appState: appState, depth: 0)
                        }
                    }
                    .padding(6)
                }
            }
        } else {
            ContentUnavailableView(
                appState.isWorkspaceContext ? "未打开工作区" : "未选择 Repository",
                systemImage: "folder"
            )
        }
    }

    private var visibleRootName: String {
        if appState.isWorkspaceContext {
            return appState.workspace?.name ?? "工作区"
        }
        return appState.selectedRepository?.name ?? "Repository"
    }

    @ViewBuilder
    private var documentView: some View {
        if appState.isLoadingDocument {
            ProgressView("正在加载文档…")
        } else if let document = appState.loadedDocument {
            switch document {
            case .text(let textDocument):
                if appState.showsMarkdownPreview,
                   appState.selectedFileURL?.pathExtension.lowercased() == "md" {
                    MarkdownDocumentView(
                        text: appState.documentText,
                        fileName: appState.selectedFileURL?.lastPathComponent ?? ""
                    )
                } else {
                    SourceDocumentView(
                        text: $appState.documentText,
                        isLarge: textDocument.isLarge,
                        fileName: appState.selectedFileURL?.lastPathComponent ?? "",
                        fileExtension: appState.selectedFileURL?.pathExtension.lowercased() ?? "",
                        encoding: textDocument.encoding,
                        isModified: appState.hasUnsavedDocumentChanges,
                        isSaving: appState.isSavingDocument,
                        scrollToLine: appState.pendingSourceLine
                    )
                }
            case .binary(let size):
                ContentUnavailableView(
                    "二进制文件",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("这个 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) 文件无法按文本显示。")
                )
            case .unavailable(let message):
                ContentUnavailableView(
                    "文件不可用",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        } else {
            ContentUnavailableView(
                "选择一个文件",
                systemImage: "doc.text.magnifyingglass",
                description: Text("从左侧文件树选择一个文本文件。")
            )
        }
    }

    private var pendingFileAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.pendingFileSelectionURL != nil },
            set: { if !$0 { appState.cancelPendingFileSelection() } }
        )
    }

    private func visibleEntries(_ entries: [WorkspaceFileEntry]) -> [WorkspaceFileEntry] {
        guard !appState.showsHiddenFiles else { return entries }
        return entries.filter { !$0.name.hasPrefix(".") }
    }
}

@MainActor
private struct FileTreeEntryView: View {
    let entry: WorkspaceFileEntry
    @Bindable var appState: AppState
    let depth: Int

    var body: some View {
        Button {
            if entry.isDirectory {
                appState.toggleDirectory(entry.url)
            } else {
                appState.selectFile(entry.url)
            }
        } label: {
            HStack(spacing: 5) {
                if entry.isDirectory {
                    Image(systemName: appState.expandedDirectoryURLs.contains(entry.url) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                if entry.isDirectory {
                    Image(systemName: "folder").foregroundStyle(.blue)
                } else {
                    FileTypeIcon(path: entry.url.path)
                }
                Text(displayName)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if displayedEntries.contains(where: { appState.loadingDirectoryURLs.contains($0.url) }) {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            appState.selectedFileURL == entry.url ? Color.accentColor.opacity(0.14) : .clear,
            in: .rect(cornerRadius: 5)
        )

        if entry.isDirectory, appState.expandedDirectoryURLs.contains(entry.url) {
            if let message = appState.directoryLoadErrors[displayedDirectoryURL] {
                DirectoryLoadErrorView(
                    message: message,
                    retry: { appState.retryDirectory(displayedDirectoryURL) }
                )
                .padding(.leading, CGFloat(depth + 1) * 14)
            }
            ForEach(visibleChildren) { child in
                FileTreeEntryView(entry: child, appState: appState, depth: depth + 1)
            }
        }
    }

    private var displayedEntries: [WorkspaceFileEntry] {
        guard entry.isDirectory, appState.compactsSingleChildDirectories else { return [entry] }
        var entries = [entry]
        var currentURL = entry.url.standardizedFileURL
        for _ in 0..<32 {
            guard let children = appState.fileChildren[currentURL] else { break }
            let visibleChildren = appState.showsHiddenFiles
                ? children
                : children.filter { !$0.name.hasPrefix(".") }
            guard visibleChildren.count == 1,
                  let child = visibleChildren.first,
                  child.isDirectory else { break }
            entries.append(child)
            currentURL = child.url.standardizedFileURL
        }
        return entries
    }

    private var displayName: String {
        displayedEntries.map(\.name).joined(separator: "/")
    }

    private var displayedDirectoryURL: URL {
        displayedEntries.last?.url.standardizedFileURL ?? entry.url.standardizedFileURL
    }

    private var visibleChildren: [WorkspaceFileEntry] {
        let children = appState.fileChildren[displayedDirectoryURL] ?? []
        guard !appState.showsHiddenFiles else { return children }
        return children.filter { !$0.name.hasPrefix(".") }
    }
}

private struct DirectoryLoadErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("重试", systemImage: "arrow.clockwise", action: retry)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("重试加载这个目录")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}

@MainActor
struct SourceDocumentView: View {
    @Binding var text: String
    let isLarge: Bool
    let fileName: String
    let fileExtension: String
    let encoding: DocumentTextEncoding
    let isModified: Bool
    let isSaving: Bool
    let scrollToLine: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                FileTypeIcon(path: fileName)
                Text(fileName)
                    .font(.headline)
                    .lineLimit(1)
                if isModified {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .help("有未保存的改动")
                }
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(encoding.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isLarge {
                    Text("只读")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            if isLarge {
                Label("大文件模式为只读，以保持编辑器流畅。", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary)
            }
            NativeCodeEditor(
                text: $text,
                isEditable: !isLarge,
                style: isLarge ? .plain : .source(fileExtension: fileExtension),
                scrollToLine: scrollToLine
            )
        }
    }
}

@MainActor
struct FileQuickOpenSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 12) {
            TextField("按名称搜索文件", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, value in
                    appState.searchWorkspaceFiles(query: value)
                }

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(appState.fileSearchResults) { entry in
                        Button {
                            appState.selectFile(entry.url)
                            appState.selectSection(.files)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(relativePath(for: entry.url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .overlay {
                if appState.isSearchingFiles {
                    ProgressView()
                } else if !query.isEmpty, appState.fileSearchResults.isEmpty {
                    ContentUnavailableView("没有匹配的文件", systemImage: "magnifyingglass")
                }
            }
        }
        .padding(16)
        .frame(width: 620, height: 460)
    }

    private func relativePath(for url: URL) -> String {
        guard let workspacePath = appState.workspace?.path else { return url.path }
        let prefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }
}
