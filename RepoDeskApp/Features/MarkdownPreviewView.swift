import AppKit
import SwiftUI

@MainActor
struct MarkdownDocumentView: View {
    let text: String
    let fileName: String
    let fontSize: Double
    let headerActions: DocumentHeaderActions
    @State private var contentFindState = ContentFindState()

    private var blocks: [MarkdownPreviewBlock] {
        MarkdownPreviewParser.parse(text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
                Text(fileName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text("预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                headerActions
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            if contentFindState.isPresented {
                ContentFindBar(
                    state: $contentFindState,
                    matchCount: searchMatches.count,
                    dismiss: { contentFindState.dismiss() }
                )
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            MarkdownBlockView(
                                block: block,
                                baseFontSize: fontSize,
                                search: searchPresentation(forBlockAt: index)
                            )
                            .id(index)
                        }
                    }
                    .repoDeskFontSize(fontSize)
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: contentFindState.navigationRequestID) { _, _ in
                    scrollToActiveMatch(using: proxy)
                }
            }
        }
        .background(ContentFindCommandListener(
            requestFind: { contentFindState.present() },
            navigateMatch: navigateContentFind
        ))
        .onChange(of: text) { _, _ in
            guard contentFindState.isPresented else { return }
            contentFindState.resetSelection()
        }
    }

    private var searchMatches: [MarkdownPreviewSearchMatch] {
        return blocks.enumerated().flatMap { blockIndex, block in
            searchableSegments(in: block).enumerated().flatMap { segmentIndex, segment in
                ContentSearchMatcher.matches(
                    in: segment,
                    query: contentFindState.query,
                    options: contentFindState.options
                ).map {
                    MarkdownPreviewSearchMatch(
                        blockIndex: blockIndex,
                        segmentIndex: segmentIndex,
                        range: $0.range
                    )
                }
            }
        }
    }

    private func searchPresentation(
        forBlockAt blockIndex: Int
    ) -> [Int: MarkdownTextSearchPresentation] {
        let matches = searchMatches
        let activeIndex = contentFindState.activeMatchIndex(matchCount: matches.count)
        let activeMatch = activeIndex.map { matches[$0] }
        return Dictionary(grouping: matches.filter { $0.blockIndex == blockIndex }, by: \.segmentIndex)
            .mapValues { segmentMatches in
                MarkdownTextSearchPresentation(
                    ranges: segmentMatches.map(\.range),
                    activeRange: activeMatch.flatMap { active in
                        active.blockIndex == blockIndex
                            && active.segmentIndex == segmentMatches[0].segmentIndex
                            ? active.range
                            : nil
                    }
                )
            }
    }

    private func scrollToActiveMatch(using proxy: ScrollViewProxy) {
        let matches = searchMatches
        guard let index = contentFindState.activeMatchIndex(matchCount: matches.count) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(matches[index].blockIndex, anchor: .center)
        }
    }

    private func navigateContentFind(by offset: Int) {
        if !contentFindState.isPresented {
            contentFindState.present()
        }
        contentFindState.navigate(by: offset, matchCount: searchMatches.count)
    }

    @MainActor
    private func searchableSegments(in block: MarkdownPreviewBlock) -> [String] {
        switch block {
        case .heading(_, let text), .paragraph(let text), .blockQuote(let text):
            return [markdownPlainText(text)]
        case .listItem(let item):
            return [markdownPlainText(item.text)]
        case .codeBlock(_, let code):
            return [code]
        case .thematicBreak:
            return []
        case .table(let headers, let rows):
            return (headers + rows.flatMap { $0 }).map { markdownPlainText($0) }
        }
    }
}

private struct MarkdownPreviewSearchMatch {
    let blockIndex: Int
    let segmentIndex: Int
    let range: NSRange
}

private struct MarkdownTextSearchPresentation {
    let ranges: [NSRange]
    let activeRange: NSRange?
}

