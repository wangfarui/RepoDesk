import AppKit
import SwiftUI
@testable import RepoDesk

private struct HistoryJarRenderingError: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
enum VerifyHistoryJarRendering {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-JarRendering-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let contents = root.appendingPathComponent("contents", isDirectory: true)
        for directory in [repository, contents] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await git(["init", "--initial-branch=main"], in: repository)
        try await archive(version: 1, repository: repository, contents: contents)
        _ = try await git(["add", "fixture.jar"], in: repository)
        _ = try await git(["commit", "-m", "before"], in: repository)
        let parent = try await git(["rev-parse", "HEAD"], in: repository)
        try await archive(version: 2, repository: repository, contents: contents)
        _ = try await git(["add", "fixture.jar"], in: repository)
        _ = try await git(["commit", "-m", "after"], in: repository)
        let hash = try await git(["rev-parse", "HEAD"], in: repository)

        _ = NSApplication.shared
        try await render(repository: repository, hash: hash, parent: parent,
                         size: NSSize(width: 900, height: 550), fontSize: 13,
                         appearance: .aqua, colorScheme: .light, name: "history-jar-regular.png")
        try await render(repository: repository, hash: hash, parent: parent,
                         size: NSSize(width: 600, height: 400), fontSize: 13,
                         appearance: .aqua, colorScheme: .light, name: "history-jar-compact.png")
        try await render(repository: repository, hash: hash, parent: parent,
                         size: NSSize(width: 900, height: 550), fontSize: 20,
                         appearance: .darkAqua, colorScheme: .dark, name: "history-jar-dark-large-font.png")
        print("History JAR rendering verification passed (regular, compact, dark large font; historical text loaded on both sides)")
    }

    private static func archive(version: Int, repository: URL, contents: URL) async throws {
        let runtime = try JavaLanguageRuntime.resolve()
        let plugins = runtime.jdtRootURL.appendingPathComponent("plugins")
        guard let compiler = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix("org.eclipse.jdt.core.compiler.batch_")
                && $0.pathExtension == "jar" }) else {
            throw HistoryJarRenderingError(description: "Bundled Java compiler is missing")
        }
        let sourceURL = contents.deletingLastPathComponent().appendingPathComponent("UnicodeDemo.java")
        let source = """
        @Deprecated(since="费用量取值（1一口价\(version == 1 ? "" : " 7按预提")）")
        public class UnicodeDemo {
            public String 中文字段 = "真实内容😀";
            public String value() { return "mode=\(version == 1 ? "before" : "after")"; }
        }
        """
        try Data(source.utf8).write(to: sourceURL)
        _ = try await run(runtime.javaExecutableURL.path, [
            "-jar", compiler.path, "-17", "-encoding", "UTF-8", "-g:none", "-d", contents.path, sourceURL.path
        ], in: contents)
        try Data("mode=\(version == 1 ? "before" : "after")\nlabel=历史包内资源\n".utf8)
            .write(to: contents.appendingPathComponent("config.properties"))
        try Data("unchanged\n".utf8).write(to: contents.appendingPathComponent("unchanged.txt"))
        let destination = repository.appendingPathComponent("fixture.jar")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        _ = try await run("/usr/bin/zip", ["-q", "-9", destination.path, "UnicodeDemo.class", "config.properties", "unchanged.txt"], in: contents)
    }

    private static func render(
        repository: URL, hash: String, parent: String, size: NSSize, fontSize: CGFloat,
        appearance: NSAppearance.Name, colorScheme: ColorScheme, name: String
    ) async throws {
        let rootView = HistoryJarDiffView(
            repositoryURL: repository, hash: hash,
            file: GitCommitFile(path: "fixture.jar", originalPath: nil, status: .modified),
            parentHashes: [parent], ignoresWhitespace: false, fontSize: fontSize
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, colorScheme)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = NSAppearance(named: appearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.appearance = NSAppearance(named: appearance)
        window.alphaValue = 0.01
        window.orderFront(nil)
        defer { window.close() }

        // Yield the main actor so SwiftUI's .task and the real Git commands can finish.
        // Inspect selectable text rather than accepting a screenshot of a loading indicator.
        var hasHistoricalText = false
        for _ in 0..<50 {
            hostingView.layoutSubtreeIfNeeded()
            let textViews = descendantTextViews(in: hostingView)
            let oldText = textViews.first { $0.accessibilityIdentifier() == "RepoDesk.SideBySideDiff.Old.SelectableText" }?.string ?? ""
            let newText = textViews.first { $0.accessibilityIdentifier() == "RepoDesk.SideBySideDiff.New.SelectableText" }?.string ?? ""
            if oldText.contains("mode=before"), newText.contains("mode=after"),
               oldText.contains("费用量取值（1一口价）"), newText.contains("费用量取值（1一口价 7按预提）"),
               oldText.contains("中文字段"), newText.contains("真实内容😀") {
                hasHistoricalText = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(150))
        hostingView.layoutSubtreeIfNeeded()
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/\(name)")
        try saveRendering(of: hostingView, to: output)
        guard hasHistoricalText else {
            throw HistoryJarRenderingError(description: "JAR historical Java must load with readable Unicode on both sides: \(output.path)")
        }
        let fittingSize = hostingView.fittingSize
        guard fittingSize.width <= size.width + 1, fittingSize.height <= size.height + 1 else {
            throw HistoryJarRenderingError(description: "JAR content exceeded \(size.width)x\(size.height): fitting size \(fittingSize); \(output.path)")
        }
    }

    private static func descendantTextViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { descendantTextViews(in: $0) }
    }

    private static func saveRendering(of view: NSView, to output: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw HistoryJarRenderingError(description: "Could not allocate JAR rendering bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 10_000 else {
            throw HistoryJarRenderingError(description: "JAR rendering was empty")
        }
        try png.write(to: output, options: .atomic)
    }

    private static func git(_ arguments: [String], in repository: URL) async throws -> String {
        try await run("/usr/bin/git", [
            "-c", "user.name=RepoDesk Verification", "-c", "user.email=repodesk@example.test",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"
        ] + arguments, in: repository)
    }

    private static func run(_ executable: String, _ arguments: [String], in directory: URL) async throws -> String {
        let result = try await SystemCommandRunner(timeout: .seconds(15)).run(CommandRequest(
            executableURL: URL(fileURLWithPath: executable), arguments: arguments, workingDirectoryURL: directory,
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        ))
        guard result.terminationStatus == 0 else {
            throw HistoryJarRenderingError(description: "Fixture command failed: \(String(decoding: result.standardError, as: UTF8.self))")
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
