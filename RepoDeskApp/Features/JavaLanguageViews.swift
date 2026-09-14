import AppKit
import SwiftUI

enum JavaNavigationPopupLayout {
    static let horizontalMargin: CGFloat = 10
    static let anchorGap: CGFloat = 12
    static let defaultAnchor = CGPoint(x: 18, y: 18)

    static func origin(
        anchor: JavaNavigationPopupAnchor?,
        popupSize: CGSize,
        availableSize: CGSize
    ) -> CGPoint {
        let anchor = anchor.map { CGPoint(x: $0.x, y: $0.y) } ?? defaultAnchor
        let rightOrigin = anchor.x + anchorGap
        let leftOrigin = anchor.x - anchorGap - popupSize.width
        let maximumOrigin = max(
            horizontalMargin,
            availableSize.width - popupSize.width - horizontalMargin
        )
        let x: CGFloat
        if rightOrigin + popupSize.width <= availableSize.width - horizontalMargin {
            x = rightOrigin
        } else if leftOrigin >= horizontalMargin {
            x = leftOrigin
        } else {
            x = min(max(rightOrigin, horizontalMargin), maximumOrigin)
        }
        let preferredY = anchor.y + 18
        let y = preferredY + popupSize.height <= availableSize.height - horizontalMargin
            ? preferredY
            : max(horizontalMargin, anchor.y - popupSize.height - anchorGap)
        return CGPoint(x: x, y: y)
    }

    static func fileColumnWidth(fileNames: [String], popupWidth: CGFloat) -> CGFloat {
        let minimumSourceWidth: CGFloat = 180
        let rowChromeWidth: CGFloat = 22 + 16 + 27 + 42 + 6
        let maximumWidth = max(190, popupWidth - minimumSourceWidth - rowChromeWidth)
        return min(max(190, requiredFileColumnWidth(fileNames: fileNames)), maximumWidth)
    }

    static func requiredFileColumnWidth(fileNames: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        return ceil(fileNames.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0) + 8
    }

    static func matchesFileName(_ fileName: String, query: String) -> Bool {
        let query = query
            .lowercased()
            .filter { !$0.isWhitespace }
        guard !query.isEmpty else { return true }

        let candidates = [
            fileName.lowercased(),
            (fileName as NSString).deletingPathExtension.lowercased()
        ]
        return candidates.contains { candidate in
            var candidateIndex = candidate.startIndex
            for character in query {
                guard let match = candidate[candidateIndex...].firstIndex(of: character) else {
                    return false
                }
                candidateIndex = candidate.index(after: match)
            }
            return true
        }
    }
}

@MainActor
struct JavaIndexStatusView: View {
    @Bindable var appState: AppState
    @State private var showsDetails = false

    var body: some View {
        Group {
            if appState.javaIndexSnapshot.javaRepositoryCount > 0 {
                Button {
                    showsDetails.toggle()
                } label: {
                    HStack(spacing: 7) {
                        statusIcon
                        Text(statusText)
                            .font(.caption)
                            .lineLimit(1)
                        if let progress = aggregateProgress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 70)
                        }
                    }
                    .frame(width: 310, alignment: .center)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("查看 Java 索引状态")
                .accessibilityIdentifier("RepoDesk.JavaIndexStatus")
                .accessibilityLabel(statusText)
                .accessibilityValue(statusText)
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    detailsPopover
                }
            } else {
                Color.clear.frame(width: 310, height: 20)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if appState.javaIndexSnapshot.failedRepositoryCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if appState.javaIndexSnapshot.isBackgroundIndexingPaused {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
        } else if appState.javaIndexSnapshot.indexingRepository != nil {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var statusText: String {
        let snapshot = appState.javaIndexSnapshot
        if snapshot.isBackgroundIndexingPaused {
            return "Java 索引已暂停 · \(snapshot.readyRepositoryCount)/\(snapshot.javaRepositoryCount)"
        }
        if let indexing = snapshot.indexingRepository {
            return "正在索引 \(indexing.displayName) · \(snapshot.readyRepositoryCount)/\(snapshot.javaRepositoryCount)"
        }
        if snapshot.failedRepositoryCount > 0 {
            return "Java 索引 \(snapshot.readyRepositoryCount)/\(snapshot.javaRepositoryCount) · \(snapshot.failedRepositoryCount) 失败"
        }
        return "Java 索引已就绪 · \(snapshot.readyRepositoryCount)/\(snapshot.javaRepositoryCount)"
    }

    private var aggregateProgress: Double? {
        let snapshot = appState.javaIndexSnapshot
        guard snapshot.javaRepositoryCount > 0,
              snapshot.readyRepositoryCount < snapshot.javaRepositoryCount else { return nil }
        let completed = Double(snapshot.readyRepositoryCount)
        let current = snapshot.indexingRepository?.progress ?? 0
        return min(1, (completed + current) / Double(snapshot.javaRepositoryCount))
    }

    private var detailsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Java 索引")
                        .font(.headline)
                    Text("\(appState.javaIndexSnapshot.runningJVMCount) JVM · \(cacheText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    appState.javaIndexSnapshot.isBackgroundIndexingPaused ? "继续" : "暂停",
                    systemImage: appState.javaIndexSnapshot.isBackgroundIndexingPaused
                        ? "play.fill"
                        : "pause.fill"
                ) {
                    appState.setJavaBackgroundIndexingPaused(
                        !appState.javaIndexSnapshot.isBackgroundIndexingPaused
                    )
                }
                .labelStyle(.iconOnly)
                .help(appState.javaIndexSnapshot.isBackgroundIndexingPaused ? "继续后台索引" : "暂停后台索引")
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.javaIndexSnapshot.repositories.filter { $0.phase != .notRequired }) { state in
                        repositoryRow(state)
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .frame(maxHeight: 340)

            Divider()
            HStack {
                Button("清理未使用缓存", systemImage: "trash") {
                    appState.clearUnusedJavaCaches()
                }
                Spacer()
                SettingsLink {
                    Label("Java 设置", systemImage: "gearshape")
                }
            }
            .padding(10)
        }
        .frame(width: 440)
    }

