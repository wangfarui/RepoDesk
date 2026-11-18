import AppKit
import SwiftUI

struct DocumentHeaderActions: View {
    let canRevealSelectedFile: Bool
    let onRevealSelectedFile: () -> Void
    let canShowGitHistory: Bool
    let onShowGitHistory: () -> Void
    let isReloadDisabled: Bool
    let onReloadSelectedFile: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button("在文件树中定位", systemImage: "scope", action: onRevealSelectedFile)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canRevealSelectedFile)
                .help("在文件树中定位当前文件")

            Button("查看 Git 提交历史", systemImage: "clock.arrow.circlepath", action: onShowGitHistory)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canShowGitHistory)
                .help("查看当前文件的 Git 提交历史")

            Button("重新加载", systemImage: "arrow.clockwise", action: onReloadSelectedFile)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isReloadDisabled)
                .help("从磁盘重新加载当前文件")
        }
    }
}

@MainActor
struct FilesView: View {
    @Environment(\.isEnabled) private var isSectionActive
    @Bindable var appState: AppState
    @State private var selectedTreeItem: FileTreeItemSelection?
    @State private var selectedTreeItems: Set<FileTreeItemSelection> = []
    @State private var selectionAnchorURL: URL?
    @State private var pendingFilePastePlan: WorkspaceFilePastePlan?
    @State private var filePasteErrorMessage: String?
    @State private var isPastingFiles = false
    @State private var newFileItemRequest: NewFileItemRequest?
    @State private var newFileItemName = ""
    @State private var newFileItemErrorMessage: String?
    @State private var isCreatingFileItem = false
    @State private var renameFileItemRequest: RenameFileItemRequest?
    @State private var renameFileItemName = ""
    @State private var renameFileItemErrorMessage: String?
    @State private var isRenamingFileItem = false
    @State private var deleteFileItemRequest: DeleteFileItemRequest?
    @State private var deleteFileItemErrorMessage: String?
    @State private var isDeletingFileItem = false
    @State private var contextMenuTreeItemURL: URL?
    @State private var subtreeExpansionTask: Task<Void, Never>?
    @State private var subtreeExpansionReachedLimit = false
    @FocusState private var focusedFileTreeURL: URL?
    private let fileTransfer = FileSystemWorkspaceFileTransfer()
    private let fileCreator = FileSystemWorkspaceFileCreator()
    private let fileRenamer = FileSystemWorkspaceFileRenamer()

