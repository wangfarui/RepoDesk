import AppKit
import Foundation
import SwiftUI
@testable import RepoDesk

private struct JavaVerificationError: Error, CustomStringConvertible {
    let description: String
}

private actor FakeSessionRegistry {
    private(set) var startedRepositories: [String] = []
    private(set) var startedConfigurations: [JavaLanguageServerConfiguration] = []
    private(set) var runningCount = 0
    private(set) var maximumRunningCount = 0

    func started(_ configuration: JavaLanguageServerConfiguration) {
        startedRepositories.append(configuration.repository.displayName)
        startedConfigurations.append(configuration)
        runningCount += 1
        maximumRunningCount = max(maximumRunningCount, runningCount)
    }

    func stopped() {
        runningCount = max(0, runningCount - 1)
    }

    func snapshot() -> (started: [String], running: Int, maximum: Int) {
        (startedRepositories, runningCount, maximumRunningCount)
    }

    func configurations() -> [JavaLanguageServerConfiguration] {
        startedConfigurations
    }
}

private actor FakeJavaLanguageServerSession: JavaLanguageServerSession {
    nonisolated let events: AsyncStream<JavaLanguageServerEvent>
    private let continuation: AsyncStream<JavaLanguageServerEvent>.Continuation
    private let registry: FakeSessionRegistry
    private let readyDelay: Duration
    private let navigationResult: [JavaNavigationTarget]
    private var didStart = false
    private var didStop = false

    init(
        registry: FakeSessionRegistry,
        readyDelay: Duration,
        navigationResult: [JavaNavigationTarget] = []
    ) {
        self.registry = registry
        self.readyDelay = readyDelay
        self.navigationResult = navigationResult
        let pair = AsyncStream<JavaLanguageServerEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: JavaLanguageServerConfiguration) async throws {
        didStart = true
        await registry.started(configuration)
        continuation.yield(.progress(fraction: 0.25, detail: "fake import"))
    }

    func waitUntilReady(timeout: Duration) async throws {
        try await Task.sleep(for: readyDelay)
        continuation.yield(.ready)
    }

    func shutdown() async {
        guard didStart, !didStop else { return }
        didStop = true
        await registry.stopped()
        continuation.finish()
    }

    func openOrUpdateDocument(fileURL: URL, text: String) async throws {}
    func closeDocument(fileURL: URL) async {}
    func navigationTargets(for request: JavaNavigationRequest) async throws -> [JavaNavigationTarget] {
        navigationResult
    }
    func searchSymbols(query: String, scope: JavaSymbolSearchScope) async throws -> [JavaNavigationTarget] { [] }
    func semanticTokens(fileURL: URL, text: String) async throws -> [JavaSemanticToken] { [] }
    func notifyFilesChanged(_ fileURLs: [URL]) async {}
}

private actor SnapshotRecorder {
    private var latest = JavaIndexSnapshot.idle

    func record(_ snapshot: JavaIndexSnapshot) {
        latest = snapshot
    }

    func snapshot() -> JavaIndexSnapshot { latest }
}

@main
enum VerifyJavaLanguage {
    static func main() async throws {
        try verifyClickRequestsContextualNavigation()
        try verifyMethodDeclarationSelectionRanges()
        try verifyEditorNavigationShortcuts()
        try await verifyNavigationRestoresFocusAfterMounting()
        try await verifyNavigationCentersTargetAfterMounting()
        try verifySettingsAndWireFormats()
        try verifyUTF16Navigation()
        try verifyDetectorAndCache()
        try await verifyNestedRepositoryBoundaries()
        try await verifySchedulerAndForegroundPreemption()
        try await verifyNavigationWaitsForReadyCachedRepository()
        try verifyNavigationTargetSources()
        print("Java language verification passed")
    }

