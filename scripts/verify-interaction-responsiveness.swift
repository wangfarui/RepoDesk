import AppKit
import Foundation
import SwiftUI
@testable import RepoDesk

@main
@MainActor
enum VerifyInteractionResponsiveness {
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskInteraction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "RepoDesk.InteractionVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try await verifySearch(in: root)
        try await verifySearchCancellationAndProgress(in: root, defaults: defaults)
        try await verifyHistory(in: root, defaults: defaults)
        try await verifyRetainedEditorAndTabs(in: root, defaults: defaults)
        print("Interaction responsiveness verification passed (package directories, progressive/cancelled search, History caching/filters, retained editor/focus, single-row scrolling tabs)")
    }

    private static func verifySearch(in root: URL) async throws {
        for name in ["alpha.service", "ordinary", "Ignored.app", "target"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "first\r\nUniqueAuditNeedle\r\nthird".write(
                to: directory.appendingPathComponent("UniqueAuditNeedle.java"), atomically: true, encoding: .utf8
            )
        }
        let names = await FileSystemWorkspaceSearch().search(in: root, query: "UniqueAuditNeedle", limit: 100)
        let content = await FileSystemWorkspaceTextSearch().search(in: root, query: "uniqueauditneedle", limit: 300)
        try require(names.count == 2 && content.count == 2, "Workspace search skips .service source or includes generated/app bundles")
        try require(content.allSatisfy { $0.line == 2 }, "Search reports incorrect CRLF line numbers")
        let utf16 = root.appendingPathComponent("ordinary/utf16.txt")
        try "第一行\r\n加工分类 Needle".write(to: utf16, atomically: true, encoding: .utf16)
        let unicode = await FileSystemWorkspaceTextSearch().search(in: root, query: "加工分类 needle", limit: 10)
        try require(unicode.count == 1 && unicode[0].line == 2, "UTF-16 Unicode/case-insensitive search regressed")
        let many = root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<80 {
            try "needle \(index)".write(to: many.appendingPathComponent("\(index).txt"), atomically: true, encoding: .utf8)
        }
        let batches = SearchBatches()
        let results = await FileSystemWorkspaceTextSearch().search(in: many, query: "needle", limit: 45) {
            batches.record($0.count)
        }
        try require(results.count == 45 && batches.counts.contains(where: { $0 > 0 && $0 < 45 }), "Search does not publish partial results or respect its limit")
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return await FileSystemWorkspaceTextSearch().search(in: many, query: "needle", limit: 300)
        }
        cancelled.cancel()
        let cancelledResults = await cancelled.value
        try require(cancelledResults.isEmpty, "A cancelled search still scans files")
    }

    private static func verifySearchCancellationAndProgress(in root: URL, defaults: UserDefaults) async throws {
        let search = ControlledSearch(root: root)
        let state = AppState(
            workspace: WorkspaceSummary(url: root), workspaceTextSearch: search,
            windowStateStore: UserDefaultsWindowStateStore(defaults: defaults),
            appPreferencesStore: UserDefaultsAppPreferencesStore(defaults: defaults), restoresWorkspaceOnLaunch: false
        )
        state.searchWorkspaceText(query: "old")
        try await waitUntil { state.textSearchResults.first?.lineText == "old-partial" }
        try require(state.isSearchingText, "Partial result waits for the entire scan")
        state.searchWorkspaceText(query: "new")
        try require(state.textSearchResults.first?.lineText == "old-partial" && state.textSearchResultsAreStale,
                    "Updating a search erases old results without marking them stale")
        try await waitUntil { !state.isSearchingText && state.textSearchResults.first?.lineText == "new-final" }
        let cancelled = await search.cancelledQueries
        try require(cancelled.contains("old") && !state.textSearchResultsAreStale, "Old search is not cancelled or overwrites the new query")
        state.searchWorkspaceText(query: "dismiss")
        try await waitUntil { state.textSearchResults.first?.lineText == "dismiss-partial" }
        state.cancelSearches()
        try await Task.sleep(for: .milliseconds(30))
        let dismissedQueries = await search.cancelledQueries
        try require(dismissedQueries.contains("dismiss") && !state.isSearchingText, "Dismissed search continues running")
    }

    private static func verifyHistory(in root: URL, defaults: UserDefaults) async throws {
        let reader = DelayedHistoryReader()
        let repository = RegisteredRepository(displayName: "repo", relativePath: ".", isPinned: false)
        let state = AppState(
            workspace: WorkspaceSummary(url: root), repositories: [repository], selectedRepositoryID: repository.id,
            gitRepositoryReader: reader, windowStateStore: UserDefaultsWindowStateStore(defaults: defaults),
            appPreferencesStore: UserDefaultsAppPreferencesStore(defaults: defaults), restoresWorkspaceOnLaunch: false
        )
        await state.refreshCurrentRepository()
        let first = Task { await state.ensureHistoryLoaded() }
        try await waitUntil { await reader.historyCount == 1 }
        let metadataFinished = await reader.metadataFinished
        try require(!metadataFinished, "Default History is still blocked behind the authors scan")
        await first.value
        await state.ensureHistoryLoaded()
        let cachedCount = await reader.historyCount
        try require(cachedCount == 1, "Re-entering unchanged History reloads commits")
        await state.refreshHistory()
        let refreshedCount = await reader.historyCount
        try require(refreshedCount == 2, "Explicit History refresh incorrectly uses stale cache")
        state.historyAuthorFilter = .me
        await state.refreshHistory()
        let authors = await reader.requestedAuthors
        try require(authors.last! == "Alice", "Me filter ran before resolving the Git username")
        state.historyBranchFilter = .branch("deleted")
        state.historyAuthorFilter = .author("missing")
        await state.refreshHistory()
        try require(state.historyBranchFilter == .current && state.historyAuthorFilter == .all,
                    "Stale branch/author filters were not validated before loading History")
        await reader.changeHead()
        await state.refreshCurrentRepository()
        await state.ensureHistoryLoaded()
        let invalidatedCount = await reader.historyCount
        try require(invalidatedCount == 5, "Changed HEAD does not invalidate cached History")
    }

    private static func verifyRetainedEditorAndTabs(in root: URL, defaults: UserDefaults) async throws {
        let state = AppState(
            workspace: WorkspaceSummary(url: root), selectedSection: .files,
            windowStateStore: UserDefaultsWindowStateStore(defaults: defaults),
            appPreferencesStore: UserDefaultsAppPreferencesStore(defaults: defaults), restoresWorkspaceOnLaunch: false
        )
        state.fileChildren[root.standardizedFileURL] = (0..<1_000).map {
            WorkspaceFileEntry(url: root.appendingPathComponent("File\($0).java"), name: "File\($0).java", isDirectory: false)
        }
        let source = (0..<3_000).map { "private String field\($0) = \"value\";" }.joined(separator: "\n")
        let document = LoadedDocument.text(LoadedTextDocument(text: source, isLarge: false, encoding: .utf8,
            revision: DocumentRevision(byteCount: source.utf8.count, contentDigest: 1)))
        state.openFileTabs = (0..<7).map {
            OpenFileTab(url: root.appendingPathComponent("LongInventoryImportConvert\($0).java"), loadedDocument: document,
                text: source, originalText: source, fingerprint: nil, showsMarkdownPreview: false, isLoading: false, visibleLine: 1)
        }
        state.selectedFileURL = state.openFileTabs[0].url
        state.loadedDocument = document
        state.documentText = source
        state.documentOriginalText = source
        let host = NSHostingView(rootView: RootView(appState: state))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.close() }
        try await settle(host)
        guard let editor = descendants(host).compactMap({ $0 as? NSTextView }).first(where: { $0.string == source }) else {
            throw failure("Source editor not rendered")
        }
        editor.setSelectedRange(NSRange(location: 100, length: 3))
        window.makeFirstResponder(editor)
        state.selectedSection = .changes
        try await settle(host)
        try require(window.firstResponder !== editor && !ContentFindWindowRegistry.shared.contains(window),
                    "Inactive Files editor still owns keyboard focus or Find commands")
        state.selectedSection = .files
        try await settle(host)
        let retained = descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == source }
        try require(retained === editor && editor.selectedRange() == NSRange(location: 100, length: 3),
                    "Module switch recreates editor or loses the selection")
        let tabsScroll = descendants(host).compactMap { $0 as? NSScrollView }.first {
            $0.frame.height >= 35 && $0.frame.height <= 52
        }
        guard let tabsScroll, let tabsDocument = tabsScroll.documentView else { throw failure("Single-row tab scroller is missing") }
        try require(tabsDocument.frame.width > tabsScroll.contentView.bounds.width + 100, "Overflowing file tabs do not scroll horizontally")
        state.selectFileTab(state.openFileTabs.last!)
        try await settle(host)
        try require(tabsScroll.contentView.bounds.minX > 100, "Selecting an offscreen tab does not scroll it into view")
        state.selectFileTab(state.openFileTabs[0])
        try await settle(host)
        try require(tabsScroll.contentView.bounds.minX < 1, "Selecting the first tab does not restore the leftmost viewport")
        let origin = editor.enclosingScrollView!.convert(NSPoint.zero, to: host)
        state.closeOtherFileTabs(keeping: state.openFileTabs[0].id)
        try await settle(host)
        let after = editor.enclosingScrollView!.convert(NSPoint.zero, to: host)
        try require(abs(origin.y - after.y) < 1, "Closing file tabs shifts the editor vertically")
        try require(descendants(host).count < 1_500, "1000-row file tree still materializes all native rows")
        print("Retained editor and single-row tab layout verified; 1000-row tree native views: \(descendants(host).count)")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/interaction-responsiveness.png"))
        }
    }

    private static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw failure("Timed out waiting for interaction state")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "InteractionResponsiveness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class SearchBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var counts: [Int] { lock.withLock { values } }
    func record(_ count: Int) { lock.withLock { values.append(count) } }
}

