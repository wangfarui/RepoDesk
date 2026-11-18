import AppKit
import SwiftUI
@testable import RepoDesk

@main @MainActor
enum VerifyFilesEditingPerformance {
    static func main() async throws {
        _ = NSApplication.shared
        let source = (["class Example {"] + (1...3000).map {
            "    private String field\($0) = \"中文注释与库存修改标记 😀 \($0)\"; // generated field"
        } + ["}"]).joined(separator: "\n")
        let markers = FileGitLineChanges()
        var headReads = 0
        await markers.load(fileIdentity: "editing.java", text: source) { headReads += 1; return source }
        try await waitUntil { !markers.isComputing }
        let state = EditingState(text: source, markers: markers)
        let host = NSHostingView(rootView: NativeCodeEditor(
            text: Binding(get: { state.text }, set: { state.update($0) }),
            isEditable: true, style: .source(fileExtension: "java"), showsLineNumbers: true,
            gitLineChanges: [:], contentIdentity: "editing.java", fontSize: 13,
            usesAsyncSourceStyling: true
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let view = try unwrap(findTextView(host), "Missing editor")
        let coordinator = try unwrap(view.delegate as? NativeCodeEditor.Coordinator, "Missing coordinator")
        let target = (source as NSString).range(of: "field1500").location
        view.setSelectedRange(NSRange(location: target, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        let initialKeyword = (source as NSString).range(of: "private String field1500").location
        try await waitUntil {
            view.textStorage?.attribute(.foregroundColor, at: initialKeyword, effectiveRange: nil) as? NSColor == .systemBlue
        }
        view.insertText("w", replacementRange: view.selectedRange())
        try await waitUntil { !markers.isComputing }
        var keyTimes: [Double] = []
        var markerTimes: [Double] = []
        for _ in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            view.insertText("x", replacementRange: view.selectedRange())
            keyTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await waitUntil { !markers.isComputing }
            markerTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try require(markers.markers == [1501: .modified], "Typing marks the wrong source line")
            // Exercise the same representable update used to paint the latest gutter.
            coordinator.gitLineChanges = markers.markers
            coordinator.configureLineNumbers(true, in: view.enclosingScrollView!)
        }
        let keyAverage = keyTimes.reduce(0, +) / Double(keyTimes.count)
        let markerAverage = markerTimes.reduce(0, +) / Double(markerTimes.count)
        report("Typing blocks", average: keyAverage, maximum: keyTimes.max()!)
        report("Typing to accurate markers", average: markerAverage, maximum: markerTimes.max()!)
        try require(keyAverage < 25, "Typing exceeds 25ms per key: \(keyAverage)")
        try require(markerAverage < 50, "Marker latency exceeds 50ms: \(markerAverage)")
        try require(headReads == 1, "Typing reloads the HEAD baseline")

        view.insertText("\nnewLine;\n", replacementRange: view.selectedRange())
        try await waitUntil { !markers.isComputing }
        try require(markers.markers == [1501: .modified, 1502: .added, 1503: .added], "Inserted lines/shifted numbering are wrong")
        let editedText = state.text
        for _ in 0..<30 where state.text != source && view.undoManager?.canUndo == true {
            view.undoManager?.undo()
            try await waitUntil { !markers.isComputing }
        }
        try require(state.text == source && markers.markers.isEmpty, "Undo fails to restore text or clear markers")
        for _ in 0..<30 where state.text != editedText && view.undoManager?.canRedo == true {
            view.undoManager?.redo()
            try await waitUntil { !markers.isComputing }
        }
        try require(state.text == editedText, "Highlighting breaks redo")
        let keyword = (state.text as NSString).range(of: "private String field1510").location
        view.scrollRangeToVisible(NSRange(location: keyword, length: 0))
        try await waitUntil {
            view.textStorage?.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor == .systemBlue
        }
        try require(view.string == state.text, "Background styling changes source text")
        let distantKeyword = (state.text as NSString).range(of: "private String field2800").location
        let distantLine = SourceLineIndex(text: state.text).lineNumber(containingUTF16Offset: distantKeyword)
        coordinator.navigateIfNeeded(to: NativeTextNavigationRequest(line: distantLine))
        try await waitUntil {
            view.textStorage?.attribute(.foregroundColor, at: distantKeyword, effectiveRange: nil) as? NSColor == .systemBlue
        }

        // A commit changes the baseline once; typing still reuses that revision.
        await markers.load(fileIdentity: "editing.java", text: editedText) { headReads += 1; return editedText }
        try await waitUntil { !markers.isComputing }
        try require(markers.markers.isEmpty && headReads == 2, "Commit does not clear markers")
        markers.update(text: editedText + "\nadded", fileIdentity: "editing.java")
        markers.update(text: editedText, fileIdentity: "editing.java")
        try await waitUntil { !markers.isComputing }
        try require(markers.markers.isEmpty, "An obsolete comparison overwrites the latest edit")
        let oldLoad = Task {
            await markers.load(fileIdentity: "old.java", text: "old") {
                try await Task.sleep(for: .milliseconds(40))
                return "old"
            }
        }
        try await Task.sleep(for: .milliseconds(2))
        await markers.load(fileIdentity: "new.java", text: "new") { "new" }
        await oldLoad.value
        try await waitUntil { !markers.isComputing }
        try require(markers.fileIdentity == "new.java" && markers.markers.isEmpty, "Switching files admits stale results")
        try verifyLineDiff()
        print("Files editing verification passed (3000 lines, typing/marker budgets, HEAD cache, undo/redo, viewport syntax, commit and stale results)")
    }

    private static func verifyLineDiff() throws {
        let cases: [(String, String, [Int: GitLineChangeKind])] = [
            ("", "", [:]), ("", "one\ntwo\n", [1: .added, 2: .added]),
            ("a\nb\nc\n", "a\nB\nnew\nc\n", [2: .modified, 3: .added]),
            ("a\nb\nc\n", "a\nc\n", [:]),
            ("a\nold\nkeep\nremove\ntail\n", "a\nchanged\ninserted\nkeep\ntail\n", [2: .modified, 3: .added]),
            ("abc", "abc\n", [1: .modified]),
            ("a\r\nb\r\n", "a\nb\n", [:]),
            ("中文😀\nold\n", "中文😀\nnew\n", [2: .modified])
        ]
        for (old, new, expected) in cases {
            let actual = try GitLineChanges.markers(baseline: GitLineChanges.lines(in: old), text: new)
            try require(actual == expected, "Memory diff mismatch for \(old.debugDescription) -> \(new.debugDescription): \(actual)")
        }
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw failure("Timed out waiting for editor update") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func report(_ name: String, average: Double, maximum: Double) {
        FileHandle.standardError.write(Data("\(name): average=\(String(format: "%.2f", average))ms max=\(String(format: "%.2f", maximum))ms\n".utf8))
    }

    private static func findTextView(_ view: NSView) -> NSTextView? {
        if let view = view as? NSTextView { return view }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "FilesEditingPerformance", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw failure(message) }; return value
    }
}

@MainActor private final class EditingState {
    var text: String
    let markers: FileGitLineChanges
    init(text: String, markers: FileGitLineChanges) { self.text = text; self.markers = markers }
    func update(_ text: String) {
        self.text = text
        markers.update(text: text, fileIdentity: "editing.java")
    }
}
