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
            | item | `online.base.item.service` |
            """),
            fontSize: RepoDeskFontSize.default
        )
        guard htmlDocument.html.contains("class=\"markdown-table\""),
              htmlDocument.html.contains("text-align:left"),
              htmlDocument.html.contains("text-align:right"),
              htmlDocument.html.contains("data-source-start=\"3\""),
              htmlDocument.text.contains("online.base.item.service") else {
            throw MarkdownPreviewSelectionVerificationError.renderedMarkdownWasNotExposed
        }
        print("Markdown preview selection verification passed")
    }
}
