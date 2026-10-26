import AppKit
import SwiftUI

enum GitMergeDiffLineKind: Equatable, Sendable {
    case unchanged
    case changed
    case deleted
}

struct GitMergeDiffLine: Equatable, Sendable {
    let number: Int
    let text: String
    let kind: GitMergeDiffLineKind
}

struct GitMergeDiffRow: Equatable, Identifiable, Sendable {
    let id: Int
    let target: GitMergeDiffLine?
    let result: GitMergeDiffLine?
    let source: GitMergeDiffLine?
    let differsFromTarget: Bool
    let differsFromSource: Bool

    var isChanged: Bool {
        differsFromTarget || differsFromSource || result == nil
    }

    var isUnchangedAcrossAllVersions: Bool {
        guard !isChanged, let target, let result, let source else { return false }
        return target.text == result.text && source.text == result.text
    }
}

struct GitMergeDiffGap: Equatable, Identifiable, Sendable {
    let rowRange: Range<Int>
    var id: String { "gap:\(rowRange.lowerBound):\(rowRange.upperBound)" }
    var count: Int { rowRange.count }
    var title: String { "已隐藏 \(count) 行 · 点击展开" }
}

enum GitMergeDiffDisplayRow: Equatable, Identifiable, Sendable {
    case line(GitMergeDiffRow)
    case gap(GitMergeDiffGap)

    var id: String {
        switch self {
        case .line(let row): "line:\(row.id)"
        case .gap(let gap): gap.id
        }
    }

    var line: GitMergeDiffRow? {
        guard case .line(let row) = self else { return nil }
        return row
    }
}

struct GitMergeDiffRenderModel: Equatable, Sendable {
    let rows: [GitMergeDiffRow]
    let gaps: [GitMergeDiffGap]
    var gapIDs: Set<String> { Set(gaps.map(\.id)) }

    init(diff: GitMergeFileDiff) {
        let target = PairwiseMergeAlignment(diff: diff.target)
        let source = PairwiseMergeAlignment(diff: diff.source)
        var rows: [GitMergeDiffRow] = []

        func appendDeletedRows(before resultNumber: Int) {
            let targetLines = target.deletionsBeforeResult[resultNumber] ?? []
            let sourceLines = source.deletionsBeforeResult[resultNumber] ?? []
            for index in 0..<max(targetLines.count, sourceLines.count) {
                rows.append(
                    GitMergeDiffRow(
                        id: rows.count,
                        target: targetLines.indices.contains(index) ? targetLines[index] : nil,
                        result: nil,
                        source: sourceLines.indices.contains(index) ? sourceLines[index] : nil,
                        differsFromTarget: targetLines.indices.contains(index),
                        differsFromSource: sourceLines.indices.contains(index)
                    )
                )
            }
        }

        for resultIndex in diff.resultLines.indices {
            let resultNumber = resultIndex + 1
            appendDeletedRows(before: resultNumber)
            let differsFromTarget = target.changedResultLines.contains(resultNumber)
            let differsFromSource = source.changedResultLines.contains(resultNumber)
            rows.append(
                GitMergeDiffRow(
                    id: rows.count,
                    target: target.linesByResult[resultNumber],
                    result: GitMergeDiffLine(
                        number: resultNumber,
                        text: diff.resultLines[resultIndex],
                        kind: differsFromTarget || differsFromSource ? .changed : .unchanged
                    ),
                    source: source.linesByResult[resultNumber],
                    differsFromTarget: differsFromTarget,
                    differsFromSource: differsFromSource
                )
            )
        }
        appendDeletedRows(before: diff.resultLines.count + 1)
        self.rows = rows
        gaps = Self.makeGaps(rows: rows)
    }

    func displayRows(expandedGapIDs: Set<String> = []) -> [GitMergeDiffDisplayRow] {
        var displayed: [GitMergeDiffDisplayRow] = []
        var cursor = 0
        for gap in gaps where !expandedGapIDs.contains(gap.id) {
            displayed.append(contentsOf: rows[cursor..<gap.rowRange.lowerBound].map(GitMergeDiffDisplayRow.line))
            displayed.append(.gap(gap))
            cursor = gap.rowRange.upperBound
        }
        displayed.append(contentsOf: rows[cursor...].map(GitMergeDiffDisplayRow.line))
        return displayed
    }

