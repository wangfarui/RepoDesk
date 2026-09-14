import Foundation
@testable import RepoDesk

private actor SemanticTokenProvider: JavaLanguageProviding {
    nonisolated let events: AsyncStream<JavaLanguageProviderEvent>
    private var requestedFiles: [URL] = []
    private let emptyFirstRequestFiles: Set<URL>

    init(emptyFirstRequestFiles: Set<URL> = []) {
        self.emptyFirstRequestFiles = emptyFirstRequestFiles
        events = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func configure(_ settings: JavaIndexSettings) async {}
    func updateWorkspace(
        workspaceURL: URL?,
        repositories: [RegisteredRepository],
        projectJavaHome: String?,
        mavenUserSettingsFile: String?
    ) async {}
    func prioritize(repositoryID: RegisteredRepository.ID) async {}
    func navigationTargets(
        repositoryID: RegisteredRepository.ID,
        request: JavaNavigationRequest
    ) async -> [JavaNavigationTarget] { [] }
    func searchSymbols(_ request: JavaSymbolSearchRequest) async -> [JavaNavigationTarget] { [] }
    func semanticTokens(
        repositoryID: RegisteredRepository.ID,
        fileURL: URL,
        text: String
    ) async -> [JavaSemanticToken] {
        requestedFiles.append(fileURL)
        try? await Task.sleep(for: .milliseconds(20))
        if emptyFirstRequestFiles.contains(fileURL), requestCount(for: fileURL) == 1 {
            return []
        }
        return [Self.token(for: fileURL)]
    }
    func notifyFilesChanged(_ fileURLs: [URL]) async {}
    func setBackgroundIndexingPaused(_ paused: Bool) async {}
    func rebuildIndex(repositoryID: RegisteredRepository.ID) async {}
    func clearUnusedCaches() async {}
    func shutdown() async {}

    func requestCount(for fileURL: URL) -> Int {
        requestedFiles.count { $0 == fileURL }
    }

    nonisolated static func token(for fileURL: URL) -> JavaSemanticToken {
        JavaSemanticToken(
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 0, character: 6),
                end: JavaSourcePosition(line: 0, character: 12)
            ),
            style: fileURL.lastPathComponent == "First.java" ? .class : .method
        )
    }
}

@main
@MainActor
enum VerifyJavaSemanticSwitching {
    static func main() async throws {
        let workspaceURL = URL(fileURLWithPath: "/tmp/RepoDeskJavaSemanticSwitch", isDirectory: true)
        let repository = RegisteredRepository(
            displayName: "java-repo",
            relativePath: "java-repo",
            isPinned: true
        )
        let repositoryURL = workspaceURL.appendingPathComponent("java-repo", isDirectory: true)
        let firstURL = repositoryURL.appendingPathComponent("First.java")
        let secondURL = repositoryURL.appendingPathComponent("Second.java")
        let thirdURL = repositoryURL.appendingPathComponent("Third.java")
        let firstText = "class First {}"
        let secondText = "class Second {}"
        let thirdText = "class Third {}"
        let firstDocument = textDocument(firstText)
        let secondDocument = textDocument(secondText)
        let thirdDocument = textDocument(thirdText)
        let firstTab = tab(url: firstURL, text: firstText, document: firstDocument)
        let secondTab = tab(url: secondURL, text: secondText, document: secondDocument)
        let thirdTab = tab(url: thirdURL, text: thirdText, document: thirdDocument)
        let provider = SemanticTokenProvider(emptyFirstRequestFiles: [thirdURL])
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            javaLanguageProvider: provider,
            restoresWorkspaceOnLaunch: false
        )
        state.openFileTabs = [firstTab, secondTab, thirdTab]
        state.selectedFileURL = firstURL
        state.loadedDocument = firstDocument
        state.documentText = firstText
        state.documentOriginalText = firstText
        state.javaSemanticTokens = [
            JavaSemanticToken(
                range: JavaSourceRange(
                    start: JavaSourcePosition(line: 0, character: 6),
                    end: JavaSourcePosition(line: 0, character: 11)
                ),
                style: .class
            )
        ]

        state.selectFileTab(secondTab)

        guard state.selectedFileURL == secondURL else {
            throw VerificationError.failed("Java tab switch did not activate the target file")
        }
        guard state.javaSemanticTokens.isEmpty else {
            throw VerificationError.failed("Java tab switch retained semantic tokens from the previous file")
        }
        try await waitUntil(timeout: .milliseconds(150)) {
            state.javaSemanticTokens == [SemanticTokenProvider.token(for: secondURL)]
        }

        state.selectFileTab(firstTab)
        guard state.javaSemanticTokens.isEmpty else {
            throw VerificationError.failed("Uncached Java tab displayed semantic tokens from another file")
        }
        try await waitUntil(timeout: .milliseconds(150)) {
            state.javaSemanticTokens == [SemanticTokenProvider.token(for: firstURL)]
        }

        state.selectFileTab(secondTab)
        guard state.javaSemanticTokens == [SemanticTokenProvider.token(for: secondURL)] else {
            throw VerificationError.failed("Cached Java semantic tokens were not restored synchronously")
        }
        guard await provider.requestCount(for: secondURL) == 1 else {
            throw VerificationError.failed("Cached Java tab requested semantic tokens again")
        }

        state.selectFileTab(thirdTab)
        try await waitUntil(timeout: .milliseconds(150)) {
            Task.isCancelled || state.selectedFileURL == thirdURL
        }
        try await Task.sleep(for: .milliseconds(60))
        guard state.javaSemanticTokens.isEmpty,
              await provider.requestCount(for: thirdURL) == 1 else {
            throw VerificationError.failed("Java empty-token fixture did not complete its first request")
        }
        state.selectFileTab(secondTab)
        state.selectFileTab(thirdTab)
        try await waitUntil(timeout: .milliseconds(150)) {
            state.javaSemanticTokens == [SemanticTokenProvider.token(for: thirdURL)]
        }
        guard await provider.requestCount(for: thirdURL) == 2 else {
            throw VerificationError.failed("Empty Java semantic tokens were cached as a stable result")
        }
        print("Java semantic switching verification passed")
    }

    private static func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VerificationError.failed("Timed out waiting for Java semantic token refresh")
    }

    private static func textDocument(_ text: String) -> LoadedDocument {
        .text(
            LoadedTextDocument(
                text: text,
                isLarge: false,
                encoding: .utf8,
                revision: DocumentRevision(byteCount: text.utf8.count, contentDigest: 0)
            )
        )
    }

    private static func tab(url: URL, text: String, document: LoadedDocument) -> OpenFileTab {
        OpenFileTab(
            url: url,
            loadedDocument: document,
            text: text,
            originalText: text,
            fingerprint: nil,
            showsMarkdownPreview: false,
            isLoading: false,
            visibleLine: 1
        )
    }

    private enum VerificationError: Error {
        case failed(String)
    }
}
