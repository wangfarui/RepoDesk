import Foundation
@testable import RepoDesk

private actor ColdNavigationProvider: JavaLanguageProviding {
    nonisolated let events = AsyncStream<JavaLanguageProviderEvent> { $0.finish() }
    private(set) var requests = 0
    let delay: Duration
    let targets: [JavaNavigationTarget]
    init(delay: Duration = .seconds(3), targets: [JavaNavigationTarget] = []) {
        self.delay = delay
        self.targets = targets
    }
    func configure(_ settings: JavaIndexSettings) async {}
    func updateWorkspace(workspaceURL: URL?, repositories: [RegisteredRepository], projectJavaHome: String?, mavenUserSettingsFile: String?, mavenLocalRepositoryURL: URL?) async {}
    func prioritize(repositoryID: RegisteredRepository.ID) async {}
    func navigationTargets(repositoryID: RegisteredRepository.ID, request: JavaNavigationRequest) async -> [JavaNavigationTarget] {
        requests += 1
        try? await Task.sleep(for: delay)
        return targets
    }
    func searchSymbols(_ request: JavaSymbolSearchRequest) async -> [JavaNavigationTarget] { [] }
    func semanticTokens(repositoryID: RegisteredRepository.ID, fileURL: URL, text: String) async -> [JavaSemanticToken] { [] }
    func notifyFilesChanged(_ fileURLs: [URL]) async {}
    func setBackgroundIndexingPaused(_ paused: Bool) async {}
    func rebuildIndex(repositoryID: RegisteredRepository.ID) async {}
    func clearUnusedCaches() async {}
    func shutdown() async {}
}

@MainActor private final class NavigationWindowStore: WindowStateStoring {
    func state(for workspaceURL: URL) -> WorkspaceWindowState { .initial }
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {}
}

@main @MainActor enum VerifyFirstClick {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoDesk-FirstClick-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("repo/src/main/java/example/Dao.java")
        let caller = source.deletingLastPathComponent().appendingPathComponent("Manager.java")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "package example;\nclass Dao { public void searchPriceVersions() {} }"
        try Data(text.utf8).write(to: source)
        try Data("package example;\nclass Manager { Dao dao; void searchByPriceId() { dao.searchPriceVersions(); } }".utf8).write(to: caller)
        let repository = RegisteredRepository(displayName: "repo", relativePath: "repo", isPinned: false)
        let provider = ColdNavigationProvider()
        let state = AppState(workspace: WorkspaceSummary(url: root), repositories: [repository],
                             selectedRepositoryID: repository.id, selectedSection: .files,
                             windowStateStore: NavigationWindowStore(), javaLanguageProvider: provider,
                             restoresWorkspaceOnLaunch: false)
        state.selectFile(source)
        while state.isLoadingDocument { try await Task.sleep(for: .milliseconds(5)) }
        let position = JavaSourcePosition(line: 1, character: ("class Dao { public void ").utf16.count)
        let start = ContinuousClock.now
        state.performJavaNavigation(action: .contextual, fileURL: source, position: position, documentText: text)
        while state.selectedFileURL != caller.standardizedFileURL {
            guard start.duration(to: .now) < .milliseconds(500) else {
                throw VerificationError(description: "First declaration click waited for the cold Java provider instead of opening its caller within 500ms")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        print("First declaration click: \(start.duration(to: .now))")
        let count = await provider.requests
        guard count == 0 else { throw VerificationError(description: "Source caller navigation unnecessarily started a slow semantic request") }

        // When a semantic session is ready, it must retain authority over the
        // source shortcut (e.g. additional callers through inherited bindings).
        let semanticCaller = caller.deletingLastPathComponent().appendingPathComponent("InheritedManager.java")
        try Data("package example; class InheritedManager {}".utf8).write(to: semanticCaller)
        let zero = JavaSourcePosition(line: 0, character: 0)
        let readyProvider = ColdNavigationProvider(delay: .milliseconds(10), targets: [JavaNavigationTarget(
            fileURL: semanticCaller, range: JavaSourceRange(start: zero, end: zero), selectionRange: nil,
            name: "inheritedCaller", detail: nil, containerName: "InheritedManager", kind: .method
        )])
        let readyState = AppState(workspace: WorkspaceSummary(url: root), repositories: [repository],
                                  selectedRepositoryID: repository.id, selectedSection: .files,
                                  windowStateStore: NavigationWindowStore(), javaLanguageProvider: readyProvider,
                                  restoresWorkspaceOnLaunch: false)
        readyState.selectFile(source)
        while readyState.isLoadingDocument { try await Task.sleep(for: .milliseconds(5)) }
        readyState.javaIndexSnapshot = JavaIndexSnapshot(
            repositories: [JavaRepositoryIndexState(repositoryID: repository.id, displayName: "repo", phase: .ready,
                                                     progress: 1, detail: nil, branchName: nil, cacheBytes: 0)],
            activeRepositoryID: repository.id, runningJVMCount: 1, cacheBytes: 0, isBackgroundIndexingPaused: false
        )
        readyState.performJavaNavigation(action: .contextual, fileURL: source, position: position, documentText: text)
        let semanticStart = ContinuousClock.now
        while readyState.selectedFileURL != semanticCaller.standardizedFileURL {
            guard semanticStart.duration(to: .now) < .milliseconds(500) else {
                throw VerificationError(description: "Source shortcut incorrectly replaced the ready semantic result")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await readyProvider.requests == 1 else {
            throw VerificationError(description: "Ready semantic navigation was bypassed")
        }
        print("First-click Java navigation verification passed")
    }
}
private struct VerificationError: Error, CustomStringConvertible { let description: String }
