import AppKit
@testable import RepoDesk

enum MarkdownPreviewSelectionVerificationError: LocalizedError {
    case renderedMarkdownWasNotExposed
    case searchRangeWasNotAligned

    var errorDescription: String? {
        switch self {
        case .renderedMarkdownWasNotExposed:
            "Markdown preview selection model did not expose rendered text"
        case .searchRangeWasNotAligned:
            "Markdown preview search range was not aligned with rendered text"
        }
    }
}

@main
struct MarkdownPreviewSelectionVerification {
    @MainActor
    static func main() throws {
        let blocks: [MarkdownPreviewBlock] = [
            .heading(level: 1, text: "**Heading**"),
            .paragraph("A [link](https://example.com) and `code`."),
            .listItem(MarkdownPreviewListItem(marker: .task(isChecked: true), depth: 0, text: "Done")),
            .codeBlock(language: "swift", code: "let value = 1"),
            .table(
                headers: ["Name", "Value"],
                alignments: [.left, .left],
                rows: [["one", "1"]]
            )
        ]
        let document = MarkdownPreviewAttributedDocument(
            blocks: blocks,
            fontSize: RepoDeskFontSize.default
        )

        guard document.text.contains("Heading"),
              document.text.contains("link and code."),
              document.text.contains("☑ Done"),
              !document.text.contains("**Heading**"),
              !document.text.contains("[link](https://example.com)") else {
            throw MarkdownPreviewSelectionVerificationError.renderedMarkdownWasNotExposed
        }

        let matches = ContentSearchMatcher.matches(
            in: document.text,
            query: "let value",
            options: ContentSearchOptions()
        )
        guard matches.count == 1,
              (document.text as NSString).substring(with: matches[0].range) == "let value" else {
            throw MarkdownPreviewSelectionVerificationError.searchRangeWasNotAligned
        }

        let parsedDocument = MarkdownPreviewAttributedDocument(
            blocks: MarkdownPreviewParser.parseWithSourceLines("""
            # Heading

            ```swift
            let first = 1
            let second = 2
            ```
            """),
            fontSize: RepoDeskFontSize.default
        )
        guard let secondLineRange = parsedDocument.textRange(forSourceLine: 5),
              parsedDocument.sourceLine(forCharacterOffset: secondLineRange.location) == 5 else {
            throw MarkdownPreviewSelectionVerificationError.searchRangeWasNotAligned
        }

        let htmlDocument = MarkdownPreviewHTMLDocument(
            blocks: MarkdownPreviewParser.parseWithSourceLines("""
            ## Warehouse baseline

            | Name | Value |
            | :--- | ---: |
            | item | `example.services.item.service` |
            """),
            fontSize: RepoDeskFontSize.default
        )
        guard htmlDocument.html.contains("class=\"markdown-table\""),
              htmlDocument.html.contains("text-align:left"),
              htmlDocument.html.contains("text-align:right"),
              htmlDocument.html.contains("data-source-start=\"3\""),
              htmlDocument.text.contains("example.services.item.service") else {
            throw MarkdownPreviewSelectionVerificationError.renderedMarkdownWasNotExposed
        }
        try verifyHTMLSearchOffsets()
        try verifyBoldLabels()
        let links = MarkdownPreviewHTMLDocument(
            blocks: MarkdownPreviewParser.parseWithSourceLines("""
            [**Source**](Source.swift:42) [Website](https://example.com) [Section](#heading)
            """),
            fontSize: RepoDeskFontSize.default
        )
        guard links.html.contains("href=\"repodesk-markdown-file://open?target=Source.swift:42\""),
              links.html.contains("href=\"https://example.com\""),
              links.html.contains("href=\"#heading\""), links.text.contains("Source Website Section") else {
            throw MarkdownPreviewSelectionVerificationError.renderedMarkdownWasNotExposed
        }
        print("Markdown preview selection verification passed")
    }

