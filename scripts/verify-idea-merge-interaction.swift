import AppKit
import SwiftUI
@testable import RepoDesk

private struct MergeInteractionFailure: Error { let message: String }

@main @MainActor
enum VerifyIdeaMergeInteraction {
    static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw MergeInteractionFailure(message: message) } }
    static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
        view.layoutSubtreeIfNeeded()
    }
    static func main() throws {
        _ = NSApplication.shared
        let preview = !CommandLine.arguments.contains("--verify")
        NSApp.setActivationPolicy(preview ? .regular : .accessory)
        NSApp.finishLaunching()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REPODESK_PROJECT_DIR"] ?? FileManager.default.currentDirectoryPath)
        GitMergeAppearance.registerFonts(in: root.appendingPathComponent("Support/Resources/MergeFonts"))
        let common = (0..<7).map { "    // shared line \($0)\n" }.joined()
        let tail = (0..<600).map { "    // unchanged tail \($0)\n" }.joined()
        let base = "class Orders {\n" + common + "    String first = \"base-one\";\n" + common + "    String second = \"base-two\";\n" + common + "    void unchanged() {}\n" + tail + "}\n"
        let ours = base.replacingOccurrences(of: "base-one", with: "left-one").replacingOccurrences(of: "base-two", with: "left-two").replacingOccurrences(of: "void unchanged() {}", with: "void unchanged() {}\n    void leftOnly() {}")
        let theirs = base.replacingOccurrences(of: "base-one", with: "right-one").replacingOccurrences(of: "base-two", with: "right-two")
        let initial = GitThreeWayMergeDocument(base: base, ours: ours, theirs: theirs, automaticallyApply: false)
        var file = GitConflictFile(path: "Orders.java", ours: ours, theirs: theirs, result: base, isResolved: false, base: base)
        file.mergeDocument = initial
        let controller = NSHostingController(rootView: MergeConflictEditorSheet(file: file, yoursBranch: "test", theirsBranch: "incoming", fontSize: 13, apply: { _ in true }))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Merge Orders.java — IDEA interaction verification"
        window.isReleasedWhenClosed = false
        window.alphaValue = preview ? 1 : 0.01
        window.contentViewController = controller
        if preview { window.makeKeyAndOrderFront(nil) }
        let host = controller.view
        settle(host)
        guard let canvas = descendants(host).compactMap({ $0 as? MergeCanvasView }).first,
              let coordinator = canvas.coordinator else { throw MergeInteractionFailure(message: "Native merge canvas missing") }
        let state = coordinator.parent.state
        let conflicts = state.document.changes.filter(\.isConflict).map(\.id)
        try require(conflicts.count == 2, "Verification fixture must contain two separate conflicts")
        let first = conflicts[0], second = conflicts[1]
        func button(_ id: Int, _ pane: Int, _ operation: String) -> NSButton? {
            descendants(canvas).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "RepoDesk.MergeConflictEditor.Block.\(id).\(pane).\(operation)" }
        }
        try require(button(first, 0, "Accept") != nil && button(first, 2, "Accept") != nil && button(first, 0, "Ignore") != nil,
                    "Visible conflict is missing block-local arrows/ignore actions")
        try require(canvas.layer?.masksToBounds == true && coordinator.scrolls.allSatisfy { $0.layer?.masksToBounds == true }, "Native editing area must clip document painting")
        try require(canvas.frame.height < host.bounds.height - 80, "Document displaced toolbar/footer")
        for scroll in coordinator.scrolls { try require(canvas.bounds.insetBy(dx: -0.5, dy: -0.5).contains(scroll.frame), "A pane escapes the editing viewport") }
        let menuTitles = ["Accept Left Side", "Accept Right Side", "Resolve using Left", "Resolve using Right", "Ignore Left Side", "Ignore Right Side", "Resolve Simple Conflicts", "Ignore", "Reset Change"]
        let text = coordinator.texts[1]
        let position = text.convert(NSPoint(x: 10, y: coordinator.documentY(state.document.changes.first { $0.id == first }!.resultRange.start, 1) + 2), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: position, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let menu = text.menu(for: event)!
        try require(Array(menu.items.prefix(9).map(\.title)) == menuTitles, "Result context menu differs from the IDEA action order")
        button(first, 0, "Accept")!.performClick(nil); settle(host)
        try require(state.document.result.contains("left-one") && !state.document.result.contains("right-one"), "Left gutter arrow applied wrong content")
        try require(button(first, 0, "Accept") == nil && button(first, 2, "Accept") != nil, "Accepting one side must remove only that side's actions")
        try require(state.document.unresolvedIDs.contains(first), "A single side incorrectly resolved both alternatives")
        let afterFirst = state.document
        let viewportBeforeAction = coordinator.scrolls.map { $0.contentView.bounds.minY }
        button(second, 2, "Accept")!.performClick(nil); settle(host)
        try require(zip(coordinator.scrolls, viewportBeforeAction).allSatisfy { abs($0.0.contentView.bounds.minY - $0.1) < 1 }, "Clicking an already visible gutter action jumped the viewport")
        try require(state.document.result.contains("right-two") && state.document.result.contains("left-one"), "A non-selected block action affected the selected block")
        state.undoManager.undo(); settle(host)
        try require(state.document == afterFirst && button(second, 2, "Accept") != nil, "Undo did not restore text and gutter actions")
        state.undoManager.redo(); settle(host)
        button(second, 0, "Ignore")!.performClick(nil); settle(host)
        try require(!state.document.unresolvedIDs.contains(second) && state.document.result.contains("right-two"), "Ignore discarded accepted text or left the decision pending")
        for scroll in coordinator.scrolls { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        settle(host)
        let controlClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        button(first, 2, "Accept")!.rightMouseDown(with: controlClick); settle(host)
        try require(!state.document.unresolvedIDs.contains(first) && state.document.result.contains("left-one") && state.document.result.contains("right-one"), "Ctrl+Click after accepting one side did not append and resolve the conflict")
        try require(coordinator.texts[0].string == ours && coordinator.texts[2].string == theirs, "Gutter actions modified source documents")
        state.change { $0.applyNonConflicting() }; settle(host)
        try require(state.document.unresolvedIDs.isEmpty, "Non-conflicting batch did not finish remaining changes")
        state.change { $0 = initial }; state.undoManager.removeAllActions(); settle(host)
        for scroll in coordinator.scrolls { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        settle(host)
        let left = coordinator.scrolls[0]
        left.contentView.scroll(to: NSPoint(x: 0, y: 1300)); left.reflectScrolledClipView(left.contentView); settle(host)
        try require(button(first, 0, "Accept") == nil, "Offscreen block actions did not leave the viewport")
        left.contentView.scroll(to: .zero); left.reflectScrolledClipView(left.contentView); settle(host)
        try require(button(first, 0, "Accept") != nil, "Block actions did not return after scrolling")
        for size in [NSSize(width: 1100, height: 600), NSSize(width: 1800, height: 1000), NSSize(width: 1440, height: 820)] {
            window.setContentSize(size); host.frame.size = size; settle(host)
            try require(canvas.frame.height < size.height - 80, "Resizing allowed the document to overlap controls")
            for scroll in coordinator.scrolls { try require(canvas.bounds.insetBy(dx: -0.5, dy: -0.5).contains(scroll.frame), "Resizing detached a pane from the clipping region: pane=\(scroll.frame), canvas=\(canvas.bounds), host=\(host.bounds), requested=\(size)") }
        }
        let settings = coordinator.settings
        settings.showLineNumbers = false; settle(host)
        try require(coordinator.gutters[0].frame.width == 44 && coordinator.gutters[1].frame.width == 16, "Settings did not update native line-number layout")
        settings.showLineNumbers = true; settings.softWrap = true; settings.showWhitespaces = true; settle(host)
        try require(coordinator.texts[1].layoutManager?.showsInvisibleCharacters == true, "Whitespace setting did not reach the native document")
        settings.softWrap = false; settings.showWhitespaces = false; settle(host)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = root.appendingPathComponent("build/idea-merge-parity.png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
        }
        print("IDEA merge interaction passed (block-local actions, independent selection, Ctrl+Click, undo/redo, source immutability, context menu, scroll and viewport clipping)")
        if preview { NSApp.activate(ignoringOtherApps: true); NSApp.run() }
        else { window.contentViewController = nil; window.close() }
    }
}
