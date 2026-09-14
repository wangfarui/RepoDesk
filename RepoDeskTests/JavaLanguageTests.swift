import Foundation
import Testing
@testable import RepoDesk

struct JavaLanguageTests {
    @Test func javaSemanticTokensOnlyScheduleOnReadyTransition() {
        #expect(
            AppState.shouldScheduleJavaSemanticTokens(
                previousPhase: .indexing,
                currentPhase: .ready
            )
        )
        #expect(
            !AppState.shouldScheduleJavaSemanticTokens(
                previousPhase: .ready,
                currentPhase: .ready
            )
        )
        #expect(
            !AppState.shouldScheduleJavaSemanticTokens(
                previousPhase: .failed,
                currentPhase: .indexing
            )
        )
    }

    @Test func javaIndexSettingsUseRequestedDefaultsAndClampUnsafeValues() {
        #expect(JavaIndexSettings.default.maximumJVMCount == 1)
        #expect(JavaIndexSettings.default.processorCountPerJVM == min(2, ProcessInfo.processInfo.activeProcessorCount))
        #expect(JavaIndexSettings.default.maximumHeapMegabytes == 2_048)
        #expect(JavaIndexSettings.default.cacheLimitGigabytes == 10)

        let clamped = JavaIndexSettings(
            maximumJVMCount: 20,
            processorCountPerJVM: 0,
            maximumHeapMegabytes: 200,
            cacheLimitGigabytes: 500
        )
        #expect(clamped.maximumJVMCount == 4)
        #expect(clamped.processorCountPerJVM == 1)
        #expect(clamped.maximumHeapMegabytes == 1_024)
        #expect(clamped.cacheLimitGigabytes == 100)
    }

    @Test func lspFramerHandlesFragmentedAndCombinedMessages() throws {
        let first = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":2}"#.utf8)
        let combined = LSPMessageFramer.frame(first) + LSPMessageFramer.frame(second)
        var framer = LSPMessageFramer()

        let split = combined.count / 2
        #expect(try framer.append(combined.prefix(split)).isEmpty)
        let messages = try framer.append(combined.suffix(from: split))

        #expect(messages == [first, second])
    }

    @Test func javaDetectorRecognizesMavenAndNestedJavaProjects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-JavaDetector-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let detector = FileSystemJavaProjectDetector()

        #expect(!detector.isJavaProject(at: root))
        try Data("<project/>".utf8).write(to: root.appendingPathComponent("pom.xml"))
        #expect(detector.isJavaProject(at: root))

        try FileManager.default.removeItem(at: root.appendingPathComponent("pom.xml"))
        let source = root.appendingPathComponent("module/src/main/java/example/App.java")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("class App {}".utf8).write(to: source)
        #expect(detector.isJavaProject(at: root))

        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        let nestedRepository = root.appendingPathComponent("nested-repository", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedRepository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("<project/>".utf8).write(to: nestedRepository.appendingPathComponent("pom.xml"))
        #expect(!detector.isJavaProject(at: root))
    }
}