    private func repositoryRow(_ state: JavaRepositoryIndexState) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon(for: state.phase))
                .foregroundStyle(color(for: state.phase))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.displayName)
                    .lineLimit(1)
                Text(state.detail ?? phaseText(state.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let progress = state.progress, state.phase == .indexing {
                ProgressView(value: progress)
                    .frame(width: 68)
            }
            Text(ByteCountFormatter.string(fromByteCount: state.cacheBytes, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button("重建索引", systemImage: "arrow.clockwise") {
                appState.rebuildJavaIndex(repositoryID: state.repositoryID)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("重建 \(state.displayName) 的 Java 索引")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private var cacheText: String {
        let used = ByteCountFormatter.string(
            fromByteCount: appState.javaIndexSnapshot.cacheBytes,
            countStyle: .file
        )
        return "缓存 \(used)/\(appState.javaIndexSettings.cacheLimitGigabytes) GB"
    }

    private func phaseText(_ phase: JavaRepositoryIndexPhase) -> String {
        switch phase {
        case .notRequired: "非 Java 项目"
        case .queued: "等待索引"
        case .starting: "正在启动"
        case .indexing: "正在索引"
        case .ready: "已就绪"
        case .stale: "等待刷新"
        case .paused: "已暂停"
        case .failed: "索引失败"
        }
    }

    private func icon(for phase: JavaRepositoryIndexPhase) -> String {
        switch phase {
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        case .indexing, .starting: "arrow.triangle.2.circlepath"
        case .queued, .stale: "clock"
        case .notRequired: "minus.circle"
        }
    }

    private func color(for phase: JavaRepositoryIndexPhase) -> Color {
        switch phase {
        case .ready: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

@MainActor
struct JavaNavigationResultsPopup: View {
    static let preferredSize = CGSize(width: 760, height: 250)

    let presentation: JavaNavigationResultPresentation
    let size: CGSize
    let selectTarget: (JavaNavigationTarget) -> Void
    let dismiss: () -> Void
    @State private var selectedTargetID: String?
    @State private var searchQuery = ""
    @FocusState private var isFocused: Bool

    private var filteredTargets: [JavaNavigationTarget] {
        presentation.targets.filter {
            JavaNavigationPopupLayout.matchesFileName(
                $0.fileURL.lastPathComponent,
                query: searchQuery
            )
        }
    }

    private var fileColumnWidth: CGFloat {
        JavaNavigationPopupLayout.fileColumnWidth(
            fileNames: presentation.targets.map(\.fileURL.lastPathComponent),
            popupWidth: size.width
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if filteredTargets.isEmpty {
                        ContentUnavailableView(
                            "没有匹配结果",
                            systemImage: "magnifyingglass"
                        )
                        .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredTargets) { target in
                                Button {
                                    selectedTargetID = target.id
                                    open(target)
                                } label: {
                                    JavaUsageTargetRow(
                                        target: target,
                                        isSelected: selectedTargetID == target.id,
                                        fileColumnWidth: fileColumnWidth
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(targetAccessibilityIdentifier(target))
                                .id(target.id)
                            }
                        }
                    }
                }
                .onChange(of: selectedTargetID) {
                    guard let selectedTargetID else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(selectedTargetID, anchor: .center)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 7)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            searchQuery = ""
            selectedTargetID = filteredTargets.first?.id
            isFocused = true
        }
        .onChange(of: presentation.id) {
            searchQuery = ""
            selectedTargetID = filteredTargets.first?.id
            isFocused = true
        }
        .onChange(of: searchQuery) {
            selectedTargetID = filteredTargets.first?.id
        }
        .onKeyPress(.upArrow, phases: .down) { _ in
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            guard let selectedTarget else { return .ignored }
            open(selectedTarget)
            return .handled
        }
        .onExitCommand(perform: dismiss)
        .accessibilityIdentifier("RepoDesk.JavaNavigationResults")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(presentation.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text("\(filteredTargets.count) usages")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("关闭", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("关闭跳转结果")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文件名或类名", text: $searchQuery)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("RepoDesk.JavaNavigationResults.Search")
            if !searchQuery.isEmpty {
                Button("清除搜索", systemImage: "xmark.circle.fill") {
                    searchQuery = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var selectedTarget: JavaNavigationTarget? {
        guard let selectedTargetID else { return filteredTargets.first }
        return filteredTargets.first { $0.id == selectedTargetID }
            ?? filteredTargets.first
    }

    private func moveSelection(by offset: Int) {
        guard !filteredTargets.isEmpty else { return }
        let currentIndex = filteredTargets.firstIndex { $0.id == selectedTargetID } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), filteredTargets.count - 1)
        selectedTargetID = filteredTargets[nextIndex].id
    }

    private func open(_ target: JavaNavigationTarget) {
        selectTarget(target)
        dismiss()
    }
}

@MainActor
struct JavaSymbolSearchSheet: View {
    @Bindable var appState: AppState
    let initialScope: JavaSymbolSearchScope
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope: JavaSymbolSearchScope
    @FocusState private var queryFocused: Bool

    init(appState: AppState, initialScope: JavaSymbolSearchScope) {
        self.appState = appState
        self.initialScope = initialScope
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit(openFirstResult)
                    .accessibilityIdentifier("RepoDesk.JavaSymbolSearch.Query")
                Picker("范围", selection: $scope) {
                    Text("类").tag(JavaSymbolSearchScope.types)
                    Text("方法").tag(JavaSymbolSearchScope.methods)
                    Text("全部").tag(JavaSymbolSearchScope.all)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                if appState.isSearchingJavaSymbols {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            Divider()
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("输入 Java 符号", systemImage: "curlybraces")
            } else if appState.javaSymbolSearchResults.isEmpty, !appState.isSearchingJavaSymbols {
                ContentUnavailableView("没有可用结果", systemImage: "magnifyingglass")
            } else {
                List(appState.javaSymbolSearchResults) { target in
                    Button {
                        appState.selectJavaSymbolTarget(target)
                        dismiss()
                    } label: {
                        JavaNavigationTargetRow(target: target)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(targetAccessibilityIdentifier(target))
                }
            }
        }
        .frame(minWidth: 700, minHeight: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RepoDesk.JavaSymbolSearch")
        .onAppear {
            queryFocused = true
            appState.javaSymbolSearchResults = []
        }
        .onChange(of: query) { search() }
        .onChange(of: scope) { search() }
    }

    private var searchPlaceholder: String {
        switch scope {
        case .types: "搜索 Java 类或接口"
        case .methods: "搜索 Java 方法"
        case .all: "搜索 Java 符号"
        }
    }

    private func search() {
        appState.searchJavaSymbols(query: query, scope: scope)
    }

    private func openFirstResult() {
        guard let target = appState.javaSymbolSearchResults.first else { return }
        appState.selectJavaSymbolTarget(target)
        dismiss()
    }
}

private struct JavaNavigationTargetRow: View {
    let target: JavaNavigationTarget

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(target.name)
                        .fontWeight(.medium)
                    if let detail = target.detail, !detail.isEmpty {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(locationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(target.range.start.line + 1):\(target.range.start.character + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(target.name)
    }

    private var locationText: String {
        if let containerName = target.containerName, !containerName.isEmpty {
            return "\(containerName) · \(target.fileURL.path)"
        }
        return target.fileURL.path
    }

    private var symbolImage: String {
        switch target.kind {
        case .class: "c.square"
        case .interface: "i.square"
        case .method, .constructor, .function: "function"
        case .enum: "e.square"
        default: "curlybraces"
        }
    }
}

private struct JavaUsageTargetRow: View {
    let target: JavaNavigationTarget
    let isSelected: Bool
    let fileColumnWidth: CGFloat
    @State private var sourceLine: String?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(target.fileURL.lastPathComponent)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: fileColumnWidth, alignment: .leading)
            Text("\(target.range.start.line + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
            Text(sourceLine ?? target.detail ?? target.name)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(.rect)
        .help(locationHelp)
        .task(id: target.id) {
            sourceLine = await loadSourceLine()
        }
    }

    private var locationHelp: String {
        let container = target.containerName.map { " · \($0)" } ?? ""
        return "\(target.fileURL.path):\(target.range.start.line + 1)\(container)"
    }

    private func loadSourceLine() async -> String? {
        let url = target.fileURL
        let lineNumber = target.range.start.line
        return await Task.detached(priority: .utility) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.indices.contains(lineNumber) else { return nil }
            let line = lines[lineNumber].trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }.value
    }
}

private func targetAccessibilityIdentifier(_ target: JavaNavigationTarget) -> String {
    "RepoDesk.JavaTarget.\(target.fileURL.lastPathComponent).\(target.range.start.line).\(target.range.start.character)"
}
