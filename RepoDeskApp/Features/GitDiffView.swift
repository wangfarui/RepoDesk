import AppKit
import SwiftUI

enum GitDiffGapExpansionAction: Equatable, Sendable {
    case expandAll
    case collapseAll

    static func resolve(
        gapIDs: Set<String>,
        expandedGapIDs: Set<String>
    ) -> GitDiffGapExpansionAction {
        !gapIDs.isEmpty && gapIDs.isSubset(of: expandedGapIDs) ? .collapseAll : .expandAll
    }

    var title: String {
        switch self {
        case .expandAll: "展开全部未改动片段"
        case .collapseAll: "折叠全部未改动片段"
        }
    }

    var systemImage: String {
        switch self {
        case .expandAll: "arrow.up.left.and.arrow.down.right"
        case .collapseAll: "arrow.down.right.and.arrow.up.left"
        }
    }
}

enum GitDiffHunkNavigation {
    static func adjacentIndex(
        currentIndex: Int,
        offset: Int,
        targetCount: Int
    ) -> Int? {
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0, targetIndex < targetCount else { return nil }
        return targetIndex
    }

    static func cursor(
        viewportOffset: CGFloat,
        viewportHeight: CGFloat,
        targetCenters: [CGFloat]
    ) -> GitDiffHunkNavigationCursor {
        let reference = max(0, viewportOffset) + max(0, viewportHeight) / 2
        let tolerance: CGFloat = 0.5
        let previousIndex = targetCenters.lastIndex { $0 < reference - tolerance }
        let nextIndex = targetCenters.firstIndex { $0 > reference + tolerance }
        return GitDiffHunkNavigationCursor(
            previousIndex: previousIndex,
            nextIndex: nextIndex
        )
    }
}

struct GitDiffHunkNavigationCursor: Equatable, Sendable {
    let previousIndex: Int?
    let nextIndex: Int?
}

struct GitDiffNavigationTarget: Equatable, Sendable {
    let unifiedRowID: String
    let sideRowID: String
    let newLine: Int
}

struct GitDiffSelectableTextRow: Equatable {
    let text: String
    let height: CGFloat
    let selectedLine: Int?
    let gapID: String?

    init(
        text: String,
        height: CGFloat = 22,
        selectedLine: Int? = nil,
        gapID: String? = nil
    ) {
        self.text = text
        self.height = height
        self.selectedLine = selectedLine
        self.gapID = gapID
    }
}

struct GitDiffSelectableTextModel: Equatable {
    static let emptyLineMarker = "\u{200B}"

    let rows: [GitDiffSelectableTextRow]
    let fontSize: CGFloat
    let horizontalInset: CGFloat

    init(
        rows: [GitDiffSelectableTextRow],
        fontSize: CGFloat = NSFont.systemFontSize,
        horizontalInset: CGFloat = 0
    ) {
        self.rows = rows
        self.fontSize = fontSize
        self.horizontalInset = horizontalInset
    }

    var storageText: String {
        rows.map { $0.text.isEmpty ? Self.emptyLineMarker : $0.text }.joined(separator: "\n")
    }

    var searchableLines: [String] {
        rows.map(\.text)
    }

    func navigationTarget(
        forLineAt index: Int,
        leadingOffset: CGFloat = 0
    ) -> GitDiffVerticalNavigationTarget? {
        guard rows.indices.contains(index) else { return nil }
        let offset = rows[..<index].reduce(leadingOffset) { $0 + $1.height }
        return GitDiffVerticalNavigationTarget(offset: offset, height: rows[index].height)
    }

    func copiedText(in range: NSRange) -> String {
        let storage = storageText as NSString
        guard range.location != NSNotFound,
              range.location <= storage.length,
              range.length <= storage.length - range.location else { return "" }
        let copiedText = NSMutableString(string: storage.substring(with: range))
        for markerLocation in emptyLineMarkerLocations.reversed()
            where NSLocationInRange(markerLocation, range) {
            copiedText.deleteCharacters(in: NSRange(
                location: markerLocation - range.location,
                length: 1
            ))
        }
        return copiedText as String
    }

    func row(atVerticalOffset offset: CGFloat) -> GitDiffSelectableTextRow? {
        guard offset >= 0 else { return nil }
        var currentOffset: CGFloat = 0
        for row in rows {
            currentOffset += row.height
            if offset < currentOffset { return row }
        }
        return nil
    }

    private var emptyLineMarkerLocations: [Int] {
        var locations: [Int] = []
        var location = 0
        for (index, row) in rows.enumerated() {
            if row.text.isEmpty { locations.append(location) }
            location += ((row.text.isEmpty ? Self.emptyLineMarker : row.text) as NSString).length
            if index < rows.count - 1 { location += 1 }
        }
        return locations
    }
}

struct GitDiffSelectableTextContextAction: Equatable {
    let title: String
    let isOn: Bool
}

@MainActor
struct GitDiffSelectableTextView: NSViewRepresentable {
    let model: GitDiffSelectableTextModel
    var accessibilityIdentifier: String
    var contextAction: GitDiffSelectableTextContextAction? = nil
    var onSelectLine: ((Int) -> Void)? = nil
    var onActivateGap: ((String) -> Void)? = nil
    var performContextAction: (() -> Void)? = nil
    var contentSearch: ContentSearchPresentation? = nil

    func makeNSView(context: Context) -> GitDiffSelectableTextViewSurface {
        let textView = GitDiffSelectableTextViewSurface(frame: .zero)
        textView.configure()
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        update(textView)
        return textView
    }

    func updateNSView(_ textView: GitDiffSelectableTextViewSurface, context: Context) {
        update(textView)
    }

    private func update(_ textView: GitDiffSelectableTextViewSurface) {
        textView.onSelectLine = onSelectLine
        textView.onActivateGap = onActivateGap
        textView.contextAction = contextAction
        textView.performContextAction = performContextAction
        textView.apply(model, contentSearch: contentSearch)
    }
}

@MainActor
final class GitDiffSelectableTextViewSurface: NSTextView {
    private(set) var model = GitDiffSelectableTextModel(rows: [])
    var contextAction: GitDiffSelectableTextContextAction?
    var onSelectLine: ((Int) -> Void)?
    var onActivateGap: ((String) -> Void)?
    var performContextAction: (() -> Void)?

    override var isFlipped: Bool { true }

    func configure() {
        drawsBackground = false
        backgroundColor = .clear
        textColor = .clear
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        focusRingType = .none
        insertionPointColor = .clear
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.42),
            .foregroundColor: NSColor.clear
        ]
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        isHorizontallyResizable = true
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    func apply(
        _ nextModel: GitDiffSelectableTextModel,
        contentSearch: ContentSearchPresentation?
    ) {
        if model != nextModel {
            model = nextModel
            textContainerInset = NSSize(width: model.horizontalInset, height: 0)

            let font = NSFont.monospacedSystemFont(
                ofSize: model.fontSize,
                weight: .regular
            )
            let attributedText = NSMutableAttributedString(
                string: model.storageText,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.clear
                ]
            )
            if let height = model.rows.first?.height,
               model.rows.allSatisfy({ $0.height == height }) {
                attributedText.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle(height: height),
                    range: NSRange(location: 0, length: attributedText.length)
                )
            } else {
                var groupStart = 0
                var groupLength = 0
                var groupHeight = model.rows.first?.height
                for (index, row) in model.rows.enumerated() {
                    let rowLength = ((row.text.isEmpty ? Self.emptyLineMarker : row.text) as NSString).length
                        + (index < model.rows.count - 1 ? 1 : 0)
                    if let currentGroupHeight = groupHeight,
                       row.height != currentGroupHeight {
                        attributedText.addAttribute(
                            .paragraphStyle,
                            value: paragraphStyle(height: currentGroupHeight),
                            range: NSRange(location: groupStart, length: groupLength)
                        )
                        groupStart += groupLength
                        groupLength = 0
                    }
                    groupHeight = row.height
                    groupLength += rowLength
                }
                if let groupHeight, groupLength > 0 {
                    attributedText.addAttribute(
                        .paragraphStyle,
                        value: paragraphStyle(height: groupHeight),
                        range: NSRange(location: groupStart, length: groupLength)
                    )
                }
            }
            textStorage?.setAttributedString(attributedText)
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        applyContentSearch(contentSearch)
    }

    func apply(_ nextModel: GitDiffSelectableTextModel) {
        apply(nextModel, contentSearch: nil)
    }

    private func applyContentSearch(_ presentation: ContentSearchPresentation?) {
        guard let layoutManager else { return }
        let storageLength = textStorage?.length ?? 0
        let fullRange = NSRange(location: 0, length: storageLength)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        guard let presentation else { return }
        for range in presentation.ranges where isValid(range, length: storageLength) {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.28),
                forCharacterRange: range
            )
        }
        if let activeRange = presentation.activeRange,
           isValid(activeRange, length: storageLength) {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.systemOrange.withAlphaComponent(0.52),
                forCharacterRange: activeRange
            )
        }
    }

    private func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location <= length
            && range.length <= length - range.location
    }

    private func paragraphStyle(height: CGFloat) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = height
        paragraphStyle.maximumLineHeight = height
        paragraphStyle.lineSpacing = 0
        return paragraphStyle
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let row = model.row(atVerticalOffset: point.y) {
            if let gapID = row.gapID {
                onActivateGap?(gapID)
                return
            }
            if let selectedLine = row.selectedLine {
                onSelectLine?(selectedLine)
            }
        }
        super.mouseDown(with: event)
    }

    override func copy(_ sender: Any?) {
        guard let copiedText = selectedCopyText() else {
            super.copy(sender)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedText, forType: .string)
    }

    func selectedCopyText() -> String? {
        let selection = selectedRange()
        guard selection.length > 0 else { return nil }
        return model.copiedText(in: selection)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let contextAction else { return menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(
            title: contextAction.title,
            action: #selector(runContextAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = contextAction.isOn ? .on : .off
        menu.addItem(item)
        return menu
    }

    override func autoscroll(with event: NSEvent) -> Bool {
        let didAutoscroll = super.autoscroll(with: event)
        guard let verticalScrollView = enclosingVerticalScrollView() else {
            return didAutoscroll
        }
        let clipView = verticalScrollView.contentView
        let point = clipView.convert(event.locationInWindow, from: nil)
        let bounds = clipView.bounds
        let distance: CGFloat
        if point.y < bounds.minY {
            distance = point.y - bounds.minY
        } else if point.y > bounds.maxY {
            distance = point.y - bounds.maxY
        } else {
            return didAutoscroll
        }
        let maximumOffset = max(
            0,
            (verticalScrollView.documentView?.bounds.height ?? 0) - bounds.height
        )
        let nextOffset = min(max(0, bounds.origin.y + distance), maximumOffset)
        clipView.scroll(to: NSPoint(x: bounds.origin.x, y: nextOffset))
        verticalScrollView.reflectScrolledClipView(clipView)
        return true
    }

    @objc private func runContextAction(_ sender: Any?) {
        performContextAction?()
    }

    private func enclosingVerticalScrollView() -> NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView,
               scrollView.hasVerticalScroller {
                return scrollView
            }
            ancestor = view.superview
        }
        return nil
    }

    private static let emptyLineMarker = GitDiffSelectableTextModel.emptyLineMarker
}

