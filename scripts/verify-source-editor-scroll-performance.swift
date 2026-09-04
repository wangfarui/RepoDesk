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
    static func main() throws {
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
        print("Source editor scroll performance verification passed")
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
        (["public final class ScrollPerformanceFixture {"]
            + (1...518).map {
                "    private final String generatedField\($0) = \"generated-value-\($0)\";"
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
