import Foundation
@testable import RepoDesk

private struct FileNavigationVerificationError: Error, CustomStringConvertible {
    let description: String
}

private actor NavigationJavaLanguageProvider: JavaLanguageProviding {
    nonisolated let events: AsyncStream<JavaLanguageProviderEvent>

    init() {
        events = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func configure(_ settings: JavaIndexSettings) async {}
    func updateWorkspace(
        workspaceURL: URL?,
        repositories: [RegisteredRepository],
        projectJavaHome: String?,
        mavenUserSettingsFile: String?, mavenLocalRepositoryURL: URL?
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
    ) async -> [JavaSemanticToken] { [] }
    func notifyFilesChanged(_ fileURLs: [URL]) async {}
    func setBackgroundIndexingPaused(_ paused: Bool) async {}
    func rebuildIndex(repositoryID: RegisteredRepository.ID) async {}
    func clearUnusedCaches() async {}
    func shutdown() async {}
}

@MainActor
private final class NavigationWindowStateStore: WindowStateStoring {
    func state(for workspaceURL: URL) -> WorkspaceWindowState { .initial }
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {}
}

@main
@MainActor
enum VerifyFileNavigationHistory {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskFileNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try ["A.swift", "B.java", "C.md", "D.txt"].map { name -> URL in
            let url = root.appendingPathComponent(name)
            try "\(name)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        try verifyBackForwardAndBranching(root: root, files: files)
        try verifyTabSelection(root: root, files: files)
        try verifyImportFoldingTabs(root: root, files: files)
        try verifyClosedFileReopens(root: root, files: files)
        try verifyDeletedFileIsSkipped(root: root, files: files)
        try verifyMouseButtons()
        print("File navigation history verification passed")
    }

    private static func verifyBackForwardAndBranching(root: URL, files: [URL]) throws {
        let state = makeState(root: root)
        state.selectFile(files[0], line: 10)
        state.rememberSelectedFileVisibleLine(12)
        state.selectFile(files[1], line: 20)
        state.rememberSelectedFileVisibleLine(23)
        state.selectFile(files[2], line: 30)

        try require(state.navigateFileBack(), "First backward navigation was unavailable")
        try requireLocation(state, file: files[1], line: 23)
        try require(state.navigateFileBack(), "Second backward navigation was unavailable")
        try requireLocation(state, file: files[0], line: 12)
        try require(state.navigateFileForward(), "First forward navigation was unavailable")
        try requireLocation(state, file: files[1], line: 23)
        try require(state.navigateFileForward(), "Second forward navigation was unavailable")
        try requireLocation(state, file: files[2], line: 30)

        try require(state.navigateFileBack(), "Backward navigation before branching failed")
        state.selectFile(files[3], line: 4)
        try require(!state.canNavigateFileForward, "A new navigation did not clear forward history")
        try require(!state.navigateFileForward(), "Cleared forward history still navigated")

        state.selectFile(files[3], line: 4)
        try require(state.navigateFileBack(), "Duplicate selection removed valid backward history")
        try requireLocation(state, file: files[1], line: 23)
    }

    private static func verifyTabSelection(root: URL, files: [URL]) throws {
        let state = makeState(root: root)
        state.selectFile(files[0], line: 5)
        state.selectFile(files[1], line: 8)
        guard let firstTab = state.openFileTabs.first(where: { $0.url == files[0] }) else {
            throw FileNavigationVerificationError(description: "Tab fixture did not open the first file")
        }
        state.selectFileTab(firstTab)
        try require(state.selectedFileURL == files[0], "Tab selection did not activate its file")
        try require(state.navigateFileBack(), "Tab selection was not added to history")
        try requireLocation(state, file: files[1], line: 8)
    }

    private static func verifyImportFoldingTabs(root: URL, files: [URL]) throws {
        let state = makeState(root: root)
        let javaFile = files[1]
        state.selectFile(javaFile, line: 1)
        guard let index = state.openFileTabs.firstIndex(where: { $0.url == javaFile }) else {
            throw FileNavigationVerificationError(description: "Java tab did not open")
        }
        try require(!state.openFileTabs[index].importsExpanded, "New Java tab should default to folded imports")
        state.openFileTabs[index].importsExpanded = true
        state.selectFile(files[0], line: 1)
        guard let javaTab = state.openFileTabs.first(where: { $0.url == javaFile }) else {
            throw FileNavigationVerificationError(description: "Java tab disappeared on switch")
        }
        state.selectFileTab(javaTab)
        try require(state.openFileTabs.first { $0.url == javaFile }?.importsExpanded == true,
                    "Switching tabs lost the expanded import state")
        state.closeFileTab(id: javaFile)
        state.selectFile(javaFile, line: 1)
        try require(state.openFileTabs.first { $0.url == javaFile }?.importsExpanded == false,
                    "Closing and reopening a Java tab should reset import folding")
    }

    private static func verifyClosedFileReopens(root: URL, files: [URL]) throws {
        let state = makeState(root: root)
        state.selectFile(files[0], line: 6)
        state.selectFile(files[1], line: 9)
        state.closeFileTab(id: files[0])
        try require(!state.openFileTabs.contains(where: { $0.url == files[0] }), "Fixture did not close file")
        try require(state.navigateFileBack(), "Closed history target was not navigable")
        try requireLocation(state, file: files[0], line: 6)
        try require(state.openFileTabs.contains(where: { $0.url == files[0] }), "Closed history target did not reopen")
    }

    private static func verifyDeletedFileIsSkipped(root: URL, files: [URL]) throws {
        let state = makeState(root: root)
        state.selectFile(files[0], line: 3)
        state.selectFile(files[1], line: 7)
        state.selectFile(files[2], line: 11)
        try FileManager.default.removeItem(at: files[1])
        defer { try? "B.java\n".write(to: files[1], atomically: true, encoding: .utf8) }

        try require(state.navigateFileBack(), "History stopped at a deleted file")
        try requireLocation(state, file: files[0], line: 3)
    }

    private static func verifyMouseButtons() throws {
        try require(
            RepoDeskApplicationDelegate.fileNavigationAction(forMouseButton: 3) == .back,
            "Mouse button 3 was not mapped to backward navigation"
        )
        try require(
            RepoDeskApplicationDelegate.fileNavigationAction(forMouseButton: 4) == .forward,
            "Mouse button 4 was not mapped to forward navigation"
        )
        try require(
            RepoDeskApplicationDelegate.fileNavigationAction(forMouseButton: 2) == nil,
            "Middle mouse button must remain untouched"
        )
    }

    private static func makeState(root: URL) -> AppState {
        AppState(
            workspace: WorkspaceSummary(url: root),
            selectedSection: .files,
            windowStateStore: NavigationWindowStateStore(),
            javaLanguageProvider: NavigationJavaLanguageProvider(),
            restoresWorkspaceOnLaunch: false
        )
    }

    private static func requireLocation(_ state: AppState, file: URL, line: Int) throws {
        try require(state.selectedFileURL == file, "Expected \(file.lastPathComponent) to be selected")
        try require(
            state.selectedSourceNavigationRequest?.line == line,
            "Expected \(file.lastPathComponent) to restore line \(line)"
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FileNavigationVerificationError(description: message) }
    }
}
