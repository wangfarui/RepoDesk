import Foundation

enum JavaWorkspaceNavigationFallback {
    private static let indexCache = JavaWorkspaceNavigationIndexCache()

    static func invalidate(workspaceURL: URL) async {
        await indexCache.invalidate(workspaceURL: workspaceURL)
    }

    static func targets(
        for request: JavaNavigationRequest,
        workspaceURL: URL?,
        repositories: [RegisteredRepository]
    ) async -> [JavaNavigationTarget] {
        guard request.action == .contextual || request.action == .declaration,
              let workspaceURL else { return [] }

        let normalizedWorkspaceURL = workspaceURL.standardizedFileURL
        let repositories = repositories
        let sourceFilesByType = await indexCache.sourceFilesByType(
            workspaceURL: normalizedWorkspaceURL,
            repositories: repositories
        )
        return await Task.detached(priority: .utility) {
            Self.findTargets(
                for: request,
                sourceFilesByType: sourceFilesByType
            )
        }.value
    }

    nonisolated private static func findTargets(
        for request: JavaNavigationRequest,
        sourceFilesByType: [String: [URL]]
    ) -> [JavaNavigationTarget] {
        guard let symbol = identifier(at: request.position, in: request.documentText) else {
            return []
        }

        let offset = utf16Offset(for: request.position, in: request.documentText)
        let prefix = (request.documentText as NSString).substring(
            with: NSRange(location: 0, length: min(offset, (request.documentText as NSString).length))
        )
        let receiver = try? NSRegularExpression(pattern: #"([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*$"#)
            .firstMatch(
                in: prefix,
                range: NSRange(location: 0, length: (prefix as NSString).length)
            )
            .flatMap { match -> String? in
                guard match.numberOfRanges > 1 else { return nil }
                return (prefix as NSString).substring(with: match.range(at: 1))
            }

        let typeNames = candidateTypeNames(
            receiver: receiver,
            symbol: symbol,
            documentText: request.documentText
        )
        guard !typeNames.isEmpty else { return [] }

        for typeName in typeNames {
            let matchingFiles = sourceFilesByType[typeName] ?? []
            for fileURL in matchingFiles {
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let methodRange = methodNameRange(named: symbol, in: text)
                guard let range = methodRange ?? fieldNameRange(named: symbol, in: text) else {
                    continue
                }
                return [JavaNavigationTarget(
                    fileURL: fileURL.standardizedFileURL,
                    range: range,
                    selectionRange: range,
                    name: symbol,
                    detail: nil,
                    containerName: typeName,
                    kind: methodRange == nil ? .field : .method
                )]
            }
        }
        return []
    }

    private static func candidateTypeNames(
        receiver: String?,
        symbol: String,
        documentText: String
    ) -> [String] {
        var names: [String] = []
        if let receiver, !receiver.isEmpty {
            let declarationPattern = #"\b([A-Za-z_$][A-Za-z0-9_$]*)\s+"#
                + NSRegularExpression.escapedPattern(for: receiver)
                + #"\b"#
            if let match = try? NSRegularExpression(pattern: declarationPattern)
                .firstMatch(
                    in: documentText,
                    range: NSRange(location: 0, length: (documentText as NSString).length)
                ),
               match.numberOfRanges > 1 {
                names.append((documentText as NSString).substring(with: match.range(at: 1)))
            }
        }

        let imports: [String]
        if let expression = try? NSRegularExpression(
            pattern: #"(?m)^\s*import\s+([A-Za-z_$][A-Za-z0-9_$.]*)\s*;"#
        ) {
            imports = expression.matches(
                in: documentText,
                range: NSRange(location: 0, length: (documentText as NSString).length)
            ).compactMap { match -> String? in
                guard match.numberOfRanges > 1 else { return nil }
                return (documentText as NSString)
                    .substring(with: match.range(at: 1))
                    .split(separator: ".")
                    .last
                    .map(String.init)
            }
        } else {
            imports = []
        }
        names.append(contentsOf: imports)
        if names.isEmpty, receiver?.first?.isUppercase == true {
            names.append(receiver!)
        }

        var unique: [String] = []
        for name in names where !name.isEmpty && !unique.contains(name) {
            unique.append(name)
        }
        return unique
    }

    fileprivate static func sourceFilesByTypeUnderRoots(_ roots: [URL]) -> [String: [URL]] {
        var filesByType: [String: [URL]] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if ["target", "build", "out", "node_modules"].contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "java" else { continue }
                filesByType[url.deletingPathExtension().lastPathComponent, default: []].append(url)
            }
        }
        return filesByType
    }

    private static func methodNameRange(named name: String, in text: String) -> JavaSourceRange? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\("#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        ),
        match.numberOfRanges > 0 else { return nil }
        let nameRange = match.range(at: 0)
        let openParen = (text as NSString).range(of: "(", range: nameRange)
        let end = openParen.location == NSNotFound ? NSMaxRange(nameRange) : openParen.location
        let range = NSRange(location: nameRange.location, length: max(0, end - nameRange.location))
        return sourceRange(in: text, utf16Range: range)
    }

    private static func fieldNameRange(named name: String, in text: String) -> JavaSourceRange? {
        let pattern = #"(?m)^[ \t]*(?:(?:public|protected|private|static|final|transient|volatile)\s+)*[A-Za-z_$][A-Za-z0-9_$<>,.?\[\]]*\s+("#
            + NSRegularExpression.escapedPattern(for: name)
            + #")\s*(?:=|;)"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        ) else { return nil }
        return sourceRange(in: text, utf16Range: match.range(at: 1))
    }

    private static func identifier(at position: JavaSourcePosition, in text: String) -> String? {
        let offset = utf16Offset(for: position, in: text)
        let source = text as NSString
        guard source.length > 0 else { return nil }
        var index = min(max(0, offset), source.length - 1)
        if !isIdentifierCharacter(source.character(at: index)), index > 0 { index -= 1 }
        guard isIdentifierCharacter(source.character(at: index)) else { return nil }
        var start = index
        var end = index + 1
        while start > 0, isIdentifierCharacter(source.character(at: start - 1)) { start -= 1 }
        while end < source.length, isIdentifierCharacter(source.character(at: end)) { end += 1 }
        return source.substring(with: NSRange(location: start, length: end - start))
    }

    private static func isIdentifierCharacter(_ character: unichar) -> Bool {
        character == 95 || character == 36 || CharacterSet.alphanumerics.contains(UnicodeScalar(character)!)
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
}

private actor JavaWorkspaceNavigationIndexCache {
    private struct CacheKey: Hashable, Sendable {
        let workspacePath: String
        let repositorySignature: String
    }

    private var entries: [CacheKey: [String: [URL]]] = [:]

    func sourceFilesByType(
        workspaceURL: URL,
        repositories: [RegisteredRepository]
    ) async -> [String: [URL]] {
        let key = CacheKey(
            workspacePath: workspaceURL.standardizedFileURL.path,
            repositorySignature: repositories
                .map { "\($0.id):\($0.name)" }
                .joined(separator: "\n")
        )
        if let cached = entries[key] {
            return cached
        }

        let roots = repositories.map { repository in
            repository.relativePath == "."
                ? workspaceURL
                : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
        }
        let index = await Task.detached(priority: .utility) {
            JavaWorkspaceNavigationFallback.sourceFilesByTypeUnderRoots(roots)
        }.value
        entries = [key: index]
        return index
    }

    func invalidate(workspaceURL: URL) {
        let path = workspaceURL.standardizedFileURL.path
        entries = entries.filter { $0.key.workspacePath != path }
    }
}