    private static func verifyNavigationTargetSources() throws {
        let workspaceURL = URL(fileURLWithPath: "/tmp/RepoDesk-Java-Sources", isDirectory: true)
        let mavenRepositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Maven-Sources-\(UUID().uuidString)", isDirectory: true)
        let dependencyFileURL = mavenRepositoryURL
            .appendingPathComponent("com/google/guava/guava/32.0.0/guava-32.0.0.jar")
        try FileManager.default.createDirectory(
            at: dependencyFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: dependencyFileURL)
        defer { try? FileManager.default.removeItem(at: mavenRepositoryURL) }

        let repository = RegisteredRepository(
            displayName: "common",
            relativePath: "common",
            isPinned: false
        )
        let sourceURL = workspaceURL
            .appendingPathComponent("common/src/main/java/sample/Greeter.java")
        let sourceTarget = JavaNavigationTarget(
            fileURL: sourceURL,
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 3, character: 0),
                end: JavaSourcePosition(line: 3, character: 7)
            ),
            selectionRange: nil,
            name: "Greeter",
            detail: nil,
            containerName: nil,
            kind: .interface
        )
        let source = JavaNavigationTargetSourceResolver.origin(
            for: sourceTarget,
            workspaceURL: workspaceURL,
            repositories: [repository]
        )
        try require(
            source == .workspaceRepository(
                repositoryID: repository.id,
                repositoryName: repository.name,
                fileURL: sourceURL.standardizedFileURL
            ),
            "Workspace Java target source was not mapped to its Git repository"
        )

        let dependencyURI = "jdt://contents/guava-32.0.0.jar/com/google/common/collect/ImmutableList.class"
        let dependencyTarget = JavaNavigationTarget(
            fileURL: try requireURL(dependencyURI),
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 120, character: 8),
                end: JavaSourcePosition(line: 120, character: 20)
            ),
            selectionRange: nil,
            name: "ImmutableList",
            detail: nil,
            containerName: nil,
            kind: .interface
        )
        let dependency = JavaNavigationTargetSourceResolver.origin(
            for: dependencyTarget,
            workspaceURL: workspaceURL,
            repositories: [repository],
            mavenLocalRepositoryURL: mavenRepositoryURL
        )
        try require(
            dependency == .dependency(
                JavaDependencyReference(
                    uri: dependencyURI,
                    jarName: "guava-32.0.0.jar",
                    packageName: "com.google.common.collect",
                    typeName: "ImmutableList",
                    mavenCoordinate: "com.google.guava:guava:32.0.0"
                )
            ),
            "JDT dependency URI was not mapped to its JAR and qualified type"
        )

        let crossRepositoryWorkspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Java-CrossRepository-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: crossRepositoryWorkspaceURL) }
        let managerRepository = RegisteredRepository(
            displayName: "manager",
            relativePath: "manager",
            isPinned: false
        )
        let moduleDirectory = crossRepositoryWorkspaceURL
            .appendingPathComponent("manager/inventorymanager-client", isDirectory: true)
        let moduleSourceURL = moduleDirectory
            .appendingPathComponent(
                "src/main/java/com/internet/inventorymanager/client/service/InventoryManagerClientService.java"
            )
        try FileManager.default.createDirectory(
            at: moduleSourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("interface InventoryManagerClientService {}".utf8).write(to: moduleSourceURL)
        try Data("""
        <project>
          <groupId>com.internet.saasbusinessmanager</groupId>
          <artifactId>saasbusinessmanager</artifactId>
          <version>${revision}</version>
          <packaging>pom</packaging>
          <modules><module>inventorymanager-client</module></modules>
          <properties><revision>2.6.1-SNAPSHOT</revision></properties>
        </project>
        """.utf8).write(to: crossRepositoryWorkspaceURL.appendingPathComponent("manager/pom.xml"))
        try Data("""
        <project>
          <parent>
            <groupId>com.internet.saasbusinessmanager</groupId>
            <artifactId>saasbusinessmanager</artifactId>
            <version>${revision}</version>
          </parent>
          <artifactId>inventorymanager-client</artifactId>
        </project>
        """.utf8).write(to: moduleDirectory.appendingPathComponent("pom.xml"))

        let workspaceDependencyURI = "jdt://contents/inventorymanager-client-2.6.1-SNAPSHOT.jar/com/internet/inventorymanager/client/service/InventoryManagerClientService.class"
        let workspaceDependencyTarget = JavaNavigationTarget(
            fileURL: try requireURL(workspaceDependencyURI),
            range: dependencyTarget.range,
            selectionRange: nil,
            name: "InventoryManagerClientService",
            detail: nil,
            containerName: nil,
            kind: .interface
        )
        let workspaceDependencyOrigin = JavaNavigationTargetSourceResolver.origin(
            for: workspaceDependencyTarget,
            workspaceURL: crossRepositoryWorkspaceURL,
            repositories: [managerRepository]
        )
        try require(
            workspaceDependencyOrigin == .workspaceRepository(
                repositoryID: managerRepository.id,
                repositoryName: managerRepository.name,
                fileURL: moduleSourceURL.standardizedFileURL
            ),
            "A Maven dependency from the same workspace was not mapped back to its source repository"
        )
    }

    private static func requireURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw JavaVerificationError(description: "Invalid verification URL: \(string)")
        }
        return url
    }

    @MainActor
    private static func verifyClickRequestsContextualNavigation() throws {
        _ = NSApplication.shared
        let source = """
        interface ProcessingNotifyApi {
            ProcessingNotifyDetailPageResult searchProcessingNotifyDetailPage();
        }
        """
        var requests: [(JavaNavigationAction, JavaSourcePosition)] = []
        let editor = NativeCodeEditor(
            text: .constant(source),
            isEditable: true,
            style: .source(fileExtension: "java"),
            isJavaNavigationEnabled: true,
            onJavaNavigation: { action, position, _ in requests.append((action, position)) }
        )
        let hostingView = NSHostingView(rootView: editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: hostingView),
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            throw JavaVerificationError(description: "Java click fixture did not render")
        }
        layoutManager.ensureLayout(for: textContainer)
        let identifierRange = (source as NSString).range(of: "ProcessingNotifyDetailPageResult")
        let glyphRange = layoutManager.glyphRange(forCharacterRange: identifierRange, actualCharacterRange: nil)
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let point = textView.convert(
            NSPoint(x: bounds.midX + textView.textContainerOrigin.x, y: bounds.midY + textView.textContainerOrigin.y),
            to: nil
        )
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            throw JavaVerificationError(description: "Could not create Java class click")
        }
        textView.mouseDown(with: event)
        try require(requests.count == 1, "Class click did not dispatch exactly one navigation request")
        try require(
            requests[0].0 == .contextual,
            "Class click requested \(requests[0].0) instead of semantic contextual navigation"
        )
        try require(
            requests[0].1 == JavaSourcePosition(line: 1, character: 4),
            "Class click resolved a different token instead of the return type"
        )
        try require(window.makeFirstResponder(textView), "Click fixture could not focus the editor")
        for symbol in ["ProcessingNotifyDetailPageResult", "searchProcessingNotifyDetailPage"] {
            let range = (source as NSString).range(of: symbol)
            textView.setSelectedRange(range)
            guard let keyEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "b",
                charactersIgnoringModifiers: "b",
                isARepeat: false,
                keyCode: 11
            ) else {
                throw JavaVerificationError(description: "Could not create definition shortcut")
            }
            try require(textView.performKeyEquivalent(with: keyEvent), "Command+B was not handled")
            try require(requests.last?.0 == .declaration, "Command+B must always request definition")
        }
        let methodRange = (source as NSString).range(of: "searchProcessingNotifyDetailPage")
        textView.setSelectedRange(methodRange)
        guard let implementationEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        ) else {
            throw JavaVerificationError(description: "Could not create implementation shortcut")
        }
        try require(
            textView.performKeyEquivalent(with: implementationEvent),
            "Option+Command+B was not handled"
        )
        try require(
            requests.last?.0 == .implementation,
            "Option+Command+B must request implementations"
        )
    }

    private static func verifyMethodDeclarationSelectionRanges() throws {
        let symbols = try JSONValue(any: [[
            "kind": 5,
            "selectionRange": ["start": ["line": 0, "character": 6], "end": ["line": 0, "character": 12]],
            "children": [[
                "kind": 6,
                "range": ["start": ["line": 2, "character": 0], "end": ["line": 12, "character": 5]],
                "selectionRange": ["start": ["line": 5, "character": 35], "end": ["line": 5, "character": 40]]
            ], [
                "kind": 5,
                "children": [[
                    "kind": 6,
                    "selectionRange": ["start": ["line": 15, "character": 20], "end": ["line": 15, "character": 25]]
                ]]
            ]]
        ]])
        for position in [JavaSourcePosition(line: 5, character: 35), JavaSourcePosition(line: 5, character: 39), JavaSourcePosition(line: 15, character: 22)] {
            try require(
                JDTLanguageServerSession.isMethodDeclaration(in: symbols, at: position),
                "Method name selection did not match: \(position)"
            )
        }
        for position in [JavaSourcePosition(line: 0, character: 8), JavaSourcePosition(line: 2, character: 1), JavaSourcePosition(line: 5, character: 10), JavaSourcePosition(line: 5, character: 40), JavaSourcePosition(line: 9, character: 35)] {
            try require(
                !JDTLanguageServerSession.isMethodDeclaration(in: symbols, at: position),
                "Type, annotation, return type or method call mistaken for declaration: \(position)"
            )
        }
        let noNameRange = try JSONValue(any: [[
            "kind": 6,
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 30, "character": 0]]
        ]])
        try require(
            !JDTLanguageServerSession.isMethodDeclaration(in: noNameRange, at: JavaSourcePosition(line: 5, character: 3)),
            "Missing name range must not turn a whole method body into an incoming-call link"
        )
    }

    @MainActor
    private static func verifyEditorNavigationShortcuts() throws {
        _ = NSApplication.shared
        var backCount = 0
        var forwardCount = 0
        let editor = NativeCodeEditor(
            text: .constant("func caller() {}"),
            isEditable: true,
            style: .source(fileExtension: "swift"),
            isJavaNavigationEnabled: false,
            onNavigationBack: { backCount += 1 },
            onNavigationForward: { forwardCount += 1 }
        )
        let hostingView = NSHostingView(rootView: editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: hostingView) else {
            throw JavaVerificationError(description: "Source editor did not render")
        }
        try require(window.makeFirstResponder(textView), "Java editor did not accept keyboard focus")
        let deviceFlags: [NSEvent.ModifierFlags] = [[], .numericPad, .function, [.numericPad, .function]]
        for (index, flags) in deviceFlags.enumerated() {
            for (keyCode, character) in [(UInt16(123), "\u{F702}"), (UInt16(124), "\u{F703}")] {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: flags.union([.command, .option]),
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: character,
                    charactersIgnoringModifiers: character,
                    isARepeat: false,
                    keyCode: keyCode
                ) else {
                    throw JavaVerificationError(description: "Could not create navigation key event")
                }
                try require(
                    textView.performKeyEquivalent(with: event),
                "File history shortcut ignored arrow flags \(flags.rawValue)"
                )
            }
            try require(
                backCount == index + 1 && forwardCount == index + 1,
                "File history callbacks did not fire for arrow flags \(flags.rawValue)"
            )
        }
    }

    @MainActor
    private static func verifyNavigationRestoresFocusAfterMounting() async throws {
        let text = "class Caller {}"
        let coordinator = NativeCodeEditor(text: .constant(text), isEditable: true).makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = text
        coordinator.textView = textView
        coordinator.navigateIfNeeded(to: NativeTextNavigationRequest(line: 1))

        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(textView)
        try await Task.sleep(for: .milliseconds(20))
        try require(
            window.firstResponder === textView,
            "Java navigation did not restore focus when the target editor mounted"
        )
    }

    @MainActor
    private static func verifyNavigationCentersTargetAfterMounting() async throws {
        let targetLine = 193
        let source = (1...260).map { line in
            line == targetLine
                ? "public ProcessingNotifyDetailPageResult searchProcessingNotifyDetailPage() {"
                : "// representative source line \(line)"
        }.joined(separator: "\n")
        let request = NativeTextNavigationRequest(
            range: JavaSourceRange(
                start: JavaSourcePosition(line: targetLine - 1, character: 7),
                end: JavaSourcePosition(line: targetLine - 1, character: 39)
            )
        )
        let editor = NativeCodeEditor(
            text: .constant(source),
            isEditable: true,
            style: .source(fileExtension: "java"),
            navigationRequest: request,
            showsLineNumbers: true,
            contentIdentity: "navigation-centering.java",
            fontSize: 13
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_100, height: 700)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        hostingView.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: hostingView),
              let layoutManager = textView.layoutManager,
              textView.textContainer != nil else {
            throw JavaVerificationError(description: "Navigation centering fixture did not render")
        }
        let index = SourceLineIndex(text: source)
        guard let lineRange = index.contentRange(forLine: targetLine, in: source) else {
            throw JavaVerificationError(description: "Navigation target line was unavailable")
        }
        layoutManager.ensureLayout(forCharacterRange: lineRange)
        let glyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let targetY = lineRect.midY + textView.textContainerOrigin.y
        let visibleRect = textView.visibleRect
        let relativeY = (targetY - visibleRect.minY) / visibleRect.height
        try require(
            (0.35...0.65).contains(relativeY),
            "Navigation target was not centered in the editor viewport: \(relativeY)"
        )
    }

    @MainActor
    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
    }

    private static func verifySettingsAndWireFormats() throws {
        try require(
            AppState.shouldScheduleJavaSemanticTokens(
                previousPhase: .indexing,
                currentPhase: .ready
            ),
            "Java semantic tokens did not schedule when indexing became ready"
        )
        try require(
            !AppState.shouldScheduleJavaSemanticTokens(
                previousPhase: .ready,
                currentPhase: .ready
            ),
            "Java semantic tokens were rescheduled by a ready snapshot"
        )
        try require(JavaIndexSettings.default.maximumJVMCount == 1, "Unexpected JVM default")
        try require(JavaIndexSettings.default.maximumHeapMegabytes == 2_048, "Unexpected heap default")
        try require(JavaIndexSettings.default.cacheLimitGigabytes == 10, "Unexpected cache default")
        let clamped = JavaIndexSettings(
            maximumJVMCount: 10,
            processorCountPerJVM: 0,
            maximumHeapMegabytes: 200,
            cacheLimitGigabytes: 200
        )
        try require(clamped.maximumJVMCount == 4, "JVM limit was not clamped")
        try require(clamped.processorCountPerJVM == 1, "CPU limit was not clamped")
        try require(clamped.maximumHeapMegabytes == 1_024, "Heap limit was not clamped")
        try require(clamped.cacheLimitGigabytes == 100, "Cache limit was not clamped")

        let value: JSONValue = .object([
            "enabled": .bool(true),
            "count": .integer(3),
            "items": .array([.string("Java"), .null])
        ])
        try require(try JSONValue(data: value.encodedData()) == value, "JSONValue did not round-trip")
        try require(
            try JSONValue(data: Data("{\"id\":1}".utf8))["id"]?.intValue == 1,
            "JSON-RPC numeric id was not decoded as a number"
        )

        let first = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":2}"#.utf8)
        let wire = LSPMessageFramer.frame(first) + LSPMessageFramer.frame(second)
        var framer = LSPMessageFramer()
        let split = wire.count / 3
        try require(try framer.append(wire.prefix(split)).isEmpty, "Partial LSP frame was emitted")
        try require(
            try framer.append(wire.suffix(from: split)) == [first, second],
            "Combined LSP frames were not decoded"
        )
        var malformed = LSPMessageFramer()
        do {
            _ = try malformed.append(Data("Header: value\r\n\r\nbody".utf8))
            throw JavaVerificationError(description: "Malformed LSP header was accepted")
        } catch LSPMessageFramingError.missingContentLength {}
    }

    private static func verifyUTF16Navigation() throws {
        let text = "第一行\nclass Emoji { String value = \"😀\"; }\n"
        let index = SourceLineIndex(text: text)
        let source = text as NSString
        let emojiRange = source.range(of: "😀")
        let position = JavaSourcePosition(
            line: 1,
            character: emojiRange.location - index.lineStartOffsets[1]
        )
        let range = JavaSourceRange(
            start: position,
            end: JavaSourcePosition(line: 1, character: position.character + emojiRange.length)
        )
        try require(index.utf16Range(for: range, in: text) == emojiRange, "UTF-16 range mapping failed")
    }

    private static func verifyDetectorAndCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Java-Static-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let detector = FileSystemJavaProjectDetector()
        try require(!detector.isJavaProject(at: root), "Empty repository was detected as Java")
        let ignoredJava = root.appendingPathComponent("target/generated/Ignored.java")
        try FileManager.default.createDirectory(
            at: ignoredJava.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("class Ignored {}".utf8).write(to: ignoredJava)
        try require(!detector.isJavaProject(at: root), "Generated target source was detected")
        let nestedRepository = root.appendingPathComponent("nested-repository", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedRepository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("<project/>".utf8).write(to: nestedRepository.appendingPathComponent("pom.xml"))
        try require(
            !detector.isJavaProject(at: root),
            "Nested Git repository made the parent repository look like a Java project"
        )
        try FileManager.default.removeItem(at: nestedRepository)
        let pom = root.appendingPathComponent("module/pom.xml")
        try FileManager.default.createDirectory(at: pom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<project/>".utf8).write(to: pom)
        try require(detector.isJavaProject(at: root), "Nested Maven module was not detected")

        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let cache = JavaLanguageCacheStore(rootURL: cacheRoot)
        let environmentCacheRoot = root.appendingPathComponent("environment-cache", isDirectory: true)
        try require(
            JavaLanguageCacheStore(
                environment: ["REPODESK_JAVA_LANGUAGE_CACHE_ROOT": environmentCacheRoot.path]
            ).rootURL == environmentCacheRoot,
            "Java cache root environment override was ignored"
        )
        let firstRepository = root.appendingPathComponent("first", isDirectory: true)
        let secondRepository = root.appendingPathComponent("second", isDirectory: true)
        let firstDirectory = try cache.dataDirectory(for: firstRepository)
        let secondDirectory = try cache.dataDirectory(for: secondRepository)
        let firstMetadata = firstDirectory.appendingPathComponent(".metadata", isDirectory: true)
        let secondMetadata = secondDirectory.appendingPathComponent(".metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: firstMetadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondMetadata, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: firstMetadata.appendingPathComponent("payload"))
        try Data(repeating: 2, count: 128).write(to: secondMetadata.appendingPathComponent("payload"))
        let scopedRepository = root.appendingPathComponent("scoped", isDirectory: true)
        let oldScopedDirectory = try cache.dataDirectory(
            for: scopedRepository,
            scopeIdentifier: "old-boundary"
        )
        let oldPayload = oldScopedDirectory.appendingPathComponent("old-payload")
        try Data(repeating: 3, count: 128).write(to: oldPayload)
        try cache.markReady(repositoryURL: scopedRepository, scopeIdentifier: "old-boundary")
        try require(
            cache.hasReadyCache(for: scopedRepository, scopeIdentifier: "old-boundary"),
            "Scoped Java cache was not marked ready"
        )
        _ = try cache.dataDirectory(for: scopedRepository, scopeIdentifier: "new-boundary")
        try require(
            !FileManager.default.fileExists(atPath: oldPayload.path),
            "Java cache survived a repository-boundary change"
        )
        try require(
            !cache.hasReadyCache(for: scopedRepository, scopeIdentifier: "new-boundary"),
            "Boundary-invalidated Java cache remained ready"
        )
        _ = cache.trim(to: 0, excluding: [secondRepository])
        try require(cache.bytes(for: firstRepository) == 0, "Unused cache was not removed")
        try require(cache.bytes(for: secondRepository) > 0, "Active cache was removed")
    }

    private static func verifyNestedRepositoryBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Java-Boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownModule = root.appendingPathComponent("own-module", isDirectory: true)
        let nestedRepository = root.appendingPathComponent("nested-repository", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ownModule,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nestedRepository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("<project/>".utf8).write(to: ownModule.appendingPathComponent("pom.xml"))
        try Data("<project/>".utf8).write(to: nestedRepository.appendingPathComponent("pom.xml"))
        let repositories = [
            RegisteredRepository(displayName: "root", relativePath: ".", isPinned: false),
            RegisteredRepository(
                displayName: "nested-repository",
                relativePath: "nested-repository",
                isPinned: false
            )
        ]
        let registry = FakeSessionRegistry()
        let cache = JavaLanguageCacheStore(rootURL: root.appendingPathComponent("cache"))
        let engine = JavaLanguageEngine(
            settings: JavaIndexSettings(maximumJVMCount: 1),
            cacheStore: cache,
            backgroundDelay: .seconds(30),
            foregroundIdleTimeout: .seconds(30),
            sessionFactory: {
                FakeJavaLanguageServerSession(registry: registry, readyDelay: .milliseconds(20))
            }
        )
        await engine.updateWorkspace(
            workspaceURL: root,
            repositories: repositories,
            projectJavaHome: nil,
            mavenUserSettingsFile: nil
        )
        await engine.prioritize(repositoryID: repositories[0].id)
        try await waitUntil(timeout: .seconds(2)) {
            await registry.configurations().contains {
                $0.repository.repositoryID == repositories[0].id
            }
        }
        guard let configuration = await registry.configurations().first(where: {
            $0.repository.repositoryID == repositories[0].id
        }) else {
            throw JavaVerificationError(description: "Root Java repository did not start")
        }
        try require(
            configuration.repository.nestedRepositoryURLs == [nestedRepository.standardizedFileURL],
            "Java engine did not pass the nested Git repository boundary to JDT"
        )
        try require(
            configuration.repository.containsOwnedFile(ownModule.appendingPathComponent("pom.xml")),
            "Parent repository rejected its own Java module"
        )
        try require(
            !configuration.repository.containsOwnedFile(nestedRepository.appendingPathComponent("pom.xml")),
            "Parent repository still owned files inside the nested Git repository"
        )
        await engine.shutdown()

        try FileManager.default.removeItem(at: ownModule)
        let staleRootCache = try cache.dataDirectory(
            for: root,
            scopeIdentifier: "legacy-parent-scope"
        )
        try Data(repeating: 4, count: 128).write(
            to: staleRootCache.appendingPathComponent("stale-parent-index")
        )
        let cleanupEngine = JavaLanguageEngine(
            settings: JavaIndexSettings(maximumJVMCount: 1),
            cacheStore: cache,
            backgroundDelay: .seconds(30),
            foregroundIdleTimeout: .seconds(30),
            sessionFactory: {
                FakeJavaLanguageServerSession(registry: registry, readyDelay: .milliseconds(20))
            }
        )
        await cleanupEngine.updateWorkspace(
            workspaceURL: root,
            repositories: repositories,
            projectJavaHome: nil,
            mavenUserSettingsFile: nil
        )
        try require(
            cache.bytes(for: root) == 0,
            "Non-Java parent repository kept its stale Java index cache"
        )
        await cleanupEngine.shutdown()
    }

    private static func verifySchedulerAndForegroundPreemption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Java-Scheduler-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("alpha", isDirectory: true)
        let secondURL = root.appendingPathComponent("beta", isDirectory: true)
        let nonJavaURL = root.appendingPathComponent("notes", isDirectory: true)
        for url in [firstURL, secondURL, nonJavaURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for url in [firstURL, secondURL] {
            try Data("<project/>".utf8).write(to: url.appendingPathComponent("pom.xml"))
        }
        let repositories = [
            RegisteredRepository(displayName: "alpha", relativePath: "alpha", isPinned: false),
            RegisteredRepository(displayName: "beta", relativePath: "beta", isPinned: false),
            RegisteredRepository(displayName: "notes", relativePath: "notes", isPinned: false)
        ]
        let registry = FakeSessionRegistry()
        let cache = JavaLanguageCacheStore(rootURL: root.appendingPathComponent("cache"))
        let engine = JavaLanguageEngine(
            settings: JavaIndexSettings(maximumJVMCount: 1),
            cacheStore: cache,
            backgroundDelay: .zero,
            foregroundIdleTimeout: .milliseconds(300),
            sessionFactory: {
                FakeJavaLanguageServerSession(registry: registry, readyDelay: .milliseconds(350))
            }
        )
        let recorder = SnapshotRecorder()
        let eventTask = Task {
            for await event in engine.events {
                if case .snapshot(let snapshot) = event {
                    await recorder.record(snapshot)
                }
            }
        }
        await engine.updateWorkspace(
            workspaceURL: root,
            repositories: repositories,
            projectJavaHome: nil,
            mavenUserSettingsFile: nil
        )
        try await Task.sleep(for: .milliseconds(80))
        await engine.prioritize(repositoryID: repositories[1].id)
        try await waitUntil(timeout: .seconds(4)) {
            let snapshot = await recorder.snapshot()
            return snapshot.readyRepositoryCount == 2
        }
        let sessionSnapshot = await registry.snapshot()
        let indexSnapshot = await recorder.snapshot()
        try require(sessionSnapshot.started.contains("beta"), "Foreground repository was not started")
        try require(sessionSnapshot.maximum == 1, "Configured JVM concurrency was exceeded")
        try require(
            indexSnapshot.repositories.first(where: { $0.displayName == "notes" })?.phase == .notRequired,
            "Non-Java repository was scheduled"
        )
        await engine.shutdown()
        try await waitUntil(timeout: .seconds(2)) {
            await registry.snapshot().running == 0
        }
        eventTask.cancel()
    }

    private static func verifyNavigationWaitsForReadyCachedRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Java-Navigation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryURL = root.appendingPathComponent("process", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try Data("<project/>".utf8).write(to: repositoryURL.appendingPathComponent("pom.xml"))
        let repositories = [
            RegisteredRepository(displayName: "process", relativePath: "process", isPinned: false)
        ]
        let cache = JavaLanguageCacheStore(rootURL: root.appendingPathComponent("cache"))
        try cache.markReady(repositoryURL: repositoryURL)
        let result = JavaNavigationTarget(
            fileURL: repositoryURL.appendingPathComponent("src/App.java"),
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 0, character: 0),
                end: JavaSourcePosition(line: 0, character: 3)
            ),
            selectionRange: nil,
            name: "App",
            detail: nil,
            containerName: nil,
            kind: .class
        )
        let registry = FakeSessionRegistry()
        let engine = JavaLanguageEngine(
            settings: JavaIndexSettings(maximumJVMCount: 1),
            cacheStore: cache,
            backgroundDelay: .zero,
            foregroundIdleTimeout: .seconds(30),
            sessionFactory: {
                FakeJavaLanguageServerSession(
                    registry: registry,
                    readyDelay: .milliseconds(20),
                    navigationResult: [result]
                )
            }
        )
        await engine.updateWorkspace(
            workspaceURL: root,
            repositories: repositories,
            projectJavaHome: nil,
            mavenUserSettingsFile: nil
        )
        let request = JavaNavigationRequest(
            action: .declaration,
            fileURL: repositoryURL.appendingPathComponent("src/App.java"),
            position: JavaSourcePosition(line: 0, character: 0),
            documentText: "class App {}"
        )
        let first = await engine.navigationTargets(repositoryID: repositories[0].id, request: request)
        try require(
            first == [result],
            "First navigation did not wait for the cached repository session to become query-ready"
        )
        let sessionSnapshot = await registry.snapshot()
        try require(
            sessionSnapshot.running == 1,
            "Cached repository session was not retained for foreground navigation"
        )
        await engine.shutdown()
    }

    private static func waitUntil(
        timeout: Duration,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw JavaVerificationError(description: "Timed out waiting for Java verification state")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw JavaVerificationError(description: message) }
    }
}
