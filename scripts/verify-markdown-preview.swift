import Foundation

enum MarkdownPreviewVerificationError: LocalizedError {
    case missingBlocks([String])

    var errorDescription: String? {
        switch self {
        case .missingBlocks(let blocks):
            "Markdown preview did not produce blocks: \(blocks.joined(separator: ", "))"
        }
    }
}

@main
struct MarkdownPreviewVerification {
    static func main() throws {
        let source = """
        # Heading

        A paragraph with **strong text**.

        - First item
        - [x] Completed item

        ```swift
        let value = 1
        ```

        | Name | Value |
        | --- | --- |
        | one | 1 |
        """
        let blocks = MarkdownPreviewParser.parse(source)
        var foundHeading = false
        var foundList = false
        var foundCode = false
        var foundTable = false

        for block in blocks {
            switch block {
            case .heading:
                foundHeading = true
            case .listItem:
                foundList = true
            case .codeBlock:
                foundCode = true
            case .table:
                foundTable = true
            default:
                break
            }
        }

        let missing = [
            foundHeading ? nil : "heading",
            foundList ? nil : "list",
            foundCode ? nil : "code",
            foundTable ? nil : "table"
        ].compactMap { $0 }
        guard missing.isEmpty else {
            throw MarkdownPreviewVerificationError.missingBlocks(missing)
        }
        print("Markdown preview verification passed")
    }
}