    private static func makeGaps(rows: [GitMergeDiffRow]) -> [GitMergeDiffGap] {
        let contextCount = 3
        var gaps: [GitMergeDiffGap] = []
        var index = 0
        while index < rows.count {
            guard rows[index].isUnchangedAcrossAllVersions else {
                index += 1
                continue
            }
            let start = index
            while index < rows.count, rows[index].isUnchangedAcrossAllVersions { index += 1 }
            let hiddenStart = start == 0 ? start : min(index, start + contextCount)
            let hiddenEnd = index == rows.count ? index : max(start, index - contextCount)
            if hiddenStart < hiddenEnd {
                gaps.append(GitMergeDiffGap(rowRange: hiddenStart..<hiddenEnd))
            }
        }
        return gaps
    }
}

private struct GitMergeContentSearchMatch {
    let pane: GitHistoryBlameSide
    let match: ContentSearchMatch
}

@MainActor
struct GitMergeDiffView: View {
    let diff: GitMergeFileDiff
    let ignoresWhitespace: Bool
    let toggleIgnoreWhitespace: () -> Void
    let jumpToSource: (Int?) -> Void
    let blame: [GitHistoryBlameSide: [Int: GitBlameLine]]
    private let blameColorScales: [GitHistoryBlameSide: GitBlameColorScale]
    let toggleBlame: (GitHistoryBlameSide) -> (() -> Void)?
    let fontSize: CGFloat

    private let renderModel: GitMergeDiffRenderModel
    private let controlledExpandedGapIDs: Binding<Set<String>>?
    @State private var expandedGapIDs: Set<String>
    @State private var displayRows: [GitMergeDiffDisplayRow]
    @State private var selectableTextModels: [GitHistoryBlameSide: GitDiffSelectableTextModel]
    @State private var searchExpandedGapIDsSnapshot: Set<String>?
    @State private var viewportAnchorRequestID: UUID?
    @State private var selectedChangeIndex = 0
    @State private var scrollRequest: GitDiffScrollRequest?
    @State private var verticalViewport = GitDiffVerticalViewport.zero
    @State private var manualNavigationCursor: GitDiffHunkNavigationCursor?
    @State private var horizontalScrollSynchronization = GitDiffHorizontalScrollSynchronization()
    @State private var contentFindState = ContentFindState()

    private let headerHeight: CGFloat = 30
    private let rowHeight: CGFloat

