import Foundation

struct WorkspaceTextSearchResult: Equatable, Identifiable, Sendable {
    let fileURL: URL
    let line: Int
    let lineText: String

    var id: String { "\(fileURL.standardizedFileURL.path):\(line)" }
}

protocol WorkspaceTextSearching: Sendable {
    func search(in workspaceURL: URL, query: String, limit: Int) async -> [WorkspaceTextSearchResult]
    func search(
        in workspaceURL: URL, query: String, limit: Int,
        onUpdate: @escaping @Sendable ([WorkspaceTextSearchResult]) -> Void
    ) async -> [WorkspaceTextSearchResult]
}

extension WorkspaceTextSearching {
    func search(
        in workspaceURL: URL, query: String, limit: Int,
        onUpdate: @escaping @Sendable ([WorkspaceTextSearchResult]) -> Void
    ) async -> [WorkspaceTextSearchResult] {
        let results = await search(in: workspaceURL, query: query, limit: limit)
        if !Task.isCancelled { onUpdate(results) }
        return results
    }
}

struct FileSystemWorkspaceTextSearch: WorkspaceTextSearching {
    private static let skippedDirectories: Set<String> = [
        ".git", ".gradle", ".idea", "build", "node_modules", "target"
    ]
    private static let maximumSearchFileSize = 10_000_000

    func search(in workspaceURL: URL, query: String, limit: Int = 300) async -> [WorkspaceTextSearchResult] {
        await search(in: workspaceURL, query: query, limit: limit, onUpdate: { _ in })
    }

    func search(
        in workspaceURL: URL, query: String, limit: Int,
        onUpdate: @escaping @Sendable ([WorkspaceTextSearchResult]) -> Void
    ) async -> [WorkspaceTextSearchResult] {
        guard !Task.isCancelled else { return [] }
        let worker = Task.detached(priority: .userInitiated) {
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let matcher = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: normalizedQuery), options: [.caseInsensitive]
            )
            guard !normalizedQuery.isEmpty, limit > 0,
                  let enumerator = FileManager.default.enumerator(
                    at: workspaceURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                    options: [],
                    errorHandler: { _, _ in true }
                  ) else { return [WorkspaceTextSearchResult]() }

            var results: [WorkspaceTextSearchResult] = []
            var lastPublishedCount = 0
            var lastPublishedAt = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled, let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
                ) else { continue }
                if values.isDirectory == true {
                    // Source repositories ending in .service are macOS packages too.
                    // Skip known generated/app bundles explicitly instead of all packages.
                    if Self.skippedDirectories.contains(url.lastPathComponent)
                        || url.lastPathComponent.hasPrefix(".")
                        || ["app", "framework", "bundle", "xcodeproj"].contains(url.pathExtension.lowercased()) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      (values.fileSize ?? 0) <= Self.maximumSearchFileSize,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      (!Self.isBinary(data) || Self.isUTF16(data)),
                      let text = Self.decodeText(data),
                      matcher?.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil else { continue }

                // Most files do not match. Avoid allocating/splitting every line of
                // every file, and only enumerate lines after the whole-file prefilter.
                var lineIndex = 0
                text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, _, stop in
                    defer { lineIndex += 1 }
                    guard !Task.isCancelled, results.count < limit else { stop = true; return }
                    guard let line, matcher?.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil else { return }
                    results.append(WorkspaceTextSearchResult(
                        fileURL: url, line: lineIndex + 1,
                        lineText: line.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                let now = ProcessInfo.processInfo.systemUptime
                if results.count > lastPublishedCount,
                   lastPublishedCount == 0 || results.count - lastPublishedCount >= 32 || now - lastPublishedAt >= 0.06 {
                    onUpdate(results)
                    lastPublishedCount = results.count
                    lastPublishedAt = now
                }
                if results.count >= limit { break }
            }
            if !Task.isCancelled, results.count != lastPublishedCount { onUpdate(results) }
            return results
        }
        return await withTaskCancellationHandler {
            if Task.isCancelled { worker.cancel() }
            return await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(8_192).contains(0)
    }

    private static func isUTF16(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    }
}