private enum GitDiffContentSearchPane: Equatable {
    case unified
    case old
    case new
}

private struct GitDiffContentSearchMatch {
    let pane: GitDiffContentSearchPane
    let match: ContentSearchMatch
}

@MainActor
struct GitDiffView: View {
    let diff: GitFileDiff
    let ignoresWhitespace: Bool
    let toggleIgnoreWhitespace: () -> Void
    let presentation: GitDiffPresentation
    let setPresentation: (GitDiffPresentation) -> Void
    let jumpToSource: (Int?) -> Void
    let lockedPresentation: GitDiffPresentation?
    let openComparison: ((GitDiffRenderModel) -> Void)?
    let oldBlame: [Int: GitBlameLine]?
    let newBlame: [Int: GitBlameLine]?
    let toggleOldBlame: (() -> Void)?
    let toggleNewBlame: (() -> Void)?
    let fontSize: CGFloat
    private let renderModel: GitDiffRenderModel

    @State private var expandedGapIDs: Set<String> = []
    @State private var selectedNewLine: Int?
    @State private var selectedHunkIndex = 0
    @State private var scrollRequest: GitDiffScrollRequest?
    @State private var verticalViewport = GitDiffVerticalViewport.zero
    @State private var manualNavigationCursor: GitDiffHunkNavigationCursor?
    @State private var sideHorizontalScrollSynchronization = GitDiffHorizontalScrollSynchronization()
    @State private var viewportAnchorRequestID: UUID?
    @State private var selectableTextModels: GitDiffSelectableTextModels
    @State private var contentFindState = ContentFindState()
    @State private var searchExpandedGapIDsSnapshot: Set<String>?