    @MainActor
    private static func verifyBoldLabels() throws {
        let source = """
        # **标题：**说明

        **说明：**中文正文，**Label:**body，以及 **正常加粗**。
        **内容含 `code`：**正文与 **内容含 *斜体*：**正文。
        **数字：**123，**结束！**中文与 **括号）：**中文。

        - **锁定范围：**业务模式为现货采购或期货采购。
        - **主单仍可编辑：**商品明细锁定后仍可修改主单。

        > **提示：**请刷新后重试。

        | 项目 | 说明 |
        | --- | --- |
        | **仓库：**明细 | **计量：**数量 |

        **关联：**[链接](https://example.com)与 `code`。
        """
        let blocks = MarkdownPreviewParser.parseWithSourceLines(source)
        let html = MarkdownPreviewHTMLDocument(blocks: blocks, fontSize: RepoDeskFontSize.default)
        let attributed = MarkdownPreviewAttributedDocument(blocks: blocks, fontSize: RepoDeskFontSize.default)
        for label in ["标题：", "说明：", "Label:", "锁定范围：", "主单仍可编辑：", "提示：", "仓库：", "计量：", "关联："] {
            guard html.html.contains("<strong>\(label)</strong>"),
                  !html.text.contains("**\(label)**") else {
                throw NSError(domain: "MarkdownBoldLabels", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Bold label was not rendered: \(label)"
                ])
            }
            let range = (attributed.text as NSString).range(of: label)
            guard range.location != NSNotFound,
                  let font = attributed.attributedText.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                  NSFontManager.shared.traits(of: font).contains(.boldFontMask) else {
                throw NSError(domain: "MarkdownBoldLabels", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Bold label font was not applied: \(label)"
                ])
            }
        }
        let literalCases = [
            "`**代码：**正文`", "``**代码：**正文``", "`未闭合 **代码：**正文",
            #"\**转义：**正文"#, #"**转义：\**正文"#,
            "** 未加粗：**正文", "**未加粗： **正文", "空白 ** ** 保持原样", "**未闭合：正文",
            "[链接](https://example.com/**path:**segment)",
            "<https://example.com/**path:**segment>"
        ]
        for literal in literalCases {
            let blocks = MarkdownPreviewParser.parseWithSourceLines(literal)
            let rendered = MarkdownPreviewHTMLDocument(blocks: blocks, fontSize: RepoDeskFontSize.default)
            let baseline = try AttributedString(markdown: literal)
            guard !rendered.html.contains("<strong>"),
                  !rendered.html.contains("RepoDeskStrongBoundary"),
                  rendered.text == String(baseline.characters) + "\n" else {
                throw NSError(domain: "MarkdownBoldLabels", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Literal Markdown changed: \(literal)"
                ])
            }
        }
        guard html.html.contains("<code>code</code>"),
              html.html.contains("<em>斜体</em>"),
              html.html.contains("<strong>数字：</strong>123"),
              html.html.contains("<strong>结束！</strong>中文"),
              !html.text.contains("RepoDeskStrongBoundary") else {
            throw MarkdownPreviewSelectionVerificationError.renderedMarkdownWasNotExposed
        }
        let mixedSource = "RepoDesk**Strong**Boundary **标签：**正文"
        let mixed = MarkdownPreviewHTMLDocument(
            blocks: MarkdownPreviewParser.parseWithSourceLines(mixedSource),
            fontSize: RepoDeskFontSize.default
        )
        guard mixed.text == "RepoDeskStrongBoundary 标签：正文\n" else {
            throw MarkdownPreviewSelectionVerificationError.renderedMarkdownWasNotExposed
        }
    }

    @MainActor
    private static func verifyHTMLSearchOffsets() throws {
        let source = """
        ## 3.4 评审

        | 评审事项 | 当前依据 |
        | --- | --- |
        | 3.4 | **规则确认** |

        本章确认单一决定，**评审：**3.4 继续保持待补充状态。

        | 项目 | 结果 |
        | --- | --- |
        | 😀 | [3.4](https://example.com) |

        单一决定，**版本：**😀**3.4** 继续待补充。

        ```swift
        let version = "3.4"
        ```

        ```a&b
        3.4
        ```

        结尾 3.4。
        """
        let document = MarkdownPreviewHTMLDocument(
            blocks: MarkdownPreviewParser.parseWithSourceLines(source),
            fontSize: RepoDeskFontSize.default
        )
        // Read the emitted text nodes, including the hidden separators counted by
        // repoDeskApplySearch's TreeWalker. Checking document.text alone misses drift.
        guard let start = document.html.range(of: "<main class=\"markdown-document\">"),
              let end = document.html.range(of: "</main>", range: start.upperBound..<document.html.endIndex) else {
            throw MarkdownPreviewSelectionVerificationError.renderedMarkdownWasNotExposed
        }
        let fragment = "<main>" + document.html[start.upperBound..<end.lowerBound] + "</main>"
        let collector = MarkdownHTMLTextCollector()
        let parser = XMLParser(data: Data(fragment.utf8))
        parser.delegate = collector
        guard parser.parse() else {
            throw MarkdownPreviewSelectionVerificationError.renderedMarkdownWasNotExposed
        }
        let domText = collector.text
        let matches = ContentSearchMatcher.matches(
            in: document.text,
            query: "3.4",
            options: ContentSearchOptions()
        )
        guard matches.count == 8 else {
            throw MarkdownPreviewSelectionVerificationError.searchRangeWasNotAligned
        }
        for match in matches {
            guard NSMaxRange(match.range) <= (domText as NSString).length,
                  (domText as NSString).substring(with: match.range) == "3.4" else {
                throw MarkdownPreviewSelectionVerificationError.searchRangeWasNotAligned
            }
        }
        guard domText == document.text else {
            throw MarkdownPreviewSelectionVerificationError.searchRangeWasNotAligned
        }
    }
}

private final class MarkdownHTMLTextCollector: NSObject, XMLParserDelegate {
    var text = ""

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        text += whitespaceString
    }
}