private actor ControlledSearch: WorkspaceTextSearching {
    let root: URL
    var cancelledQueries: [String] = []
    init(root: URL) { self.root = root }
    func search(in workspaceURL: URL, query: String, limit: Int) async -> [WorkspaceTextSearchResult] { [] }
    func search(in workspaceURL: URL, query: String, limit: Int,
                onUpdate: @escaping @Sendable ([WorkspaceTextSearchResult]) -> Void) async -> [WorkspaceTextSearchResult] {
        onUpdate([result("\(query)-partial")])
        do { try await Task.sleep(for: .milliseconds(350)) }
        catch { cancelledQueries.append(query); return [] }
        return [result("\(query)-final")]
    }
    private func result(_ text: String) -> WorkspaceTextSearchResult {
        WorkspaceTextSearchResult(fileURL: root.appendingPathComponent("result.txt"), line: 1, lineText: text)
    }
}

private actor DelayedHistoryReader: GitRepositoryReading {
    var historyCount = 0
    var metadataFinished = false
    var requestedAuthors: [String?] = []
    private var currentHash = "abcdef"
    func changeHead() { currentHash = "fedcba" }
    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(branch: "main", isDetachedHEAD: false, aheadCount: 0, behindCount: 0, changes: [],
            lastCommit: GitCommitSummary(hash: currentHash, subject: "Commit", author: "Alice", authoredAt: nil))
    }
    func fileDiff(repositoryURL: URL, target: GitDiffTarget, ignoringWhitespace: Bool) async throws -> GitFileDiff {
        throw GitRepositoryError.pushPreparationUnavailable
    }
    func history(repositoryURL: URL, limit: Int, skip: Int, revision: String?, author: String?) async throws -> [GitCommitSummary] {
        historyCount += 1
        requestedAuthors.append(author)
        return []
    }
    func branches(repositoryURL: URL) async throws -> [GitBranch] {
        [GitBranch(name: "main", hash: "abcdef", upstream: nil, isRemote: false, isCurrent: true)]
    }
    func authors(repositoryURL: URL) async throws -> [String] {
        metadataFinished = false
        try await Task.sleep(for: .milliseconds(250))
        metadataFinished = true
        return ["Alice"]
    }
    func currentUserName(repositoryURL: URL) async throws -> String? { "Alice" }
    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail { throw GitRepositoryError.pushPreparationUnavailable }
}
