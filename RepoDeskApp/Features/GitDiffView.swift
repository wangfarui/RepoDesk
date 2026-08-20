import SwiftUI

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
    private let renderModel: GitDiffRenderModel

    @State private var expandedGapIDs: Set<String> = []
    @State private var selectedNewLine: Int?

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
        self.renderModel = renderModel ?? GitDiffRenderModel(diff: diff)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
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
                case .sideBySide:
                    sideBySideView
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: diff) { _, _ in
            expandedGapIDs = []
            selectedNewLine = firstNewLine
        }
        .onAppear { selectedNewLine = firstNewLine }
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
            Menu("未改动片段", systemImage: "arrow.up.and.down.text.horizontal") {
                Button("展开全部未改动片段") {
                    expandedGapIDs = Set(renderModel.gaps.map(\.id))
                }
                Button("折叠未改动片段") {
                    expandedGapIDs = []
                }
            }
            .labelStyle(.iconOnly)
            .help("展开或折叠未改动片段")
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
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(renderModel.unifiedRows) { row in
                        switch row.content {
                        case .gap(let gap):
                            gapRow(gap)
                        case .line(let line):
                            unifiedLine(line)
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .frame(minHeight: geometry.size.height, alignment: .topLeading)
            }
            .accessibilityIdentifier("RepoDesk.UnifiedDiffScroll")
            .scrollIndicators(.visible, axes: .horizontal)
        }
    }

    private var sideBySideView: some View {
        GeometryReader { geometry in
            let contentHeight = max(geometry.size.height, sideBySideContentHeight)
            ScrollView(.vertical) {
                HSplitView {
                    sidePane(side: .old, height: contentHeight)
                        .frame(minWidth: GitDiffLayoutMetrics.minimumSidePaneWidth)
                    sidePane(side: .new, height: contentHeight)
                        .frame(minWidth: GitDiffLayoutMetrics.minimumSidePaneWidth)
                }
                .frame(width: geometry.size.width, height: contentHeight)
            }
            .accessibilityIdentifier("RepoDesk.SideBySideDiffVerticalScroll")
            .scrollIndicators(.visible, axes: .vertical)
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
            VStack(spacing: 0) {
                diffHeader(
                    side == .old ? diff.oldLabel : diff.newLabel,
                    width: geometry.size.width
                )
                HStack(alignment: .top, spacing: 0) {
                    if blameIsVisible(side) {
                        blameColumn(side: side)
                            .frame(width: blameWidth)
                            .contextMenu { blameContextMenu(side) }
                    }
                    ScrollView(.horizontal) {
                        sideCodeColumn(side: side, width: codeContentWidth)
                            .contextMenu { blameContextMenu(side) }
                    }
                    .frame(width: codeViewportWidth, alignment: .leading)
                    .scrollIndicators(.visible, axes: .horizontal)
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .topLeading)
        }
        .frame(height: height)
    }

    private func sideCodeColumn(side: GitBlameSide, width: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(renderModel.sideRows) { row in
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
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func blameColumn(side: GitBlameSide) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(renderModel.sideRows) { row in
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
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
    }

    @ViewBuilder
    private func blameGapRows(_ gap: DiffGap, side: GitBlameSide) -> some View {
        if expandedGapIDs.contains(gap.id) {
            ForEach(expandedLines(for: gap)) { line in
                blameCell(blameLine(for: line, side: side))
            }
        } else {
            Color.clear.frame(width: 226, height: 25)
        }
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
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .frame(minHeight: 22)
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
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 22)
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
        .frame(minHeight: 22)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
    }

    private static let blameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy/MM/dd"
        return formatter
    }()

    private var sideBySideContentHeight: CGFloat {
        28 + renderModel.sideRows.reduce(CGFloat.zero) { height, row in
            guard let gap = row.gap else { return height + 22 }
            return height + (expandedGapIDs.contains(gap.id) ? CGFloat(gap.count) * 22 : 25)
        }
    }

    private func gapRow(_ gap: DiffGap) -> some View {
        Group {
            if expandedGapIDs.contains(gap.id) {
                ForEach(expandedLines(for: gap)) { line in
                    unifiedLine(line)
                }
            } else {
                Button {
                    expandedGapIDs.insert(gap.id)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "ellipsis")
                        Text("折叠了 \(gap.count) 行未改动内容，点击展开")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 25)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.06))
            }
        }
    }

    private func sideGapRow(
        _ gap: DiffGap,
        width: CGFloat,
        side: GitBlameSide
    ) -> some View {
        Group {
            if expandedGapIDs.contains(gap.id) {
                ForEach(expandedLines(for: gap)) { line in
                    sideCell(line, width: width, side: side)
                }
            } else {
                Button {
                    expandedGapIDs.insert(gap.id)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "ellipsis")
                        Text("折叠了 \(gap.count) 行未改动内容，点击展开")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(width: width, height: 25, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.06))
            }
        }
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
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var effectivePresentation: GitDiffPresentation {
        lockedPresentation ?? presentation
    }

    private var firstNewLine: Int? {
        diff.hunks.first.map { max($0.newStart, 1) }
    }

    private func expandedLines(for gap: DiffGap) -> [DiffLine] {
        (0..<gap.count).map { offset in
            let oldNumber = gap.oldStart + offset
            let newNumber = gap.newStart + offset
            let text = diff.newLines.indices.contains(newNumber - 1)
                ? diff.newLines[newNumber - 1]
                : (diff.oldLines.indices.contains(oldNumber - 1) ? diff.oldLines[oldNumber - 1] : "")
            return DiffLine(oldNumber: oldNumber, newNumber: newNumber, text: text, kind: .context)
        }
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
            computedUnifiedRows.append(contentsOf: lines.map(UnifiedRow.line))
            computedSideRows.append(contentsOf: Self.pairedLines(lines))
            previousOldEnd = hunk.oldStart + hunk.oldCount
            previousNewEnd = hunk.newStart + hunk.newCount
        }
        let tailCount = min(
            diff.oldLines.count - previousOldEnd + 1,
            diff.newLines.count - previousNewEnd + 1
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