    init(
        diff: GitFileDiff,
        ignoresWhitespace: Bool,
        toggleIgnoreWhitespace: @escaping () -> Void,
        presentation: GitDiffPresentation = .unified,
        setPresentation: @escaping (GitDiffPresentation) -> Void = { _ in },
        jumpToSource: @escaping (Int?) -> Void,
        lockedPresentation: GitDiffPresentation? = nil,
        openComparison: ((GitDiffRenderModel) -> Void)? = nil,
        oldBlame: [Int: GitBlameLine]? = nil,
        newBlame: [Int: GitBlameLine]? = nil,
        toggleOldBlame: (() -> Void)? = nil,
        toggleNewBlame: (() -> Void)? = nil,
        fontSize: CGFloat = NSFont.systemFontSize,
        renderModel: GitDiffRenderModel? = nil
    ) {
        self.diff = diff
        self.ignoresWhitespace = ignoresWhitespace
        self.toggleIgnoreWhitespace = toggleIgnoreWhitespace
        self.presentation = presentation
        self.setPresentation = setPresentation
        self.jumpToSource = jumpToSource
        self.lockedPresentation = lockedPresentation
        self.openComparison = openComparison
        self.oldBlame = oldBlame
        self.newBlame = newBlame
        self.toggleOldBlame = toggleOldBlame
        self.toggleNewBlame = toggleNewBlame
        self.fontSize = fontSize
        let resolvedRenderModel = renderModel ?? GitDiffRenderModel(diff: diff)
        self.renderModel = resolvedRenderModel
        let shouldBuildSelectableText = Self.shouldBuildSelectableText(for: resolvedRenderModel)
        _selectableTextModels = State(initialValue: shouldBuildSelectableText
            ? Self.makeSelectableTextModels(
                diff: diff,
                renderModel: resolvedRenderModel,
                expandedGapIDs: [],
                fontSize: fontSize,
                lineHeight: Self.lineHeight(for: fontSize),
                gapHeight: Self.gapHeight(for: fontSize)
            )
            : GitDiffSelectableTextModels.empty)
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
                    "Binary Diff",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("该文件是二进制文件，无法显示文本 Diff。")
                )
            } else if diff.hunks.isEmpty {
                ContentUnavailableView(
                    "没有可显示的 Diff",
                    systemImage: "checkmark.circle",
                    description: Text("忽略空白后可能没有内容变化。")
                )
            } else {
                switch effectivePresentation {
                case .unified:
                    unifiedView
                        .font(.system(size: fontSize))
                case .sideBySide:
                    sideBySideView
                        .font(.system(size: fontSize))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(ContentFindCommandListener(
            requestFind: presentContentFind,
            navigateMatch: navigateContentFind
        ))
        .onChange(of: diff) { _, _ in
            expandedGapIDs = []
            searchExpandedGapIDsSnapshot = nil
            contentFindState.dismiss()
            contentFindState.resetSelection()
            selectableTextModels = Self.shouldBuildSelectableText(for: renderModel)
                ? Self.makeSelectableTextModels(
                    diff: diff,
                    renderModel: renderModel,
                    expandedGapIDs: [],
                    fontSize: fontSize,
                    lineHeight: lineHeight,
                    gapHeight: gapRowHeight
                )
                : GitDiffSelectableTextModels.empty
            selectedHunkIndex = 0
            scrollRequest = nil
            verticalViewport = .zero
            manualNavigationCursor = nil
            viewportAnchorRequestID = nil
            sideHorizontalScrollSynchronization.reset()
            selectedNewLine = firstNewLine
        }
        .onAppear { selectedNewLine = firstNewLine }
        .onChange(of: fontSize) { _, _ in
            refreshSelectableText(for: effectivePresentation)
        }
        .onChange(of: effectivePresentation) { _, nextPresentation in
            refreshSelectableText(for: nextPresentation)
            verticalViewport = .zero
            manualNavigationCursor = nil
            if contentFindState.isPresented {
                contentFindState.resetSelection()
            }
            scrollToSelectedHunk()
        }
        .onChange(of: contentFindState.query) { previousQuery, nextQuery in
            updateGapExpansionForSearch(
                previousQuery: previousQuery,
                nextQuery: nextQuery
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(diff.path)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(diff.oldLabel)  →  \(diff.newLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let openComparison {
                Button("对比", systemImage: "rectangle.split.2x1") {
                    openComparison(renderModel)
                }
                .help("在弹框中打开 Side-by-side 对比")
            } else if lockedPresentation == nil {
                Picker(
                    "Diff 模式",
                    selection: Binding(
                        get: { presentation },
                        set: setPresentation
                    )
                ) {
                    ForEach(GitDiffPresentation.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            Button("上一个改动片段", systemImage: "chevron.up") {
                navigateHunk(offset: -1)
            }
            .labelStyle(.iconOnly)
            .disabled(!canNavigateToPreviousHunk)
            .help("上一个改动片段")
            .accessibilityIdentifier("RepoDesk.Diff.PreviousHunk")
            Button("下一个改动片段", systemImage: "chevron.down") {
                navigateHunk(offset: 1)
            }
            .labelStyle(.iconOnly)
            .disabled(!canNavigateToNextHunk)
            .help("下一个改动片段")
            .accessibilityIdentifier("RepoDesk.Diff.NextHunk")
            Button(gapExpansionAction.title, systemImage: gapExpansionAction.systemImage) {
                toggleAllGaps()
            }
            .labelStyle(.iconOnly)
            .disabled(
                gapIDs.isEmpty
                    || (contentFindState.isPresented && !contentFindState.query.isEmpty)
            )
            .help(gapExpansionAction.title)
            .accessibilityIdentifier("RepoDesk.Diff.ToggleAllGaps")
            Button(
                "忽略空白",
                systemImage: ignoresWhitespace ? "textformat.alt" : "textformat"
            ) {
                toggleIgnoreWhitespace()
            }
            .labelStyle(.iconOnly)
            .help(ignoresWhitespace ? "当前忽略空白变化" : "忽略空白变化")
            Button("跳转到源文件", systemImage: "arrow.turn.down.right") {
                jumpToSource(selectedNewLine ?? firstNewLine)
            }
            .labelStyle(.iconOnly)
            .help("Jump To Source")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var unifiedView: some View {
        GeometryReader { geometry in
            let contentWidth = max(
                GitDiffLayoutMetrics.minimumUnifiedWidth,
                max(geometry.size.width, renderModel.requiredUnifiedWidth)
            )
            let horizontalViewportHeight = max(
                geometry.size.height,
                unifiedContentHeight + GitDiffLayoutMetrics.horizontalScrollerReserve
            )
            let horizontalContentHeight = max(
                unifiedContentHeight,
                horizontalViewportHeight - GitDiffLayoutMetrics.horizontalScrollerReserve
            )
            let contentHeight = horizontalViewportHeight
            let navigationTargets = unifiedVerticalNavigationTargets
            GitDiffVerticalScrollView(
                identifier: "RepoDesk.UnifiedDiffVerticalScroll",
                contentHeight: contentHeight,
                requestID: activeContentSearchTarget == nil
                    ? scrollRequest?.id
                    : contentFindState.navigationRequestID,
                target: activeContentSearchTarget
                    ?? navigationTarget(at: selectedHunkIndex, in: navigationTargets),
                viewport: $verticalViewport,
                navigationTargetCenters: navigationTargets.map {
                    $0.offset + $0.height / 2
                },
                viewportAnchorRequestID: viewportAnchorRequestID,
                manualNavigationCursor: $manualNavigationCursor
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    GitDiffHorizontalScrollView(
                        identifier: "RepoDesk.UnifiedDiffHorizontalScroll",
                        contentWidth: contentWidth,
                        contentHeight: horizontalContentHeight
                    ) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: visibleUnifiedRows.leadingHeight)
                                ForEach(visibleUnifiedRows.rows) { row in
                                    switch row.content {
                                    case .gap(let gap):
                                        gapRow(gap)
                                    case .line(let line):
                                        unifiedLine(line)
                                    }
                                }
                                Color.clear.frame(height: visibleUnifiedRows.trailingHeight)
                            }
                            .frame(width: contentWidth, alignment: .topLeading)
                            .frame(height: horizontalContentHeight, alignment: .topLeading)

                            if usesSelectableTextOverlay(for: .unified) {
                                GitDiffSelectableTextView(
                                    model: selectableTextModels.unified,
                                    accessibilityIdentifier: "RepoDesk.UnifiedDiff.SelectableText",
                                    onSelectLine: { selectedNewLine = $0 },
                                    onActivateGap: { gapID in
                                        setExpandedGapIDs(expandedGapIDs.union([gapID]))
                                    },
                                    contentSearch: contentSearchPresentation(for: .unified)
                                )
                                .frame(
                                    width: max(1, contentWidth - 132),
                                    height: horizontalContentHeight
                                )
                                .offset(x: 132)
                            }
                        }
                        .frame(width: contentWidth, alignment: .topLeading)
                        .frame(height: horizontalContentHeight, alignment: .topLeading)
                    }
                    .frame(
                        width: geometry.size.width,
                        height: horizontalViewportHeight,
                        alignment: .topLeading
                    )
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.size.width, height: contentHeight, alignment: .topLeading)
            }
        }
    }

    private var sideBySideView: some View {
        GeometryReader { geometry in
            let contentHeight = max(geometry.size.height, sideBySideContentHeight)
            let navigationTargets = sideVerticalNavigationTargets
            GitDiffVerticalScrollView(
                identifier: "RepoDesk.SideBySideDiffVerticalScroll",
                contentHeight: contentHeight,
                requestID: activeContentSearchTarget == nil
                    ? scrollRequest?.id
                    : contentFindState.navigationRequestID,
                target: activeContentSearchTarget
                    ?? navigationTarget(at: selectedHunkIndex, in: navigationTargets),
                viewport: $verticalViewport,
                navigationTargetCenters: navigationTargets.map {
                    $0.offset + $0.height / 2
                },
                viewportAnchorRequestID: viewportAnchorRequestID,
                manualNavigationCursor: $manualNavigationCursor
            ) {
                HSplitView {
                    sidePane(side: .old, height: contentHeight)
                        .frame(minWidth: GitDiffLayoutMetrics.minimumSidePaneWidth)
                    sidePane(side: .new, height: contentHeight)
                        .frame(minWidth: GitDiffLayoutMetrics.minimumSidePaneWidth)
                }
                .frame(width: geometry.size.width, height: contentHeight)
            }
        }
    }

    private func sidePane(
        side: GitBlameSide,
        height: CGFloat
    ) -> some View {
        GeometryReader { geometry in
            let blameWidth: CGFloat = blameIsVisible(side) ? 226 : 0
            let codeViewportWidth = max(0, geometry.size.width - blameWidth)
            let requiredWidth = side == .old
                ? renderModel.requiredOldPaneWidth
                : renderModel.requiredNewPaneWidth
            let codeContentWidth = max(
                codeViewportWidth,
                max(requiredWidth, GitDiffLayoutMetrics.minimumSidePaneWidth)
            )
            let codeViewportHeight = max(0, height - 28)
            let codeContentHeight = max(
                sideRowsContentHeight,
                codeViewportHeight - GitDiffLayoutMetrics.horizontalScrollerReserve
            )
            VStack(spacing: 0) {
                diffHeader(
                    side == .old ? diff.oldLabel : diff.newLabel,
                    width: geometry.size.width
                )
                HStack(alignment: .top, spacing: 0) {
                    if blameIsVisible(side) {
                        blameColumn(side: side, height: codeContentHeight)
                            .frame(width: blameWidth, height: codeContentHeight)
                            .contextMenu { blameContextMenu(side) }
                    }
                    GitDiffHorizontalScrollView(
                        identifier: "RepoDesk.SideBySideDiffHorizontalScroll.\(side == .old ? "old" : "new")",
                        contentWidth: codeContentWidth,
                        contentHeight: codeContentHeight,
                        synchronization: sideHorizontalScrollSynchronization
                    ) {
                        ZStack(alignment: .topLeading) {
                            sideCodeColumn(
                                side: side,
                                width: codeContentWidth,
                                height: codeContentHeight
                            )
                            .contextMenu { blameContextMenu(side) }

                            if usesSelectableTextOverlay(for: side == .old ? .old : .new) {
                                GitDiffSelectableTextView(
                                    model: side == .old
                                        ? selectableTextModels.old
                                        : selectableTextModels.new,
                                    accessibilityIdentifier: "RepoDesk.SideBySideDiff.\(side == .old ? "Old" : "New").SelectableText",
                                    contextAction: selectableTextContextAction(side),
                                    onSelectLine: { selectedNewLine = $0 },
                                    onActivateGap: { gapID in
                                        setExpandedGapIDs(expandedGapIDs.union([gapID]))
                                    },
                                    performContextAction: {
                                        if side == .old {
                                            toggleOldBlame?()
                                        } else {
                                            toggleNewBlame?()
                                        }
                                    },
                                    contentSearch: contentSearchPresentation(
                                        for: side == .old ? .old : .new
                                    )
                                )
                                .frame(
                                    width: max(1, codeContentWidth - 55),
                                    height: codeContentHeight
                                )
                                .offset(x: 55)
                            }
                        }
                        .frame(
                            width: codeContentWidth,
                            height: codeContentHeight,
                            alignment: .topLeading
                        )
                    }
                    .frame(
                        width: codeViewportWidth,
                        height: codeViewportHeight,
                        alignment: .leading
                    )
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .topLeading)
        }
        .frame(height: height)
    }

    private func sideCodeColumn(
        side: GitBlameSide,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: visibleSideRows.leadingHeight)
            ForEach(visibleSideRows.rows) { row in
                if let gap = row.gap {
                    sideGapRow(gap, width: width, side: side)
                } else {
                    sideCell(
                        side == .old ? row.old : row.new,
                        width: width,
                        side: side
                    )
                }
            }
            Color.clear.frame(height: visibleSideRows.trailingHeight)
        }
        .frame(
            width: width,
            height: height,
            alignment: .topLeading
        )
    }

    private func blameColumn(side: GitBlameSide, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(width: 226, height: visibleSideRows.leadingHeight)
            ForEach(visibleSideRows.rows) { row in
                if let gap = row.gap {
                    blameGapRows(gap, side: side)
                } else {
                    blameCell(
                        blameLine(
                            for: side == .old ? row.old : row.new,
                            side: side
                        )
                    )
                }
            }
            Color.clear.frame(width: 226, height: visibleSideRows.trailingHeight)
        }
        .frame(height: height, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
    }

    @ViewBuilder
    private func blameGapRows(_ gap: DiffGap, side: GitBlameSide) -> some View {
        Color.clear.frame(width: 226, height: gapRowHeight)
    }

    @ViewBuilder
    private func blameContextMenu(_ side: GitBlameSide) -> some View {
        if let toggle = side == .old ? toggleOldBlame : toggleNewBlame {
            Button {
                toggle()
            } label: {
                if blameIsVisible(side) {
                    Label("Annotate with Git Blame", systemImage: "checkmark")
                } else {
                    Text("Annotate with Git Blame")
                }
            }
        }
    }

    private func unifiedLine(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            lineNumber(line.oldNumber)
            lineNumber(line.newNumber)
            Text(line.prefix)
                .foregroundStyle(line.foreground)
                .frame(width: 22)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: fontSize, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .frame(height: lineHeight)
        .background(line.background)
        .contentShape(.rect)
        .onTapGesture {
            if let newNumber = line.newNumber { selectedNewLine = newNumber }
        }
    }

    private func sideCell(
        _ line: DiffLine?,
        width: CGFloat,
        side: GitBlameSide
    ) -> some View {
        HStack(spacing: 0) {
            lineNumber(side == .old ? line?.oldNumber : line?.newNumber)
            Text(line?.text ?? " ")
                .font(.system(size: fontSize, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
        .frame(width: width, alignment: .leading)
        .frame(height: lineHeight)
        .background(line?.background ?? Color.clear)
        .contentShape(.rect)
        .onTapGesture {
            if let newNumber = line?.newNumber { selectedNewLine = newNumber }
        }
    }

    private func blameLine(for line: DiffLine?, side: GitBlameSide) -> GitBlameLine? {
        let annotations = side == .old ? oldBlame : newBlame
        let number = side == .old ? line?.oldNumber : line?.newNumber
        guard let number else { return nil }
        return annotations?[number]
    }

    private func blameIsVisible(_ side: GitBlameSide) -> Bool {
        side == .old ? oldBlame != nil : newBlame != nil
    }

    private func selectableTextContextAction(
        _ side: GitBlameSide
    ) -> GitDiffSelectableTextContextAction? {
        let toggle = side == .old ? toggleOldBlame : toggleNewBlame
        guard toggle != nil else { return nil }
        return GitDiffSelectableTextContextAction(
            title: "Annotate with Git Blame",
            isOn: blameIsVisible(side)
        )
    }

    private func blameCell(_ blame: GitBlameLine?) -> some View {
        HStack(spacing: 6) {
            Text(blame?.authoredAt.map(Self.blameDateFormatter.string(from:)) ?? "")
                .frame(width: 58, alignment: .leading)
            Text(blame?.author ?? "")
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            Text(blame?.isUncommitted != false ? "" : String(blame?.commitHash.prefix(8) ?? ""))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
        }
        .font(.caption2.monospaced())
        .foregroundStyle(blame?.isUncommitted != false ? .secondary : .primary)
        .padding(.horizontal, 7)
        .frame(width: 226, alignment: .leading)
        .frame(height: lineHeight)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
    }

    private static let blameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy/MM/dd"
        return formatter
    }()

    private var sideBySideContentHeight: CGFloat {
        28 + sideRowsContentHeight + GitDiffLayoutMetrics.horizontalScrollerReserve
    }

    private var sideRowsContentHeight: CGFloat {
        renderModel.sideRows.reduce(CGFloat.zero) { height, row in
            guard let gap = row.gap else { return height + lineHeight }
            return height + (
                expandedGapIDs.contains(gap.id)
                    ? CGFloat(gap.count) * lineHeight
                    : gapRowHeight
            )
        }
    }

    private var unifiedContentHeight: CGFloat {
        renderModel.unifiedRows.reduce(CGFloat.zero) { $0 + unifiedRowHeight($1) }
    }

    private static func makeSelectableTextModels(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        expandedGapIDs: Set<String>,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        gapHeight: CGFloat
    ) -> GitDiffSelectableTextModels {
        GitDiffSelectableTextModels(
            unified: makeUnifiedSelectableText(
                diff: diff,
                renderModel: renderModel,
                expandedGapIDs: expandedGapIDs,
                fontSize: fontSize,
                lineHeight: lineHeight,
                gapHeight: gapHeight
            ),
            old: makeSideSelectableText(
                .old,
                diff: diff,
                renderModel: renderModel,
                expandedGapIDs: expandedGapIDs,
                fontSize: fontSize,
                lineHeight: lineHeight,
                gapHeight: gapHeight
            ),
            new: makeSideSelectableText(
                .new,
                diff: diff,
                renderModel: renderModel,
                expandedGapIDs: expandedGapIDs,
                fontSize: fontSize,
                lineHeight: lineHeight,
                gapHeight: gapHeight
            )
        )
    }

    private static func makeUnifiedSelectableText(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        expandedGapIDs: Set<String>,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        gapHeight: CGFloat
    ) -> GitDiffSelectableTextModel {
        GitDiffSelectableTextModel(rows: renderModel.unifiedRows.flatMap { row in
            switch row.content {
            case .line(let line):
                return [GitDiffSelectableTextRow(
                    text: line.text,
                    height: lineHeight,
                    selectedLine: line.newNumber
                )]
            case .gap(let gap):
                guard expandedGapIDs.contains(gap.id) else {
                    return [GitDiffSelectableTextRow(
                        text: "",
                        height: gapHeight,
                        gapID: gap.id
                    )]
                }
                return (0..<gap.count).map { offset in
                    let line = expandedLine(in: diff, for: gap, offset: offset)
                    return GitDiffSelectableTextRow(
                        text: line.text,
                        height: lineHeight,
                        selectedLine: line.newNumber
                    )
                }
            }
        }, fontSize: fontSize)
    }

    private static func makeSideSelectableText(
        _ side: GitBlameSide,
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        expandedGapIDs: Set<String>,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        gapHeight: CGFloat
    ) -> GitDiffSelectableTextModel {
        GitDiffSelectableTextModel(
            rows: renderModel.sideRows.flatMap { row in
            if let gap = row.gap {
                guard expandedGapIDs.contains(gap.id) else {
                    return [GitDiffSelectableTextRow(
                        text: "",
                        height: gapHeight,
                        gapID: gap.id
                    )]
                }
                return (0..<gap.count).map { offset in
                    let line = expandedLine(in: diff, for: gap, offset: offset)
                    return GitDiffSelectableTextRow(
                        text: line.text,
                        height: lineHeight,
                        selectedLine: line.newNumber
                    )
                }
            }
            let line = side == .old ? row.old : row.new
            return [GitDiffSelectableTextRow(
                text: line?.text ?? "",
                height: lineHeight,
                selectedLine: line?.newNumber
            )]
            },
            fontSize: fontSize,
            horizontalInset: 8
        )
    }

    private var visibleUnifiedRows: GitDiffVisibleRows<UnifiedRow> {
        visibleRows(
            renderModel.unifiedRows,
            totalHeight: unifiedContentHeight,
            viewportOffset: verticalViewport.offset,
            rowHeight: unifiedRowHeight,
            expandedRowCount: { row in
                guard case .gap(let gap) = row.content,
                      expandedGapIDs.contains(gap.id) else { return nil }
                return gap.count
            },
            expandedRow: { row, offset in
                guard case .gap(let gap) = row.content else { return row }
                return .line(expandedLine(for: gap, offset: offset))
            }
        )
    }

    private var visibleSideRows: GitDiffVisibleRows<SideRow> {
        visibleRows(
            renderModel.sideRows,
            totalHeight: sideRowsContentHeight,
            viewportOffset: max(0, verticalViewport.offset - 28),
            rowHeight: sideRowHeight,
            expandedRowCount: { row in
                guard let gap = row.gap,
                      expandedGapIDs.contains(gap.id) else { return nil }
                return gap.count
            },
            expandedRow: { row, offset in
                guard let gap = row.gap else { return row }
                let line = expandedLine(for: gap, offset: offset)
                return SideRow(old: line, new: line)
            }
        )
    }

    private func visibleRows<Row>(
        _ rows: [Row],
        totalHeight: CGFloat,
        viewportOffset: CGFloat,
        rowHeight: (Row) -> CGFloat,
        expandedRowCount: (Row) -> Int?,
        expandedRow: (Row, Int) -> Row
    ) -> GitDiffVisibleRows<Row> {
        let viewportHeight = max(verticalViewport.height, 680)
        let overscan: CGFloat = 264
        let lowerBound = max(0, viewportOffset - overscan)
        let upperBound = viewportOffset + viewportHeight + overscan

        let expandedLineHeight = lineHeight
        var visibleRows: [Row] = []
        visibleRows.reserveCapacity(Int(ceil((viewportHeight + overscan * 2) / expandedLineHeight)))
        var currentOffset: CGFloat = 0
        var firstVisibleOffset: CGFloat?
        var renderedEnd: CGFloat = 0

        for row in rows {
            if let expandedCount = expandedRowCount(row) {
                let expandedHeight = CGFloat(expandedCount) * expandedLineHeight
                let rowEnd = currentOffset + expandedHeight
                if rowEnd > lowerBound, currentOffset < upperBound {
                    let firstIndex = max(
                        0,
                        min(expandedCount, Int(floor((lowerBound - currentOffset) / expandedLineHeight)))
                    )
                    let endIndex = max(
                        firstIndex,
                        min(expandedCount, Int(ceil((upperBound - currentOffset) / expandedLineHeight)))
                    )
                    if firstIndex < endIndex {
                        firstVisibleOffset = firstVisibleOffset
                            ?? currentOffset + CGFloat(firstIndex) * expandedLineHeight
                        for offset in firstIndex..<endIndex {
                            visibleRows.append(expandedRow(row, offset))
                        }
                        renderedEnd = currentOffset + CGFloat(endIndex) * expandedLineHeight
                    }
                }
                currentOffset = rowEnd
            } else {
                let height = rowHeight(row)
                let rowEnd = currentOffset + height
                if rowEnd > lowerBound, currentOffset < upperBound {
                    firstVisibleOffset = firstVisibleOffset ?? currentOffset
                    visibleRows.append(row)
                    renderedEnd = rowEnd
                }
                currentOffset = rowEnd
            }
            if currentOffset >= upperBound { break }
        }

        return GitDiffVisibleRows(
            leadingHeight: firstVisibleOffset ?? min(totalHeight, lowerBound),
            rows: visibleRows,
            trailingHeight: max(0, totalHeight - renderedEnd)
        )
    }

    private func unifiedRowHeight(_ row: UnifiedRow) -> CGFloat {
        guard case .gap(let gap) = row.content else { return lineHeight }
        return expandedGapIDs.contains(gap.id) ? CGFloat(gap.count) * lineHeight : gapRowHeight
    }

    private func sideRowHeight(_ row: SideRow) -> CGFloat {
        guard let gap = row.gap else { return lineHeight }
        return expandedGapIDs.contains(gap.id) ? CGFloat(gap.count) * lineHeight : gapRowHeight
    }

    private var unifiedVerticalNavigationTargets: [GitDiffVerticalNavigationTarget] {
        let targetIndices = Dictionary(uniqueKeysWithValues:
            renderModel.navigationTargets.enumerated().map { index, target in
                (target.unifiedRowID, index)
            }
        )
        var targets = Array<GitDiffVerticalNavigationTarget?>(
            repeating: nil,
            count: renderModel.navigationTargets.count
        )
        var offset: CGFloat = 0
        for row in renderModel.unifiedRows {
            let height = unifiedRowHeight(row)
            if let targetIndex = targetIndices[row.id] {
                targets[targetIndex] = GitDiffVerticalNavigationTarget(
                    offset: offset,
                    height: height
                )
            }
            offset += height
        }
        return targets.compactMap { $0 }
    }

    private var sideVerticalNavigationTargets: [GitDiffVerticalNavigationTarget] {
        let targetIndices = Dictionary(uniqueKeysWithValues:
            renderModel.navigationTargets.enumerated().map { index, target in
                (target.sideRowID, index)
            }
        )
        var targets = Array<GitDiffVerticalNavigationTarget?>(
            repeating: nil,
            count: renderModel.navigationTargets.count
        )
        var offset: CGFloat = 28
        for row in renderModel.sideRows {
            let height = sideRowHeight(row)
            if let targetIndex = targetIndices[row.id] {
                targets[targetIndex] = GitDiffVerticalNavigationTarget(
                    offset: offset,
                    height: height
                )
            }
            offset += height
        }
        return targets.compactMap { $0 }
    }

    private func navigationTarget(
        at index: Int,
        in targets: [GitDiffVerticalNavigationTarget]
    ) -> GitDiffVerticalNavigationTarget? {
        guard targets.indices.contains(index) else { return nil }
        return targets[index]
    }

    private func gapRow(_ gap: DiffGap) -> some View {
        Button {
            setExpandedGapIDs(expandedGapIDs.union([gap.id]))
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "ellipsis")
                Text("折叠了 \(gap.count) 行未改动内容，点击展开")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: gapRowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityIdentifier("RepoDesk.Diff.Gap.\(gap.id)")
    }

    private func sideGapRow(
        _ gap: DiffGap,
        width: CGFloat,
        side: GitBlameSide
    ) -> some View {
        Button {
            setExpandedGapIDs(expandedGapIDs.union([gap.id]))
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "ellipsis")
                Text("折叠了 \(gap.count) 行未改动内容，点击展开")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(width: width, height: gapRowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityIdentifier("RepoDesk.Diff.Gap.\(gap.id).\(side == .old ? "old" : "new")")
    }

    private func diffHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(width: width, height: 28, alignment: .leading)
            .background(.quaternary)
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: max(9, fontSize - 2), design: .monospaced).monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var effectivePresentation: GitDiffPresentation {
        lockedPresentation ?? presentation
    }

    private func usesSelectableTextOverlay(for pane: GitDiffContentSearchPane) -> Bool {
        let rowCount: Int
        switch pane {
        case .unified:
            rowCount = selectableTextModels.unified.rows.count
        case .old:
            rowCount = selectableTextModels.old.rows.count
        case .new:
            rowCount = selectableTextModels.new.rows.count
        }
        return rowCount <= 12_000
    }

    private var contentSearchMatches: [GitDiffContentSearchMatch] {
        switch effectivePresentation {
        case .unified:
            return ContentSearchMatcher.matches(
                in: selectableTextModels.unified.searchableLines,
                query: contentFindState.query,
                options: contentFindState.options
            ).map { GitDiffContentSearchMatch(pane: .unified, match: $0) }
        case .sideBySide:
            let oldMatches = ContentSearchMatcher.matches(
                in: selectableTextModels.old.searchableLines,
                query: contentFindState.query,
                options: contentFindState.options
            )
            let newMatches = ContentSearchMatcher.matches(
                in: selectableTextModels.new.searchableLines,
                query: contentFindState.query,
                options: contentFindState.options
            )
            let oldByLine = Dictionary(grouping: oldMatches, by: \.lineIndex)
            let newByLine = Dictionary(grouping: newMatches, by: \.lineIndex)
            let rowCount = max(
                selectableTextModels.old.rows.count,
                selectableTextModels.new.rows.count
            )
            return (0..<rowCount).flatMap { lineIndex in
                (oldByLine[lineIndex] ?? []).map {
                    GitDiffContentSearchMatch(pane: .old, match: $0)
                } + (newByLine[lineIndex] ?? []).map {
                    GitDiffContentSearchMatch(pane: .new, match: $0)
                }
            }
        }
    }

    private func contentSearchPresentation(
        for pane: GitDiffContentSearchPane
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
        let matches = contentSearchMatches
        guard let index = contentFindState.activeMatchIndex(matchCount: matches.count) else {
            return nil
        }
        let active = matches[index]
        switch active.pane {
        case .unified:
            return selectableTextModels.unified.navigationTarget(
                forLineAt: active.match.lineIndex
            )
        case .old:
            return selectableTextModels.old.navigationTarget(
                forLineAt: active.match.lineIndex,
                leadingOffset: 28
            )
        case .new:
            return selectableTextModels.new.navigationTarget(
                forLineAt: active.match.lineIndex,
                leadingOffset: 28
            )
        }
    }

    private func presentContentFind() {
        contentFindState.present()
        if !contentFindState.query.isEmpty,
           searchExpandedGapIDsSnapshot == nil {
            searchExpandedGapIDsSnapshot = expandedGapIDs
            setExpandedGapIDs(gapIDs)
        }
    }

    private func dismissContentFind() {
        if let snapshot = searchExpandedGapIDsSnapshot {
            setExpandedGapIDs(snapshot)
        }
        searchExpandedGapIDsSnapshot = nil
        contentFindState.dismiss()
    }

    private func navigateContentFind(by offset: Int) {
        if !contentFindState.isPresented {
            presentContentFind()
        }
        contentFindState.navigate(by: offset, matchCount: contentSearchMatches.count)
    }

    private func updateGapExpansionForSearch(
        previousQuery: String,
        nextQuery: String
    ) {
        if previousQuery.isEmpty, !nextQuery.isEmpty {
            searchExpandedGapIDsSnapshot = expandedGapIDs
            setExpandedGapIDs(gapIDs)
        } else if !previousQuery.isEmpty, nextQuery.isEmpty,
                  let snapshot = searchExpandedGapIDsSnapshot {
            setExpandedGapIDs(snapshot)
            searchExpandedGapIDsSnapshot = nil
        }
    }

    private var gapIDs: Set<String> {
        Set(renderModel.gaps.map(\.id))
    }

    private var gapExpansionAction: GitDiffGapExpansionAction {
        GitDiffGapExpansionAction.resolve(
            gapIDs: gapIDs,
            expandedGapIDs: expandedGapIDs
        )
    }

    private func toggleAllGaps() {
        switch gapExpansionAction {
        case .expandAll:
            setExpandedGapIDs(gapIDs)
        case .collapseAll:
            setExpandedGapIDs([])
        }
    }

    private func setExpandedGapIDs(_ nextGapIDs: Set<String>) {
        guard nextGapIDs != expandedGapIDs else { return }
        viewportAnchorRequestID = UUID()
        expandedGapIDs = nextGapIDs
        refreshSelectableText(for: effectivePresentation)
    }

    private func refreshSelectableText(for presentation: GitDiffPresentation) {
        guard Self.shouldBuildSelectableText(for: renderModel) else {
            selectableTextModels = .empty
            return
        }
        switch presentation {
        case .unified:
            selectableTextModels = GitDiffSelectableTextModels(
                unified: Self.makeUnifiedSelectableText(
                    diff: diff,
                    renderModel: renderModel,
                    expandedGapIDs: expandedGapIDs,
                    fontSize: fontSize,
                    lineHeight: lineHeight,
                    gapHeight: gapRowHeight
                ),
                old: selectableTextModels.old,
                new: selectableTextModels.new
            )
        case .sideBySide:
            selectableTextModels = GitDiffSelectableTextModels(
                unified: selectableTextModels.unified,
                old: Self.makeSideSelectableText(
                    .old,
                    diff: diff,
                    renderModel: renderModel,
                    expandedGapIDs: expandedGapIDs,
                    fontSize: fontSize,
                    lineHeight: lineHeight,
                    gapHeight: gapRowHeight
                ),
                new: Self.makeSideSelectableText(
                    .new,
                    diff: diff,
                    renderModel: renderModel,
                    expandedGapIDs: expandedGapIDs,
                    fontSize: fontSize,
                    lineHeight: lineHeight,
                    gapHeight: gapRowHeight
                )
            )
        }
    }

    private var canNavigateToPreviousHunk: Bool {
        previousHunkIndex != nil
    }

    private var canNavigateToNextHunk: Bool {
        nextHunkIndex != nil
    }

    private var previousHunkIndex: Int? {
        manualNavigationCursor?.previousIndex ?? GitDiffHunkNavigation.adjacentIndex(
            currentIndex: selectedHunkIndex,
            offset: -1,
            targetCount: renderModel.navigationTargets.count
        )
    }

    private var nextHunkIndex: Int? {
        manualNavigationCursor?.nextIndex ?? GitDiffHunkNavigation.adjacentIndex(
            currentIndex: selectedHunkIndex,
            offset: 1,
            targetCount: renderModel.navigationTargets.count
        )
    }

    private func navigateHunk(offset: Int) {
        guard let targetIndex = offset < 0 ? previousHunkIndex : nextHunkIndex else { return }
        manualNavigationCursor = nil
        selectedHunkIndex = targetIndex
        selectedNewLine = renderModel.navigationTargets[targetIndex].newLine
        scrollToSelectedHunk()
    }

    private func scrollToSelectedHunk() {
        guard renderModel.navigationTargets.indices.contains(selectedHunkIndex) else { return }
        scrollRequest = GitDiffScrollRequest()
    }

    private var firstNewLine: Int? {
        renderModel.navigationTargets.first?.newLine
            ?? diff.hunks.first.map { max($0.newStart, 1) }
    }

    private var lineHeight: CGFloat {
        Self.lineHeight(for: fontSize)
    }

    private static func shouldBuildSelectableText(for renderModel: GitDiffRenderModel) -> Bool {
        renderModel.unifiedRows.count <= 12_000
            && renderModel.sideRows.count <= 12_000
    }

    private var gapRowHeight: CGFloat {
        Self.gapHeight(for: fontSize)
    }

    private static func lineHeight(for fontSize: CGFloat) -> CGFloat {
        max(22, ceil(fontSize + 8))
    }

    private static func gapHeight(for fontSize: CGFloat) -> CGFloat {
        max(25, lineHeight(for: fontSize) + 3)
    }

    private func expandedLine(for gap: DiffGap, offset: Int) -> DiffLine {
        Self.expandedLine(in: diff, for: gap, offset: offset)
    }

    private static func expandedLine(
        in diff: GitFileDiff,
        for gap: DiffGap,
        offset: Int
    ) -> DiffLine {
        let oldNumber = gap.oldStart + offset
        let newNumber = gap.newStart + offset
        let text = diff.newLines.indices.contains(newNumber - 1)
            ? diff.newLines[newNumber - 1]
            : (diff.oldLines.indices.contains(oldNumber - 1) ? diff.oldLines[oldNumber - 1] : "")
        return DiffLine(oldNumber: oldNumber, newNumber: newNumber, text: text, kind: .context)
    }
}

@MainActor
struct GitDiffRenderModel {
    fileprivate let requiredUnifiedWidth: CGFloat
    fileprivate let requiredOldPaneWidth: CGFloat
    fileprivate let requiredNewPaneWidth: CGFloat
    fileprivate let gaps: [DiffGap]
    fileprivate let unifiedRows: [UnifiedRow]
    fileprivate let sideRows: [SideRow]
    let navigationTargets: [GitDiffNavigationTarget]

    init(diff: GitFileDiff) {
        requiredUnifiedWidth = GitDiffLayoutMetrics.requiredUnifiedWidth(
            oldLines: diff.oldLines,
            newLines: diff.newLines
        )
        requiredOldPaneWidth = GitDiffLayoutMetrics.requiredSidePaneWidth(lines: diff.oldLines)
        requiredNewPaneWidth = GitDiffLayoutMetrics.requiredSidePaneWidth(lines: diff.newLines)

        var computedGaps: [DiffGap] = []
        var computedUnifiedRows: [UnifiedRow] = []
        var computedSideRows: [SideRow] = []
        var computedNavigationTargets: [GitDiffNavigationTarget] = []
        var previousOldEnd = 1
        var previousNewEnd = 1
        for hunk in diff.hunks {
            let count = min(hunk.oldStart - previousOldEnd, hunk.newStart - previousNewEnd)
            if count > 0 {
                let gap = DiffGap(oldStart: previousOldEnd, newStart: previousNewEnd, count: count)
                computedGaps.append(gap)
                computedUnifiedRows.append(.gap(gap))
                computedSideRows.append(SideRow(gap: gap))
            }
            let lines = Self.hunkLines(hunk)
            let hunkUnifiedRows = lines.map(UnifiedRow.line)
            let hunkSideRows = Self.pairedLines(lines)
            computedUnifiedRows.append(contentsOf: hunkUnifiedRows)
            computedSideRows.append(contentsOf: hunkSideRows)
            computedNavigationTargets.append(contentsOf: Self.navigationTargets(
                lines: lines,
                sideRows: hunkSideRows,
                fallbackNewLine: max(hunk.newStart, 1)
            ))
            previousOldEnd = hunk.oldStart + hunk.oldCount
            previousNewEnd = hunk.newStart + hunk.newCount
        }
        let tailCount = min(
            diff.oldLineCount - previousOldEnd + 1,
            diff.newLineCount - previousNewEnd + 1
        )
        if tailCount > 0 {
            let gap = DiffGap(oldStart: previousOldEnd, newStart: previousNewEnd, count: tailCount)
            computedGaps.append(gap)
            computedUnifiedRows.append(.gap(gap))
            computedSideRows.append(SideRow(gap: gap))
        }
        gaps = computedGaps
        unifiedRows = computedUnifiedRows
        sideRows = computedSideRows
        navigationTargets = computedNavigationTargets
    }

    private static func hunkLines(_ hunk: GitDiffHunk) -> [DiffLine] {
        var oldNumber = hunk.oldStart
        var newNumber = hunk.newStart
        return hunk.lines.map { patchLine in
            let line: DiffLine
            switch patchLine.kind {
            case .context:
                line = DiffLine(
                    oldNumber: oldNumber,
                    newNumber: newNumber,
                    text: patchLine.text,
                    kind: .context
                )
                oldNumber += 1
                newNumber += 1
            case .deletion:
                line = DiffLine(
                    oldNumber: oldNumber,
                    newNumber: nil,
                    text: patchLine.text,
                    kind: .deletion
                )
                oldNumber += 1
            case .addition:
                line = DiffLine(
                    oldNumber: nil,
                    newNumber: newNumber,
                    text: patchLine.text,
                    kind: .addition
                )
                newNumber += 1
            }
            return line
        }
    }

    private static func pairedLines(_ lines: [DiffLine]) -> [SideRow] {
        var rows: [SideRow] = []
        var index = 0
        while index < lines.count {
            if lines[index].kind == .context {
                rows.append(SideRow(old: lines[index], new: lines[index]))
                index += 1
                continue
            }
            var deletions: [DiffLine] = []
            var additions: [DiffLine] = []
            while index < lines.count, lines[index].kind != .context {
                if lines[index].kind == .deletion { deletions.append(lines[index]) }
                if lines[index].kind == .addition { additions.append(lines[index]) }
                index += 1
            }
            for offset in 0..<max(deletions.count, additions.count) {
                rows.append(
                    SideRow(
                        old: deletions.indices.contains(offset) ? deletions[offset] : nil,
                        new: additions.indices.contains(offset) ? additions[offset] : nil
                    )
                )
            }
        }
        return rows
    }

    private static func navigationTargets(
        lines: [DiffLine],
        sideRows: [SideRow],
        fallbackNewLine: Int
    ) -> [GitDiffNavigationTarget] {
        var sideRowIDByLineID: [String: String] = [:]
        sideRowIDByLineID.reserveCapacity(lines.count)
        for row in sideRows {
            if let oldLineID = row.old?.id { sideRowIDByLineID[oldLineID] = row.id }
            if let newLineID = row.new?.id { sideRowIDByLineID[newLineID] = row.id }
        }

        var targets: [GitDiffNavigationTarget] = []
        var index = 0
        while index < lines.count {
            while index < lines.count, lines[index].kind == .context { index += 1 }
            guard index < lines.count else { break }

            let changeStart = index
            while index < lines.count, lines[index].kind != .context { index += 1 }
            let changeLines = lines[changeStart..<index]
            guard let targetLine = changeLines.first,
                  let sideRowID = sideRowIDByLineID[targetLine.id] else {
                continue
            }
            let newLine = changeLines.lazy.compactMap(\.newNumber).first
                ?? lines[index...].lazy.compactMap(\.newNumber).first
                ?? lines[..<changeStart].lazy.compactMap(\.newNumber).last
                ?? fallbackNewLine
            targets.append(
                GitDiffNavigationTarget(
                    unifiedRowID: targetLine.id,
                    sideRowID: sideRowID,
                    newLine: newLine
                )
            )
        }
        return targets
    }
}

fileprivate struct DiffGap: Identifiable {
    let oldStart: Int
    let newStart: Int
    let count: Int
    var id: String { "gap:\(oldStart):\(newStart):\(count)" }
}

fileprivate struct DiffLine: Identifiable {
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
    let kind: GitPatchLineKind

    var id: String { "line:\(oldNumber ?? -1):\(newNumber ?? -1):\(kind):\(text)" }
    var prefix: String { kind == .addition ? "+" : (kind == .deletion ? "−" : " ") }
    var foreground: Color { kind == .addition ? .green : (kind == .deletion ? .red : .secondary) }
    var background: Color {
        kind == .addition ? Color.green.opacity(0.11) : (kind == .deletion ? Color.red.opacity(0.10) : .clear)
    }
}

fileprivate struct UnifiedRow: Identifiable {
    enum Content {
        case gap(DiffGap)
        case line(DiffLine)
    }

    let content: Content
    var id: String {
        switch content {
        case .gap(let gap): gap.id
        case .line(let line): line.id
        }
    }

    static func gap(_ gap: DiffGap) -> Self { Self(content: .gap(gap)) }
    static func line(_ line: DiffLine) -> Self { Self(content: .line(line)) }
}

fileprivate struct SideRow: Identifiable {
    let old: DiffLine?
    let new: DiffLine?
    let gap: DiffGap?

    init(old: DiffLine? = nil, new: DiffLine? = nil, gap: DiffGap? = nil) {
        self.old = old
        self.new = new
        self.gap = gap
    }

    init(gap: DiffGap) {
        old = nil
        new = nil
        self.gap = gap
    }

    var id: String { gap?.id ?? "side:\(old?.id ?? ""):\(new?.id ?? "")" }
}

struct GitDiffVerticalNavigationTarget: Equatable {
    let offset: CGFloat
    let height: CGFloat
}

struct GitDiffVerticalViewport: Equatable {
    let offset: CGFloat
    let height: CGFloat

    static let zero = GitDiffVerticalViewport(offset: 0, height: 0)
}

private struct GitDiffViewportAnchor {
    let targetIndex: Int
    let viewportOffset: CGFloat
}

private struct GitDiffVisibleRows<Row> {
    let leadingHeight: CGFloat
    let rows: [Row]
    let trailingHeight: CGFloat
}

private struct GitDiffSelectableTextModels {
    let unified: GitDiffSelectableTextModel
    let old: GitDiffSelectableTextModel
    let new: GitDiffSelectableTextModel

    static let empty = GitDiffSelectableTextModels(
        unified: GitDiffSelectableTextModel(rows: []),
        old: GitDiffSelectableTextModel(rows: []),
        new: GitDiffSelectableTextModel(rows: [])
    )
}

struct GitDiffScrollRequest: Equatable {
    let id = UUID()
}

@MainActor
final class GitDiffHorizontalScrollSynchronization {
    private final class Entry {
        weak var scrollView: NSScrollView?
        var contentWidth: CGFloat

        init(scrollView: NSScrollView, contentWidth: CGFloat) {
            self.scrollView = scrollView
            self.contentWidth = contentWidth
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var currentOffset: CGFloat = 0
    private var isSynchronizing = false

    func register(_ scrollView: NSScrollView, contentWidth: CGFloat) {
        removeReleasedScrollViews()
        entries[ObjectIdentifier(scrollView)] = Entry(
            scrollView: scrollView,
            contentWidth: contentWidth
        )
        synchronize(to: currentOffset)
    }

    func unregister(_ scrollView: NSScrollView) {
        entries.removeValue(forKey: ObjectIdentifier(scrollView))
    }

    func didScroll(_ scrollView: NSScrollView) {
        guard !isSynchronizing else { return }
        if entries[ObjectIdentifier(scrollView)] == nil {
            entries[ObjectIdentifier(scrollView)] = Entry(
                scrollView: scrollView,
                contentWidth: scrollView.documentView?.bounds.width ?? 0
            )
        }
        synchronize(to: scrollView.contentView.bounds.origin.x)
    }

    func reset() {
        synchronize(to: 0)
    }

    private func synchronize(to requestedOffset: CGFloat) {
        removeReleasedScrollViews()
        let activeEntries = entries.values.compactMap { entry -> (Entry, NSScrollView)? in
            guard let scrollView = entry.scrollView else { return nil }
            return (entry, scrollView)
        }
        guard !activeEntries.isEmpty else {
            currentOffset = max(0, requestedOffset)
            return
        }

        let sharedMaximumOffset = activeEntries.map { entry, scrollView in
            max(0, entry.contentWidth - scrollView.contentView.bounds.width)
        }.max() ?? 0
        let synchronizedOffset = min(max(0, requestedOffset), sharedMaximumOffset)
        currentOffset = synchronizedOffset
        isSynchronizing = true
        defer { isSynchronizing = false }
        for (entry, scrollView) in activeEntries {
            if let documentView = scrollView.documentView {
                let synchronizedDocumentWidth = max(
                    entry.contentWidth,
                    scrollView.contentView.bounds.width + sharedMaximumOffset
                )
                if abs(documentView.frame.width - synchronizedDocumentWidth) >= 0.5 {
                    documentView.setFrameSize(NSSize(
                        width: synchronizedDocumentWidth,
                        height: documentView.frame.height
                    ))
                }
            }
            guard abs(scrollView.contentView.bounds.origin.x - synchronizedOffset) >= 0.5 else {
                continue
            }
            scrollView.contentView.scroll(
                to: NSPoint(
                    x: synchronizedOffset,
                    y: scrollView.contentView.bounds.origin.y
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func removeReleasedScrollViews() {
        entries = entries.filter { $0.value.scrollView != nil }
    }
}

private final class GitDiffHorizontalDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class GitDiffHorizontalScrollViewContainer: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let horizontalDelta = abs(event.scrollingDeltaX)
        let verticalDelta = abs(event.scrollingDeltaY)
        guard verticalDelta > 0,
              verticalDelta >= horizontalDelta,
              let verticalScrollView = enclosingVerticalScrollView() else {
            super.scrollWheel(with: event)
            return
        }
        verticalScrollView.scrollWheel(with: event)
    }

    func enclosingVerticalScrollView() -> NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView,
               scrollView !== self,
               scrollView.hasVerticalScroller {
                return scrollView
            }
            ancestor = view.superview
        }
        return nil
    }
}

@MainActor
struct GitDiffHorizontalScrollView<Content: View>: NSViewRepresentable {
    let identifier: String
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let synchronization: GitDiffHorizontalScrollSynchronization?
    let content: Content

    init(
        identifier: String,
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        synchronization: GitDiffHorizontalScrollSynchronization? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.identifier = identifier
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.synchronization = synchronization
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = GitDiffHorizontalScrollViewContainer(frame: .zero)
        scrollView.identifier = NSUserInterfaceItemIdentifier(identifier)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.contentView.postsBoundsChangedNotifications = synchronization != nil

        let hostingView = NSHostingView(rootView: hostedContent)
        hostingView.sizingOptions = []
        let documentView = GitDiffHorizontalDocumentView(frame: NSRect(
            x: 0,
            y: 0,
            width: max(1, contentWidth),
            height: max(1, contentHeight)
        ))
        documentView.addSubview(hostingView)
        scrollView.documentView = documentView
        context.coordinator.hostingView = hostingView
        context.coordinator.documentView = documentView
        if let synchronization {
            context.coordinator.observe(
                scrollView.contentView,
                synchronization: synchronization
            )
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = context.coordinator.hostingView,
              let documentView = context.coordinator.documentView else { return }
        if let synchronization {
            scrollView.contentView.postsBoundsChangedNotifications = true
            context.coordinator.observe(
                scrollView.contentView,
                synchronization: synchronization
            )
        } else {
            scrollView.contentView.postsBoundsChangedNotifications = false
            context.coordinator.stopObserving()
            context.coordinator.synchronization = nil
        }
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        let horizontalOffset = scrollView.contentView.bounds.origin.x
        hostingView.rootView = hostedContent
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(1, contentWidth),
            height: max(1, contentHeight)
        )
        documentView.frame = hostingView.frame
        hostingView.layoutSubtreeIfNeeded()

        let maximumOffset = max(0, contentWidth - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(
            to: NSPoint(
                x: min(max(0, horizontalOffset), maximumOffset),
                y: scrollView.contentView.bounds.origin.y
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        synchronization?.register(scrollView, contentWidth: contentWidth)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
        coordinator.synchronization?.unregister(scrollView)
    }

    @MainActor
    final class Coordinator: NSObject {
        var hostingView: NSHostingView<AnyView>?
        fileprivate weak var documentView: GitDiffHorizontalDocumentView?
        fileprivate var synchronization: GitDiffHorizontalScrollSynchronization?
        private weak var observedClipView: NSClipView?
        fileprivate var isUpdating = false

        func observe(
            _ clipView: NSClipView,
            synchronization: GitDiffHorizontalScrollSynchronization?
        ) {
            self.synchronization = synchronization
            guard observedClipView !== clipView else { return }
            stopObserving()
            observedClipView = clipView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        func stopObserving() {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            observedClipView = nil
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard !isUpdating,
                  let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView else { return }
            synchronization?.didScroll(scrollView)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    private var hostedContent: AnyView {
        AnyView(
            ZStack(alignment: .topLeading) {
                Color.clear.frame(
                    width: max(1, contentWidth),
                    height: max(1, contentHeight)
                )
                content
            }
            .frame(
                width: max(1, contentWidth),
                height: max(1, contentHeight),
                alignment: .topLeading
            )
        )
    }
}

@MainActor
struct GitDiffVerticalScrollView<Content: View>: NSViewRepresentable {
    let identifier: String
    let contentHeight: CGFloat
    let requestID: UUID?
    let target: GitDiffVerticalNavigationTarget?
    @Binding var viewport: GitDiffVerticalViewport
    let navigationTargetCenters: [CGFloat]
    let viewportAnchorRequestID: UUID?
    @Binding var manualNavigationCursor: GitDiffHunkNavigationCursor?
    let content: Content

    init(
        identifier: String,
        contentHeight: CGFloat,
        requestID: UUID?,
        target: GitDiffVerticalNavigationTarget?,
        viewport: Binding<GitDiffVerticalViewport>,
        navigationTargetCenters: [CGFloat],
        viewportAnchorRequestID: UUID? = nil,
        manualNavigationCursor: Binding<GitDiffHunkNavigationCursor?>,
        @ViewBuilder content: () -> Content
    ) {
        self.identifier = identifier
        self.contentHeight = contentHeight
        self.requestID = requestID
        self.target = target
        _viewport = viewport
        self.navigationTargetCenters = navigationTargetCenters
        self.viewportAnchorRequestID = viewportAnchorRequestID
        _manualNavigationCursor = manualNavigationCursor
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.identifier = NSUserInterfaceItemIdentifier(identifier)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true

        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width]
        scrollView.documentView = hostingView
        context.coordinator.hostingView = hostingView
        context.coordinator.observe(scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = context.coordinator.hostingView else { return }
        let viewportBinding = $viewport
        let manualNavigationCursorBinding = $manualNavigationCursor
        context.coordinator.onViewportChange = { nextViewport in
            guard viewportBinding.wrappedValue != nextViewport else { return }
            viewportBinding.wrappedValue = nextViewport
        }
        let viewportAnchor = context.coordinator.captureViewportAnchor(
            requestID: viewportAnchorRequestID,
            bounds: scrollView.contentView.bounds,
            documentView: hostingView
        )
        context.coordinator.configureNavigation(
            targetCenters: navigationTargetCenters,
            currentCursor: manualNavigationCursor
        ) { nextCursor in
            guard manualNavigationCursorBinding.wrappedValue != nextCursor else { return }
            manualNavigationCursorBinding.wrappedValue = nextCursor
        }
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        hostingView.rootView = content
        resizeDocument(hostingView, in: scrollView)
        if let viewportAnchor {
            context.coordinator.performProgrammaticScroll {
                scroll(
                    preserving: viewportAnchor,
                    targetCenters: navigationTargetCenters,
                    in: scrollView,
                    documentView: hostingView
                )
            }
        }
        context.coordinator.publish(
            scrollView.contentView.bounds,
            isManual: manualNavigationCursor != nil
        )

        if !context.coordinator.didSetInitialPosition {
            context.coordinator.didSetInitialPosition = true
            DispatchQueue.main.async {
                context.coordinator.performProgrammaticScroll {
                    resizeDocument(hostingView, in: scrollView)
                    scroll(toTopIn: scrollView, documentView: hostingView)
                }
            }
        }

        guard let requestID,
              let target,
              context.coordinator.lastRequestID != requestID else { return }
        context.coordinator.lastRequestID = requestID
        DispatchQueue.main.async {
            context.coordinator.performProgrammaticScroll {
                resizeDocument(hostingView, in: scrollView)
                scroll(to: target, in: scrollView, documentView: hostingView)
            }
        }
    }

    private func resizeDocument(_ hostingView: NSHostingView<Content>, in scrollView: NSScrollView) {
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(1, scrollView.contentSize.width),
            height: max(1, contentHeight)
        )
        hostingView.layoutSubtreeIfNeeded()
    }

    private func scroll(
        to target: GitDiffVerticalNavigationTarget,
        in scrollView: NSScrollView,
        documentView: NSView
    ) {
        let viewportHeight = scrollView.contentView.bounds.height
        let maximumOffset = max(0, documentView.bounds.height - viewportHeight)
        let centeredOffset = target.offset - max(0, (viewportHeight - target.height) / 2)
        let clampedOffset = min(max(0, centeredOffset), maximumOffset)
        let verticalOffset = documentView.isFlipped
            ? clampedOffset
            : maximumOffset - clampedOffset
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: verticalOffset
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scroll(
        preserving anchor: GitDiffViewportAnchor,
        targetCenters: [CGFloat],
        in scrollView: NSScrollView,
        documentView: NSView
    ) {
        guard targetCenters.indices.contains(anchor.targetIndex) else { return }
        let viewportHeight = scrollView.contentView.bounds.height
        let maximumOffset = max(0, documentView.bounds.height - viewportHeight)
        let requestedTopOffset = targetCenters[anchor.targetIndex] - anchor.viewportOffset
        let clampedTopOffset = min(max(0, requestedTopOffset), maximumOffset)
        let verticalOffset = documentView.isFlipped
            ? clampedTopOffset
            : maximumOffset - clampedTopOffset
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: verticalOffset
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scroll(toTopIn scrollView: NSScrollView, documentView: NSView) {
        let maximumOffset = max(
            0,
            documentView.bounds.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: documentView.isFlipped ? 0 : maximumOffset
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @MainActor
    final class Coordinator: NSObject {
        var hostingView: NSHostingView<Content>?
        var lastRequestID: UUID?
        var didSetInitialPosition = false
        var onViewportChange: ((GitDiffVerticalViewport) -> Void)?
        var isUpdating = false
        private var observedClipView: NSClipView?
        private var lastPublishedViewport: GitDiffVerticalViewport?
        private var navigationTargetCenters: [CGFloat] = []
        private var onManualNavigationCursorChange: ((GitDiffHunkNavigationCursor) -> Void)?
        private var lastPublishedManualNavigationCursor: GitDiffHunkNavigationCursor?
        private var isProgrammaticallyScrolling = false
        private var lastViewportAnchorRequestID: UUID?

        fileprivate func captureViewportAnchor(
            requestID: UUID?,
            bounds: NSRect,
            documentView: NSView
        ) -> GitDiffViewportAnchor? {
            guard let requestID,
                  requestID != lastViewportAnchorRequestID else { return nil }
            lastViewportAnchorRequestID = requestID
            guard !navigationTargetCenters.isEmpty else { return nil }

            let maximumOffset = max(0, documentView.bounds.height - bounds.height)
            let topOffset = documentView.isFlipped
                ? bounds.origin.y
                : maximumOffset - bounds.origin.y
            let viewportCenter = topOffset + bounds.height / 2
            guard let targetIndex = navigationTargetCenters.indices.min(by: {
                abs(navigationTargetCenters[$0] - viewportCenter)
                    < abs(navigationTargetCenters[$1] - viewportCenter)
            }) else { return nil }
            return GitDiffViewportAnchor(
                targetIndex: targetIndex,
                viewportOffset: navigationTargetCenters[targetIndex] - topOffset
            )
        }

        func configureNavigation(
            targetCenters: [CGFloat],
            currentCursor: GitDiffHunkNavigationCursor?,
            onChange: @escaping (GitDiffHunkNavigationCursor) -> Void
        ) {
            if navigationTargetCenters != targetCenters || currentCursor == nil {
                lastPublishedManualNavigationCursor = nil
            }
            navigationTargetCenters = targetCenters
            onManualNavigationCursorChange = onChange
        }

        func performProgrammaticScroll(_ action: () -> Void) {
            isProgrammaticallyScrolling = true
            defer { isProgrammaticallyScrolling = false }
            action()
        }

        func observe(_ clipView: NSClipView) {
            guard observedClipView !== clipView else { return }
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            observedClipView = clipView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            publish(
                clipView.bounds,
                isManual: !isUpdating && !isProgrammaticallyScrolling
            )
        }

        func publish(_ bounds: NSRect, isManual: Bool) {
            let quantum: CGFloat = 220
            let nextViewport = GitDiffVerticalViewport(
                offset: floor(max(0, bounds.origin.y) / quantum) * quantum,
                height: max(1, bounds.height)
            )
            let viewportChanged = nextViewport != lastPublishedViewport
            let shouldRefreshCursor = isManual
                && (viewportChanged || lastPublishedManualNavigationCursor == nil)
            guard viewportChanged || shouldRefreshCursor else { return }
            if viewportChanged {
                lastPublishedViewport = nextViewport
            }
            let nextCursor: GitDiffHunkNavigationCursor? = if shouldRefreshCursor {
                GitDiffHunkNavigation.cursor(
                    viewportOffset: bounds.origin.y,
                    viewportHeight: bounds.height,
                    targetCenters: navigationTargetCenters
                )
            } else {
                nil
            }
            let shouldPublishCursor = nextCursor != nil
                && nextCursor != lastPublishedManualNavigationCursor
            if shouldPublishCursor {
                lastPublishedManualNavigationCursor = nextCursor
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if viewportChanged {
                    self.onViewportChange?(nextViewport)
                }
                if shouldPublishCursor, let nextCursor {
                    self.onManualNavigationCursorChange?(nextCursor)
                }
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