    var body: some View {
        VStack(spacing: 0) {
            if !appState.openFileTabs.isEmpty {
                fileTabsBar
                Divider()
            }
            HSplitView {
                fileTree
                    .frame(minWidth: 240, idealWidth: 310, maxWidth: 440)
                VStack(spacing: 0) {
                    documentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !selectedFilePathComponents.isEmpty {
                        Divider()
                        filePathBar
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if isSectionActive, appState.selectedFileURL?.pathExtension.lowercased() == "md" {
                    Picker(
                        "Markdown 视图",
                        selection: Binding(
                            get: { appState.showsMarkdownPreview },
                            set: { appState.setMarkdownPreview($0) }
                        )
                    ) {
                        Text("源码").tag(false)
                        Text("预览").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("切换 Markdown 源码和预览")
                }
            }
        }
        .alert("从磁盘重新加载？", isPresented: $appState.showsDiscardAndReloadConfirmation) {
            Button("取消", role: .cancel) {}
            Button("放弃改动并重新加载", role: .destructive) {
                appState.discardChangesAndReload()
            }
        } message: {
            Text("重新加载会丢弃当前未保存的改动。")
        }
        .alert("目标中已存在同名项目", isPresented: pendingFilePasteBinding) {
            Button("替换", role: .destructive) {
                resolvePendingFilePaste(.replace)
            }
            Button("保留两者") {
                resolvePendingFilePaste(.keepBoth)
            }
            Button("取消", role: .cancel) {
                pendingFilePastePlan = nil
            }
        } message: {
            Text(filePasteConflictMessage)
        }
        .alert("无法粘贴", isPresented: filePasteErrorBinding) {
            Button("好", role: .cancel) {
                filePasteErrorMessage = nil
            }
        } message: {
            Text(filePasteErrorMessage ?? "文件操作失败。")
        }
        .sheet(item: $newFileItemRequest) { request in
            NewFileItemSheet(
                title: request.isDirectory ? "新建目录" : "新建文件",
                placeholder: request.isDirectory ? "目录名称" : "文件名称",
                directoryName: request.directoryURL.lastPathComponent,
                name: $newFileItemName,
                create: createFileItem,
                cancel: cancelNewFileItem
            )
        }
        .alert("无法创建", isPresented: newFileItemErrorBinding) {
            Button("好", role: .cancel) {
                newFileItemErrorMessage = nil
            }
        } message: {
            Text(newFileItemErrorMessage ?? "文件操作失败。")
        }
        .sheet(item: $renameFileItemRequest) { request in
            RenameFileItemSheet(
                title: request.isDirectory ? "重命名目录" : "重命名文件",
                name: $renameFileItemName,
                rename: renameFileItem,
                cancel: cancelRenameFileItem
            )
        }
        .alert("无法重命名", isPresented: renameFileItemErrorBinding) {
            Button("好", role: .cancel) {
                renameFileItemErrorMessage = nil
            }
        } message: {
            Text(renameFileItemErrorMessage ?? "文件操作失败。")
        }
        .sheet(item: $deleteFileItemRequest) { _ in
            DeleteConfirmationSheet(
                message: deleteFileItemMessage,
                delete: deleteFileItem,
                cancel: { deleteFileItemRequest = nil }
            )
        }
        .alert("无法删除", isPresented: deleteFileItemErrorBinding) {
            Button("好", role: .cancel) {
                deleteFileItemErrorMessage = nil
            }
        } message: {
            Text(deleteFileItemErrorMessage ?? "文件操作失败。")
        }
        .alert("无法撤销删除", isPresented: fileDeletionRestoreErrorBinding) {
            Button("好", role: .cancel) {
                appState.fileDeletionRestoreErrorMessage = nil
            }
        } message: {
            Text(appState.fileDeletionRestoreErrorMessage ?? "文件恢复失败。")
        }
        .task(id: isSectionActive ? appState.visibleWorkspaceRootURL?.path : nil) {
            guard isSectionActive, let rootURL = appState.visibleWorkspaceRootURL else { return }
            if let selectedFileURL = appState.selectedFileURL,
               WorkspaceTreeRefreshPlanner.isSameOrDescendant(selectedFileURL, of: rootURL) {
                let selection = FileTreeItemSelection(
                    url: selectedFileURL,
                    isDirectory: false
                )
                selectedTreeItem = selection
                selectedTreeItems = [selection]
                selectionAnchorURL = selectedFileURL.standardizedFileURL
            } else {
                let selection = FileTreeItemSelection(url: rootURL, isDirectory: true)
                selectedTreeItem = selection
                selectedTreeItems = [selection]
                selectionAnchorURL = rootURL
            }
            focusedFileTreeURL = nil
            contextMenuTreeItemURL = nil
            await appState.loadDirectory(rootURL)
        }
        .onChange(of: isSectionActive ? appState.visibleWorkspaceRootURL?.path : nil) {
            cancelSubtreeExpansion()
        }
        .onChange(of: appState.showsHiddenFiles) {
            cancelSubtreeExpansion()
        }
        .onDisappear(perform: cancelSubtreeExpansion)
        .onChange(of: appState.selectedFileURL) {
            guard let selectedFileURL = appState.selectedFileURL else { return }
            let selection = FileTreeItemSelection(url: selectedFileURL, isDirectory: false)
            selectedTreeItem = selection
            selectedTreeItems = [selection]
            selectionAnchorURL = selectedFileURL.standardizedFileURL
        }
    }

    @ViewBuilder
    private var fileTree: some View {
        if let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL {
            VStack(spacing: 0) {
                Button("") {
                    beginDeletingSelectedFileItems()
                }
                .keyboardShortcut(
                    appState.shortcut(for: .deleteFileItem).keyEquivalent,
                    modifiers: appState.shortcut(for: .deleteFileItem).eventModifiers
                )
                .disabled(selectedTreeItems.isEmpty)
                .opacity(0)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                Button("") {
                    beginDeletingSelectedFileItems()
                }
                .keyboardShortcut(
                    appState.shortcut(for: .deleteFileItem).keyEquivalent,
                    modifiers: appState.shortcut(for: .deleteFileItem).eventModifiers
                )
                .disabled(selectedTreeItems.isEmpty)
                .opacity(0)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)

                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(visibleRootName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    if isPastingFiles {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if subtreeExpansionTask != nil {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("正在展开子树")
                        Button("取消展开", systemImage: "xmark.circle", action: cancelSubtreeExpansion)
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                            .help("取消展开")
                    }
                    Button("全部收起", systemImage: "arrow.down.right.and.arrow.up.left") {
                        collapseFileTree(at: rootURL)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                    .help("全部收起")
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
                .contentShape(.rect)
                .background(fileTreeItemBackground(for: rootURL))
                .onTapGesture {
                    handleTreeItemClick(
                        itemURL: rootURL,
                        isDirectory: true,
                        activationURL: rootURL,
                        siblingURLs: [rootURL]
                    )
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focusedFileTreeURL, equals: rootURL)
                .onKeyPress(phases: .down) { keyPress in
                    handleFileTreeKeyPress(
                        keyPress,
                        itemURL: rootURL,
                        isDirectory: true
                    )
                }
                .fileSystemPathCopyMenu(
                    FileSystemPathCopyValues(itemURL: rootURL, rootURL: rootURL),
                    copyItem: { copyFileTreeItems(for: rootURL) },
                    pasteItem: { requestPaste(into: rootURL, isDirectory: true) },
                    newFileItem: { beginCreatingFileItem(in: rootURL, isDirectory: false) },
                    newDirectoryItem: { beginCreatingFileItem(in: rootURL, isDirectory: true) },
                    renameItem: nil,
                    openInFinderItem: {
                        openFileSystemItemInFinder(at: rootURL, isDirectory: true)
                    },
                    isContextMenuPresented: contextMenuPresentationBinding(for: rootURL)
                )

                Divider()

                if subtreeExpansionReachedLimit {
                    Text("子树超过 \(AppState.directorySubtreeEntryLimit) 项，请选择较小的目录展开。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                let rows = visibleTreeRows(at: rootURL)
                let contentWidth = fileTreeContentWidth(rows: rows)
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView([.horizontal, .vertical]) {
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
                                ForEach(rows) { row in
                                    FileTreeEntryView(
                                        entry: row.entry,
                                        appState: appState,
                                        depth: row.depth,
                                        minimumRowWidth: geometry.size.width - 12,
                                        selectedTreeItem: $selectedTreeItem,
                                        selectedTreeItems: selectedTreeItems,
                                        contextMenuTreeItemURL: $contextMenuTreeItemURL,
                                        focusedFileTreeURL: $focusedFileTreeURL,
                                        requestPaste: requestPaste,
                                        beginCreatingFileItem: beginCreatingFileItem,
                                        beginRenamingFileItem: beginRenamingFileItem,
                                        beginDeletingFileItem: beginDeletingFileItem,
                                        beginDeletingSelectedFileItems: beginDeletingSelectedFileItems,
                                        handleTreeItemClick: handleTreeItemClick,
                                        prepareContextMenu: prepareContextMenu,
                                        expandSubtree: expandSubtree,
                                        viewGitHistory: { appState.showFileHistory(for: row.entry.url) }
                                    )
                                }
                            }
                            .padding(6)
                            .frame(
                                minWidth: max(geometry.size.width, contentWidth),
                                minHeight: geometry.size.height,
                                alignment: .topLeading
                            )
                        }
                        .onChange(of: appState.fileTreeRevealRequest?.id) {
                            guard let fileURL = appState.fileTreeRevealRequest?.fileURL else { return }
                            proxy.scrollTo(fileURL)
                        }
                    }
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

    private var selectedFilePathComponents: [String] {
        guard let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL,
              let fileURL = appState.selectedFileURL?.standardizedFileURL else {
            return []
        }
        let rootComponents = rootURL.pathComponents
        let fileComponents = fileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return []
        }
        return [visibleRootName] + Array(fileComponents.dropFirst(rootComponents.count))
    }

    private var filePathBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(selectedFilePathComponents.indices, id: \.self) { index in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(selectedFilePathComponents[index])
                            .foregroundStyle(index == selectedFilePathComponents.count - 1 ? .primary : .secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .id(index)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 27)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                proxy.scrollTo(selectedFilePathComponents.count - 1, anchor: .trailing)
            }
            .onChange(of: appState.selectedFileURL) {
                proxy.scrollTo(selectedFilePathComponents.count - 1, anchor: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selectedFilePathComponents.joined(separator: " > "))
    }

    @ViewBuilder
    private var documentView: some View {
        if appState.isLoadingDocument {
            ProgressView("正在加载文档…")
        } else if let document = appState.loadedDocument {
            switch document {
            case .text(let textDocument):
                if appState.showsMarkdownPreview, let fileURL = appState.selectedFileURL,
                   fileURL.pathExtension.lowercased() == "md" {
                    MarkdownDocumentView(
                        text: appState.documentText,
                        fileURL: fileURL,
                        projectRootURL: appState.visibleWorkspaceRootURL,
                        fontSize: appState.fileContentFontSize,
                        sourceLine: appState.selectedFileVisibleLine,
                        navigationRequest: appState.selectedSourceNavigationRequest,
                        headerActions: documentHeaderActions,
                        onVisibleLineChange: { appState.rememberSelectedFileVisibleLine($0) },
                        onNavigationHandled: { appState.clearSelectedSourceNavigationRequest($0) },
                        onOpenFile: { target, line in
                            guard appState.selectedFileURL == fileURL else { return }
                            appState.selectFile(target, line: line)
                        }
                    )
                } else {
                    SourceDocumentView(
                        text: Binding(
                            get: { appState.documentText },
                            set: { appState.updateSelectedDocumentText($0) }
                        ),
                        isLarge: textDocument.isLarge,
                        fileIdentity: appState.selectedFileURL?.standardizedFileURL.path ?? "",
                        fileName: appState.selectedFileURL?.lastPathComponent ?? "",
                        fileExtension: appState.selectedFileURL?.pathExtension.lowercased() ?? "",
                        isModified: appState.hasUnsavedDocumentChanges,
                        isSaving: appState.isSavingDocument,
                        headerActions: documentHeaderActions,
                        navigationRequest: appState.selectedSourceNavigationRequest,
                        onVisibleLineChange: { appState.rememberSelectedFileVisibleLine($0) },
                        onNavigationHandled: { appState.clearSelectedSourceNavigationRequest($0) },
                        fontSize: appState.fileContentFontSize,
                        semanticTokens: appState.javaSemanticTokens,
                        javaNavigationLoadingPresentation: appState.javaNavigationLoadingPresentation,
                        javaNavigationPresentation: appState.javaNavigationResultPresentation,
                        javaNavigationSourcePresentation: appState.javaNavigationSourcePresentation,
                        onJavaNavigation: { action, position, anchor in
                            guard let fileURL = appState.selectedFileURL else { return }
                            appState.performJavaNavigation(
                                action: action,
                                fileURL: fileURL,
                                position: position,
                                documentText: appState.documentText,
                                anchor: anchor.map {
                                    JavaNavigationPopupAnchor(x: $0.x, y: $0.y)
                                }
                            )
                        },
                        onJavaNavigationTargetSelected: appState.selectJavaNavigationTarget,
                        onJavaNavigationDismissed: {
                            appState.javaNavigationResultPresentation = nil
                        },
                        onJavaNavigationSourceOpened: appState.openJavaNavigationSource,
                        onJavaNavigationSourceDismissed: appState.dismissJavaNavigationSource,
                        onNavigationBack: { appState.navigateFileBack() },
                        onNavigationForward: { appState.navigateFileForward() },
                        shortcuts: appState.shortcuts,
                        loadGitBlame: selectedFileGitBlameLoader,
                        loadGitLineBaseline: selectedFileGitLineBaselineLoader,
                        gitSnapshot: appState.selectedFileGitSnapshot,
                        gitBaselineChange: appState.selectedFileGitChange,
                        onGitBlameCommitSelected: { hash in
                            guard let fileURL = appState.selectedFileURL else { return }
                            appState.showFileBlameCommitInHistory(hash, fileURL: fileURL)
                        },
                        importsExpanded: selectedFileImportsExpanded
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

    private var fileTabsBar: some View {
        HStack(spacing: FileTabStripMetrics.spacing) {
            FileTabStripScrollView(
                contextID: appState.visibleWorkspaceRootURL?.path,
                tabIDs: appState.openFileTabs.map(\.id),
                selectedID: appState.selectedFileURL
            ) {
                HStack(spacing: FileTabStripMetrics.spacing) {
                    ForEach(appState.openFileTabs) { tab in
                        fileTab(tab)
                            .frame(width: FileTabStripMetrics.tabWidth, height: FileTabStripMetrics.tabHeight)
                    }
                }
                .padding(.horizontal, FileTabStripMetrics.inset)
            }
            .accessibilityIdentifier("RepoDesk.FileTabs.Scroll")
            Menu {
                ForEach(appState.openFileTabs) { tab in
                    Button {
                        appState.selectFileTab(tab)
                    } label: {
                        Label(
                            "\(tab.url.lastPathComponent) — \(fileTabPath(tab))",
                            systemImage: appState.selectedFileURL == tab.url ? "checkmark" : "doc.text"
                        )
                    }
                }
            } label: {
                Image(systemName: "list.bullet").frame(width: 28, height: 30)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("所有打开的文件")
            .accessibilityLabel("所有打开的文件")
            .accessibilityIdentifier("RepoDesk.FileTabs.Overflow")
            .padding(.trailing, 8)
        }
        .frame(height: FileTabStripMetrics.stripHeight)
    }

    private func fileTab(_ tab: OpenFileTab) -> some View {
        let isSelected = appState.selectedFileURL == tab.url
        return HStack(spacing: 6) {
            Button {
                appState.selectFileTab(tab)
            } label: {
                HStack(spacing: 6) {
                    FileTypeIcon(path: tab.url.path)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.url.lastPathComponent).lineLimit(1)
                        Text(fileTabPath(tab))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(width: 220, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(tab.url.path)
            .accessibilityIdentifier("RepoDesk.FileTab.\(tab.url.lastPathComponent)")
            .accessibilityValue(isSelected ? "selected" : "open")
            Button { appState.closeFileTab(id: tab.id) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭 \(tab.url.lastPathComponent)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                    in: .rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .contextMenu {
            Button("关闭当前", systemImage: "xmark") { appState.closeFileTab(id: tab.id) }
            Button("关闭其他", systemImage: "xmark.circle") { appState.closeOtherFileTabs(keeping: tab.id) }
            Button("关闭所有", systemImage: "xmark.circle.fill") { appState.closeAllFileTabs() }
        }
    }

    private func fileTabPath(_ tab: OpenFileTab) -> String {
        guard let root = appState.visibleWorkspaceRootURL?.standardizedFileURL else {
            return tab.url.deletingLastPathComponent().path
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard tab.url.path.hasPrefix(rootPath) else { return tab.url.deletingLastPathComponent().path }
        let relative = String(tab.url.path.dropFirst(rootPath.count))
        let directory = (relative as NSString).deletingLastPathComponent
        return directory.isEmpty ? "." : directory
    }

    private var selectedFileGitBlameLoader: (() async throws -> [GitBlameLine])? {
        guard appState.canBlameSelectedFile else { return nil }
        return { try await appState.blameForSelectedFile() }
    }

    private var selectedFileGitLineBaselineLoader: (() async throws -> String?)? {
        guard appState.canBlameSelectedFile else { return nil }
        return { try await appState.lineChangeBaselineForSelectedFile() }
    }

    private var selectedFileImportsExpanded: Binding<Bool> {
        let fileURL = appState.selectedFileURL
        return Binding(
            get: { appState.openFileTabs.first { $0.url == fileURL }?.importsExpanded ?? false },
            set: { value in
                guard let index = appState.openFileTabs.firstIndex(where: { $0.url == fileURL }) else { return }
                appState.openFileTabs[index].importsExpanded = value
            }
        )
    }

    private var documentHeaderActions: DocumentHeaderActions {
        DocumentHeaderActions(
            canRevealSelectedFile: appState.canRevealSelectedFileInTree,
            onRevealSelectedFile: { Task { await appState.revealSelectedFileInTree() } },
            canShowGitHistory: appState.canShowGitHistoryForSelectedFile,
            onShowGitHistory: {
                guard let selectedFileURL = appState.selectedFileURL else { return }
                appState.showFileHistory(for: selectedFileURL)
            },
            isReloadDisabled: appState.isLoadingDocument || appState.isSavingDocument,
            onReloadSelectedFile: appState.requestReloadSelectedFile
        )
    }

    private var pendingFilePasteBinding: Binding<Bool> {
        Binding(
            get: { pendingFilePastePlan != nil },
            set: { if !$0 { pendingFilePastePlan = nil } }
        )
    }

    private var filePasteErrorBinding: Binding<Bool> {
        Binding(
            get: { filePasteErrorMessage != nil },
            set: { if !$0 { filePasteErrorMessage = nil } }
        )
    }

    private var filePasteConflictMessage: String {
        guard let pendingFilePastePlan else { return "请选择如何处理同名项目。" }
        let conflicts = pendingFilePastePlan.conflictingDestinationURLs
        if conflicts.count == 1, let name = conflicts.first?.lastPathComponent {
            return "“\(name)”已经存在。"
        }
        return "有 \(conflicts.count) 个同名项目已经存在。"
    }

    private func handleTreeItemClick(
        itemURL: URL,
        isDirectory: Bool,
        activationURL: URL,
        siblingURLs: [URL]
    ) {
        let itemURL = itemURL.standardizedFileURL
        let selection = FileTreeItemSelection(url: itemURL, isDirectory: isDirectory)
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []

        if modifiers.contains(.shift) {
            let siblings = siblingURLs.map { $0.standardizedFileURL }
            if let anchor = selectionAnchorURL,
               let anchorIndex = siblings.firstIndex(of: anchor),
               let itemIndex = siblings.firstIndex(of: itemURL) {
                let range = anchorIndex <= itemIndex
                    ? siblings[anchorIndex...itemIndex]
                    : siblings[itemIndex...anchorIndex]
                let kinds = Dictionary(uniqueKeysWithValues: selectedTreeItems.map { ($0.url, $0.isDirectory) })
                selectedTreeItems = Set(range.map {
                    FileTreeItemSelection(
                        url: $0,
                        isDirectory: kinds[$0] ?? ($0 == itemURL ? isDirectory : directoryFlag(at: $0))
                    )
                })
            } else {
                selectedTreeItems = [selection]
                selectionAnchorURL = itemURL
            }
            selectedTreeItem = selection
            focusedFileTreeURL = itemURL
            return
        }

        if modifiers.contains(.command) {
            if selectedTreeItems.contains(selection) {
                selectedTreeItems.remove(selection)
            } else {
                selectedTreeItems.insert(selection)
            }
            selectedTreeItem = selection
            selectionAnchorURL = itemURL
            focusedFileTreeURL = itemURL
            return
        }

        selectedTreeItems = [selection]
        selectedTreeItem = selection
        selectionAnchorURL = itemURL
        focusedFileTreeURL = itemURL
        if isDirectory {
            cancelSubtreeExpansion()
            appState.toggleDirectory(activationURL.standardizedFileURL)
        } else {
            appState.selectFile(itemURL)
        }
    }

    private func collapseFileTree(at rootURL: URL) {
        cancelSubtreeExpansion()
        appState.collapseFileTree(at: rootURL)

        let selection = FileTreeItemSelection(url: rootURL, isDirectory: true)
        selectedTreeItem = selection
        selectedTreeItems = [selection]
        selectionAnchorURL = rootURL
        focusedFileTreeURL = rootURL
    }

    private func expandSubtree(at directoryURL: URL) {
        cancelSubtreeExpansion()
        subtreeExpansionTask = Task {
            let reachedLimit = await appState.expandDirectorySubtree(directoryURL)
            guard !Task.isCancelled else { return }
            subtreeExpansionReachedLimit = reachedLimit
            subtreeExpansionTask = nil
        }
    }

    private func cancelSubtreeExpansion() {
        subtreeExpansionTask?.cancel()
        subtreeExpansionTask = nil
        subtreeExpansionReachedLimit = false
    }

    private func prepareContextMenu(for itemURL: URL, isDirectory: Bool) {
        let itemURL = itemURL.standardizedFileURL
        guard !selectedTreeItems.contains(where: { $0.url == itemURL }) else { return }
        let selection = FileTreeItemSelection(url: itemURL, isDirectory: isDirectory)
        selectedTreeItems = [selection]
        selectedTreeItem = selection
        selectionAnchorURL = itemURL
        focusedFileTreeURL = itemURL
    }

    private func fileTreeItemBackground(for itemURL: URL) -> Color {
        let itemURL = itemURL.standardizedFileURL
        if selectedTreeItems.contains(where: { $0.url == itemURL }) {
            return Color.accentColor.opacity(0.14)
        }
        if contextMenuTreeItemURL == itemURL {
            return Color.accentColor.opacity(0.06)
        }
        return .clear
    }

    private func contextMenuPresentationBinding(for itemURL: URL) -> Binding<Bool> {
        let itemURL = itemURL.standardizedFileURL
        return Binding(
            get: { contextMenuTreeItemURL == itemURL },
            set: { isPresented in
                if isPresented {
                    contextMenuTreeItemURL = itemURL
                } else if contextMenuTreeItemURL == itemURL {
                    contextMenuTreeItemURL = nil
                }
            }
        )
    }

    private func copyFileTreeItems(for itemURL: URL) {
        let itemURL = itemURL.standardizedFileURL
        let urls = selectedTreeItems.count > 1 && selectedTreeItems.contains(where: { $0.url == itemURL })
            ? selectedTreeItems.map(\.url)
            : [itemURL]
        FileSystemClipboard.copyItems(at: urls)
    }

    private func beginCreatingFileItem(in directoryURL: URL, isDirectory: Bool) {
        guard let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL else { return }
        let directoryURL = directoryURL.standardizedFileURL
        guard WorkspaceTreeRefreshPlanner.isSameOrDescendant(directoryURL, of: rootURL),
              (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              !isCreatingFileItem else { return }
        newFileItemName = ""
        newFileItemRequest = NewFileItemRequest(
            directoryURL: directoryURL,
            isDirectory: isDirectory
        )
    }

    private func beginDeletingFileItem(_ itemURL: URL, isDirectory: Bool) {
        guard let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL,
              itemURL.standardizedFileURL != rootURL,
              WorkspaceTreeRefreshPlanner.isSameOrDescendant(itemURL, of: rootURL),
              !isDeletingFileItem else { return }
        let itemURL = itemURL.standardizedFileURL
        if selectedTreeItems.contains(where: { $0.url == itemURL }) {
            beginDeletingSelectedFileItems()
            return
        }
        deleteFileItemRequest = DeleteFileItemRequest(
            items: [FileTreeItemSelection(url: itemURL, isDirectory: isDirectory)]
        )
    }

    private func beginRenamingFileItem(_ itemURL: URL, isDirectory: Bool) {
        guard let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL,
              itemURL.standardizedFileURL != rootURL,
              WorkspaceTreeRefreshPlanner.isSameOrDescendant(itemURL, of: rootURL),
              !isRenamingFileItem else { return }
        let itemURL = itemURL.standardizedFileURL
        renameFileItemName = itemURL.lastPathComponent
        renameFileItemRequest = RenameFileItemRequest(
            itemURL: itemURL,
            isDirectory: isDirectory
        )
    }

    private func beginDeletingSelectedFileItems() {
        guard let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL,
              !isDeletingFileItem else { return }
        let items = normalizedDeletionItems(
            selectedTreeItems.filter {
                $0.url != rootURL && WorkspaceTreeRefreshPlanner.isSameOrDescendant($0.url, of: rootURL)
            }
        )
        guard !items.isEmpty else { return }
        deleteFileItemRequest = DeleteFileItemRequest(items: items)
    }

    private func deleteFileItem() {
        guard let request = deleteFileItemRequest,
              let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL else { return }
        deleteFileItemRequest = nil
        isDeletingFileItem = true
        Task {
            let backupDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoDeskDeleted", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let deletedURLs = request.items.map { $0.url.standardizedFileURL }
            let tabsToRestore = appState.openFileTabs.filter { tab in
                deletedURLs.contains {
                    WorkspaceTreeRefreshPlanner.isSameOrDescendant(tab.url, of: $0)
                }
            }
            let selectedFileToRestore = appState.selectedFileURL
            var deletedItems: [WorkspaceFileDeletionItem] = []
            do {
                for item in request.items {
                    let deletedItem = try await FileSystemWorkspaceFileDeleter().delete(
                        WorkspaceFileDeletionRequest(
                            itemURL: item.url,
                            workspaceRootURL: rootURL,
                            backupDirectoryURL: backupDirectoryURL
                        )
                    )
                    deletedItems.append(deletedItem)
                    appState.closeFileTabs(at: item.url)
                }
                appState.recordDeletedFileSession(
                    WorkspaceFileDeletionSession(
                        items: deletedItems,
                        backupDirectoryURL: backupDirectoryURL,
                        workspaceRootURL: rootURL
                    ),
                    tabs: tabsToRestore,
                    selectedFileURL: selectedFileToRestore
                )
                for directoryURL in Set(request.items.map { $0.url.deletingLastPathComponent().standardizedFileURL }) {
                    await appState.loadDirectory(directoryURL, forceReload: true)
                }
                let deletedURLs = Set(request.items.map(\.url))
                selectedTreeItems = selectedTreeItems.filter { selection in
                    !deletedURLs.contains(where: { WorkspaceTreeRefreshPlanner.isSameOrDescendant(selection.url, of: $0) })
                }
                selectedTreeItem = nil
                selectionAnchorURL = nil
                focusedFileTreeURL = nil
            } catch {
                if !deletedItems.isEmpty {
                    appState.recordDeletedFileSession(
                        WorkspaceFileDeletionSession(
                            items: deletedItems,
                            backupDirectoryURL: backupDirectoryURL,
                            workspaceRootURL: rootURL
                        ),
                        tabs: tabsToRestore,
                        selectedFileURL: selectedFileToRestore
                    )
                } else {
                    try? FileManager.default.removeItem(at: backupDirectoryURL)
                }
                deleteFileItemErrorMessage = error.localizedDescription
            }
            isDeletingFileItem = false
        }
    }

    private func createFileItem() {
        guard let request = newFileItemRequest else { return }
        let name = newFileItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFileItemRequest = nil
        newFileItemName = ""
        guard !name.isEmpty else { return }

        isCreatingFileItem = true
        Task {
            do {
                let destinationURL = try await fileCreator.create(
                    WorkspaceFileCreationRequest(
                        directoryURL: request.directoryURL,
                        name: name,
                        isDirectory: request.isDirectory
                    )
                )
                await appState.loadDirectory(request.directoryURL, forceReload: true)
                let selection = FileTreeItemSelection(
                    url: destinationURL,
                    isDirectory: request.isDirectory
                )
                selectedTreeItem = selection
                selectedTreeItems = [selection]
                selectionAnchorURL = destinationURL.standardizedFileURL
                await appState.revealFileTreeItem(destinationURL)
                focusedFileTreeURL = destinationURL
                if !request.isDirectory {
                    appState.selectFile(destinationURL)
                }
            } catch {
                newFileItemErrorMessage = error.localizedDescription
            }
            isCreatingFileItem = false
        }
    }

    private func cancelNewFileItem() {
        newFileItemRequest = nil
        newFileItemName = ""
    }

    private func renameFileItem() {
        guard let request = renameFileItemRequest,
              let rootURL = appState.visibleWorkspaceRootURL?.standardizedFileURL else { return }
        let newName = renameFileItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        renameFileItemRequest = nil
        renameFileItemName = ""
        guard !newName.isEmpty else { return }

        isRenamingFileItem = true
        Task {
            do {
                let newURL = try await fileRenamer.rename(
                    WorkspaceFileRenameRequest(
                        itemURL: request.itemURL,
                        newName: newName,
                        workspaceRootURL: rootURL
                    )
                )
                appState.fileItemWasRenamed(from: request.itemURL, to: newURL)
                await appState.loadDirectory(
                    request.itemURL.deletingLastPathComponent(),
                    forceReload: true
                )
                let selection = FileTreeItemSelection(
                    url: newURL,
                    isDirectory: request.isDirectory
                )
                selectedTreeItem = selection
                selectedTreeItems = [selection]
                selectionAnchorURL = newURL.standardizedFileURL
                await appState.revealFileTreeItem(newURL)
                focusedFileTreeURL = newURL.standardizedFileURL
            } catch {
                renameFileItemErrorMessage = error.localizedDescription
            }
            isRenamingFileItem = false
        }
    }

    private func cancelRenameFileItem() {
        renameFileItemRequest = nil
        renameFileItemName = ""
    }

    private func handleFileTreeKeyPress(
        _ keyPress: KeyPress,
        itemURL: URL,
        isDirectory: Bool
    ) -> KeyPress.Result {
        if matchesFileTreeShortcut(keyPress, id: .copyFileTreeItem) {
            copyFileTreeItems(for: itemURL)
            return .handled
        }
        if matchesFileTreeShortcut(keyPress, id: .pasteFileTreeItem) {
            requestPaste(into: itemURL, isDirectory: isDirectory)
            return .handled
        }
        return .ignored
    }

    private func matchesFileTreeShortcut(_ keyPress: KeyPress, id: AppShortcutID) -> Bool {
        let binding = appState.shortcut(for: id)
        return keyPress.modifiers == binding.eventModifiers
            && keyPress.characters.lowercased() == binding.key
    }

    private func requestPaste(into itemURL: URL, isDirectory: Bool) {
        guard !isPastingFiles else { return }
        let sourceURLs = FileSystemClipboard.fileURLs()
        guard !sourceURLs.isEmpty else { return }
        let destinationDirectoryURL = isDirectory
            ? itemURL.standardizedFileURL
            : itemURL.deletingLastPathComponent().standardizedFileURL
        isPastingFiles = true
        Task {
            do {
                let plan = try await fileTransfer.preparePaste(
                    sourceURLs: sourceURLs,
                    destinationDirectoryURL: destinationDirectoryURL
                )
                isPastingFiles = false
                if plan.conflictingDestinationURLs.isEmpty {
                    performPaste(plan, resolution: .replace)
                } else {
                    pendingFilePastePlan = plan
                }
            } catch {
                isPastingFiles = false
                filePasteErrorMessage = error.localizedDescription
            }
        }
    }

    private var newFileItemErrorBinding: Binding<Bool> {
        Binding(
            get: { newFileItemErrorMessage != nil },
            set: { if !$0 { newFileItemErrorMessage = nil } }
        )
    }

    private var renameFileItemErrorBinding: Binding<Bool> {
        Binding(
            get: { renameFileItemErrorMessage != nil },
            set: { if !$0 { renameFileItemErrorMessage = nil } }
        )
    }

    private var deleteFileItemErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteFileItemErrorMessage != nil },
            set: { if !$0 { deleteFileItemErrorMessage = nil } }
        )
    }

    private var fileDeletionRestoreErrorBinding: Binding<Bool> {
        Binding(
            get: { appState.fileDeletionRestoreErrorMessage != nil },
            set: { if !$0 { appState.fileDeletionRestoreErrorMessage = nil } }
        )
    }

    private var deleteFileItemMessage: String {
        guard let request = deleteFileItemRequest else { return "" }
        if request.items.count > 1 {
            return "确定删除这 \(request.items.count) 个项目吗？"
        }
        guard let item = request.items.first else { return "" }
        if item.isDirectory {
            return "确定要删除目录“\(item.url.lastPathComponent)”及其全部内容吗？"
        }
        return "确定要删除文件“\(item.url.lastPathComponent)”吗？"
    }

    private func normalizedDeletionItems(_ items: [FileTreeItemSelection]) -> [FileTreeItemSelection] {
        let sorted = items.sorted { $0.url.path.count < $1.url.path.count }
        return sorted.filter { item in
            !sorted.contains { other in
                other.url != item.url
                    && WorkspaceTreeRefreshPlanner.isSameOrDescendant(item.url, of: other.url)
            }
        }
    }

    private func directoryFlag(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func resolvePendingFilePaste(_ resolution: WorkspaceFilePasteConflictResolution) {
        guard let plan = pendingFilePastePlan else { return }
        pendingFilePastePlan = nil
        performPaste(plan, resolution: resolution)
    }

    private func performPaste(
        _ plan: WorkspaceFilePastePlan,
        resolution: WorkspaceFilePasteConflictResolution
    ) {
        guard !isPastingFiles else { return }
        isPastingFiles = true
        Task {
            do {
                let result = try await fileTransfer.executePaste(plan, resolution: resolution)
                await appState.loadDirectory(result.destinationDirectoryURL, forceReload: true)
                if let item = result.items.first {
                    let selection = FileTreeItemSelection(
                        url: item.destinationURL,
                        isDirectory: item.isDirectory
                    )
                    selectedTreeItem = selection
                    selectedTreeItems = [selection]
                    selectionAnchorURL = item.destinationURL.standardizedFileURL
                    await appState.revealFileTreeItem(item.destinationURL)
                    focusedFileTreeURL = item.destinationURL.standardizedFileURL
                }
            } catch {
                filePasteErrorMessage = error.localizedDescription
            }
            isPastingFiles = false
        }
    }

    private func visibleEntries(_ entries: [WorkspaceFileEntry]) -> [WorkspaceFileEntry] {
        guard !appState.showsHiddenFiles else { return entries }
        return entries.filter { !$0.name.hasPrefix(".") }
    }

    private struct TreeRow: Identifiable {
        let entry: WorkspaceFileEntry
        let depth: Int
        let widthDepth: Int
        var id: URL { entry.url }
    }

    private func visibleTreeRows(at rootURL: URL) -> [TreeRow] {
        var rows: [TreeRow] = []
        func visit(_ directory: URL, depth: Int, widthDepth: Int) {
            for entry in visibleEntries(appState.fileChildren[directory] ?? []) {
                rows.append(TreeRow(entry: entry, depth: depth, widthDepth: widthDepth))
                let displayed = FileTreeEntryView.displayedEntries(for: entry, appState: appState)
                if entry.isDirectory, appState.expandedDirectoryURLs.contains(entry.url),
                   let directory = displayed.last?.url {
                    visit(directory, depth: depth + 1, widthDepth: widthDepth + displayed.count)
                }
            }
        }
        visit(rootURL, depth: 0, widthDepth: 0)
        return rows
    }

    private func fileTreeContentWidth(rows: [TreeRow]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(appState.interfaceFontSize))
        return rows.reduce(CGFloat.zero) { width, row in
            let title = FileTreeEntryView.displayedEntries(for: row.entry, appState: appState)
                .map(\.name).joined(separator: "/")
            return max(width, FileTreeTitleWidthCache.shared.width(title, font: font)
                + CGFloat(row.widthDepth) * 14 + 52)
        }
    }

}

@MainActor
private struct NewFileItemSheet: View {
    let title: String
    let placeholder: String
    let directoryName: String
    @Binding var name: String
    let create: () -> Void
    let cancel: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            Text("在“\(directoryName)”中创建")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("创建", action: create)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            isNameFocused = true
        }
        .onExitCommand(perform: cancel)
    }
}

@MainActor
private struct RenameFileItemSheet: View {
    let title: String
    @Binding var name: String
    let rename: () -> Void
    let cancel: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("重命名", action: rename)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            isNameFocused = true
        }
        .onExitCommand(perform: cancel)
    }
}

@MainActor
private struct DeleteConfirmationSheet: View {
    let message: String
    let delete: () -> Void
    let cancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认删除")
                .font(.headline)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel)
                    .buttonStyle(.plain)
                    .focusable(false)
                Button("删除", role: .destructive, action: delete)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .focusable(false)
            }
        }
        .padding(20)
        .frame(width: 380)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
        }
        .onKeyPress(.return, phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty else { return .ignored }
            delete()
            return .handled
        }
        .onExitCommand(perform: cancel)
    }
}

private struct NewFileItemRequest: Identifiable {
    let id = UUID()
    let directoryURL: URL
    let isDirectory: Bool
}

private struct RenameFileItemRequest: Identifiable {
    let id = UUID()
    let itemURL: URL
    let isDirectory: Bool
}

private struct DeleteFileItemRequest: Identifiable {
    let id = UUID()
    let items: [FileTreeItemSelection]
}

private struct FileTreeItemSelection: Hashable {
    let url: URL
    let isDirectory: Bool
}

@MainActor
private final class FileTreeTitleWidthCache {
    static let shared = FileTreeTitleWidthCache()
    private var widths: [String: CGFloat] = [:]

    func width(_ title: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName):\(font.pointSize):\(title)"
        if let width = widths[key] { return width }
        if widths.count >= 10_000 { widths.removeAll(keepingCapacity: true) }
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        widths[key] = width
        return width
    }
}

@MainActor
private struct FileTreeEntryView: View {
    let entry: WorkspaceFileEntry
    @Bindable var appState: AppState
    let depth: Int
    let minimumRowWidth: CGFloat
    @Binding var selectedTreeItem: FileTreeItemSelection?
    let selectedTreeItems: Set<FileTreeItemSelection>
    @Binding var contextMenuTreeItemURL: URL?
    let focusedFileTreeURL: FocusState<URL?>.Binding
    let requestPaste: (URL, Bool) -> Void
    let beginCreatingFileItem: (URL, Bool) -> Void
    let beginRenamingFileItem: (URL, Bool) -> Void
    let beginDeletingFileItem: (URL, Bool) -> Void
    let beginDeletingSelectedFileItems: () -> Void
    let handleTreeItemClick: (URL, Bool, URL, [URL]) -> Void
    let prepareContextMenu: (URL, Bool) -> Void
    let expandSubtree: (URL) -> Void
    let viewGitHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                handleTreeItemClick(commandItemURL, entry.isDirectory, entry.url, siblingURLs)
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
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 2)
                    if displayedEntries.contains(where: { appState.loadingDirectoryURLs.contains($0.url) }) {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.leading, CGFloat(depth) * 14)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minWidth: minimumRowWidth, alignment: .leading)
                .frame(height: max(26, appState.interfaceFontSize + 14))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(
                rowBackgroundColor,
                in: .rect(cornerRadius: 5)
            )
            .focusable()
            .focusEffectDisabled()
            .focused(focusedFileTreeURL, equals: commandItemURL)
            .onKeyPress(phases: .down) { keyPress in
                if matchesFileTreeShortcut(keyPress, id: .copyFileTreeItem) {
                    copySelectedItems()
                    return .handled
                }
                if matchesFileTreeShortcut(keyPress, id: .pasteFileTreeItem) {
                    requestPaste(commandItemURL, entry.isDirectory)
                    return .handled
                }
                return .ignored
            }
            .id(entry.url.standardizedFileURL)
            .fileSystemPathCopyMenu(
                isMultiSelection ? nil : pathCopyValues,
                copyItem: { copySelectedItems() },
                pasteItem: isMultiSelection ? nil : { requestPaste(commandItemURL, entry.isDirectory) },
                newFileItem: isMultiSelection ? nil : (entry.isDirectory
                    ? { beginCreatingFileItem(commandItemURL, false) }
                    : nil),
                newDirectoryItem: isMultiSelection ? nil : (entry.isDirectory
                    ? { beginCreatingFileItem(commandItemURL, true) }
                    : nil),
                expandSubtreeItem: entry.isDirectory && !isMultiSelection
                    ? { expandSubtree(entry.url) }
                    : nil,
                renameItem: isMultiSelection ? nil : {
                    beginRenamingFileItem(commandItemURL, entry.isDirectory)
                },
                deleteItem: { beginDeletingFileItem(commandItemURL, entry.isDirectory) },
                viewGitHistoryItem: entry.isDirectory || isMultiSelection ? nil : viewGitHistory,
                openInFinderItem: isMultiSelection ? nil : {
                    openFileSystemItemInFinder(at: commandItemURL, isDirectory: entry.isDirectory)
                },
                isContextMenuPresented: contextMenuPresentationBinding
            )

            if entry.isDirectory, appState.expandedDirectoryURLs.contains(entry.url),
               let message = appState.directoryLoadErrors[displayedDirectoryURL] {
                DirectoryLoadErrorView(message: message, retry: { appState.retryDirectory(displayedDirectoryURL) })
                    .padding(.leading, CGFloat(depth + 1) * 14)
            }
        }
    }

    private var displayedEntries: [WorkspaceFileEntry] {
        Self.displayedEntries(for: entry, appState: appState)
    }

    fileprivate static func displayedEntries(
        for entry: WorkspaceFileEntry,
        appState: AppState
    ) -> [WorkspaceFileEntry] {
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

    private var commandItemURL: URL {
        entry.isDirectory ? displayedDirectoryURL : entry.url.standardizedFileURL
    }

    private static func commandItemURL(
        for entry: WorkspaceFileEntry,
        appState: AppState
    ) -> URL {
        let displayedEntries = Self.displayedEntries(for: entry, appState: appState)
        return (entry.isDirectory ? displayedEntries.last?.url : entry.url)?.standardizedFileURL
            ?? entry.url.standardizedFileURL
    }

    private var siblingURLs: [URL] {
        let parentURL = entry.url.deletingLastPathComponent().standardizedFileURL
        let siblings = appState.fileChildren[parentURL] ?? []
        return siblings
            .filter { appState.showsHiddenFiles || !$0.name.hasPrefix(".") }
            .map { Self.commandItemURL(for: $0, appState: appState) }
    }

    private var isMultiSelection: Bool {
        selectedTreeItems.count > 1 && selectedTreeItems.contains(where: { $0.url == commandItemURL })
    }

    private func copySelectedItems() {
        let urls = isMultiSelection ? selectedTreeItems.map(\.url) : [commandItemURL]
        FileSystemClipboard.copyItems(at: urls)
    }

    private var rowBackgroundColor: Color {
        if selectedTreeItems.contains(where: { $0.url == commandItemURL }) {
            return Color.accentColor.opacity(0.14)
        }
        if contextMenuTreeItemURL == commandItemURL {
            return Color.accentColor.opacity(0.06)
        }
        return .clear
    }

    private var contextMenuPresentationBinding: Binding<Bool> {
        Binding(
            get: { contextMenuTreeItemURL == commandItemURL },
            set: { isPresented in
                if isPresented {
                    prepareContextMenu(commandItemURL, entry.isDirectory)
                    contextMenuTreeItemURL = commandItemURL
                } else if contextMenuTreeItemURL == commandItemURL {
                    contextMenuTreeItemURL = nil
                }
            }
        )
    }

    private var pathCopyValues: FileSystemPathCopyValues? {
        guard let rootURL = appState.visibleWorkspaceRootURL else { return nil }
        let itemURL = entry.isDirectory ? displayedDirectoryURL : entry.url
        return FileSystemPathCopyValues(itemURL: itemURL, rootURL: rootURL)
    }

    private var visibleChildren: [WorkspaceFileEntry] {
        let children = appState.fileChildren[displayedDirectoryURL] ?? []
        guard !appState.showsHiddenFiles else { return children }
        return children.filter { !$0.name.hasPrefix(".") }
    }

    private func matchesFileTreeShortcut(_ keyPress: KeyPress, id: AppShortcutID) -> Bool {
        let binding = appState.shortcut(for: id)
        return keyPress.modifiers == binding.eventModifiers
            && keyPress.characters.lowercased() == binding.key
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

private struct FileLineChangesRequest: Equatable {
    let fileIdentity: String
    let headRevision: String?
    let originalPath: String?
    let isUntracked: Bool
    let canLoad: Bool
}

@MainActor
struct SourceDocumentView: View {
    @Environment(\.isEnabled) private var isSectionActive
    @Binding var text: String
    let isLarge: Bool
    let fileIdentity: String
    let fileName: String
    let fileExtension: String
    let isModified: Bool
    let isSaving: Bool
    let headerActions: DocumentHeaderActions
    let navigationRequest: NativeTextNavigationRequest?
    let onVisibleLineChange: (Int) -> Void
    let onNavigationHandled: (UUID) -> Void
    let fontSize: Double
    let semanticTokens: [JavaSemanticToken]
    let javaNavigationLoadingPresentation: JavaNavigationLoadingPresentation?
    let javaNavigationPresentation: JavaNavigationResultPresentation?
    let javaNavigationSourcePresentation: JavaNavigationSourcePresentation?
    let onJavaNavigation: (JavaNavigationAction, JavaSourcePosition, CGPoint?) -> Void
    let onJavaNavigationTargetSelected: (JavaNavigationTarget) -> Void
    let onJavaNavigationDismissed: () -> Void
    let onJavaNavigationSourceOpened: () -> Void
    let onJavaNavigationSourceDismissed: () -> Void
    let onNavigationBack: () -> Void
    let onNavigationForward: () -> Void
    let shortcuts: [AppShortcutID: ShortcutBinding]
    let loadGitBlame: (() async throws -> [GitBlameLine])?
    var loadGitLineBaseline: (() async throws -> String?)? = nil
    var gitSnapshot: GitRepositorySnapshot? = nil
    var gitBaselineChange: GitFileChange? = nil
    var onGitBlameCommitSelected: ((String) -> Void)? = nil
    var importsExpanded: Binding<Bool>? = nil
    @State private var showsGoToLine = false
    @State private var goToLineInput = ""
    @State private var goToLineError: String?
    @State private var maximumLine = 1
    @State private var goToLineNavigationRequest: NativeTextNavigationRequest?
    @State private var gitBlame: [Int: NativeGitBlameAnnotation]?
    @State private var gitBlameErrorMessage: String?
    @State private var isLoadingGitBlame = false
    @State private var gitBlameRequestID = UUID()
    @State private var gitLineChanges = FileGitLineChanges()
    @State private var contentFindState = ContentFindState()
    @FocusState private var isGoToLineFieldFocused: Bool

    private var lineChangesRequest: FileLineChangesRequest {
        FileLineChangesRequest(
            fileIdentity: fileIdentity, headRevision: gitSnapshot?.lastCommit?.hash,
            originalPath: gitBaselineChange?.originalPath,
            isUntracked: gitBaselineChange?.isUntracked ?? false,
            canLoad: loadGitLineBaseline != nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                FileTypeIcon(path: fileName)
                Text(fileName)
                    .fontWeight(.semibold)
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
                if isLoadingGitBlame {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在加载 Git Blame")
                }
                if let gitBlameErrorMessage {
                    Label(gitBlameErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(gitBlameErrorMessage)
                }
                if isLarge {
                    Text("只读")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Button("跳转到首行", systemImage: "arrow.up.to.line") {
                    goToLine(1)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("跳转到首行")
                .accessibilityIdentifier("RepoDesk.GoToFirstLine")

                Button("跳转到尾行", systemImage: "arrow.down.to.line") {
                    goToLine(SourceLineIndex(text: text).lineCount)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("跳转到尾行")
                .accessibilityIdentifier("RepoDesk.GoToLastLine")

                headerActions
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
            if contentFindState.isPresented {
                ContentFindBar(
                    state: $contentFindState,
                    matchCount: contentSearchMatches.count,
                    dismiss: dismissContentFind
                )
                Divider()
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    NativeCodeEditor(
                        text: $text,
                        isEditable: !isLarge,
                        style: isLarge ? .plain : .source(fileExtension: fileExtension),
                        navigationRequest: goToLineNavigationRequest ?? navigationRequest,
                        showsLineNumbers: true,
                        gitBlame: gitBlame,
                        gitLineChanges: loadGitLineBaseline == nil ? nil
                            : (gitLineChanges.fileIdentity == fileIdentity ? gitLineChanges.markers : [:]),
                        canToggleGitBlame: loadGitBlame != nil && !isLoadingGitBlame,
                        onToggleGitBlame: toggleGitBlame,
                        onSelectGitBlameCommit: onGitBlameCommitSelected,
                        onRequestGoToLine: { _, lineCount in
                            presentGoToLine(maximumLine: lineCount)
                        },
                        onVisibleLineChange: onVisibleLineChange,
                        onNavigationHandled: { id in
                            if let request = goToLineNavigationRequest, request.id == id {
                                onVisibleLineChange(request.line)
                                goToLineNavigationRequest = nil
                            } else {
                                onNavigationHandled(id)
                            }
                        },
                        contentIdentity: fileIdentity,
                        fontSize: CGFloat(fontSize),
                        contentSearch: contentSearchPresentation,
                        focusRequestID: contentFindState.contentFocusRequestID,
                        semanticTokens: semanticTokens,
                        isJavaNavigationEnabled: fileExtension == "java",
                        onJavaNavigation: onJavaNavigation,
                        onJavaPopupDismiss: onJavaNavigationDismissed,
                        onNavigationBack: onNavigationBack,
                        onNavigationForward: onNavigationForward,
                        shortcuts: shortcuts,
                        foldsJavaImports: fileExtension == "java",
                        importsExpanded: importsExpanded,
                        usesIncrementalStyling: true
                    )

                    if let presentation = javaNavigationLoadingPresentation {
                        let popupSize = javaNavigationLoadingPopupSize
                        JavaNavigationLoadingPopover(presentation: presentation)
                            .offset(javaNavigationLoadingOffset(
                                for: presentation,
                                popupSize: popupSize,
                                in: geometry.size
                            ))
                    }

                    if let presentation = javaNavigationPresentation {
                        let popupSize = javaNavigationPopupSize(in: geometry.size)
                        JavaNavigationResultsPopup(
                            presentation: presentation,
                            size: popupSize,
                            selectTarget: onJavaNavigationTargetSelected,
                            dismiss: onJavaNavigationDismissed
                        )
                        .offset(popupOffset(
                            for: presentation,
                            popupSize: popupSize,
                            in: geometry.size
                        ))
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                    }

                    if let presentation = javaNavigationSourcePresentation {
                        let popupSize = javaNavigationSourcePopupSize(in: geometry.size)
                        JavaNavigationSourcePopover(
                            presentation: presentation,
                            size: popupSize,
                            openWorkspaceTarget: onJavaNavigationSourceOpened,
                            dismiss: onJavaNavigationSourceDismissed
                        )
                        .offset(sourcePopupOffset(
                            for: presentation,
                            popupSize: popupSize,
                            in: geometry.size
                        ))
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                    }

                    if showsGoToLine {
                        goToLinePanel
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .clipped()
            }
        }
        .background(ContentFindCommandListener(
            requestFind: presentContentFind,
            navigateMatch: navigateContentFind
        ))
        .task(id: isSectionActive ? lineChangesRequest : nil) {
            guard isSectionActive, let loadGitLineBaseline else { return }
            await gitLineChanges.load(fileIdentity: fileIdentity, text: text, using: loadGitLineBaseline)
        }
        .onChange(of: fileIdentity) {
            dismissGoToLine()
            contentFindState.dismiss()
            contentFindState.resetSelection()
            goToLineNavigationRequest = nil
            resetGitBlame()
        }
        .onChange(of: text) {
            gitLineChanges.update(text: text, fileIdentity: fileIdentity)
            if contentFindState.isPresented {
                contentFindState.resetSelection()
            }
            guard gitBlame != nil || isLoadingGitBlame else { return }
            resetGitBlame()
        }
    }

    private func popupOffset(
        for presentation: JavaNavigationResultPresentation,
        popupSize: CGSize,
        in size: CGSize
    ) -> CGSize {
        let origin = JavaNavigationPopupLayout.origin(
            anchor: presentation.anchor,
            popupSize: popupSize,
            availableSize: size
        )
        return CGSize(width: origin.x, height: origin.y)
    }

    private var javaNavigationLoadingPopupSize: CGSize {
        CGSize(width: 170, height: 34)
    }

    private func javaNavigationLoadingOffset(
        for presentation: JavaNavigationLoadingPresentation,
        popupSize: CGSize,
        in size: CGSize
    ) -> CGSize {
        guard presentation.anchor != nil else {
            return CGSize(
                width: max(10, size.width - popupSize.width - 10),
                height: 10
            )
        }
        let origin = JavaNavigationPopupLayout.origin(
            anchor: presentation.anchor,
            popupSize: popupSize,
            availableSize: size
        )
        return CGSize(width: origin.x, height: origin.y)
    }

    private func javaNavigationPopupSize(in availableSize: CGSize) -> CGSize {
        let preferred = JavaNavigationResultsPopup.preferredSize
        return CGSize(
            width: min(preferred.width, max(380, availableSize.width - 20)),
            height: min(preferred.height, max(190, availableSize.height - 20))
        )
    }

    private func javaNavigationSourcePopupSize(in availableSize: CGSize) -> CGSize {
        CGSize(
            width: min(410, max(320, availableSize.width - 20)),
            height: min(250, max(190, availableSize.height - 20))
        )
    }

    private func sourcePopupOffset(
        for presentation: JavaNavigationSourcePresentation,
        popupSize: CGSize,
        in size: CGSize
    ) -> CGSize {
        let origin = JavaNavigationPopupLayout.origin(
            anchor: presentation.anchor,
            popupSize: popupSize,
            availableSize: size
        )
        return CGSize(width: origin.x, height: origin.y)
    }

    private var contentSearchMatches: [ContentSearchMatch] {
        return ContentSearchMatcher.matches(
            in: text,
            query: contentFindState.query,
            options: contentFindState.options
        )
    }

    private var contentSearchPresentation: ContentSearchPresentation? {
        guard contentFindState.isPresented else { return nil }
        let matches = contentSearchMatches
        let activeIndex = contentFindState.activeMatchIndex(matchCount: matches.count)
        return ContentSearchPresentation(
            ranges: matches.map(\.range),
            activeRange: activeIndex.map { matches[$0].range },
            navigationRequestID: contentFindState.navigationRequestID
        )
    }

    private func presentContentFind() {
        dismissGoToLine()
        contentFindState.present()
    }

    private func dismissContentFind() {
        contentFindState.dismiss()
    }

    private func navigateContentFind(by offset: Int) {
        if !contentFindState.isPresented {
            presentContentFind()
        }
        contentFindState.navigate(by: offset, matchCount: contentSearchMatches.count)
    }

    private func toggleGitBlame() {
        gitBlameErrorMessage = nil
        if gitBlame != nil {
            resetGitBlame()
            return
        }
        guard let loadGitBlame, !isLoadingGitBlame else { return }

        let requestID = UUID()
        gitBlameRequestID = requestID
        isLoadingGitBlame = true
        Task {
            do {
                let lines = try await loadGitBlame()
                guard gitBlameRequestID == requestID else { return }
                isLoadingGitBlame = false
                if lines.isEmpty {
                    gitBlameErrorMessage = "当前文件没有可显示的 Git Blame 信息。"
                } else {
                    gitBlame = lines.reduce(into: [:]) { annotations, line in
                        annotations[line.lineNumber] = NativeGitBlameAnnotation(
                            commitHash: line.commitHash,
                            author: line.author,
                            authoredAt: line.authoredAt,
                            isUncommitted: line.isUncommitted,
                            authorEmail: line.authorEmail,
                            message: line.message
                        )
                    }
                }
            } catch {
                guard gitBlameRequestID == requestID else { return }
                isLoadingGitBlame = false
                gitBlameErrorMessage = error.localizedDescription
            }
        }
    }

    private func resetGitBlame() {
        gitBlameRequestID = UUID()
        gitBlame = nil
        gitBlameErrorMessage = nil
        isLoadingGitBlame = false
    }

    private var goToLinePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.to.line")
                    .foregroundStyle(.secondary)
                TextField("行号", text: $goToLineInput)
                    .textFieldStyle(.plain)
                    .frame(width: 96)
                    .focused($isGoToLineFieldFocused)
                    .onSubmit(performGoToLine)
                    .onChange(of: goToLineInput) {
                        goToLineError = nil
                    }
                Text("1-\(maximumLine)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("跳转", systemImage: "arrow.turn.down.left", action: performGoToLine)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("跳转到输入的行")
            }
            if let goToLineError {
                Text(goToLineError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator.opacity(0.75), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .onExitCommand(perform: dismissGoToLine)
        .accessibilityIdentifier("RepoDesk.GoToLine")
    }

    private func presentGoToLine(maximumLine: Int) {
        dismissContentFind()
        self.maximumLine = maximumLine
        goToLineInput = ""
        goToLineError = nil
        withAnimation(.easeOut(duration: 0.12)) {
            showsGoToLine = true
        }
        DispatchQueue.main.async {
            isGoToLineFieldFocused = true
        }
    }

    private func performGoToLine() {
        do {
            let line = try GoToLineValidator.validate(goToLineInput, maximumLine: maximumLine)
            goToLine(line)
        } catch let error as GoToLineValidationError {
            goToLineError = error.message
        } catch {
            goToLineError = "无法跳转到该行。"
        }
    }

    private func goToLine(_ line: Int) {
        dismissContentFind()
        dismissGoToLine()
        goToLineNavigationRequest = NativeTextNavigationRequest(line: line)
    }

    private func dismissGoToLine() {
        withAnimation(.easeOut(duration: 0.1)) {
            showsGoToLine = false
        }
        isGoToLineFieldFocused = false
    }
}

@MainActor
struct FileNameSearchSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = SearchResultSelection()
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("文件名搜索")
                    .fontWeight(.semibold)
                Spacer()
                Text(searchScopeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("搜索文件名", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isQueryFocused)
                .onChange(of: query) { _, value in
                    selection.reset()
                    appState.searchFiles(query: value)
                }
                .onSubmit { openSelectedResult() }

            HStack(spacing: 8) {
                if appState.isSearchingFiles {
                    ProgressView().controlSize(.small)
                    Text(appState.fileSearchResultsAreStale ? "正在更新，暂保留上次结果…" : "正在搜索…")
                } else if !query.isEmpty {
                    Text("\(appState.fileSearchResults.count) 个结果")
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(height: 18)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(appState.fileSearchResults.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                selection.index = index
                                openSelectedResult()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .fontWeight(index == selection.index ? .semibold : .regular)
                                    Text(relativePath(for: entry.url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .background(
                                index == selection.index ? Color.accentColor.opacity(0.16) : .clear,
                                in: .rect(cornerRadius: 5)
                            )
                            .accessibilityAddTraits(index == selection.index ? .isSelected : [])
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: selection.index) {
                    guard !appState.fileSearchResultsAreStale, appState.fileSearchResults.indices.contains(selection.index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(appState.fileSearchResults[selection.index].id, anchor: .center)
                    }
                }
            }
            .disabled(appState.fileSearchResultsAreStale)
            .overlay {
                if !appState.isSearchingFiles, !query.isEmpty, appState.fileSearchResults.isEmpty {
                    ContentUnavailableView("没有匹配的文件", systemImage: "magnifyingglass")
                }
            }
        }
        .padding(16)
        .frame(width: 620, height: 460)
        .onAppear {
            appState.searchFiles(query: "")
            isQueryFocused = true
        }
        .onDisappear { appState.cancelSearches() }
        .onChange(of: appState.fileSearchResults) {
            selection.clamp(toCount: appState.fileSearchResults.count)
        }
        .searchResultArrowKeys(
            isEnabled: isQueryFocused,
            count: appState.fileSearchResults.count,
            selection: $selection
        )
    }

    private func openSelectedResult() {
        guard appState.fileSearchResults.indices.contains(selection.index) else { return }
        appState.selectFile(appState.fileSearchResults[selection.index].url)
        appState.selectSection(.files)
        dismiss()
    }

    private func relativePath(for url: URL) -> String {
        guard let rootPath = appState.visibleWorkspaceRootURL?.standardizedFileURL.path else { return url.path }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }

    private var searchScopeLabel: String {
        appState.isWorkspaceContext ? "工作区" : (appState.selectedRepository?.name ?? "Repository")
    }
}

@MainActor
struct FullTextSearchSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = SearchResultSelection()
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("全文检索")
                    .fontWeight(.semibold)
                Spacer()
                Text(searchScopeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("搜索文件内容", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isQueryFocused)
                .onChange(of: query) { _, value in
                    selection.reset()
                    appState.searchWorkspaceText(query: value)
                }
                .onSubmit { openSelectedResult() }

            HStack(spacing: 8) {
                if appState.isSearchingText {
                    ProgressView().controlSize(.small)
                    Text(appState.textSearchResultsAreStale ? "正在更新，暂保留上次结果…" : "正在搜索…")
                } else if !query.isEmpty {
                    Text("\(appState.textSearchResults.count) 个结果")
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(height: 18)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(appState.textSearchResults.enumerated()), id: \.element.id) { index, result in
                            Button {
                                selection.index = index
                                openSelectedResult()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        FileTypeIcon(path: result.fileURL.path)
                                        Text(result.fileURL.lastPathComponent)
                                            .fontWeight(index == selection.index ? .semibold : .regular)
                                        Text(":\(result.line)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                    }
                                    Text(result.lineText.isEmpty ? " " : result.lineText)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(relativePath(for: result.fileURL))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .background(
                                index == selection.index ? Color.accentColor.opacity(0.16) : .clear,
                                in: .rect(cornerRadius: 5)
                            )
                            .accessibilityAddTraits(index == selection.index ? .isSelected : [])
                            .id(result.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: selection.index) {
                    guard !appState.textSearchResultsAreStale, appState.textSearchResults.indices.contains(selection.index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(appState.textSearchResults[selection.index].id, anchor: .center)
                    }
                }
            }
            .disabled(appState.textSearchResultsAreStale)
            .overlay {
                if !appState.isSearchingText, !query.isEmpty, appState.textSearchResults.isEmpty {
                    ContentUnavailableView("没有匹配的内容", systemImage: "text.magnifyingglass")
                }
            }
        }
        .padding(16)
        .frame(width: 700, height: 520)
        .onAppear {
            appState.searchWorkspaceText(query: "")
            isQueryFocused = true
        }
        .onDisappear { appState.cancelSearches() }
        .onChange(of: appState.textSearchResults) {
            selection.clamp(toCount: appState.textSearchResults.count)
        }
        .searchResultArrowKeys(
            isEnabled: isQueryFocused,
            count: appState.textSearchResults.count,
            selection: $selection
        )
    }

    private func openSelectedResult() {
        guard appState.textSearchResults.indices.contains(selection.index) else { return }
        let result = appState.textSearchResults[selection.index]
        appState.selectFile(result.fileURL, line: result.line)
        appState.selectSection(.files)
        dismiss()
    }

    private func relativePath(for url: URL) -> String {
        guard let rootPath = appState.visibleWorkspaceRootURL?.standardizedFileURL.path else { return url.path }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }

    private var searchScopeLabel: String {
        appState.isWorkspaceContext ? "工作区" : (appState.selectedRepository?.name ?? "Repository")
    }
}
