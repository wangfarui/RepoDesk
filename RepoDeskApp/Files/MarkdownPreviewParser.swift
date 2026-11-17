import Foundation

struct MarkdownPreviewFileLink {
    static let navigationScheme = "repodesk-markdown-file"

    let path: String
    let line: Int?

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.port == nil else { return nil }
        if let host = components.host {
            guard url.isFileURL, host.isEmpty || host.lowercased() == "localhost" else { return nil }
        }

        var encodedPath = components.percentEncodedPath
        if let scheme = components.scheme, !url.isFileURL {
            // Foundation reads a bare filename followed by :42 as a URL scheme.
            guard scheme.contains("."), Self.lineNumber(encodedPath) != nil else { return nil }
            encodedPath = scheme + ":" + encodedPath
        }
        guard !encodedPath.isEmpty, !encodedPath.hasPrefix("//"),
              !url.isFileURL || encodedPath.hasPrefix("/") else { return nil }

        var targetLine: Int?
        if let separator = encodedPath.lastIndex(of: ":"),
           let number = Self.lineNumber(String(encodedPath[encodedPath.index(after: separator)...])) {
            targetLine = number
            encodedPath = String(encodedPath[..<separator])
        }
        guard let decodedPath = encodedPath.removingPercentEncoding,
              !decodedPath.isEmpty, !decodedPath.contains("\0") else { return nil }
        path = decodedPath
        line = targetLine
    }

    func resolve(from documentURL: URL, within projectRoot: URL) throws -> URL {
        let target = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: false)
            : documentURL.deletingLastPathComponent().appendingPathComponent(path, isDirectory: false)
        let fileURL = target.standardizedFileURL
        let root = projectRoot.standardizedFileURL
        let resolved = fileURL.resolvingSymlinksInPath()
        guard Self.contains(fileURL, within: root),
              Self.contains(resolved, within: root.resolvingSymlinksInPath()) else {
            throw ResolutionError.outsideProject(path)
        }
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ResolutionError.fileUnavailable(path)
        }
        return fileURL
    }

    private static func contains(_ fileURL: URL, within root: URL) -> Bool {
        fileURL.pathComponents.starts(with: root.pathComponents)
    }

    private static func lineNumber(_ value: String) -> Int? {
        guard value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(value), number > 0 else { return nil }
        return number
    }

    private enum ResolutionError: LocalizedError {
        case outsideProject(String)
        case fileUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .outsideProject(let path): "链接指向当前项目之外的路径“\(path)”。"
            case .fileUnavailable(let path): "找不到可打开的文件“\(path)”。"
            }
        }
    }
}

struct MarkdownPreviewListItem: Equatable, Sendable {
    enum Marker: Equatable, Sendable {
        case unordered
        case ordered(Int)
        case task(isChecked: Bool)
    }

    let marker: Marker
    let depth: Int
    let text: String
}

enum MarkdownPreviewTableAlignment: Equatable, Sendable {
    case left
    case center
    case right
}

enum MarkdownPreviewBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(MarkdownPreviewListItem)
    case blockQuote(String)
    case codeBlock(language: String?, code: String)
    case thematicBreak
    case table(
        headers: [String],
        alignments: [MarkdownPreviewTableAlignment],
        rows: [[String]]
    )
}

struct MarkdownPreviewParsedBlock: Equatable, Sendable {
    let block: MarkdownPreviewBlock
    let sourceLineRange: ClosedRange<Int>
}

enum MarkdownPreviewParser {
    static func parse(_ source: String) -> [MarkdownPreviewBlock] {
        parseWithSourceLines(source).map(\.block)
    }

