import AppKit
import SwiftUI

private struct MergeConflictResizableSheet: NSViewRepresentable {
    let minimumSize: NSSize
    var title: String? = nil

    func makeNSView(context: Context) -> MergeConflictSheetWindowView {
        MergeConflictSheetWindowView(minimumSize: minimumSize, title: title)
    }

    func updateNSView(_ nsView: MergeConflictSheetWindowView, context: Context) {
        nsView.title = title
        nsView.configureSheetWindow()
    }
}

private final class MergeConflictSheetWindowView: NSView {
    private let minimumSize: NSSize
    var title: String?

    init(minimumSize: NSSize, title: String?) {
        self.minimumSize = minimumSize
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureSheetWindow()
    }

    func configureSheetWindow() {
        // Wait until SwiftUI has attached and configured the sheet. Never change its parent window.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.sheetParent != nil else { return }
            if let title = self.title { window.title = title; window.titleVisibility = .visible }
            if !window.styleMask.contains(.resizable) {
                window.styleMask.insert(.resizable)
            }
            if window.contentMinSize != self.minimumSize {
                window.contentMinSize = self.minimumSize
            }
        }
    }
}

@MainActor
struct MergeConflictResolverSheet: View {
    @Bindable var appState: AppState
    @State private var selectedPaths = Set<String>()
    @State private var mergeQueue: [String] = []
    @State private var groupsFilesByDirectory = false
    @State private var editorSelection: MergeConflictEditorSelection?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Conflicts")
                    .font(.headline)
                Text(mergeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let message = selectedFile?.unsupportedReason ?? appState.branchOperationErrorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                    if appState.conflictFiles.isEmpty {
                        Button("Retry Merge") { Task { await appState.continueMerge() } }
                            .disabled(appState.isResolvingMergeConflict)
                    }
                }
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
                    .disabled(selectedFiles.isEmpty || selectedFiles.contains { $0.unsupportedReason != nil } || appState.isResolvingMergeConflict)

