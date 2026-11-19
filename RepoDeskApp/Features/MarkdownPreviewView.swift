import AppKit
import SwiftUI
import WebKit

@MainActor
struct MarkdownDocumentView: View {
    let text: String
    let fileURL: URL
    let projectRootURL: URL?
    let fontSize: Double
    let sourceLine: Int
    let navigationRequest: NativeTextNavigationRequest?
    let headerActions: DocumentHeaderActions
    let onVisibleLineChange: (Int) -> Void
    let onNavigationHandled: (UUID) -> Void
    let onOpenFile: (URL, Int?) -> Void
    @State private var contentFindState = ContentFindState()
    @State private var searchMatches: [ContentSearchMatch] = []
    @State private var fileLinkError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
                Text(fileURL.lastPathComponent)
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

            MarkdownPreviewTextView(
                document: previewDocument,
                contentSearch: contentSearchPresentation,
                focusRequestID: contentFindState.contentFocusRequestID,
                sourceLine: sourceLine,
                navigationRequest: navigationRequest,
                onVisibleLineChange: onVisibleLineChange,
                onNavigationHandled: onNavigationHandled,
                onFileLinkActivated: openFileLink
            )
            .id(fileURL)
        }
        .alert("无法打开文件链接", isPresented: Binding(
            get: { fileLinkError != nil },
            set: { if !$0 { fileLinkError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(fileLinkError ?? "")
        }
        .background(ContentFindCommandListener(
            requestFind: { contentFindState.present() },
            navigateMatch: navigateContentFind
        ))
        .onAppear {
            rebuildSearchMatches()
        }
        .onChange(of: text) { _, _ in
            rebuildSearchMatches()
            guard contentFindState.isPresented else { return }
            contentFindState.resetSelection()
        }
        .onChange(of: contentFindState.isPresented) { _, _ in
            rebuildSearchMatches()
        }
        .onChange(of: contentFindState.query) { _, _ in
            rebuildSearchMatches()
        }
        .onChange(of: contentFindState.options) { _, _ in
            rebuildSearchMatches()
        }
    }

    private var blocks: [MarkdownPreviewParsedBlock] {
        MarkdownPreviewParser.parseWithSourceLines(text)
    }

    private var previewDocument: MarkdownPreviewHTMLDocument {
        MarkdownPreviewHTMLDocument(blocks: blocks, fontSize: fontSize)
    }

    private var contentSearchPresentation: ContentSearchPresentation? {
        guard contentFindState.isPresented else { return nil }
        let activeRange = contentFindState
            .activeMatchIndex(matchCount: searchMatches.count)
            .map { searchMatches[$0].range }
        return ContentSearchPresentation(
            ranges: searchMatches.map(\.range),
            activeRange: activeRange,
            navigationRequestID: contentFindState.navigationRequestID
        )
    }

    private func rebuildSearchMatches() {
        let visibleText = previewDocument.text
        searchMatches = ContentSearchMatcher.matches(
            in: visibleText,
            query: contentFindState.query,
            options: contentFindState.options
        )
    }

    private func navigateContentFind(by offset: Int) {
        if !contentFindState.isPresented {
            contentFindState.present()
        }
        contentFindState.navigate(by: offset, matchCount: searchMatches.count)
    }

    private func openFileLink(_ link: MarkdownPreviewFileLink) {
        guard let projectRootURL else {
            fileLinkError = "当前项目目录不可用。"
            return
        }
        do {
            let target = try link.resolve(from: fileURL, within: projectRootURL)
            onOpenFile(target, link.line)
        } catch {
            fileLinkError = error.localizedDescription
        }
    }
}

struct MarkdownPreviewSourceLineMapping: Equatable, Sendable {
    let textRange: NSRange
    let sourceLineRange: ClosedRange<Int>
}

@MainActor
struct MarkdownPreviewAttributedDocument {
    let attributedText: NSAttributedString
    let text: String
    let identity: String
    let sourceLineMappings: [MarkdownPreviewSourceLineMapping]

    init(blocks: [MarkdownPreviewParsedBlock], fontSize: Double) {
        let normalizedFontSize = max(10, fontSize)
        let storage = NSMutableAttributedString()
        var mappings: [MarkdownPreviewSourceLineMapping] = []
        Self.appendBlocks(
            blocks,
            fontSize: normalizedFontSize,
            to: storage,
            mappings: &mappings
        )
        attributedText = storage
        text = storage.string
        identity = "\(normalizedFontSize)|\(blocks)"
        sourceLineMappings = mappings
    }

    init(blocks: [MarkdownPreviewBlock], fontSize: Double) {
        self.init(
            blocks: blocks.enumerated().map { index, block in
                MarkdownPreviewParsedBlock(
                    block: block,
                    sourceLineRange: (index + 1)...(index + 1)
                )
            },
            fontSize: fontSize
        )
    }

    func sourceLine(forCharacterOffset offset: Int) -> Int? {
        guard !sourceLineMappings.isEmpty else { return nil }
        let clampedOffset = min(max(0, offset), (text as NSString).length)
        if let mapping = sourceLineMappings.first(where: {
            clampedOffset >= $0.textRange.location
                && (clampedOffset < NSMaxRange($0.textRange)
                    || (clampedOffset == (text as NSString).length
                        && clampedOffset == NSMaxRange($0.textRange)))
        }) {
            let relativeOffset = max(0, clampedOffset - mapping.textRange.location)
            let renderedPrefix = (text as NSString).substring(
                with: NSRange(
                    location: mapping.textRange.location,
                    length: min(relativeOffset, mapping.textRange.length)
                )
            )
            let renderedLine = renderedPrefix.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            return min(
                mapping.sourceLineRange.upperBound,
                mapping.sourceLineRange.lowerBound + renderedLine
            )
        }
        return sourceLineMappings.last?.sourceLineRange.lowerBound
    }

    func textRange(forSourceLine line: Int) -> NSRange? {
        guard !sourceLineMappings.isEmpty else { return nil }
        if let mapping = sourceLineMappings.first(where: {
            $0.sourceLineRange.contains(line)
        }) {
            let renderedLine = min(
                line - mapping.sourceLineRange.lowerBound,
                max(0, mapping.sourceLineRange.count - 1)
            )
            return textRange(
                forRenderedLine: renderedLine,
                in: mapping
            )
        }
        if let next = sourceLineMappings.first(where: {
            $0.sourceLineRange.lowerBound > line
        }) {
            return next.textRange
        }
        return sourceLineMappings.last?.textRange
    }

    private func textRange(
        forRenderedLine renderedLine: Int,
        in mapping: MarkdownPreviewSourceLineMapping
    ) -> NSRange {
        guard renderedLine > 0 else { return mapping.textRange }
        let value = (text as NSString).substring(with: mapping.textRange)
        var currentLine = 0
        var offset = 0
        for character in value {
            offset += (String(character) as NSString).length
            if character == "\n" {
                currentLine += 1
                if currentLine == renderedLine {
                    return NSRange(
                        location: mapping.textRange.location + offset,
                        length: mapping.textRange.length - offset
                    )
                }
            }
        }
        return mapping.textRange
    }

    private static func appendBlocks(
        _ blocks: [MarkdownPreviewParsedBlock],
        fontSize: Double,
        to storage: NSMutableAttributedString,
        mappings: inout [MarkdownPreviewSourceLineMapping]
    ) {
        let bodyFont = NSFont.systemFont(ofSize: CGFloat(fontSize))
        let codeFont = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)

        for parsedBlock in blocks {
            let blockStart = storage.length
            switch parsedBlock.block {
            case .heading(let level, let source):
                let headingFont = NSFont.systemFont(
                    ofSize: headingSize(level, baseFontSize: fontSize),
                    weight: level <= 2 ? .bold : .semibold
                )
                append(
                    inlineText(source, font: headingFont),
                    to: storage,
                    paragraphStyle: paragraphStyle(
                        firstLineHeadIndent: 0,
                        headIndent: 0,
                        lineSpacing: 0,
                        paragraphSpacingBefore: level == 1 ? 4 : 12,
                        paragraphSpacing: level <= 2 ? 10 : 6
                    )
                )

            case .paragraph(let source):
                append(
                    inlineText(source, font: bodyFont),
                    to: storage,
                    paragraphStyle: paragraphStyle(
                        firstLineHeadIndent: 0,
                        headIndent: 0,
                        lineSpacing: 4,
                        paragraphSpacingBefore: 0,
                        paragraphSpacing: 12
                    )
                )

            case .listItem(let item):
                let listText = NSMutableAttributedString(
                    string: markerText(item.marker),
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: NSColor.textColor
                    ]
                )
                listText.append(inlineText(item.text, font: bodyFont))
                append(
                    listText,
                    to: storage,
                    paragraphStyle: paragraphStyle(
                        firstLineHeadIndent: CGFloat(item.depth * 20),
                        headIndent: CGFloat(item.depth * 20) + 24,
                        lineSpacing: 3,
                        paragraphSpacingBefore: 0,
                        paragraphSpacing: 5
                    )
                )

            case .blockQuote(let source):
                append(
                    inlineText(source, font: bodyFont, color: .secondaryLabelColor),
                    to: storage,
                    paragraphStyle: paragraphStyle(
                        firstLineHeadIndent: 15,
                        headIndent: 15,
                        lineSpacing: 4,
                        paragraphSpacingBefore: 8,
                        paragraphSpacing: 12
                    )
                )

            case .codeBlock(let language, let code):
                if let language {
                    append(
                        NSAttributedString(
                            string: language.uppercased(),
                            attributes: [
                                .font: NSFont.systemFont(ofSize: max(10, CGFloat(fontSize) - 2), weight: .semibold),
                                .foregroundColor: NSColor.secondaryLabelColor
                            ]
                        ),
                        to: storage,
                        paragraphStyle: paragraphStyle(
                            firstLineHeadIndent: 12,
                            headIndent: 12,
                            lineSpacing: 0,
                            paragraphSpacingBefore: 9,
                            paragraphSpacing: 0
                        ),
                        backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.09)
                    )
                }
                append(
                    NSAttributedString(
                        string: code,
                        attributes: [
                            .font: codeFont,
                            .foregroundColor: NSColor.textColor
                        ]
                    ),
                    to: storage,
                    paragraphStyle: paragraphStyle(
                        firstLineHeadIndent: 12,
                        headIndent: 12,
                        lineSpacing: 0,
                        paragraphSpacingBefore: language == nil ? 12 : 0,
                        paragraphSpacing: 14
                    ),
                    backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.09)
                )

            case .thematicBreak:
                append(
                    NSAttributedString(string: " ", attributes: [.font: bodyFont]),
                    to: storage,
                    paragraphStyle: paragraphStyle(
                        firstLineHeadIndent: 0,
                        headIndent: 0,
                        lineSpacing: 0,
                        paragraphSpacingBefore: 14,
                        paragraphSpacing: 14
                    )
                )

            case .table(let headers, _, let rows):
                let columnCount = max(1, max(headers.count, rows.map(\.count).max() ?? 0))
                appendTableRow(
                    headers,
                    columnCount: columnCount,
                    font: bodyFont,
                    isHeader: true,
                    to: storage
                )
                for row in rows {
                    appendTableRow(
                        row,
                        columnCount: columnCount,
                        font: bodyFont,
                        isHeader: false,
                        to: storage
                    )
                }
                append(
                    NSAttributedString(),
                    to: storage,
                    paragraphStyle: paragraphStyle(
                        firstLineHeadIndent: 0,
                        headIndent: 0,
                        lineSpacing: 0,
                        paragraphSpacingBefore: 0,
                        paragraphSpacing: 16
                    )
                )
            }
            let blockLength = storage.length - blockStart
            if blockLength > 0 {
                mappings.append(
                    MarkdownPreviewSourceLineMapping(
                        textRange: NSRange(location: blockStart, length: blockLength),
                        sourceLineRange: parsedBlock.sourceLineRange
                    )
                )
            }
        }
    }

    private static func appendTableRow(
        _ cells: [String],
        columnCount: Int,
        font: NSFont,
        isHeader: Bool,
        to storage: NSMutableAttributedString
    ) {
        let row = NSMutableAttributedString()
        for index in 0..<columnCount {
            let cell = index < cells.count ? cells[index] : ""
            let value = inlineText(cell, font: font)
            if isHeader {
                value.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                    range: NSRange(location: 0, length: value.length)
                )
                value.addAttribute(
                    .backgroundColor,
                    value: NSColor.secondaryLabelColor.withAlphaComponent(0.11),
                    range: NSRange(location: 0, length: value.length)
                )
            }
            row.append(value)
            if index < columnCount - 1 {
                row.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            }
        }
        append(
            row,
            to: storage,
            paragraphStyle: tableParagraphStyle(columnCount: columnCount)
        )
    }

    private static func inlineText(
        _ source: String,
        font: NSFont,
        color: NSColor = .textColor
    ) -> NSMutableAttributedString {
        guard let parsedText = MarkdownPreviewInlineParser.parse(source) else {
            return NSMutableAttributedString(
                string: source,
                attributes: [.font: font, .foregroundColor: color]
            )
        }

        let result = NSMutableAttributedString(
            string: parsedText.string,
            attributes: [.font: font, .foregroundColor: color]
        )
        parsedText.enumerateAttributes(
            in: NSRange(location: 0, length: parsedText.length),
            options: []
        ) { attributes, range, _ in
            guard range.length > 0 else { return }
            let intent = (attributes[.inlinePresentationIntent] as? NSNumber)
                .map { InlinePresentationIntent(rawValue: $0.uintValue) }
            var styledFont = font
            if intent?.contains(.code) == true {
                styledFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.secondaryLabelColor.withAlphaComponent(0.07),
                    range: range
                )
            }
            if intent?.contains(.stronglyEmphasized) == true {
                styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .boldFontMask)
            }
            if intent?.contains(.emphasized) == true {
                styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .italicFontMask)
            }
            result.addAttribute(.font, value: styledFont, range: range)
            if intent?.contains(.strikethrough) == true {
                result.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
            if let link = attributes[.link] {
                result.addAttributes(
                    [
                        .link: link,
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }
        }
        return result
    }

    private static func append(
        _ value: NSAttributedString,
        to storage: NSMutableAttributedString,
        paragraphStyle: NSParagraphStyle,
        backgroundColor: NSColor? = nil
    ) {
        let content = NSMutableAttributedString(attributedString: value)
        content.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: 0, length: content.length)
        content.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        if let backgroundColor {
            content.addAttribute(.backgroundColor, value: backgroundColor, range: range)
        }
        storage.append(content)
    }

    private static func paragraphStyle(
        firstLineHeadIndent: CGFloat,
        headIndent: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacingBefore: CGFloat,
        paragraphSpacing: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = paragraphSpacingBefore
        style.paragraphSpacing = paragraphSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func tableParagraphStyle(columnCount: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.tabStops = (1..<columnCount).map {
            NSTextTab(textAlignment: .left, location: CGFloat($0 * 180))
        }
        style.defaultTabInterval = 180
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func headingSize(_ level: Int, baseFontSize: Double) -> CGFloat {
        let defaultSize: CGFloat = switch level {
        case 1: 28
        case 2: 23
        case 3: 19
        case 4: 17
        default: 15
        }
        return max(10, defaultSize + CGFloat(baseFontSize - RepoDeskFontSize.default))
    }

    private static func markerText(_ marker: MarkdownPreviewListItem.Marker) -> String {
        switch marker {
        case .unordered:
            "• "
        case .ordered(let number):
            "\(number). "
        case .task(let isChecked):
            isChecked ? "☑ " : "☐ "
        }
    }
}

@MainActor
struct MarkdownPreviewHTMLDocument {
    let html: String
    let text: String
    let identity: String

    init(blocks: [MarkdownPreviewParsedBlock], fontSize: Double) {
        let normalizedFontSize = max(10, fontSize)
        var body = ""
        var renderedText = ""
        for parsedBlock in blocks {
            Self.append(
                parsedBlock,
                to: &body,
                text: &renderedText
            )
        }
        html = Self.documentHTML(body: body, fontSize: normalizedFontSize)
        text = renderedText
        identity = "\(normalizedFontSize)|\(blocks)"
    }

    private static func append(
        _ parsedBlock: MarkdownPreviewParsedBlock,
        to body: inout String,
        text: inout String
    ) {
        let range = parsedBlock.sourceLineRange
        let sourceAttributes = "data-source-start=\"\(range.lowerBound)\" data-source-end=\"\(range.upperBound)\""
        let blockBreak = "<span class=\"repoDesk-block-break\" aria-hidden=\"true\">\n</span>"

        switch parsedBlock.block {
        case .heading(let level, let source):
            let rendered = inlineHTML(source)
            body += "<h\(level) \(sourceAttributes)>\(rendered.html)</h\(level)>\(blockBreak)"
            text += rendered.text + "\n"

        case .paragraph(let source):
            let rendered = inlineHTML(source)
            body += "<p \(sourceAttributes)>\(rendered.html)</p>\(blockBreak)"
            text += rendered.text + "\n"

        case .listItem(let item):
            let rendered = inlineHTML(item.text)
            let marker = escapeHTML(markerText(item.marker))
            body += "<div class=\"markdown-list-item depth-\(min(item.depth, 8))\" \(sourceAttributes)>"
                + "<span class=\"markdown-list-marker\">\(marker)</span>"
                + rendered.html
                + "</div>\(blockBreak)"
            text += markerText(item.marker) + rendered.text + "\n"

        case .blockQuote(let source):
            let rendered = inlineHTML(source)
            body += "<blockquote \(sourceAttributes)>\(rendered.html)</blockquote>\(blockBreak)"
            text += rendered.text + "\n"

        case .codeBlock(let language, let code):
            let label = language?.uppercased() ?? ""
            let labelHTML = language.map {
                "<div class=\"markdown-code-language\">\(escapeHTML($0.uppercased()))</div>\(blockBreak)"
            } ?? ""
            body += "<div class=\"markdown-code-block\" \(sourceAttributes)>\(labelHTML)"
                + "<pre><code>\(escapeHTML(code))</code></pre></div>\(blockBreak)"
            if language != nil { text += label + "\n" }
            text += code + "\n"

        case .thematicBreak:
            body += "<hr \(sourceAttributes)><span class=\"repoDesk-block-break\" aria-hidden=\"true\"> \n</span>"
            text += " \n"

        case .table(let headers, let alignments, let rows):
            let columnCount = max(1, max(headers.count, rows.map(\.count).max() ?? 0))
            body += "<table class=\"markdown-table\" \(sourceAttributes)><thead><tr>"
            for index in 0..<columnCount {
                appendCell(
                    headers[safe: index] ?? "",
                    tag: "th",
                    alignment: alignments[safe: index] ?? .left,
                    isLastCell: index == columnCount - 1,
                    to: &body,
                    text: &text
                )
            }
            body += "</tr></thead><tbody>"
            for row in rows {
                body += "<tr>"
                for index in 0..<columnCount {
                    appendCell(
                        row[safe: index] ?? "",
                        tag: "td",
                        alignment: alignments[safe: index] ?? .left,
                        isLastCell: index == columnCount - 1,
                        to: &body,
                        text: &text
                    )
                }
                body += "</tr>"
            }
            // The last cell already emits the row's newline. An extra block break
            // would shift every subsequent search range in the DOM text nodes.
            body += "</tbody></table>"
        }
    }

    private static func appendCell(
        _ source: String,
        tag: String,
        alignment: MarkdownPreviewTableAlignment,
        isLastCell: Bool,
        to body: inout String,
        text: inout String
    ) {
        let rendered = inlineHTML(source)
        let separator = isLastCell ? "\n" : "\t"
        body += "<\(tag) style=\"text-align:\(alignment.cssValue)\">\(rendered.html)"
            + "<span class=\"repoDesk-text-separator\" aria-hidden=\"true\">\(separator)</span></\(tag)>"
        text += rendered.text + separator
    }

    private static func inlineHTML(_ source: String) -> (html: String, text: String) {
        guard let parsedText = MarkdownPreviewInlineParser.parse(source) else {
            return (escapeHTML(source), source)
        }
        var html = ""
        var text = ""
        parsedText.enumerateAttributes(
            in: NSRange(location: 0, length: parsedText.length),
            options: []
        ) { attributes, range, _ in
            guard range.length > 0 else { return }
            let value = parsedText.attributedSubstring(from: range).string
            let intent = (attributes[.inlinePresentationIntent] as? NSNumber)
                .map { InlinePresentationIntent(rawValue: $0.uintValue) }
            var tags: [String] = []
            var closingTags: [String] = []
            if let link = attributes[.link] {
                tags.append(linkTag(link))
                closingTags.insert("</a>", at: 0)
            }
            if intent?.contains(.stronglyEmphasized) == true {
                tags.append("<strong>")
                closingTags.insert("</strong>", at: 0)
            }
            if intent?.contains(.emphasized) == true {
                tags.append("<em>")
                closingTags.insert("</em>", at: 0)
            }
            if intent?.contains(.strikethrough) == true {
                tags.append("<del>")
                closingTags.insert("</del>", at: 0)
            }
            if intent?.contains(.code) == true {
                tags.append("<code>")
                closingTags.insert("</code>", at: 0)
            }
            html += tags.joined() + escapeHTML(value) + closingTags.joined()
            text += value
        }
        return (html, text)
    }

    private static func linkTag(_ link: Any) -> String {
        if let url = link as? URL, MarkdownPreviewFileLink(url: url) != nil {
            var action = URLComponents()
            action.scheme = MarkdownPreviewFileLink.navigationScheme
            action.host = "open"
            action.queryItems = [URLQueryItem(name: "target", value: url.absoluteString)]
            if let href = action.string {
                return "<a href=\"\(escapeHTML(href))\" title=\"⌘ + 单击打开文件\">"
            }
        }
        let href = escapeHTML((link as? URL)?.absoluteString ?? String(describing: link))
        return "<a href=\"\(href)\">"
    }

    private static func documentHTML(body: String, fontSize: Double) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: #ffffff; color: #24292f; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; font-size: \(fontSize)px; line-height: 1.55; overflow-x: auto; }
        .markdown-document { box-sizing: border-box; max-width: 1040px; margin: 0 auto; padding: 30px 32px 48px; }
        h1, h2, h3, h4, h5, h6 { color: #24292f; font-weight: 600; line-height: 1.25; margin: 24px 0 12px; }
        h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid #d8dee4; margin-top: 0; }
        h2 { font-size: 1.5em; padding-bottom: .25em; border-bottom: 1px solid #d8dee4; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1.05em; }
        p { margin: 0 0 14px; }
        a { color: #0969da; text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .9em; background: #f0f2f4; border-radius: 3px; padding: .12em .32em; }
        .markdown-code-block { margin: 16px 0; background: #f6f8fa; border: 1px solid #d8dee4; border-radius: 5px; overflow: hidden; }
        .markdown-code-language { padding: 8px 14px 0; color: #57606a; font-size: .78em; font-weight: 600; letter-spacing: .02em; }
        pre { margin: 0; padding: 12px 14px 14px; overflow-x: auto; white-space: pre; }
        pre code { padding: 0; background: transparent; border-radius: 0; font-size: .9em; }
        blockquote { margin: 14px 0; padding: 4px 14px; color: #57606a; border-left: 3px solid #d0d7de; }
        .markdown-list-item { margin: 4px 0; padding-left: 24px; position: relative; }
        .markdown-list-marker { position: absolute; left: 0; color: #57606a; }
        .depth-1 { margin-left: 22px; } .depth-2 { margin-left: 44px; } .depth-3 { margin-left: 66px; }
        .depth-4 { margin-left: 88px; } .depth-5 { margin-left: 110px; } .depth-6 { margin-left: 132px; }
        .depth-7 { margin-left: 154px; } .depth-8 { margin-left: 176px; }
        hr { height: 1px; border: 0; background: #d8dee4; margin: 24px 0; }
        .markdown-table { width: 100%; border-collapse: collapse; margin: 16px 0 20px; table-layout: auto; }
        .markdown-table th, .markdown-table td { border: 1px solid #d0d7de; padding: 8px 12px; vertical-align: top; }
        .markdown-table th { background: #f6f8fa; font-weight: 600; }
        .repoDesk-block-break, .repoDesk-text-separator { display: none; }
        mark.repoDesk-search { background: rgba(255, 214, 10, .38); color: inherit; padding: 0; }
        mark.repoDesk-search-active { background: rgba(255, 149, 0, .55); }
        @media (prefers-color-scheme: dark) {
            html, body { background: #1e1e1e; color: #e6edf3; }
            h1, h2, h3, h4, h5, h6 { color: #e6edf3; border-color: #444c56; }
            code { background: #343942; } .markdown-code-block { background: #2b2f36; border-color: #444c56; }
            .markdown-code-language, blockquote { color: #8b949e; } blockquote { border-color: #444c56; }
            hr { background: #444c56; } .markdown-table th { background: #2b2f36; }
            .markdown-table th, .markdown-table td { border-color: #444c56; }
            a { color: #58a6ff; }
        }
        </style></head><body><main class="markdown-document">\(body)</main>
        <script>
        (function() {
          function clearMarks(root) {
            root.querySelectorAll('mark.repoDesk-search').forEach(function(mark) {
              mark.replaceWith(document.createTextNode(mark.textContent || ''));
            });
            root.normalize();
          }
          function textNodes(root) {
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            var nodes = [], node;
            while ((node = walker.nextNode())) nodes.push(node);
            return nodes;
          }
          window.repoDeskApplySearch = function(ranges, activeIndex) {
            var root = document.querySelector('.markdown-document');
            if (!root) return;
            clearMarks(root);
            if (!ranges || ranges.length === 0) return;
            var nodes = textNodes(root), offset = 0;
            nodes.forEach(function(node) {
              var value = node.nodeValue || '', start = offset, end = offset + value.length;
              offset = end;
              var overlaps = [];
              ranges.forEach(function(range, index) {
                var rangeStart = range[0], rangeEnd = range[0] + range[1];
                if (rangeEnd > start && rangeStart < end) overlaps.push({ start: rangeStart, end: rangeEnd, index: index });
              });
              if (overlaps.length === 0) return;
              var fragment = document.createDocumentFragment(), cursor = 0;
              overlaps.sort(function(a, b) { return a.start - b.start; });
              overlaps.forEach(function(range) {
                var localStart = Math.max(0, range.start - start), localEnd = Math.min(value.length, range.end - start);
                if (localStart > cursor) fragment.appendChild(document.createTextNode(value.slice(cursor, localStart)));
                if (localEnd > localStart) {
                  var mark = document.createElement('mark');
                  mark.className = 'repoDesk-search' + (range.index === activeIndex ? ' repoDesk-search-active' : '');
                  mark.textContent = value.slice(localStart, localEnd);
                  fragment.appendChild(mark);
                  cursor = localEnd;
                }
              });
              if (cursor < value.length) fragment.appendChild(document.createTextNode(value.slice(cursor)));
              node.parentNode.replaceChild(fragment, node);
            });
            var active = root.querySelector('mark.repoDesk-search-active');
            if (active) active.scrollIntoView({ block: 'center', inline: 'nearest' });
          };
          window.repoDeskScrollToSourceLine = function(line) {
            var elements = document.querySelectorAll('[data-source-start]');
            var target = null;
            elements.forEach(function(element) {
              var start = Number(element.dataset.sourceStart), end = Number(element.dataset.sourceEnd);
              if (!target && line >= start && line <= end) target = element;
            });
            if (!target) {
              elements.forEach(function(element) { if (!target && Number(element.dataset.sourceStart) > line) target = element; });
            }
            if (target) target.scrollIntoView({ block: 'center', inline: 'nearest' });
          };
          var observer = new IntersectionObserver(function(entries) {
            var visible = entries.filter(function(entry) { return entry.isIntersecting; })
              .sort(function(a, b) { return Math.abs(a.boundingClientRect.top - window.innerHeight / 2) - Math.abs(b.boundingClientRect.top - window.innerHeight / 2); })[0];
            if (visible) {
              var element = visible.target;
              window.webkit.messageHandlers.repoDeskSourceLine.postMessage(Number(element.dataset.sourceStart));
            }
          }, { threshold: [0, .2, .8, 1] });
          document.querySelectorAll('[data-source-start]').forEach(function(element) { observer.observe(element); });
        })();
        </script></body></html>
        """
    }

    private static func markerText(_ marker: MarkdownPreviewListItem.Marker) -> String {
        switch marker {
        case .unordered: "• "
        case .ordered(let number): "\(number). "
        case .task(let isChecked): isChecked ? "☑ " : "☐ "
        }
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// Foundation follows CommonMark's punctuation flanking rule, which leaves labels
// such as **锁定范围：**正文 literal. Add a temporary word character inside those
// closing delimiters, then remove it from the attributed result before rendering.
// Both preview surfaces therefore share the same styles and visible text offsets.
private enum MarkdownPreviewInlineParser {
    static func parse(_ source: String) -> NSAttributedString? {
        var marker = "RepoDeskStrongBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        while source.contains(marker) { marker += "X" }
        let normalized = normalizeBoldLabels(source, marker: marker)
        guard let parsed = try? AttributedString(markdown: normalized) else { return nil }
        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        if normalized != source {
            while true {
                let range = (result.string as NSString).range(of: marker)
                guard range.location != NSNotFound else { break }
                result.deleteCharacters(in: range)
            }
        }
        return result
    }

    private static func normalizeBoldLabels(_ source: String, marker: String) -> String {
        var result = ""
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if let end = literalEnd(in: source, at: cursor) {
                result += source[cursor..<end]
                cursor = end
                continue
            }
            guard source[cursor...].hasPrefix("**"),
                  !source[cursor...].hasPrefix("***") else {
                result.append(source[cursor])
                cursor = source.index(after: cursor)
                continue
            }
            let contentStart = source.index(cursor, offsetBy: 2)
            var closing = contentStart
            while closing < source.endIndex {
                if let end = literalEnd(in: source, at: closing) {
                    closing = end
                } else if source[closing...].hasPrefix("**") {
                    break
                } else {
                    closing = source.index(after: closing)
                }
            }
            guard closing < source.endIndex else {
                result += source[cursor...]
                break
            }
            let end = source.index(closing, offsetBy: 2)
            let content = source[contentStart..<closing]
            if let first = content.first, !first.isWhitespace,
               let last = content.last, last.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains),
               end < source.endIndex,
               source[end].unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) {
                result += source[cursor..<closing] + marker + "**"
            } else {
                result += source[cursor..<end]
            }
            cursor = end
        }
        return result
    }

    // Skip escapes, code spans (including multi-backtick spans), and balanced
    // inline link destinations/autolinks so Markdown-looking URLs stay literal.
    private static func literalEnd(in source: String, at start: String.Index) -> String.Index? {
        if source[start] == "\\" {
            let next = source.index(after: start)
            return next < source.endIndex ? source.index(after: next) : next
        }
        if source[start] == "<",
           let end = source[start...].firstIndex(of: ">") {
            let content = source[source.index(after: start)..<end]
            if !content.contains(where: { $0.isWhitespace }),
               content.contains(":") || content.contains("@") {
                return source.index(after: end)
            }
        }
        if source[start] == "`" {
            var openingEnd = start
            while openingEnd < source.endIndex, source[openingEnd] == "`" {
                openingEnd = source.index(after: openingEnd)
            }
            let count = source.distance(from: start, to: openingEnd)
            var cursor = openingEnd
            while cursor < source.endIndex {
                let runStart = cursor
                if source[cursor] == "`" {
                    while cursor < source.endIndex, source[cursor] == "`" {
                        cursor = source.index(after: cursor)
                    }
                    if source.distance(from: runStart, to: cursor) == count { return cursor }
                } else {
                    cursor = source.index(after: cursor)
                }
            }
            return source.endIndex
        }
        if source[start] == "(", start > source.startIndex,
           source[source.index(before: start)] == "]" {
            var depth = 1
            var cursor = source.index(after: start)
            while cursor < source.endIndex {
                if source[cursor] == "\\" {
                    cursor = source.index(after: cursor)
                    if cursor < source.endIndex { cursor = source.index(after: cursor) }
                    continue
                }
                if source[cursor] == "(" { depth += 1 }
                if source[cursor] == ")" { depth -= 1 }
                cursor = source.index(after: cursor)
                if depth == 0 { return cursor }
            }
        }
        return nil
    }
}

private extension MarkdownPreviewTableAlignment {
    var cssValue: String {
        switch self {
        case .left: "left"
        case .center: "center"
        case .right: "right"
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
private struct MarkdownPreviewTextView: NSViewRepresentable {
    let document: MarkdownPreviewHTMLDocument
    let contentSearch: ContentSearchPresentation?
    let focusRequestID: UUID?
    let sourceLine: Int
    let navigationRequest: NativeTextNavigationRequest?
    let onVisibleLineChange: (Int) -> Void
    let onNavigationHandled: (UUID) -> Void
    let onFileLinkActivated: (MarkdownPreviewFileLink) -> Void

    func makeNSView(context: Context) -> MarkdownPreviewWebViewSurface {
        let webView = MarkdownPreviewWebViewSurface()
        webView.setAccessibilityIdentifier("RepoDesk.MarkdownPreview")
        return webView
    }

    func updateNSView(_ webView: MarkdownPreviewWebViewSurface, context: Context) {
        webView.apply(
            document: document,
            contentSearch: contentSearch,
            focusRequestID: focusRequestID,
            sourceLine: sourceLine,
            navigationRequest: navigationRequest,
            onVisibleLineChange: onVisibleLineChange,
            onNavigationHandled: onNavigationHandled,
            onFileLinkActivated: onFileLinkActivated
        )
    }
}

@MainActor
private final class MarkdownPreviewScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: MarkdownPreviewWebViewSurface?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.receiveScriptMessage(message)
    }
}

@MainActor
private final class MarkdownPreviewWebViewSurface: WKWebView, WKNavigationDelegate {
    private var appliedDocumentIdentity: String?
    private var appliedSearch: ContentSearchPresentation?
    private var appliedFocusRequestID: UUID?
    private var appliedNavigationRequestID: UUID?
    private var pendingSearch: ContentSearchPresentation?
    private var pendingSourceLine: Int?
    private var navigationRequest: NativeTextNavigationRequest?
    private var isDocumentLoaded = false
    private var lastReportedSourceLine: Int?
    private var onVisibleLineChange: ((Int) -> Void)?
    private var onNavigationHandled: ((UUID) -> Void)?
    private var onFileLinkActivated: ((MarkdownPreviewFileLink) -> Void)?
    private let messageProxy: MarkdownPreviewScriptMessageProxy

    init() {
        let configuration = WKWebViewConfiguration()
        let messageProxy = MarkdownPreviewScriptMessageProxy()
        self.messageProxy = messageProxy
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "document.documentElement.classList.add('repoDesk-webview');",
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        super.init(frame: .zero, configuration: configuration)
        messageProxy.owner = self
        configuration.userContentController.add(messageProxy, name: "repoDeskSourceLine")
        navigationDelegate = self
        allowsMagnification = false
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .textBackgroundColor
        appearance = NSAppearance(named: .aqua)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        document: MarkdownPreviewHTMLDocument,
        contentSearch: ContentSearchPresentation?,
        focusRequestID: UUID?,
        sourceLine: Int,
        navigationRequest: NativeTextNavigationRequest?,
        onVisibleLineChange: @escaping (Int) -> Void,
        onNavigationHandled: @escaping (UUID) -> Void,
        onFileLinkActivated: @escaping (MarkdownPreviewFileLink) -> Void
    ) {
        self.navigationRequest = navigationRequest
        self.onVisibleLineChange = onVisibleLineChange
        self.onNavigationHandled = onNavigationHandled
        self.onFileLinkActivated = onFileLinkActivated
        if appliedDocumentIdentity != document.identity {
            appliedDocumentIdentity = document.identity
            appliedSearch = nil
            pendingSearch = contentSearch
            pendingSourceLine = max(1, sourceLine)
            lastReportedSourceLine = nil
            isDocumentLoaded = false
            loadHTMLString(document.html, baseURL: nil)
        } else if isDocumentLoaded {
            applySearchIfNeeded(contentSearch)
            scrollToRequestedLine()
        } else {
            pendingSearch = contentSearch
        }
        restoreFocusIfNeeded(focusRequestID)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isDocumentLoaded = true
        applySearchIfNeeded(pendingSearch)
        pendingSearch = nil
        scrollToRequestedLine()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        let isPreviewLink = action.navigationType == .linkActivated && action.sourceFrame.isMainFrame
            && action.sourceFrame.request.url?.absoluteString == "about:blank"
        let scheme = url.scheme?.lowercased()
        if isPreviewLink, scheme == "http" || scheme == "https" {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }
        guard scheme == MarkdownPreviewFileLink.navigationScheme else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        // WebKit numbers the primary button as 1.
        guard isPreviewLink, action.buttonNumber == 1, action.modifierFlags.contains(.command),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "target" })?.value,
              let destination = URL(string: target),
              let link = MarkdownPreviewFileLink(url: destination) else { return }
        onFileLinkActivated?(link)
    }

    private func scrollToRequestedLine() {
        if let request = navigationRequest, request.id != appliedNavigationRequestID {
            appliedNavigationRequestID = request.id
            evaluate("window.repoDeskScrollToSourceLine(\(request.line));")
            Task { @MainActor [weak self] in self?.onNavigationHandled?(request.id) }
        } else if let line = pendingSourceLine {
            evaluate("window.repoDeskScrollToSourceLine(\(line));")
        }
        pendingSourceLine = nil
    }

    func receiveScriptMessage(_ message: WKScriptMessage) {
        guard message.name == "repoDeskSourceLine" else { return }
        if let line = message.body as? Int {
            reportVisibleSourceLine(line)
        } else if let number = message.body as? NSNumber {
            reportVisibleSourceLine(number.intValue)
        }
    }

    private func reportVisibleSourceLine(_ line: Int) {
        guard line > 0, line != lastReportedSourceLine else { return }
        lastReportedSourceLine = line
        onVisibleLineChange?(line)
    }

    private func applySearchIfNeeded(_ presentation: ContentSearchPresentation?) {
        guard appliedSearch != presentation, isDocumentLoaded else { return }
        appliedSearch = presentation
        let ranges = presentation?.ranges.map { [$0.location, $0.length] } ?? []
        let activeIndex = presentation?.activeRange.flatMap { active in
            presentation?.ranges.firstIndex { $0 == active }
        } ?? -1
        guard let data = try? JSONSerialization.data(withJSONObject: ranges),
              let rangesJSON = String(data: data, encoding: .utf8) else { return }
        evaluate("window.repoDeskApplySearch(\(rangesJSON), \(activeIndex));")
    }

    private func restoreFocusIfNeeded(_ requestID: UUID?) {
        guard let requestID, requestID != appliedFocusRequestID else { return }
        appliedFocusRequestID = requestID
        window?.makeFirstResponder(self)
    }

    private func evaluate(_ script: String) {
        evaluateJavaScript(script, completionHandler: nil)
    }
}
