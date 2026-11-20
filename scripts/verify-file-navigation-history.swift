import Foundation
import AppKit
import SwiftUI
@testable import RepoDesk

private struct FileNavigationVerificationError: Error, CustomStringConvertible {
    let description: String
}

// Headless verification windows have windowNumber == 0, so keyEvent(...) loses
// their identity. Supply that association explicitly when exercising the handler.
private final class FontSizeKeyEvent: NSEvent {
    var targetWindow: NSWindow?
    var key: String?
    var flags: NSEvent.ModifierFlags = []
    override var window: NSWindow? { targetWindow }
    override var charactersIgnoringModifiers: String? { key }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
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
    static func main() async throws {
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
        try await verifyTemporaryFontSizes(root: root, files: files)
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

    private static func verifyTemporaryFontSizes(root: URL, files: [URL]) async throws {
        _ = NSApplication.shared
        let state = makeState(root: root)
        state.selectFile(files[0])
        try await waitUntil { !state.isLoadingDocument }
        let baseline = state.fileContentFontSize
        let originalText = state.documentText
        let host = NSHostingView(rootView: FilesView(appState: state))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { descendant(NSTextView.self, in: host) != nil }
        guard let listener = descendant(FileFontSizeCommandView.self, in: host),
              let editor = descendant(NSTextView.self, in: host) else {
            throw FileNavigationVerificationError(description: "Missing Files font shortcut listener/editor")
        }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        func event(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
                   in target: NSWindow? = nil) -> NSEvent {
            let event = FontSizeKeyEvent()
            event.targetWindow = target ?? window
            event.key = key
            event.flags = modifiers
            return event
        }
        try require(listener.handle(event("=")) == nil, "Command = was not consumed")
        try await waitUntil { editor.font?.pointSize == baseline + 1 }
        try require(editor.selectedRange() == NSRange(location: 0, length: 2), "Zoom changed selection")
        try require(state.documentText == originalText && !state.hasUnsavedDocumentChanges,
                    "Zoom modified file contents")
        try require(listener.handle(event("+", [.command, .shift])) == nil,
                    "Command Shift + was not consumed")
        try require(state.selectedFileContentFontSize == baseline + 2, "Zoom did not advance by one")
        try require(listener.handle(event("-")) == nil && state.selectedFileContentFontSize == baseline + 1,
                    "Command - did not decrease by one")
        try require(listener.handle(event("=", [.command, .option])) != nil, "Modified shortcut was captured")
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        try require(listener.handle(event("=", in: otherWindow)) != nil, "Another window changed Files font")
        otherWindow.close()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 25))
        host.addSubview(field)
        window.makeFirstResponder(field)
        try require(listener.handle(event("=")) != nil, "Text-field shortcut changed Files font")
        field.removeFromSuperview()
        window.makeFirstResponder(editor)

        state.selectFile(files[2])
        try await waitUntil { !state.isLoadingDocument }
        try require(state.selectedFileContentFontSize == baseline, "Another file inherited zoom")
        state.setMarkdownPreview(true)
        try require(state.adjustSelectedFileFontSize(.increase), "Markdown preview could not zoom")
        // Verify the preview document without requiring WebKit's GUI processes.
        let preview = MarkdownPreviewHTMLDocument(
            blocks: MarkdownPreviewParser.parseWithSourceLines(state.documentText),
            fontSize: state.selectedFileContentFontSize
        )
        try require(preview.html.contains("font-size: \(baseline + 1)px"),
                    "Markdown preview document did not receive the temporary font")
        state.setMarkdownPreview(false)
        try require(state.selectedFileContentFontSize == baseline + 1, "Preview/source switch lost zoom")
        state.selectFile(files[0])
        try require(state.selectedFileContentFontSize == baseline + 1, "Tab switch lost per-file zoom")
        try require(listener.handle(event("0")) == nil, "Command 0 was not consumed")
        try require(state.selectedFileContentFontSize == baseline, "Reset did not restore default")
        for _ in 0..<60 { state.adjustSelectedFileFontSize(.increase) }
        try require(state.selectedFileContentFontSize == 40, "Zoom exceeded upper limit")
        try await waitUntil { descendant(NSTextView.self, in: host)?.font?.pointSize == 40 }
        try require((descendant(NativeLineNumberRulerView.self, in: host)?.ruleThickness ?? 0) > 40,
                    "Large font did not widen the line-number gutter")
        for _ in 0..<60 { state.adjustSelectedFileFontSize(.decrease) }
        try require(state.selectedFileContentFontSize == 10, "Zoom exceeded lower limit")
        state.closeSelectedFileTab()
        state.selectFile(files[0])
        try await waitUntil { !state.isLoadingDocument }
        try require(state.selectedFileContentFontSize == baseline, "Reopened tab retained temporary zoom")
        try require(state.fileContentFontSize == baseline, "Temporary zoom changed preferences")
        state.selectedSection = .history
        try require(!state.adjustSelectedFileFontSize(.increase), "Zoom ran outside Files")
        state.selectedSection = .files
        state.loadedDocument = .binary(size: 1)
        try require(!state.adjustSelectedFileFontSize(.increase), "Binary file accepted font zoom")
        print("Files temporary font shortcuts, source rendering and Markdown document verification passed")
    }

    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FileNavigationVerificationError(description: "Files font verification timed out")
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
