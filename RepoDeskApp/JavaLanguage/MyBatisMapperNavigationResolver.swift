import Foundation

enum MyBatisMapperNavigationResolver {
    private static let cache = MapperIndexCache()

    private struct MapperIdentity: Hashable {
        let namespace: String
        let methodName: String
    }

    private struct XMLStatementMatch {
        let tagName: String
        let openingTagRange: NSRange
        let idValueRange: NSRange
    }

    /// Finds the XML statement implemented by a Java Mapper method.
    ///
    /// This intentionally runs outside the Java language server. MyBatis binds
    /// an interface method to an XML statement through `namespace` and `id`,
    /// which is not represented by Java's `textDocument/implementation`.
    static func targets(
        for request: JavaNavigationRequest,
        workspaceURL: URL?,
        repositories: [RegisteredRepository]
    ) -> [JavaNavigationTarget] {
        guard request.action == .implementation,
              let workspaceURL,
              let identity = mapperIdentity(for: request) else { return [] }

        let sourceFileURL = request.fileURL.standardizedFileURL
        let repositoryRoots = repositories.compactMap { repository -> URL? in
            let root = repository.relativePath == "."
                ? workspaceURL
                : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
            let normalizedRoot = root.standardizedFileURL
            return isSameOrDescendant(sourceFileURL, of: normalizedRoot) ? normalizedRoot : nil
        }
        guard let repositoryRoot = repositoryRoots.max(by: { $0.path.count < $1.path.count }) else {
            return []
        }

        return cache.targets(identity: identity, repositoryRoot: repositoryRoot)
    }

    static func invalidate(workspaceURL: URL, changedFileURLs: [URL]? = nil) {
        cache.invalidate(workspaceURL: workspaceURL, changedFileURLs: changedFileURLs)
    }

    private static func targets(identity: MapperIdentity, sources: [URL: String]) -> [JavaNavigationTarget] {
        var results: [JavaNavigationTarget] = []
        for (fileURL, text) in sources {
            let statements = matchingStatements(in: text, namespace: identity.namespace, methodName: identity.methodName)
            for statement in statements {
                results.append(JavaNavigationTarget(
                    fileURL: fileURL,
                    range: sourceRange(in: text, utf16Range: statement.openingTagRange),
                    selectionRange: sourceRange(in: text, utf16Range: statement.idValueRange),
                    name: identity.methodName, detail: "MyBatis <\(statement.tagName)>",
                    containerName: identity.namespace, kind: .method
                ))
            }
        }
        return results.sorted {
            if $0.fileURL.path != $1.fileURL.path { return $0.fileURL.path < $1.fileURL.path }
            if $0.range.start.line != $1.range.start.line { return $0.range.start.line < $1.range.start.line }
            return $0.range.start.character < $1.range.start.character
        }
    }

    /// Queries run on the navigation utility task. Serializing the small cache
    /// keeps a file event from publishing results based on an older XML snapshot.
    /// The lock protects every access to entries and eviction order.
    private final class MapperIndexCache: @unchecked Sendable {
        private struct Entry {
            var sources: [URL: String]
            var results: [MapperIdentity: [JavaNavigationTarget]] = [:]
        }
        private let lock = NSLock()
        private var entries: [URL: Entry] = [:]
        private var order: [URL] = []

        func targets(identity: MapperIdentity, repositoryRoot: URL) -> [JavaNavigationTarget] {
            lock.withLock {
                if entries[repositoryRoot] == nil {
                    if order.count == 4 { entries.removeValue(forKey: order.removeFirst()) }
                    var sources: [URL: String] = [:]
                    for file in JavaNavigationFileScope.files(under: repositoryRoot, extension: "xml") {
                        if let text = try? String(contentsOf: file, encoding: .utf8) { sources[file] = text }
                    }
                    entries[repositoryRoot] = Entry(sources: sources)
                    order.append(repositoryRoot)
                }
                if let result = entries[repositoryRoot]?.results[identity] { return result }
                let result = MyBatisMapperNavigationResolver.targets(
                    identity: identity, sources: entries[repositoryRoot]?.sources ?? [:]
                )
                if !Task.isCancelled { entries[repositoryRoot]?.results[identity] = result }
                return result
            }
        }

