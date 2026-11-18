import AppKit
import Foundation
import SwiftUI

private struct SourceEditorScrollPerformanceError: LocalizedError {
    let scenario: String
    let duration: TimeInterval
    let updateCount: Int

    var errorDescription: String? {
        let milliseconds = duration * 1_000 / Double(updateCount)
        return "\(scenario) averaged \(String(format: "%.3f", milliseconds))ms."
    }
}

@main
@MainActor
enum SourceEditorScrollPerformanceVerification {
    static func main() async throws {
        _ = NSApplication.shared
        let sourceData = FileHandle.standardInput.readDataToEndOfFile()
        let source = String(data: sourceData, encoding: .utf8).flatMap { text in
            text.isEmpty ? nil : text
        } ?? representativeJavaSource()
        let state = SourceEditorPerformanceState(text: source)
        let editor = NativeCodeEditor(
            text: Binding(
                get: { state.text },
                set: { state.text = $0 }
            ),
            isEditable: true,
            style: .source(fileExtension: "java"),
            showsLineNumbers: true,
            contentIdentity: "scroll-performance.java",
            fontSize: 13
        )
        let coordinator = editor.makeCoordinator()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 1_600, height: 12_000))
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = source
        scrollView.documentView = textView
        coordinator.textView = textView
        coordinator.configureLineNumbers(true, in: scrollView)
        NativeTextStorageUpdater.update(
            source,
            style: .source(fileExtension: "java"),
            fontSize: 13,
            styleChanged: true,
            mode: .replace,
            in: textView
        )

        for _ in 0..<10 {
            simulateSwiftUIUpdate(coordinator: coordinator, textView: textView, scrollView: scrollView)
        }

        let updateCount = 240
        let inactiveMilliseconds = measureAverage(updateCount: updateCount) {
            simulateSwiftUIUpdate(coordinator: coordinator, textView: textView, scrollView: scrollView)
        }
        report("Source editor scroll update", inactiveMilliseconds)
        try requirePerformance(
            inactiveMilliseconds,
            scenario: "Source editor scroll updates",
            updateCount: updateCount
        )

        let searchMatches = ContentSearchMatcher.matches(
            in: source,
            query: "private",
            options: ContentSearchOptions()
        )
        let searchPresentation = ContentSearchPresentation(
            ranges: searchMatches.map(\.range),
            activeRange: searchMatches.first?.range,
            navigationRequestID: UUID()
        )
        coordinator.applyContentSearch(searchPresentation)
        let activeSearchMilliseconds = measureAverage(updateCount: updateCount) {
            simulateSwiftUIUpdate(
                coordinator: coordinator,
                textView: textView,
                scrollView: scrollView,
                contentSearch: searchPresentation
            )
        }
        report("Source editor scroll update with search", activeSearchMilliseconds)
        try requirePerformance(
            activeSearchMilliseconds,
            scenario: "Source editor scroll updates with search",
            updateCount: updateCount
        )
        try await verifyViewportScrolling(source)
        print("Source editor scroll performance verification passed")
    }

    private static func verifyViewportScrolling(_ source: String) async throws {
        var reportedLines: [Int] = []
        let editor = NativeCodeEditor(
            text: .constant(source),
            isEditable: true,
            style: .source(fileExtension: "java"),
            showsLineNumbers: true,
            onVisibleLineChange: { reportedLines.append($0) },
            contentIdentity: "viewport-performance.java",
            fontSize: 13,
            foldsJavaImports: true,
            importsExpanded: .constant(false),
            usesAsyncSourceStyling: true
        )
        let frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: editor)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: host), let scroll = textView.enclosingScrollView,
              let layout = textView.layoutManager, let container = textView.textContainer else {
            throw viewportFailure("Source editor is missing")
        }
        if let keyword = JavaSyntaxHighlighter.highlights(in: source).last(where: { $0.style == .keyword }) {
            let deadline = ContinuousClock.now + .seconds(5)
            while textView.textStorage?.attribute(.foregroundColor, at: keyword.range.location, effectiveRange: nil)
                as? NSColor != .systemBlue {
                guard ContinuousClock.now < deadline else {
                    throw viewportFailure("Source highlighting did not reach the end of the document")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        layout.ensureLayout(for: container)
        window.displayIfNeeded()
        let maximumY = textView.bounds.height - scroll.contentView.bounds.height
        guard maximumY > scroll.contentView.bounds.height else {
            throw viewportFailure("Scroll fixture needs more than two viewports")
        }
        reportedLines.removeAll()
        let positions = Array(1...120) + Array((40..<120).reversed())
        let samples = positions.map { position in
            let startedAt = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximumY * CGFloat(position) / 120))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.displayIfNeeded()
            return (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        }.sorted()
        let p95 = samples[samples.count * 95 / 100]
        report("Source editor viewport scroll p95", p95)
        guard p95 < 16.67 else { throw viewportFailure("Viewport scroll exceeded the 60 Hz frame budget at p95") }
        guard reportedLines.isEmpty else { throw viewportFailure("The clip-view callback reported a line synchronously") }
        let deadline = ContinuousClock.now + .seconds(1)
        while reportedLines.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let lineCount = SourceLineIndex(text: source).lineCount
        guard reportedLines.count == 1, let centerLine = reportedLines.first,
              (lineCount / 4...lineCount / 2).contains(centerLine) else {
            throw viewportFailure("The editor did not report the settled viewport once: \(reportedLines)")
        }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
    }

    private static func viewportFailure(_ message: String) -> NSError {
        NSError(domain: "SourceEditorScroll", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func requirePerformance(
        _ millisecondsPerUpdate: TimeInterval,
        scenario: String,
        updateCount: Int
    ) throws {
        guard millisecondsPerUpdate < 0.20 else {
            throw SourceEditorScrollPerformanceError(
                scenario: scenario,
                duration: millisecondsPerUpdate * Double(updateCount) / 1_000,
                updateCount: updateCount
            )
        }
    }

    private static func simulateSwiftUIUpdate(
        coordinator: NativeCodeEditor.Coordinator,
        textView: NSTextView,
        scrollView: NSScrollView,
        contentSearch: ContentSearchPresentation? = nil
    ) {
        coordinator.configureLineNumbers(true, in: scrollView)
        coordinator.configureFont(in: textView)
        coordinator.applyContentSearch(contentSearch)
    }

    private static func measureAverage(
        updateCount: Int,
        _ body: () -> Void
    ) -> TimeInterval {
        let startedAt = ProcessInfo.processInfo.systemUptime
        for _ in 0..<updateCount { body() }
        return (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000 / Double(updateCount)
    }

    private static func report(_ label: String, _ milliseconds: TimeInterval) {
        FileHandle.standardError.write(Data(
            "\(label): \(String(format: "%.3f", milliseconds))ms\n".utf8
        ))
    }

    private static func representativeJavaSource() -> String {
        (["import java.util.List;", "import java.util.Map;", "", "public final class ScrollPerformanceFixture {"]
            + (1...1_800).map {
                "    private final String generatedField\($0) = \"生成的值-\($0)\";"
            }
            + ["}"])
            .joined(separator: "\n")
    }

}

@MainActor
private final class SourceEditorPerformanceState {
    var text: String

    init(text: String) {
        self.text = text
    }
}
