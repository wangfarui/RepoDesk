import Foundation

enum MarkdownPreviewVerificationError: LocalizedError {
    case missingBlocks([String])
    case unexpectedFileLink(String)

    var errorDescription: String? {
        switch self {
        case .missingBlocks(let blocks):
            "Markdown preview did not produce blocks: \(blocks.joined(separator: ", "))"
        case .unexpectedFileLink(let target):
            "Unexpected Markdown file link result for \(target)"
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
        try verifyFileLinks()
        print("Markdown preview verification passed")
    }

    private static func verifyFileLinks() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = fixture.appendingPathComponent("project", isDirectory: true)
        let docs = project.appendingPathComponent("docs", isDirectory: true)
        let source = docs.appendingPathComponent("guide.md")
        let sibling = docs.appendingPathComponent("Source.swift")
        let spacedFile = project.appendingPathComponent("Target File.swift")
        let outside = fixture.appendingPathComponent("outside.txt")
        let symlink = project.appendingPathComponent("external.txt")
        try manager.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        for file in [source, sibling, spacedFile, outside] {
            try Data().write(to: file)
        }
        try manager.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let examples: [(String, URL, Int?)] = [
            ("Source.swift:42", sibling, 42),
            ("../Target%20File.swift:7", spacedFile, 7),
            (spacedFile.path, spacedFile, nil),
            (spacedFile.absoluteString + ":3", spacedFile, 3)
        ]
        for (destination, expectedFile, expectedLine) in examples {
            guard let url = URL(string: destination), let link = MarkdownPreviewFileLink(url: url),
                  try link.resolve(from: source, within: project) == expectedFile.standardizedFileURL,
                  link.line == expectedLine else {
                throw MarkdownPreviewVerificationError.unexpectedFileLink(destination)
            }
        }
        for destination in ["https://example.com/file.md:42", "//example.com/file.md", "#heading", "tel:42"] {
            guard let url = URL(string: destination), MarkdownPreviewFileLink(url: url) == nil else {
                throw MarkdownPreviewVerificationError.unexpectedFileLink(destination)
            }
        }
        for destination in ["missing.txt", "../../outside.txt", "../external.txt", "../docs"] {
            guard let url = URL(string: destination), let link = MarkdownPreviewFileLink(url: url),
                  (try? link.resolve(from: source, within: project)) == nil else {
                throw MarkdownPreviewVerificationError.unexpectedFileLink(destination)
            }
        }
    }
}