    init(
        diff: GitMergeFileDiff,
        ignoresWhitespace: Bool,
        toggleIgnoreWhitespace: @escaping () -> Void,
        jumpToSource: @escaping (Int?) -> Void,
        blame: [GitHistoryBlameSide: [Int: GitBlameLine]] = [:],
        toggleBlame: @escaping (GitHistoryBlameSide) -> (() -> Void)? = { _ in nil },
        fontSize: CGFloat = NSFont.systemFontSize,
        expandedGapIDs: Binding<Set<String>>? = nil
    ) {
        self.diff = diff
        self.ignoresWhitespace = ignoresWhitespace
        self.toggleIgnoreWhitespace = toggleIgnoreWhitespace
        self.jumpToSource = jumpToSource
        self.blame = blame
        blameColorScales = blame.mapValues { annotations in
            GitBlameColorScale(dates: annotations.values.lazy
                .filter { !$0.isUncommitted }.compactMap(\.authoredAt))
        }
        self.toggleBlame = toggleBlame
        self.fontSize = fontSize
        rowHeight = max(22, ceil(fontSize + 8))
        let renderModel = GitMergeDiffRenderModel(diff: diff)
        self.renderModel = renderModel
        controlledExpandedGapIDs = expandedGapIDs
        let resolvedGapIDs = (expandedGapIDs?.wrappedValue ?? []).intersection(renderModel.gapIDs)
        _expandedGapIDs = State(initialValue: resolvedGapIDs)
        let displayRows = renderModel.displayRows(expandedGapIDs: resolvedGapIDs)
        _displayRows = State(initialValue: displayRows)
        _selectableTextModels = State(initialValue: Self.makeSelectableTextModels(
            rows: displayRows, rowHeight: rowHeight, fontSize: fontSize
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if contentFindState.isPresented {
                Divider()
                ContentFindBar(
                    state: $contentFindState,
                    matchCount: contentSearchMatches.count,
                    dismiss: dismissContentFind
                )
            }
            Divider()
            if diff.isBinary {
                ContentUnavailableView(
                    "Binary Merge Diff",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("该文件包含二进制内容，无法显示三方文本 Diff。")
                )
            } else if renderModel.rows.isEmpty {
                ContentUnavailableView(
                    "没有可显示的 Merge Diff",
                    systemImage: "checkmark.circle",
                    description: Text("忽略空白后可能没有内容变化。")
                )
            } else {
                mergePanes
                    .font(.system(size: fontSize))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(ContentFindCommandListener(
            requestFind: presentContentFind,
            navigateMatch: navigateContentFind
        ))
        .onChange(of: diff) { _, _ in
            selectedChangeIndex = 0
            scrollRequest = nil
            verticalViewport = .zero
            manualNavigationCursor = nil
            horizontalScrollSynchronization.reset()
            contentFindState.dismiss()
            contentFindState.resetSelection()
            searchExpandedGapIDsSnapshot = nil
            viewportAnchorRequestID = nil
            setExpandedGapIDs([])
            refreshDisplayRows()
        }
        .onChange(of: currentExpandedGapIDs) { _, _ in
            viewportAnchorRequestID = UUID()
            refreshDisplayRows()
        }
        .onChange(of: fontSize) { _, _ in
            refreshDisplayRows()
        }
        .onChange(of: contentFindState.query) { previous, next in
            if previous.isEmpty, !next.isEmpty {
                searchExpandedGapIDsSnapshot = currentExpandedGapIDs
                setExpandedGapIDs(renderModel.gapIDs)
            } else if !previous.isEmpty, next.isEmpty, let snapshot = searchExpandedGapIDsSnapshot {
                setExpandedGapIDs(snapshot)
                searchExpandedGapIDsSnapshot = nil
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(diff.path)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Combined Merge Diff")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("上一个改动片段", systemImage: "chevron.up") {
                navigateChange(offset: -1)
            }
            .labelStyle(.iconOnly)
            .disabled(previousChangeIndex == nil)
            .help("上一个改动片段")
            Button("下一个改动片段", systemImage: "chevron.down") {
                navigateChange(offset: 1)
            }
            .labelStyle(.iconOnly)
            .disabled(nextChangeIndex == nil)
            .help("下一个改动片段")
            Button(gapExpansionAction.title, systemImage: gapExpansionAction.systemImage) {
                setExpandedGapIDs(gapExpansionAction == .expandAll ? renderModel.gapIDs : [])
            }
            .labelStyle(.iconOnly)
            .disabled(renderModel.gaps.isEmpty || (contentFindState.isPresented && !contentFindState.query.isEmpty))
            .help(gapExpansionAction.title)
            .accessibilityIdentifier("RepoDesk.MergeDiff.ToggleAllGaps")
            Button(
                "忽略空白",
                systemImage: ignoresWhitespace ? "textformat.alt" : "textformat"
            ) {
                toggleIgnoreWhitespace()
            }
            .labelStyle(.iconOnly)
            .help(ignoresWhitespace ? "当前忽略空白变化" : "忽略空白变化")
            Button("跳转到源文件", systemImage: "arrow.turn.down.right") {
                jumpToSource(selectedResultLine)
            }
            .labelStyle(.iconOnly)
            .help("Jump To Source")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var mergePanes: some View {
        GeometryReader { geometry in
            let contentHeight = max(geometry.size.height, mergeContentHeight)
            GitDiffVerticalScrollView(
                identifier: "RepoDesk.MergeDiffVerticalScroll",
                contentHeight: contentHeight,
                requestID: activeContentSearchTarget == nil
                    ? scrollRequest?.id
                    : contentFindState.navigationRequestID,
                target: activeContentSearchTarget
                    ?? navigationTarget(at: selectedChangeIndex),
                viewport: $verticalViewport,
                navigationTargetCenters: navigationTargets.map { $0.offset + $0.height / 2 },
                viewportAnchorRequestID: viewportAnchorRequestID,
                manualNavigationCursor: $manualNavigationCursor
            ) {
                HSplitView {
                    mergePane(.target, height: contentHeight)
                    mergePane(.result, height: contentHeight)
                    mergePane(.source, height: contentHeight)
                }
                .frame(width: geometry.size.width, height: contentHeight)
            }
        }
    }

    private func mergePane(_ pane: GitHistoryBlameSide, height: CGFloat) -> some View {
        GeometryReader { geometry in
            let blameWidth: CGFloat = blame[pane] == nil ? 0 : 226
            let viewportWidth = max(0, geometry.size.width - blameWidth)
            let contentWidth = max(
                viewportWidth,
                max(requiredWidth(for: pane), GitDiffLayoutMetrics.minimumSidePaneWidth)
            )
            let paneViewportHeight = max(0, height - headerHeight)
            let paneContentHeight = max(
                rowsContentHeight,
                paneViewportHeight - GitDiffLayoutMetrics.horizontalScrollerReserve
            )
            VStack(spacing: 0) {
                paneHeader(pane)
                HStack(alignment: .top, spacing: 0) {
                    if blame[pane] != nil {
                        blameColumn(pane, height: paneContentHeight)
                            .frame(width: blameWidth, height: paneContentHeight)
                            .contextMenu { blameContextMenu(pane) }
                    }
                    GitDiffHorizontalScrollView(
                        identifier: "RepoDesk.MergeDiffHorizontalScroll.\(pane.rawValue)",
                        contentWidth: contentWidth,
                        contentHeight: paneContentHeight,
                        synchronization: horizontalScrollSynchronization
                    ) {
                        ZStack(alignment: .topLeading) {
                            mergeCodeColumn(
                                pane,
                                width: contentWidth,
                                height: paneContentHeight
                            )
                            .contextMenu { blameContextMenu(pane) }
                            GitDiffSelectableTextView(
                                model: selectableText(for: pane),
                                accessibilityIdentifier: "RepoDesk.MergeDiff.\(pane.rawValue).SelectableText",
                                contextAction: toggleBlame(pane).map { _ in
                                    GitDiffSelectableTextContextAction(
                                        title: "Annotate with Git Blame",
                                        isOn: blame[pane] != nil
                                    )
                                },
                                onSelectLine: selectResultLine,
                                onActivateGap: expandGap,
                                performContextAction: toggleBlame(pane),
                                contentSearch: contentSearchPresentation(for: pane)
                            )
                            .frame(
                                width: max(1, contentWidth - 56),
                                height: paneContentHeight
                            )
                            .offset(x: 56)
                        }
                        .frame(
                            width: contentWidth,
                            height: paneContentHeight,
                            alignment: .topLeading
                        )
                    }
                    .frame(
                        width: viewportWidth,
                        height: paneViewportHeight,
                        alignment: .topLeading
                    )
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .topLeading)
        }
        .frame(minWidth: GitDiffLayoutMetrics.minimumSidePaneWidth)
        .frame(height: height)
    }

    private func blameColumn(_ pane: GitHistoryBlameSide, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: visibleRows.leadingHeight)
            ForEach(visibleRows.rows) { displayed in
                switch displayed {
                case .line(let row):
                    GitBlameAnnotationCell(
                        blame: line(in: row, pane: pane).flatMap { blame[pane]?[$0.number] },
                        height: rowHeight,
                        colorScale: blameColorScales[pane] ?? GitBlameColorScale(dates: [])
                    )
                case .gap(let gap):
                    Color.clear.frame(height: rowHeight)
                        .contentShape(.rect)
                        .onTapGesture { expandGap(gap.id) }
                }
            }
            Color.clear.frame(height: visibleRows.trailingHeight)
        }
        .frame(height: height, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
        .accessibilityIdentifier("RepoDesk.MergeDiff.\(pane.rawValue).Blame")
    }

    @ViewBuilder
    private func blameContextMenu(_ pane: GitHistoryBlameSide) -> some View {
        if let toggle = toggleBlame(pane) {
            Toggle("Annotate with Git Blame", isOn: Binding(
                get: { blame[pane] != nil },
                set: { _ in toggle() }
            ))
        }
    }

    private func paneHeader(_ pane: GitHistoryBlameSide) -> some View {
        HStack(spacing: 6) {
            Image(systemName: paneIcon(pane))
                .foregroundStyle(paneColor(pane))
            Text(paneTitle(pane))
                .font(.caption.weight(.semibold))
            Spacer(minLength: 4)
            Text(paneHash(pane))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: headerHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu { blameContextMenu(pane) }
    }

    private func mergeCodeColumn(
        _ pane: GitHistoryBlameSide,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: visibleRows.leadingHeight)
            ForEach(visibleRows.rows) { displayed in
                switch displayed {
                case .line(let row): mergeCell(row, pane: pane, width: width)
                case .gap(let gap): gapRow(gap, pane: pane, width: width)
                }
            }
            Color.clear.frame(height: visibleRows.trailingHeight)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func gapRow(_ gap: GitMergeDiffGap, pane: GitHistoryBlameSide, width: CGFloat) -> some View {
        Button { expandGap(gap.id) } label: {
            HStack(spacing: 0) {
                Image(systemName: "ellipsis")
                    .frame(width: 56)
                Text(gap.title)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: width, height: rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color.accentColor.opacity(0.06))
        .help("已隐藏 \(gap.count) 行未改动内容，点击后在三栏中同步展开")
        .accessibilityIdentifier("RepoDesk.MergeDiff.\(pane.rawValue).Gap.\(gap.id)")
    }

    private func mergeCell(
        _ row: GitMergeDiffRow,
        pane: GitHistoryBlameSide,
        width: CGFloat
    ) -> some View {
        let line = line(in: row, pane: pane)
        return HStack(spacing: 0) {
            Text(line.map { String($0.number) } ?? "")
                .font(.system(size: max(9, fontSize - 2), design: .monospaced).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 7)
            Divider()
            Text(line?.text ?? "")
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(lineForeground(line, pane: pane))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: rowHeight, alignment: .leading)
        .background(rowBackground(row, line: line, pane: pane))
        .contentShape(.rect)
        .onTapGesture {
            if let resultNumber = row.result?.number,
               let changeIndex = changedRows.firstIndex(where: { $0.result?.number == resultNumber }) {
                selectedChangeIndex = changeIndex
            }
        }
        .accessibilityIdentifier("RepoDesk.MergeDiff.\(pane.rawValue).Row.\(row.id)")
    }

    private var mergeContentHeight: CGFloat {
        headerHeight + rowsContentHeight + GitDiffLayoutMetrics.horizontalScrollerReserve
    }

    private var rowsContentHeight: CGFloat {
        CGFloat(displayRows.count) * rowHeight
    }

    private func selectableText(
        for pane: GitHistoryBlameSide
    ) -> GitDiffSelectableTextModel {
        selectableTextModels[pane] ?? GitDiffSelectableTextModel(rows: [])
    }

    private var contentSearchMatches: [GitMergeContentSearchMatch] {
        let matchesByPane = Dictionary(uniqueKeysWithValues: GitHistoryBlameSide.allCases.map { pane in
            let matches = selectableText(for: pane).searchMatches(
                query: contentFindState.query,
                options: contentFindState.options
            )
            return (pane, Dictionary(grouping: matches, by: \.lineIndex))
        })
        return displayRows.indices.flatMap { lineIndex in
            GitHistoryBlameSide.allCases.flatMap { pane in
                (matchesByPane[pane]?[lineIndex] ?? []).map {
                    GitMergeContentSearchMatch(pane: pane, match: $0)
                }
            }
        }
    }

    private func contentSearchPresentation(
        for pane: GitHistoryBlameSide
    ) -> ContentSearchPresentation? {
        guard contentFindState.isPresented else { return nil }
        let matches = contentSearchMatches
        let paneMatches = matches.filter { $0.pane == pane }
        let activeIndex = contentFindState.activeMatchIndex(matchCount: matches.count)
        let activeRange = activeIndex.flatMap { index in
            matches[index].pane == pane ? matches[index].match.range : nil
        }
        return ContentSearchPresentation(
            ranges: paneMatches.map(\.match.range),
            activeRange: activeRange,
            navigationRequestID: contentFindState.navigationRequestID
        )
    }

    private var activeContentSearchTarget: GitDiffVerticalNavigationTarget? {
        guard contentFindState.isPresented else { return nil }
        let matches = contentSearchMatches
        guard let index = contentFindState.activeMatchIndex(matchCount: matches.count) else {
            return nil
        }
        let active = matches[index]
        return selectableText(for: active.pane).navigationTarget(
            forLineAt: active.match.lineIndex,
            leadingOffset: headerHeight
        )
    }

    private func navigateContentFind(by offset: Int) {
        if !contentFindState.isPresented {
            presentContentFind()
        }
        contentFindState.navigate(by: offset, matchCount: contentSearchMatches.count)
    }

    private static func makeSelectableTextModels(
        rows: [GitMergeDiffDisplayRow],
        rowHeight: CGFloat,
        fontSize: CGFloat
    ) -> [GitHistoryBlameSide: GitDiffSelectableTextModel] {
        Dictionary(uniqueKeysWithValues: GitHistoryBlameSide.allCases.map { pane in
            (pane, makeSelectableText(rows: rows, pane: pane, rowHeight: rowHeight, fontSize: fontSize))
        })
    }

    private static func makeSelectableText(
        rows: [GitMergeDiffDisplayRow],
        pane: GitHistoryBlameSide,
        rowHeight: CGFloat,
        fontSize: CGFloat
    ) -> GitDiffSelectableTextModel {
        GitDiffSelectableTextModel(
            rows: rows.map { displayed in
                if case .gap(let gap) = displayed {
                    return GitDiffSelectableTextRow(text: "", height: rowHeight, gapID: gap.id)
                }
                guard let row = displayed.line else {
                    return GitDiffSelectableTextRow(text: "", height: rowHeight)
                }
                let line: GitMergeDiffLine? = switch pane {
                case .target: row.target
                case .result: row.result
                case .source: row.source
                }
                return GitDiffSelectableTextRow(
                    text: line?.text ?? "",
                    height: rowHeight,
                    selectedLine: row.result?.number
                )
            },
            fontSize: fontSize,
            horizontalInset: 8
        )
    }

    private var currentExpandedGapIDs: Set<String> {
        (controlledExpandedGapIDs?.wrappedValue ?? expandedGapIDs).intersection(renderModel.gapIDs)
    }

    private var gapExpansionAction: GitDiffGapExpansionAction {
        GitDiffGapExpansionAction.resolve(gapIDs: renderModel.gapIDs, expandedGapIDs: currentExpandedGapIDs)
    }

    private func expandGap(_ id: String) {
        setExpandedGapIDs(currentExpandedGapIDs.union([id]))
    }

    private func setExpandedGapIDs(_ ids: Set<String>) {
        viewportAnchorRequestID = UUID()
        if let controlledExpandedGapIDs {
            controlledExpandedGapIDs.wrappedValue = ids
        } else {
            expandedGapIDs = ids
        }
        refreshDisplayRows()
    }

    private func refreshDisplayRows() {
        displayRows = renderModel.displayRows(expandedGapIDs: currentExpandedGapIDs)
        selectableTextModels = Self.makeSelectableTextModels(rows: displayRows, rowHeight: rowHeight, fontSize: fontSize)
    }

    private func presentContentFind() {
        contentFindState.present()
        if !contentFindState.query.isEmpty, searchExpandedGapIDsSnapshot == nil {
            searchExpandedGapIDsSnapshot = currentExpandedGapIDs
            setExpandedGapIDs(renderModel.gapIDs)
        }
    }

    private func dismissContentFind() {
        if let snapshot = searchExpandedGapIDsSnapshot { setExpandedGapIDs(snapshot) }
        searchExpandedGapIDsSnapshot = nil
        contentFindState.dismiss()
    }

    private func selectResultLine(_ resultNumber: Int) {
        if let changeIndex = changedRows.firstIndex(where: {
            $0.result?.number == resultNumber
        }) {
            selectedChangeIndex = changeIndex
        }
    }

    private var visibleRows: MergeVisibleRows {
        let overscan: CGFloat = 660
        let viewportHeight = max(verticalViewport.height, 680)
        let rowOffset = max(0, verticalViewport.offset - headerHeight)
        let lowerBound = max(0, rowOffset - overscan)
        let upperBound = rowOffset + viewportHeight + overscan
        let startIndex = min(displayRows.count, Int(lowerBound / rowHeight))
        let endIndex = min(
            displayRows.count,
            max(startIndex, Int(ceil(upperBound / rowHeight)))
        )
        return MergeVisibleRows(
            leadingHeight: CGFloat(startIndex) * rowHeight,
            rows: displayRows[startIndex..<endIndex],
            trailingHeight: CGFloat(displayRows.count - endIndex) * rowHeight
        )
    }

    private var changedRows: [GitMergeDiffRow] {
        renderModel.rows.filter(\.isChanged)
    }

    private var navigationTargets: [GitDiffVerticalNavigationTarget] {
        displayRows.enumerated().compactMap { index, displayed in
            guard displayed.line?.isChanged == true else { return nil }
            return GitDiffVerticalNavigationTarget(
                offset: headerHeight + CGFloat(index) * rowHeight,
                height: rowHeight
            )
        }
    }

    private func navigationTarget(at index: Int) -> GitDiffVerticalNavigationTarget? {
        guard navigationTargets.indices.contains(index) else { return nil }
        return navigationTargets[index]
    }

    private var previousChangeIndex: Int? {
        manualNavigationCursor?.previousIndex ?? GitDiffHunkNavigation.adjacentIndex(
            currentIndex: selectedChangeIndex,
            offset: -1,
            targetCount: changedRows.count
        )
    }

    private var nextChangeIndex: Int? {
        manualNavigationCursor?.nextIndex ?? GitDiffHunkNavigation.adjacentIndex(
            currentIndex: selectedChangeIndex,
            offset: 1,
            targetCount: changedRows.count
        )
    }

    private func navigateChange(offset: Int) {
        guard let index = offset < 0 ? previousChangeIndex : nextChangeIndex else { return }
        manualNavigationCursor = nil
        selectedChangeIndex = index
        scrollRequest = GitDiffScrollRequest()
    }

    private var selectedResultLine: Int? {
        guard changedRows.indices.contains(selectedChangeIndex) else {
            return changedRows.lazy.compactMap(\.result?.number).first
        }
        let row = changedRows[selectedChangeIndex]
        return row.result?.number
            ?? renderModel.rows[row.id...].lazy.compactMap(\.result?.number).first
            ?? renderModel.rows[..<row.id].lazy.compactMap(\.result?.number).last
    }

    private func requiredWidth(for pane: GitHistoryBlameSide) -> CGFloat {
        switch pane {
        case .target: GitDiffLayoutMetrics.requiredSidePaneWidth(lines: diff.target.oldLines)
        case .result: GitDiffLayoutMetrics.requiredSidePaneWidth(lines: diff.resultLines)
        case .source: GitDiffLayoutMetrics.requiredSidePaneWidth(lines: diff.source.oldLines)
        }
    }

    private func line(in row: GitMergeDiffRow, pane: GitHistoryBlameSide) -> GitMergeDiffLine? {
        switch pane {
        case .target: row.target
        case .result: row.result
        case .source: row.source
        }
    }

    private func paneTitle(_ pane: GitHistoryBlameSide) -> String {
        switch pane {
        case .target: "目标父提交"
        case .result: "合并结果"
        case .source: "来源父提交"
        }
    }

    private func paneHash(_ pane: GitHistoryBlameSide) -> String {
        switch pane {
        case .target: diff.target.oldLabel
        case .result: diff.target.newLabel
        case .source: diff.source.oldLabel
        }
    }

    private func paneIcon(_ pane: GitHistoryBlameSide) -> String {
        switch pane {
        case .target: "arrow.triangle.branch"
        case .result: "checkmark.circle"
        case .source: "arrow.branch"
        }
    }

    private func paneColor(_ pane: GitHistoryBlameSide) -> Color {
        switch pane {
        case .target: .blue
        case .result: .green
        case .source: .orange
        }
    }

    private func lineForeground(_ line: GitMergeDiffLine?, pane: GitHistoryBlameSide) -> Color {
        guard let line else { return .secondary }
        switch (pane, line.kind) {
        case (.result, .changed): return Color.green
        case (_, .changed), (_, .deleted): return Color.red
        default: return Color.primary
        }
    }

    private func rowBackground(
        _ row: GitMergeDiffRow,
        line: GitMergeDiffLine?,
        pane: GitHistoryBlameSide
    ) -> Color {
        guard line != nil else {
            return row.isChanged ? Color(nsColor: .controlBackgroundColor).opacity(0.55) : .clear
        }
        switch pane {
        case .target:
            return row.differsFromTarget || row.result == nil ? Color.red.opacity(0.10) : .clear
        case .source:
            return row.differsFromSource || row.result == nil ? Color.red.opacity(0.10) : .clear
        case .result:
            if row.differsFromTarget && row.differsFromSource { return Color.yellow.opacity(0.16) }
            if row.differsFromTarget || row.differsFromSource { return Color.green.opacity(0.11) }
            return .clear
        }
    }
}

private struct MergeVisibleRows {
    let leadingHeight: CGFloat
    let rows: ArraySlice<GitMergeDiffDisplayRow>
    let trailingHeight: CGFloat
}

private struct PairwiseMergeAlignment {
    var linesByResult: [Int: GitMergeDiffLine] = [:]
    var deletionsBeforeResult: [Int: [GitMergeDiffLine]] = [:]
    var changedResultLines: Set<Int> = []

    init(diff: GitFileDiff) {
        var oldNumber = 1
        var newNumber = 1

        func oldText(at number: Int) -> String {
            diff.oldLines.indices.contains(number - 1) ? diff.oldLines[number - 1] : ""
        }

        func appendDeletion(_ line: GitMergeDiffLine, before resultNumber: Int) {
            deletionsBeforeResult[resultNumber, default: []].append(line)
        }

        func mapUnchanged(untilOld oldLimit: Int, new newLimit: Int) {
            while oldNumber < oldLimit, newNumber < newLimit {
                linesByResult[newNumber] = GitMergeDiffLine(
                    number: oldNumber,
                    text: oldText(at: oldNumber),
                    kind: .unchanged
                )
                oldNumber += 1
                newNumber += 1
            }
        }

        for hunk in diff.hunks {
            mapUnchanged(untilOld: hunk.oldStart, new: hunk.newStart)
            var pendingDeletions: [GitMergeDiffLine] = []

            func flushDeletions() {
                for line in pendingDeletions {
                    appendDeletion(line, before: newNumber)
                }
                pendingDeletions.removeAll(keepingCapacity: true)
            }

            for patchLine in hunk.lines {
                switch patchLine.kind {
                case .context:
                    flushDeletions()
                    linesByResult[newNumber] = GitMergeDiffLine(
                        number: oldNumber,
                        text: patchLine.text,
                        kind: .unchanged
                    )
                    oldNumber += 1
                    newNumber += 1
                case .deletion:
                    pendingDeletions.append(
                        GitMergeDiffLine(number: oldNumber, text: patchLine.text, kind: .deleted)
                    )
                    oldNumber += 1
                case .addition:
                    let parentLine: GitMergeDiffLine?
                    if pendingDeletions.isEmpty {
                        parentLine = nil
                    } else {
                        let deletion = pendingDeletions.removeFirst()
                        parentLine = GitMergeDiffLine(
                            number: deletion.number,
                            text: deletion.text,
                            kind: .changed
                        )
                    }
                    linesByResult[newNumber] = parentLine
                    changedResultLines.insert(newNumber)
                    newNumber += 1
                }
            }
            flushDeletions()
        }

        mapUnchanged(untilOld: diff.oldLines.count + 1, new: diff.newLines.count + 1)
        while oldNumber <= diff.oldLines.count {
            appendDeletion(
                GitMergeDiffLine(number: oldNumber, text: oldText(at: oldNumber), kind: .deleted),
                before: newNumber
            )
            oldNumber += 1
        }
        while newNumber <= diff.newLines.count {
            linesByResult[newNumber] = nil
            changedResultLines.insert(newNumber)
            newNumber += 1
        }
    }
}