        func invalidate(workspaceURL: URL, changedFileURLs: [URL]?) {
            lock.withLock {
                let changes = changedFileURLs?.map(\.standardizedFileURL)
                for root in Array(entries.keys) where isSameOrDescendant(root, of: workspaceURL.standardizedFileURL) {
                    let relevant = changes?.filter {
                        (isSameOrDescendant($0, of: root) || isSameOrDescendant(root, of: $0))
                            && ($0.pathExtension.lowercased() == "xml" || $0.pathExtension.isEmpty
                                || $0.path.contains("/.git/") || $0.lastPathComponent == "pom.xml"
                                || (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                    }
                    if let relevant, relevant.isEmpty { continue }
                    guard let relevant, relevant.allSatisfy({
                        $0.pathExtension.lowercased() == "xml" && isSameOrDescendant($0, of: root)
                            && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
                    }) else {
                        entries.removeValue(forKey: root)
                        order.removeAll { $0 == root }
                        continue
                    }
                    for file in relevant {
                        entries[root]?.sources.removeValue(forKey: file)
                        if JavaNavigationFileScope.contains(file, under: root),
                           let text = try? String(contentsOf: file, encoding: .utf8) {
                            entries[root]?.sources[file] = text
                        }
                    }
                    entries[root]?.results.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    private static func mapperIdentity(for request: JavaNavigationRequest) -> MapperIdentity? {
        let text = request.documentText
        let offset = utf16Offset(for: request.position, in: text)
        let spans = JavaSyntaxHighlighter.highlights(in: text)
        guard let method = spans.first(where: {
            $0.style == .methodDeclaration
                && (NSLocationInRange(offset, $0.range) || offset == NSMaxRange($0.range))
        }) else { return nil }
        let code = masking(spans.filter { $0.style == .comment || $0.style == .string }.map(\.range), in: text)
        let source = code as NSString
        let typeRegex = try? NSRegularExpression(
            pattern: #"\b(class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)[^;{]*\{"#
        )
        let declarations = typeRegex?.matches(in: code, range: NSRange(location: 0, length: source.length)) ?? []
        var enclosingTypes: [NSTextCheckingResult] = []
        for declaration in declarations where NSMaxRange(declaration.range) <= method.range.location {
            var depth = 1
            var cursor = NSMaxRange(declaration.range)
            while cursor < method.range.location, depth > 0 {
                if source.character(at: cursor) == 123 { depth += 1 }
                if source.character(at: cursor) == 125 { depth -= 1 }
                cursor += 1
            }
            if depth > 0 { enclosingTypes.append(declaration) }
        }
        guard let owner = enclosingTypes.last,
              source.substring(with: owner.range(at: 1)) == "interface" else { return nil }
        let packageName = firstCapture(of: #"\bpackage\s+([A-Za-z_$][A-Za-z0-9_$.]*)\s*;"#, in: code)
        let names = enclosingTypes.map { source.substring(with: $0.range(at: 2)) }
        return MapperIdentity(
            namespace: ([packageName].compactMap { $0 } + names).joined(separator: "."),
            methodName: (text as NSString).substring(with: method.range)
        )
    }

    private static func matchingStatements(
        in text: String,
        namespace: String,
        methodName: String
    ) -> [XMLStatementMatch] {
        guard text.contains(namespace), text.contains(methodName) else { return [] }
        let ignored = XMLSyntaxHighlighter.highlights(in: text).filter {
            $0.style == .comment || $0.style == .cdata || $0.style == .declaration
        }
        let markup = masking(ignored.map(\.range), in: text)
        let source = markup as NSString
        // Quotes may contain '>' and opening tags may span several lines.
        let attributes = #"(?:[^>\"']|\"[^\"]*\"|'[^']*')*>"#
        let mapperRegex = try? NSRegularExpression(pattern: #"<\s*mapper(?=\s|/?>)"# + attributes)
        let statementRegex = try? NSRegularExpression(pattern: #"<\s*(select|insert|update|delete)(?=\s|/?>)"# + attributes)
        let closeMapperRegex = try? NSRegularExpression(pattern: #"</\s*mapper\s*>"#)
        guard let mapperRegex, let statementRegex, let closeMapperRegex else { return [] }

        var results: [XMLStatementMatch] = []
        let fullRange = NSRange(location: 0, length: source.length)
        for mapperMatch in mapperRegex.matches(in: markup, range: fullRange) {
            guard let mapperNamespace = attribute(
                named: "namespace",
                in: text,
                tagRange: mapperMatch.range
            ), mapperNamespace.value == namespace else { continue }

            let searchStart = NSMaxRange(mapperMatch.range)
            let remainingRange = NSRange(location: searchStart, length: source.length - searchStart)
            let mapperEnd = closeMapperRegex.firstMatch(in: markup, range: remainingRange)?.range.location
                ?? source.length
            let bodyRange = NSRange(location: searchStart, length: max(0, mapperEnd - searchStart))
            for statementMatch in statementRegex.matches(in: markup, range: bodyRange) {
                guard let id = attribute(named: "id", in: text, tagRange: statementMatch.range),
                      id.value == methodName,
                      statementMatch.numberOfRanges > 1 else { continue }
                results.append(XMLStatementMatch(
                    tagName: source.substring(with: statementMatch.range(at: 1)),
                    openingTagRange: statementMatch.range,
                    idValueRange: id.valueRange
                ))
            }
        }
        return results
    }

    private static func attribute(
        named name: String,
        in text: String,
        tagRange: NSRange
    ) -> (value: String, valueRange: NSRange)? {
        let tag = (text as NSString).substring(with: tagRange)
        guard let regex = try? NSRegularExpression(
            pattern: #"\s+([A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#
        ) else { return nil }
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
            guard (tag as NSString).substring(with: match.range(at: 1)) == name else { continue }
            let valueRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            return (
                (tag as NSString).substring(with: valueRange),
                NSRange(location: tagRange.location + valueRange.location, length: valueRange.length)
            )
        }
        return nil
    }

    private static func masking(_ ranges: [NSRange], in text: String) -> String {
        let result = NSMutableString(string: text)
        for range in ranges {
            result.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        return result as String
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static func utf16Offset(for position: JavaSourcePosition, in text: String) -> Int {
        let index = SourceLineIndex(text: text)
        guard index.lineStartOffsets.indices.contains(position.line) else { return 0 }
        return index.lineStartOffsets[position.line] + position.character
    }

    private static func sourceRange(in text: String, utf16Range: NSRange) -> JavaSourceRange {
        let index = SourceLineIndex(text: text)
        func position(_ offset: Int) -> JavaSourcePosition {
            let line = max(0, index.lineNumber(containingUTF16Offset: offset) - 1)
            let lineStart = index.lineStartOffsets.indices.contains(line)
                ? index.lineStartOffsets[line]
                : 0
            return JavaSourcePosition(line: line, character: max(0, offset - lineStart))
        }
        return JavaSourceRange(
            start: position(utf16Range.location),
            end: position(NSMaxRange(utf16Range))
        )
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidate = candidate.standardizedFileURL.path
        let root = root.standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
