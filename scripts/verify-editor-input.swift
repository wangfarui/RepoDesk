import AppKit
import SwiftUI
@testable import RepoDesk

@Observable @MainActor
private final class InputState {
    var text = "// note: "
    var fontSize: CGFloat = 13
    var identity = "first.java"
    var semanticTokens: [JavaSemanticToken] = []
}

@MainActor private struct InputHost: View {
    @Bindable var state: InputState
    let incremental: Bool
    var fileExtension = "java"
    var body: some View {
        NativeCodeEditor(text: $state.text, isEditable: true,
                         style: .source(fileExtension: fileExtension), showsLineNumbers: true,
                         contentIdentity: state.identity, fontSize: state.fontSize,
                         semanticTokens: state.semanticTokens, usesIncrementalStyling: incremental)
    }
}

@main @MainActor
enum VerifyEditorInput {
    static func main() async throws {
        _ = NSApplication.shared
        var failures: [String] = []
        for (fileExtension, incremental) in [("java", true), ("java", false), ("xml", true), ("txt", true)] {
            let state = InputState()
            let host = NSHostingView(rootView: InputHost(state: state, incremental: incremental, fileExtension: fileExtension))
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let view = findTextView(host)!
            // Finish the hosting view's initial focus transaction before simulating IME input.
            await settle()
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
            check(view.hasMarkedText(), "\(fileExtension)/\(incremental): highlighting ended composition", into: &failures)
            view.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let markedSelection = view.selectedRange()
            let markedRange = view.markedRange()
            state.fontSize = 14
            state.semanticTokens = [JavaSemanticToken(
                range: JavaSourceRange(start: JavaSourcePosition(line: 0, character: 0),
                                       end: JavaSourcePosition(line: 0, character: 2)), style: .comment)]
            await settle()
            check(view.hasMarkedText(), "\(fileExtension)/\(incremental): view refresh ended composition", into: &failures)
            check(view.selectedRange() == markedSelection && view.markedRange() == markedRange, "\(fileExtension)/\(incremental): refresh moved IME selection", into: &failures)
            view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
            check(view.string == "// note: 中文" && state.text == view.string, "\(fileExtension)/\(incremental): IME commit corrupted source: \(view.string.debugDescription)", into: &failures)
            view.breakUndoCoalescing()
            let committed = view.string
            check(sendUndoRedo(redo: false, window: window), "Undo shortcut was not handled", into: &failures)
            await settle()
            check(view.string == "// note: ", "\(fileExtension)/\(incremental): undo did not remove the complete IME transaction: \(view.string.debugDescription)", into: &failures)
            check(sendUndoRedo(redo: true, window: window), "Redo shortcut was not handled", into: &failures)
            await settle()
            check(view.string == committed, "\(fileExtension)/\(incremental): redo did not restore IME commit", into: &failures)
            view.insertText(" edit", replacementRange: view.selectedRange())
            view.breakUndoCoalescing()
            await settle()
            check(sendUndoRedo(redo: false, window: window), "Undo shortcut was not handled", into: &failures)
            await settle()
            check(view.string == committed && state.text == committed, "\(fileExtension)/\(incremental): undo corrupted source: \(view.string.debugDescription)", into: &failures)
            check(sendUndoRedo(redo: true, window: window), "Redo shortcut was not handled", into: &failures)
            await settle()
            check(view.string == committed + " edit" && state.text == view.string, "\(fileExtension)/\(incremental): redo corrupted source: \(view.string.debugDescription)", into: &failures)
            view.setMarkedText("cancel", selectedRange: NSRange(location: 6, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            state.fontSize = 15
            await settle()
            view.unmarkText()
            await settle()
            check(!view.hasMarkedText() && state.text == view.string && view.font?.pointSize == 15,
                  "\(fileExtension)/\(incremental): ending composition did not apply deferred text/font", into: &failures)
            // The editor must keep a long Unicode source line on one visual line.
            let longLine = "// " + String(repeating: "中文😀 ", count: 150) + "目标"
            state.text = longLine
            await settle()
            let target = (longLine as NSString).range(of: "目标")
            view.setSelectedRange(target)
            view.setMarkedText("ce", selectedRange: NSRange(location: 2, length: 0), replacementRange: target)
            await settle()
            view.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText("测试", replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
            let expectedLongLine = (longLine as NSString).replacingCharacters(in: target, with: "测试")
            check(view.string == expectedLongLine && state.text == expectedLongLine,
                  "\(fileExtension)/\(incremental): replacing Unicode selection inserted unwanted text/newlines", into: &failures)
            let layout = view.layoutManager!
            layout.ensureLayout(for: view.textContainer!)
            var fragments = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in
                fragments += 1
            }
            check(fragments == 1, "\(fileExtension)/\(incremental): IME wrapped a source line into \(fragments) fragments", into: &failures)
            view.breakUndoCoalescing()
            check(sendUndoRedo(redo: false, window: window) && view.string == longLine,
                  "\(fileExtension)/\(incremental): Unicode replacement undo failed", into: &failures)
            await settle()
            check(sendUndoRedo(redo: true, window: window) && view.string == expectedLongLine,
                  "\(fileExtension)/\(incremental): Unicode replacement redo failed", into: &failures)
            await settle()
            state.identity = "second.java"
            state.text = "class Second {}"
            await settle()
            check(view.undoManager?.canUndo != true, "\(fileExtension)/\(incremental): new document retains previous document's undo", into: &failures)
            window.close()
        }
        check(!RepoDeskKeyboardShortcut.isUndoFileDeletion(key: "z", modifiers: .command,
                    selectedSection: .files, canUndo: true, isEditingText: true),
              "File deletion shortcut steals editor undo", into: &failures)
        check(RepoDeskKeyboardShortcut.isUndoFileDeletion(key: "z", modifiers: .command,
                    selectedSection: .files, canUndo: true, isEditingText: false),
              "File tree deletion undo is no longer available", into: &failures)
        for failure in failures { print("FAIL: \(failure)") }
        if !failures.isEmpty { exit(1) }
        print("Editor input verification passed (Java/XML/text, IME refresh and selection, deferred styling, Unicode replacement, no wrapping, Command-Z/Shift-Z, document undo isolation)")
    }
    private static func sendUndoRedo(redo: Bool, window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: redo ? [.command, .shift] : [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: redo ? "Z" : "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)
        else { return false }
        return window.firstResponder?.performKeyEquivalent(with: event) == true
    }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(120)) }
    private static func check(_ passed: Bool, _ message: String, into failures: inout [String]) {
        if !passed { failures.append(message) }
    }
    private static func findTextView(_ view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }
}