    static func parseWithSourceLines(_ source: String) -> [MarkdownPreviewParsedBlock] {
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedSource.components(separatedBy: "\n")
        var blocks: [MarkdownPreviewParsedBlock] = []
        var paragraphLines: [String] = []
        var paragraphStartIndex: Int?
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let startIndex = paragraphStartIndex ?? max(0, index - paragraphLines.count)
            let endIndex = max(startIndex, index - 1)
            blocks.append(
                MarkdownPreviewParsedBlock(
                    block: .paragraph(paragraphLines.joined(separator: " ")),
                    sourceLineRange: (startIndex + 1)...(endIndex + 1)
                )
            )
            paragraphLines = []
            paragraphStartIndex = nil
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = codeFence(in: trimmed) {
                flushParagraph()
                let blockStartIndex = index
                let language = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                let blockEndIndex = min(index, lines.count - 1)
                if index < lines.count { index += 1 }
                blocks.append(
                    MarkdownPreviewParsedBlock(
                        block: .codeBlock(
                            language: language.isEmpty ? nil : language,
                            code: codeLines.joined(separator: "\n")
                        ),
                        sourceLineRange: (blockStartIndex + 1)...(blockEndIndex + 1)
                    )
                )
                continue
            }

            if let heading = atxHeading(in: trimmed) {
                flushParagraph()
                blocks.append(
                    MarkdownPreviewParsedBlock(
                        block: .heading(level: heading.level, text: heading.text),
                        sourceLineRange: (index + 1)...(index + 1)
                    )
                )
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let level = setextHeadingLevel(in: lines[index + 1]),
               !trimmed.isEmpty {
                flushParagraph()
                blocks.append(
                    MarkdownPreviewParsedBlock(
                        block: .heading(level: level, text: trimmed),
                        sourceLineRange: (index + 1)...(index + 2)
                    )
                )
                index += 2
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(
                    MarkdownPreviewParsedBlock(
                        block: .thematicBreak,
                        sourceLineRange: (index + 1)...(index + 1)
                    )
                )
                index += 1
                continue
            }

            if line.contains("|"),
               let alignments = tableAlignments(
                   in: index + 1 < lines.count ? lines[index + 1] : nil
               ) {
                flushParagraph()
                let blockStartIndex = index
                let headers = tableCells(in: line)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index]
                    guard !row.trimmingCharacters(in: .whitespaces).isEmpty,
                          row.contains("|") else { break }
                    rows.append(tableCells(in: row))
                    index += 1
                }
                let blockEndIndex = max(blockStartIndex + 1, index - 1)
                blocks.append(
                    MarkdownPreviewParsedBlock(
                        block: .table(
                            headers: headers,
                            alignments: alignments,
                            rows: rows
                        ),
                        sourceLineRange: (blockStartIndex + 1)...(blockEndIndex + 1)
                    )
                )
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let blockStartIndex = index
                var quoteLines: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    quoteLines.append(
                        String(quoteLine.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(
                    MarkdownPreviewParsedBlock(
                        block: .blockQuote(quoteLines.joined(separator: "\n")),
                        sourceLineRange: (blockStartIndex + 1)...index
                    )
                )
                continue
            }

            if let listItem = listItem(in: line) {
                flushParagraph()
                blocks.append(
                    MarkdownPreviewParsedBlock(
                        block: .listItem(listItem),
                        sourceLineRange: (index + 1)...(index + 1)
                    )
                )
                index += 1
                continue
            }

            paragraphStartIndex = paragraphStartIndex ?? index
            paragraphLines.append(trimmed)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func codeFence(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func atxHeading(in line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level),
              line.dropFirst(level).first?.isWhitespace == true else { return nil }
        var text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        while text.last == "#" {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    private static func setextHeadingLevel(in line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let characters = line.filter { !$0.isWhitespace }
        guard characters.count >= 3, let first = characters.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return characters.allSatisfy { $0 == first }
    }

    private static func listItem(in line: String) -> MarkdownPreviewListItem? {
        let leadingSpaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(into: 0) { count, character in
            count += character == "\t" ? 4 : 1
        }
        let depth = leadingSpaces / 2
        let content = line.dropFirst(line.prefix { $0 == " " || $0 == "\t" }.count)

        if let first = content.first, first == "-" || first == "*" || first == "+",
           content.dropFirst().first?.isWhitespace == true {
            var text = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
            var marker: MarkdownPreviewListItem.Marker = .unordered
            if text.count >= 3, text.first == "[", text.dropFirst(2).first == "]" {
                let state = text[text.index(after: text.startIndex)]
                if state == " " || state == "x" || state == "X" {
                    marker = .task(isChecked: state == "x" || state == "X")
                    text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            }
            return MarkdownPreviewListItem(marker: marker, depth: depth, text: text)
        }

        let digits = content.prefix { $0.isNumber }
        guard !digits.isEmpty,
              let number = Int(digits),
              let delimiter = content.dropFirst(digits.count).first,
              delimiter == "." || delimiter == ")",
              content.dropFirst(digits.count + 1).first?.isWhitespace == true else { return nil }
        let text = String(content.dropFirst(digits.count + 1)).trimmingCharacters(in: .whitespaces)
        return MarkdownPreviewListItem(marker: .ordered(number), depth: depth, text: text)
    }

    private static func tableAlignments(in separatorLine: String?) -> [MarkdownPreviewTableAlignment]? {
        guard let separatorLine else { return nil }
        let cells = tableCells(in: separatorLine)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownPreviewTableAlignment] = []
        for cell in cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            let hasLeadingColon = value.first == ":"
            let hasTrailingColon = value.last == ":"
            let dashStart = value.index(value.startIndex, offsetBy: hasLeadingColon ? 1 : 0)
            let dashEnd = value.index(value.endIndex, offsetBy: hasTrailingColon ? -1 : 0)
            guard dashStart <= dashEnd else { return nil }
            let dashes = value[dashStart..<dashEnd]
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(
                hasLeadingColon && hasTrailingColon
                    ? .center
                    : hasTrailingColon ? .right : .left
            )
        }
        return alignments
    }

    private static func tableCells(in line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