private struct MarkdownBlockView: View {
    let block: MarkdownPreviewBlock
    let baseFontSize: Double
    let search: [Int: MarkdownTextSearchPresentation]

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownInlineText(source: text, search: search[0])
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .textSelection(.enabled)
                .padding(.top, level == 1 ? 4 : 12)
                .padding(.bottom, level <= 2 ? 10 : 6)
        case .paragraph(let text):
            MarkdownInlineText(source: text, search: search[0])
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.bottom, 12)
        case .listItem(let item):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                listMarker(item.marker)
                    .frame(width: 24, alignment: .trailing)
                MarkdownInlineText(source: item.text, search: search[0])
                    .lineSpacing(3)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(item.depth) * 20)
            .padding(.bottom, 5)
        case .blockQuote(let text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                MarkdownInlineText(source: text, search: search[0])
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.07))
            .padding(.bottom, 12)
        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                }
                ScrollView(.horizontal) {
                    Text(highlightedText(code, search: search[0], parsesMarkdown: false))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.09))
            .clipShape(.rect(cornerRadius: 5))
            .padding(.bottom, 14)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 14)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows, search: search)
                .padding(.bottom, 16)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        let defaultSize: CGFloat = switch level {
        case 1: 28
        case 2: 23
        case 3: 19
        case 4: 17
        default: 15
        }
        return max(10, defaultSize + CGFloat(baseFontSize - RepoDeskFontSize.default))
    }

    @ViewBuilder
    private func listMarker(_ marker: MarkdownPreviewListItem.Marker) -> some View {
        switch marker {
        case .unordered:
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
        case .ordered(let number):
            Text("\(number).")
                .font(.body.monospacedDigit())
        case .task(let isChecked):
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let search: [Int: MarkdownTextSearchPresentation]

    private var columnCount: Int {
        max(1, max(headers.count, rows.map(\.count).max() ?? 0))
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true, segmentOffset: 0)
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    tableRow(
                        row,
                        isHeader: false,
                        segmentOffset: headers.count + rows.prefix(rowIndex).reduce(0) { $0 + $1.count }
                    )
                }
            }
        }
    }

    private func tableRow(
        _ cells: [String],
        isHeader: Bool,
        segmentOffset: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { index in
                MarkdownInlineText(
                    source: index < cells.count ? cells[index] : "",
                    search: index < cells.count ? search[segmentOffset + index] : nil
                )
                    .font(isHeader ? .body.weight(.semibold) : .body)
                    .textSelection(.enabled)
                    .frame(width: 180, alignment: .leading)
                    .padding(8)
                    .background(isHeader ? Color.secondary.opacity(0.11) : Color.clear)
                    .overlay {
                        Rectangle()
                            .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                    }
            }
        }
    }
}

private struct MarkdownInlineText: View {
    let source: String
    let search: MarkdownTextSearchPresentation?

    var body: some View {
        Text(highlightedText(source, search: search, parsesMarkdown: true))
    }
}

@MainActor
private func markdownPlainText(_ source: String) -> String {
    guard let attributed = try? AttributedString(markdown: source) else { return source }
    return String(attributed.characters)
}

@MainActor
private func highlightedText(
    _ source: String,
    search: MarkdownTextSearchPresentation?,
    parsesMarkdown: Bool
) -> AttributedString {
    let attributed = parsesMarkdown
        ? ((try? AttributedString(markdown: source)) ?? AttributedString(source))
        : AttributedString(source)
    guard let search else { return attributed }
    let highlighted = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
    let length = highlighted.length

    for range in search.ranges where isValidHighlightRange(range, length: length) {
        highlighted.addAttribute(
            .backgroundColor,
            value: NSColor.systemYellow.withAlphaComponent(0.34),
            range: range
        )
    }
    if let activeRange = search.activeRange,
       isValidHighlightRange(activeRange, length: length) {
        highlighted.addAttribute(
            .backgroundColor,
            value: NSColor.systemOrange.withAlphaComponent(0.55),
            range: activeRange
        )
    }
    return AttributedString(highlighted)
}

private func isValidHighlightRange(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
        && range.location <= length
        && range.length <= length - range.location
}