                    Button("Accept Theirs") {
                        resolveSelected(with: .theirs)
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(selectedFiles.isEmpty || selectedFiles.contains { $0.unsupportedReason != nil } || appState.isResolvingMergeConflict)

                    Button("Merge...", systemImage: "arrow.triangle.merge") {
                        presentEditor()
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFiles.isEmpty || selectedFiles.contains { $0.isBinary || $0.unsupportedReason != nil } || appState.isResolvingMergeConflict)
                    .accessibilityIdentifier("RepoDesk.MergeConflicts.Merge")

                    Spacer()
                }
                .buttonStyle(MergeDialogButtonStyle())
                .frame(width: 132)
            }
            .padding(16)

            Divider()
            HStack {
                Toggle("Group files by directory", isOn: $groupsFilesByDirectory)
                    .toggleStyle(.checkbox)
                    .disabled(appState.conflictFiles.isEmpty)
                Spacer()
                if appState.isResolvingMergeConflict {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Close") {
                        Task { await appState.closeMergeConflictResolution() }
                    }
                    .disabled(appState.isResolvingMergeConflict)
                    .help("Abort this merge and close")
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MergeDialogButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
        }
        .frame(
            minWidth: 780, idealWidth: 780, maxWidth: .infinity,
            minHeight: 520, idealHeight: 520, maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MergeConflictResizableSheet(minimumSize: NSSize(width: 780, height: 520)))
        .interactiveDismissDisabled(true)
        .onAppear { selectFirstFileIfNeeded() }
        .onChange(of: visibleFilePaths) { _, _ in
            selectFirstFileIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await appState.reloadMergeSession() }
        }
        .sheet(item: $editorSelection, onDismiss: showNextQueuedFile) { selection in
            MergeConflictEditorSheet(
                file: selection.file,
                yoursBranch: targetBranchName,
                theirsBranch: appState.mergeSourceBranch ?? "Incoming Branch",
                fontSize: appState.fileContentFontSize,
                apply: { document in
                    await appState.resolveConflict(path: selection.file.path, result: document.result, document: document)
                },
                saveProgress: { document in
                    await appState.saveConflictProgress(path: selection.file.path, result: document.result, document: document)
                },
                loadBlame: { result in
                    try await appState.blameForMergeConflict(
                        file: selection.file,
                        resultContent: result
                    )
                },
                operationError: { appState.branchOperationErrorMessage },
                acceptFile: { side in await appState.acceptConflictFile(path: selection.file.path, side: side) }
            )
        }
    }

    private var conflictFileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Type").frame(width: 65, alignment: .leading)
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
                ContentUnavailableView("No conflict files", systemImage: "checkmark.circle",
                                       description: Text("The merge operation has no files to review."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedPaths) {
                    if groupsFilesByDirectory {
                        ForEach(conflictFileGroups) { group in
                            Section(group.directory) {
                                ForEach(group.files) { file in conflictFileRow(file, showsDirectory: false) }
                            }
                        }
                    } else {
                        ForEach(sortedConflictFiles) { file in conflictFileRow(file, showsDirectory: true) }
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
        showsDirectory: Bool
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
            Text(file.isBinary ? "Binary" : "Text").frame(width: 65, alignment: .leading)
            Text(file.hasOurs ? (file.hasBase ? "Modified" : "Added") : "Deleted")
                .frame(width: 92, alignment: .leading)
            Text(file.hasTheirs ? (file.hasBase ? "Modified" : "Added") : "Deleted")
                .frame(width: 92, alignment: .leading)
        }
        .font(.callout)
        .contentShape(.rect)
        .tag(file.path)
        .onTapGesture(count: 2) {
            if !selectedPaths.contains(file.path) { selectedPaths = [file.path] }
            presentEditor()
        }
        .help(file.unsupportedReason ?? (file.isBinary ? "Binary file — use Accept Yours / Theirs" : file.path))
        .accessibilityIdentifier("RepoDesk.MergeConflicts.Row.\(file.path)")
    }

    private var sortedConflictFiles: [GitConflictFile] {
        appState.conflictFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var visibleFilePaths: [String] { sortedConflictFiles.map(\.path) }
    private var selectedFiles: [GitConflictFile] { sortedConflictFiles.filter { selectedPaths.contains($0.path) } }
    private var selectedFile: GitConflictFile? { selectedFiles.first }

    private var conflictFileGroups: [MergeConflictFileGroup] {
        Dictionary(grouping: sortedConflictFiles) { directoryName($0.path) ?? "." }
            .map { MergeConflictFileGroup(directory: $0.key, files: $0.value) }
            .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
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
        selectedPaths.formIntersection(visibleFilePaths)
        if selectedPaths.isEmpty, let first = sortedConflictFiles.first { selectedPaths = [first.path] }
    }

    private func resolveSelected(with side: GitConflictSide) {
        let paths = selectedFiles.map(\.path)
        Task {
            for path in paths {
                guard await appState.acceptConflictFile(path: path, side: side) else { break }
            }
        }
    }

    private func presentEditor() {
        let files = selectedFiles
        guard !files.isEmpty, files.allSatisfy({ !$0.isBinary && $0.unsupportedReason == nil }) else { return }
        mergeQueue = files.map(\.path)
        showNextQueuedFile()
    }

    private func showNextQueuedFile() {
        while !mergeQueue.isEmpty {
            let path = mergeQueue.removeFirst()
            if let file = appState.conflictFiles.first(where: { $0.path == path }) {
                editorSelection = MergeConflictEditorSelection(file: file)
                return
            }
        }
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
    let apply: (GitThreeWayMergeDocument) async -> Bool
    let saveProgress: (GitThreeWayMergeDocument) async -> Bool
    let loadBlame: (String) async throws -> GitMergeConflictBlame
    let operationError: () -> String?
    let acceptFile: ((GitConflictSide) async -> Bool)?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mergeAutomaticallyApplyNonConflicting") private var automaticallyApply = false
    @State private var editor: GitMergeEditorState
    @State private var initialDocument: GitThreeWayMergeDocument
    @State private var selectedID: Int?
    @State private var viewSettings = GitMergeViewSettings()
    @State private var collapsed = false
    @State private var syncScroll = true
    @State private var isApplying = false
    @State private var confirmsApply = false
    @State private var confirmsCancel = false
    @State private var pendingWholeSide: GitConflictSide?
    @State private var confirmsWholeSide = false
    @State private var pendingWhitespace: GitMergeWhitespacePolicy?
    @State private var confirmsRestart = false
    @State private var errorMessage: String?
    @State private var comparison: MergeContentsComparison?
    @State private var showsBlame = false
    @State private var isLoadingBlame = false
    @State private var blame = GitMergeConflictBlame()

    init(file: GitConflictFile, yoursBranch: String, theirsBranch: String, fontSize: CGFloat,
         apply: @escaping (GitThreeWayMergeDocument) async -> Bool,
         saveProgress: @escaping (GitThreeWayMergeDocument) async -> Bool = { _ in false },
         loadBlame: @escaping (String) async throws -> GitMergeConflictBlame = { _ in GitMergeConflictBlame() },
         operationError: @escaping () -> String? = { nil },
         acceptFile: ((GitConflictSide) async -> Bool)? = nil) {
        self.file = file; self.yoursBranch = yoursBranch; self.theirsBranch = theirsBranch
        self.fontSize = fontSize; self.apply = apply; self.saveProgress = saveProgress
        self.loadBlame = loadBlame; self.operationError = operationError; self.acceptFile = acceptFile
        let auto = UserDefaults.standard.object(forKey: "mergeAutomaticallyApplyNonConflicting") as? Bool ?? false
        var document = file.mergeDocument ?? GitThreeWayMergeDocument(base: file.base ?? "", ours: file.ours, theirs: file.theirs, automaticallyApply: auto)
        if file.mergeDocument == nil, GitConflictParser.blocks(in: file.result).isEmpty,
           file.isResolved || file.expectedWorktreeData != nil {
            document.editResult(file.result)
            if file.isResolved { for change in document.changes { document.markResolved(change.id) } }
        }
        _editor = State(initialValue: GitMergeEditorState(document: document))
        _initialDocument = State(initialValue: document)
        _selectedID = State(initialValue: document.unresolvedIDs.first ?? document.changes.first?.id)
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.10))
            }
            headers
            if viewSettings.breadcrumbs == "Top" { breadcrumbs }
            GitMergeTextPanes(state: editor, selectedID: selectedID, fontSize: fontSize,
                              collapsed: collapsed, syncScroll: syncScroll, onSelect: { selectedID = $0 },
                              onExpand: { collapsed = false }, settings: viewSettings,
                              fileExtension: (file.path as NSString).pathExtension,
                              onNavigate: navigate, onCompareClipboard: compareClipboard, onAnnotate: annotate)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityIdentifier("RepoDesk.MergeConflictEditor.SynchronizedScroll")
            if viewSettings.breadcrumbs == "Bottom" { breadcrumbs }
            Divider()
            footer
        }
        .disabled(isApplying)
        .frame(minWidth: 1100, idealWidth: 1240, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .background(MergeConflictResizableSheet(minimumSize: NSSize(width: 1100, height: 600), title: "Merge \(file.path)"))
        .interactiveDismissDisabled(true)
        .alert("Apply Changes", isPresented: $confirmsApply) {
            Button("Continue Merge", role: .cancel) { }
            Button("Apply Changes and Mark Resolved") { submit() }
        } message: { Text("There are \(editor.document.unresolvedChangeCount) changes and \(editor.document.unresolvedConflictCount) conflicts left unprocessed. Apply the current result and mark the file resolved?") }
        .alert("Cancel Merge", isPresented: $confirmsCancel) {
            Button("Continue Merge", role: .cancel) { }
            Button("Discard Changes and Cancel Merge", role: .destructive) { dismiss() }
        } message: { Text("There are unsaved changes in the result file. Discard changes and cancel merge anyway?") }
        .alert("Discard Changes?", isPresented: $confirmsWholeSide) {
            Button("Continue Merge", role: .cancel) { pendingWholeSide = nil }
            Button("Discard Changes and Accept") { if let side = pendingWholeSide { submit(side: side) } }
        } message: { Text("The current merge result will be replaced with the selected file version.") }
        .alert("Update Highlighting Settings", isPresented: $confirmsRestart) {
            Button("Continue Merge", role: .cancel) { pendingWhitespace = nil }
            Button("Discard Changes and Restart Merge") { if let policy = pendingWhitespace { restart(policy) } }
        } message: { Text("Changing whitespace comparison requires restarting the file merge.") }
        .sheet(item: $comparison) { value in
            VStack(spacing: 0) {
                HStack { Text(value.title).font(.headline); Spacer(); Button("Close") { comparison = nil }.buttonStyle(MergeDialogButtonStyle()) }.padding(12)
                Divider()
                HStack(spacing: 1) {
                    VStack(spacing: 0) {
                        Text(value.leftTitle).font(.system(size: 12)).padding(6)
                        NativeCodeEditor(text: .constant(value.left), isEditable: false, style: .source(fileExtension: (file.path as NSString).pathExtension), showsLineNumbers: true, fontSize: fontSize)
                    }
                    Divider()
                    VStack(spacing: 0) {
                        Text(value.rightTitle).font(.system(size: 12)).padding(6)
                        NativeCodeEditor(text: .constant(value.right), isEditable: false, style: .source(fileExtension: (file.path as NSString).pathExtension), showsLineNumbers: true, fontSize: fontSize)
                    }
                }
            }.frame(minWidth: 900, minHeight: 550)
        }
        .sheet(isPresented: $showsBlame) { blameView }
    }
    private var toolbar: some View {
        HStack(spacing: 4) {
            iconButton("Previous Difference (⇧F7)", symbol: "arrow.up", disabled: adjacent(-1) == nil) { navigate(-1) }
            iconButton("Next Difference (F7)", symbol: "arrow.down", disabled: adjacent(1) == nil) { navigate(1) }
            toolbarSeparator
            Menu { compareMenu } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 20) }
                .menuIndicator(.hidden).help("Compare Contents")
            toolbarSeparator
            Text("Apply non-conflicting changes:").font(.system(size: 11)).padding(.horizontal, 3)
            textIcon("»", help: "Apply Non-Conflicting Changes from the Left Side", disabled: !editor.document.canApplyNonConflicting(side: .ours)) { mutate { $0.applyNonConflicting(side: .ours) } }
            textIcon("»«", help: "Apply All Non-Conflicting Changes", disabled: !editor.document.canApplyNonConflicting()) { mutate { $0.applyNonConflicting() } }
            textIcon("«", help: "Apply Non-Conflicting Changes from the Right Side", disabled: !editor.document.canApplyNonConflicting(side: .theirs)) { mutate { $0.applyNonConflicting(side: .theirs) } }
            iconButton("Resolve Simple Conflicts", symbol: "wand.and.stars", disabled: !canResolveSimple) { mutate { $0.resolveSimpleConflicts() } }
            toolbarSeparator
            Menu {
                ForEach(GitMergeWhitespacePolicy.allCases, id: \.self) { policy in
                    Button { setWhitespace(policy) } label: { if editor.document.whitespacePolicy == policy { Label(policy.rawValue, systemImage: "checkmark") } else { Text(policy.rawValue) } }
                }
            } label: { Text(editor.document.whitespacePolicy.rawValue).font(.system(size: 11)) }
                .fixedSize().help("Ignore Differences")
            Menu {
                ForEach(GitMergeHighlight.allCases, id: \.self) { highlight in
                    Button { viewSettings.highlight = highlight } label: { if viewSettings.highlight == highlight { Label(highlight.rawValue, systemImage: "checkmark") } else { Text(highlight.rawValue) } }
                }
            } label: { Text(viewSettings.highlight.rawValue).font(.system(size: 11)) }.fixedSize().help("Highlighting Differences")
            iconButton("Collapse Unchanged Fragments", symbol: "chevron.up.chevron.down", selected: collapsed) { collapsed.toggle() }
            iconButton("Synchronize Scrolling", symbol: "arrow.up.and.down", selected: syncScroll) { syncScroll.toggle() }
            Menu { settingsMenu } label: { Image(systemName: "gearshape").frame(width: 20) }
                .menuIndicator(.hidden).help("Settings")
            Spacer(minLength: 4)
            if editor.document.unresolvedIDs.isEmpty {
                Label("All conflicts resolved", systemImage: "checkmark").foregroundStyle(.green).font(.system(size: 11))
            } else {
                Text("\(editor.document.unresolvedChangeCount) changes. \(editor.document.unresolvedConflictCount) conflicts.").font(.system(size: 11))
            }
        }
        .controlSize(.small).menuStyle(.borderlessButton)
        .padding(.horizontal, 8).frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("RepoDesk.MergeConflictEditor.Toolbar")
    }
    private var toolbarSeparator: some View { Divider().frame(height: 18).padding(.horizontal, 2) }
    private func iconButton(_ title: String, symbol: String, disabled: Bool = false, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 23, height: 24) }
            .buttonStyle(.plain).foregroundStyle(disabled ? Color.secondary.opacity(0.35) : .secondary)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .disabled(disabled).help(title).accessibilityLabel(title)
    }
    private func textIcon(_ icon: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(icon, action: action).font(.system(size: 19, weight: .ultraLight)).buttonStyle(.plain)
            .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : .secondary)
            .frame(width: icon.count > 1 ? 24 : 19, height: 24).disabled(disabled).help(help).accessibilityLabel(help)
    }
    private var headers: some View {
        GeometryReader { geometry in
            let width = max(0, (geometry.size.width - 64) / 3)
            HStack(spacing: 0) {
                Label("Your version (\(yoursBranch))", systemImage: "lock").frame(width: width, alignment: .leading)
                Color.clear.frame(width: 32)
                Text("Result").frame(width: width, alignment: .leading)
                Color.clear.frame(width: 32)
                Label("Changes from server (\(theirsBranch))", systemImage: "lock").frame(width: width, alignment: .leading)
            }.font(.system(size: 12)).lineLimit(1).padding(.leading, 4)
        }.frame(height: 20).background(Color(nsColor: .controlBackgroundColor))
    }
    private var breadcrumbs: some View {
        Text(file.path.replacingOccurrences(of: "/", with: " › ")).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 22)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Button("Accept Left") { acceptWhole(.ours) }.buttonStyle(MergeDialogButtonStyle())
            Button("Accept Right") { acceptWhole(.theirs) }.buttonStyle(MergeDialogButtonStyle())
            Spacer()
            if isApplying { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel) { cancel() }.buttonStyle(MergeDialogButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Apply") { if editor.document.unresolvedIDs.isEmpty { submit() } else { confirmsApply = true } }
                .buttonStyle(MergeDialogButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("RepoDesk.MergeConflictEditor.Apply")
        }.padding(.horizontal, 16).frame(height: 50).background(Color(nsColor: .controlBackgroundColor))
    }
    private var settingsMenu: some View {
        Group {
            Toggle("Show Whitespaces", isOn: $viewSettings.showWhitespaces)
            Toggle("Show Line Numbers", isOn: $viewSettings.showLineNumbers)
            Toggle("Show Indent Guides", isOn: $viewSettings.showIndentGuides)
            Toggle("Soft-Wrap", isOn: $viewSettings.softWrap)
            Menu("Highlighting Level") {
                Button("None") { viewSettings.syntaxHighlighting = false }
                Button("Syntax") { viewSettings.syntaxHighlighting = true }
            }
            Menu("Breadcrumbs") { ForEach(["Don't show", "Top", "Bottom"], id: \.self) { value in Button(value) { viewSettings.breadcrumbs = value } } }
            Button("Resolve Conflicts in Import Statements") {}.disabled(true)
            Divider()
            Button("Help") { if let url = URL(string: "https://www.jetbrains.com/help/idea/2025.2/resolve-conflicts.html") { NSWorkspace.shared.open(url) } }
        }
    }
    private var compareMenu: some View {
        Group {
            Button("Left and Middle") { compare("Left", editor.document.ours, "Middle", editor.document.result) }
            Button("Right and Middle") { compare("Right", editor.document.theirs, "Middle", editor.document.result) }
            Button("Left and Right") { compare("Left", editor.document.ours, "Right", editor.document.theirs) }
            Divider()
            Button("Base and Left") { compare("Base", editor.document.base, "Left", editor.document.ours) }
            Button("Base and Middle") { compare("Base", editor.document.base, "Middle", editor.document.result) }
            Button("Base and Right") { compare("Base", editor.document.base, "Right", editor.document.theirs) }
        }
    }
    private var canResolveSimple: Bool { editor.document.canApplyNonConflicting() || editor.document.changes.contains { editor.document.simpleResolution(for: $0) != nil } }
    private func mutate(_ operation: (inout GitThreeWayMergeDocument) -> Void) { editor.commitPendingText?(); editor.change(operation) }
    private func adjacent(_ direction: Int) -> Int? {
        let ids = editor.document.unresolvedIDs
        guard let selectedID else { return direction > 0 ? ids.first : ids.last }
        return direction > 0 ? ids.first(where: { $0 > selectedID }) : ids.last(where: { $0 < selectedID })
    }
    private func navigate(_ direction: Int) { if let id = adjacent(direction) { selectedID = id } }
    private func cancel() {
        editor.commitPendingText?()
        if editor.document != initialDocument { confirmsCancel = true } else { dismiss() }
    }
    private func acceptWhole(_ side: GitConflictSide) {
        editor.commitPendingText?()
        if editor.document != initialDocument { pendingWholeSide = side; confirmsWholeSide = true }
        else { submit(side: side) }
    }
    private func submit(side: GitConflictSide? = nil) {
        guard !isApplying else { return }
        editor.commitPendingText?(); isApplying = true; errorMessage = nil
        Task {
            var document = editor.document
            if let side { document.editResult(side == .ours ? document.ours : document.theirs) }
            for change in document.changes { document.markResolved(change.id) }
            let success: Bool
            if let side, let acceptFile { success = await acceptFile(side) } else { success = await apply(document) }
            isApplying = false
            if success { dismiss() } else { errorMessage = operationError() ?? "Cannot apply the merge result. Refresh the file and try again." }
        }
    }
    private func setWhitespace(_ policy: GitMergeWhitespacePolicy) {
        guard policy != editor.document.whitespacePolicy else { return }
        if editor.document != initialDocument { pendingWhitespace = policy; confirmsRestart = true } else { restart(policy) }
    }
    private func restart(_ policy: GitMergeWhitespacePolicy) {
        let document = GitThreeWayMergeDocument(base: editor.document.base, ours: editor.document.ours, theirs: editor.document.theirs, automaticallyApply: automaticallyApply, whitespacePolicy: policy)
        editor.change { $0 = document }; initialDocument = document; selectedID = document.unresolvedIDs.first
    }
    private func compare(_ leftTitle: String, _ left: String, _ rightTitle: String, _ right: String) {
        editor.commitPendingText?()
        comparison = MergeContentsComparison(title: "\(leftTitle) / \(rightTitle) — \(file.path)", leftTitle: leftTitle, rightTitle: rightTitle, left: left, right: right)
    }
    private func compareClipboard(_ text: String) { compare("Selected Version", text, "Clipboard", NSPasteboard.general.string(forType: .string) ?? "") }
    private func annotate() {
        guard !isLoadingBlame else { return }; isLoadingBlame = true
        Task { do { blame = try await loadBlame(editor.document.result); showsBlame = true } catch { errorMessage = error.localizedDescription }; isLoadingBlame = false }
    }
    private func annotations(_ lines: [Int: GitBlameLine]) -> [Int: NativeGitBlameAnnotation] {
        lines.mapValues { NativeGitBlameAnnotation(commitHash: $0.commitHash, author: $0.author, authoredAt: $0.authoredAt, isUncommitted: $0.isUncommitted, authorEmail: $0.authorEmail, message: $0.message) }
    }
    private var blameView: some View {
        VStack(spacing: 0) {
            HStack { Text("Annotate — \(file.path)").font(.headline); Spacer(); Button("Close") { showsBlame = false } }.padding()
            HStack(spacing: 1) {
                NativeCodeEditor(text: .constant(file.ours), isEditable: false, showsLineNumbers: true, gitBlame: annotations(blame.yours), fontSize: fontSize)
                NativeCodeEditor(text: .constant(editor.document.result), isEditable: false, showsLineNumbers: true, gitBlame: annotations(blame.result), fontSize: fontSize)
                NativeCodeEditor(text: .constant(file.theirs), isEditable: false, showsLineNumbers: true, gitBlame: annotations(blame.theirs), fontSize: fontSize)
            }
        }.frame(minWidth: 1100, minHeight: 600)
    }
}

private struct MergeContentsComparison: Identifiable {
    let id = UUID()
    let title: String
    let leftTitle: String
    let rightTitle: String
    let left: String
    let right: String
}

struct MergeDialogButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).padding(.horizontal, 14).frame(height: 28)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color(red: 0.21, green: 0.45, blue: 0.94) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(prominent ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
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
