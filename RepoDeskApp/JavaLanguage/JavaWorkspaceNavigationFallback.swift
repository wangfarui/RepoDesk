import Foundation

enum JavaWorkspaceNavigationFallback {
    private static let indexCache = JavaWorkspaceNavigationIndexCache()
    private static let callerIndexCache = JavaMethodCallerIndexCache()

    static func invalidate(workspaceURL: URL, changedFileURLs: [URL]? = nil) async {
        await indexCache.invalidate(workspaceURL: workspaceURL)
        await callerIndexCache.invalidate(workspaceURL: workspaceURL, changedFileURLs: changedFileURLs)
    }

    static func prepareMethodCallers(
        fileURL: URL,
        workspaceURL: URL?,
        repositories: [RegisteredRepository]
    ) async {
        guard let workspaceURL,
              let repositoryURL = owningRepository(fileURL: fileURL, workspaceURL: workspaceURL,
                                                    repositories: repositories) else { return }
        _ = await callerIndexCache.filesByMethodName(workspaceURL: workspaceURL, repositoryURL: repositoryURL)
    }

    static func isMethodDeclaration(_ request: JavaNavigationRequest) -> Bool {
        request.action == .contextual
            && methodDeclarationRange(in: request.documentText, at: request.position) != nil
    }

    static func targets(
        for request: JavaNavigationRequest,
        workspaceURL: URL?,
        repositories: [RegisteredRepository]
    ) async -> [JavaNavigationTarget] {
        guard request.action == .contextual || request.action == .declaration,
              let workspaceURL else { return [] }

        let normalizedWorkspaceURL = workspaceURL.standardizedFileURL
        if isMethodDeclaration(request),
           let symbol = identifier(at: request.position, in: request.documentText),
           let repositoryURL = owningRepository(fileURL: request.fileURL, workspaceURL: normalizedWorkspaceURL,
                                                 repositories: repositories) {
            // Incoming calls have the same repository scope as the Java server.
            // Definition fallback below can still resolve other repositories.
            let files = await callerIndexCache.filesByMethodName(
                workspaceURL: normalizedWorkspaceURL, repositoryURL: repositoryURL
            )[symbol] ?? []
            return await Task.detached(priority: .userInitiated) {
                findIncomingCallTargets(named: symbol, request: request,
                                        sourceFiles: Array(Set(files + [request.fileURL.standardizedFileURL])))
            }.value
        }
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

        guard !isMethodDeclaration(request) else { return [] }

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

    private static func findIncomingCallTargets(
        named symbol: String,
        request: JavaNavigationRequest,
        sourceFiles: [URL]
    ) -> [JavaNavigationTarget] {
        let targetFileURL = request.fileURL.standardizedFileURL
        let targetType = targetFileURL.deletingPathExtension().lastPathComponent
        let targetCode = codeMaskingLiterals(in: request.documentText)
        let targetPackage = packageName(in: targetCode)
        // Without semantic bindings, same-named overloads cannot be distinguished
        // reliably. Keep the fallback conservative; JDT handles overloads.
        let declarations = JavaSyntaxHighlighter.highlights(in: request.documentText).filter {
            $0.style == .methodDeclaration
                && (request.documentText as NSString).substring(with: $0.range) == symbol
        }
        guard declarations.count == 1 else { return [] }
        var results: [JavaNavigationTarget] = []

        for fileURL in sourceFiles {
            let text: String
            if fileURL.standardizedFileURL == targetFileURL {
                text = request.documentText
            } else if let savedText = try? String(contentsOf: fileURL, encoding: .utf8) {
                text = savedText
            } else {
                continue
            }
            guard text.contains(symbol) else { continue }
            let spans = JavaSyntaxHighlighter.highlights(in: text)
            let code = codeMaskingLiterals(in: text, spans: spans)
            let methodDeclarations = spans.filter { $0.style == .methodDeclaration }
                .sorted { $0.range.location < $1.range.location }
            let fileType = fileURL.deletingPathExtension().lastPathComponent
            for call in spans where call.style == .methodCall {
                let callName = (text as NSString).substring(with: call.range)
                guard callName == symbol else { continue }
                let callOffset = call.range.location
                let enclosingDeclaration = methodDeclarations.last {
                    $0.range.location < callOffset
                }
                guard callBelongsToType(
                    callOffset: callOffset,
                    text: code,
                    fileType: fileType,
                    targetType: targetType,
                    targetPackage: targetPackage
                ) else { continue }

                let range = sourceRange(in: text, utf16Range: call.range)
                results.append(JavaNavigationTarget(
                    fileURL: fileURL.standardizedFileURL,
                    range: range,
                    selectionRange: range,
                    name: enclosingDeclaration.map {
                        (text as NSString).substring(with: $0.range)
                    } ?? symbol,
                    detail: nil,
                    containerName: fileType,
                    kind: .method
                ))
            }
        }

        return results.sorted {
            if $0.fileURL.path != $1.fileURL.path {
                return $0.fileURL.path < $1.fileURL.path
            }
            if $0.range.start.line != $1.range.start.line {
                return $0.range.start.line < $1.range.start.line
            }
            return $0.range.start.character < $1.range.start.character
        }
    }

    private static func owningRepository(
        fileURL: URL, workspaceURL: URL, repositories: [RegisteredRepository]
    ) -> URL? {
        let path = fileURL.standardizedFileURL.path
        return repositories.map {
            ($0.relativePath == "." ? workspaceURL : workspaceURL.appendingPathComponent($0.relativePath))
                .standardizedFileURL
        }.filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    private static func methodDeclarationRange(
        in text: String,
        at position: JavaSourcePosition
    ) -> NSRange? {
        let offset = utf16Offset(for: position, in: text)
        return JavaSyntaxHighlighter.highlights(in: text).first {
            guard $0.style == .methodDeclaration else { return false }
            return NSLocationInRange(offset, $0.range) || offset == NSMaxRange($0.range)
        }?.range
    }

    private static func callBelongsToType(
        callOffset: Int,
        text: String,
        fileType: String,
        targetType: String,
        targetPackage: String
    ) -> Bool {
        let prefix = (text as NSString).substring(
            with: NSRange(location: 0, length: min(callOffset, (text as NSString).length))
        )
        let receiverMatch = try? NSRegularExpression(
            pattern: #"([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*$"#
        ).firstMatch(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        )
        guard let receiverMatch, receiverMatch.numberOfRanges > 1 else {
            return fileType == targetType && packageName(in: text) == targetPackage
        }
        let receiver = (prefix as NSString).substring(with: receiverMatch.range(at: 1))
        if receiver == "this" {
            return fileType == targetType && packageName(in: text) == targetPackage
        }
        let typePattern = #"\b([A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*)\s+"#
            + NSRegularExpression.escapedPattern(for: receiver) + #"\s*(?=[;=,)])"#
        guard let typeMatch = try? NSRegularExpression(pattern: typePattern).matches(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        ).last,
        typeMatch.numberOfRanges > 1 else {
            return false
        }
        let receiverType = (prefix as NSString).substring(with: typeMatch.range(at: 1))
        let qualifiedTarget = targetPackage.isEmpty ? targetType : targetPackage + "." + targetType
        if receiverType.contains(".") { return receiverType == qualifiedTarget }
        guard receiverType == targetType else { return false }
        let importPattern = #"\bimport\s+([A-Za-z_$][A-Za-z0-9_$.]*)\."#
            + NSRegularExpression.escapedPattern(for: targetType) + #"\s*;"#
        if let importedPackage = firstCapture(of: importPattern, in: text) {
            return importedPackage == targetPackage
        }
        return packageName(in: text) == targetPackage
    }

    private static func codeMaskingLiterals(
        in text: String,
        spans: [JavaSyntaxHighlightSpan]? = nil
    ) -> String {
        let code = NSMutableString(string: text)
        for span in spans ?? JavaSyntaxHighlighter.highlights(in: text)
            where span.style == .comment || span.style == .string {
            code.replaceCharacters(in: span.range, with: String(repeating: " ", count: span.range.length))
        }
        return code as String
    }

    private static func packageName(in text: String) -> String {
        firstCapture(of: #"\bpackage\s+([A-Za-z_$][A-Za-z0-9_$.]*)\s*;"#, in: text) ?? ""
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        ), match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
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
                let values = try? url.resourceValues(forKeys: Set(keys))
                if ["target", "build", "out", "node_modules"].contains(name)
                    || values?.isSymbolicLink == true
                    || (values?.isDirectory == true
                        && FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)) {
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

private actor JavaMethodCallerIndexCache {
    private struct Key: Hashable, Sendable {
        let workspacePath: String
        let repositoryPath: String
    }

    private struct Entry {
        let generation: UUID
        let task: Task<[String: [URL]], Never>
    }

    private var entries: [Key: Entry] = [:]

    func filesByMethodName(workspaceURL: URL, repositoryURL: URL) async -> [String: [URL]] {
        let key = Key(workspacePath: workspaceURL.standardizedFileURL.path,
                      repositoryPath: repositoryURL.standardizedFileURL.path)
        let entry: Entry
        if let cached = entries[key] {
            entry = cached
        } else {
            // Store the task before awaiting it so prewarming and the first click
            // share one scan rather than launching duplicate repository reads.
            let task = Task.detached(priority: .utility) {
                let files = JavaWorkspaceNavigationFallback.sourceFilesByTypeUnderRoots([repositoryURL])
                    .values.flatMap { $0 }
                guard let expression = try? NSRegularExpression(
                    pattern: #"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\("#
                ) else { return [String: [URL]]() }
                var index: [String: [URL]] = [:]
                for fileURL in files {
                    guard !Task.isCancelled else { return [:] }
                    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                    let source = text as NSString
                    let names = Set(expression.matches(in: text, range: NSRange(location: 0, length: source.length))
                        .map { source.substring(with: $0.range(at: 1)) })
                    for name in names { index[name, default: []].append(fileURL.standardizedFileURL) }
                }
                return index
            }
            entry = Entry(generation: UUID(), task: task)
            entries[key] = entry
        }
        let result = await entry.task.value
        guard entries[key]?.generation == entry.generation else {
            // File changes during a scan must not repopulate the cache with its
            // stale result or let a waiting navigation use that result.
            return await filesByMethodName(workspaceURL: workspaceURL, repositoryURL: repositoryURL)
        }
        return result
    }

    func invalidate(workspaceURL: URL, changedFileURLs: [URL]?) {
        let path = workspaceURL.standardizedFileURL.path
        let relevantURLs = changedFileURLs?.filter {
            $0.pathExtension.lowercased() == "java" || $0.pathExtension.isEmpty
                || $0.path.contains("/.git/") || $0.lastPathComponent == "pom.xml"
        }
        let keys = entries.keys.filter { key in
            guard key.workspacePath == path else { return false }
            guard let relevantURLs else { return true }
            return relevantURLs.contains {
                let changedPath = $0.standardizedFileURL.path
                return changedPath == key.repositoryPath || changedPath.hasPrefix(key.repositoryPath + "/")
                    || key.repositoryPath.hasPrefix(changedPath + "/")
            }
        }
        for key in keys {
            entries.removeValue(forKey: key)?.task.cancel()
        }
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
