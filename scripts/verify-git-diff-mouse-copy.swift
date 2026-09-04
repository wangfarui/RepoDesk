import AppKit
import SwiftUI

private struct GitDiffMouseCopyVerificationError: Error {
    let message: String
}

@main
@MainActor
enum GitDiffMouseCopyVerification {
    static func main() throws {
        let diff = GitFileDiff(
            path: "Sources/Selection.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: ["let first = 1", "let second = 2", "let third = 3"],
            newLines: ["let first = 1", "let changed = 20", "let third = 3"],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 3,
                    newStart: 1,
                    newCount: 3,
                    lines: [
                        GitPatchLine(kind: .context, text: "let first = 1"),
                        GitPatchLine(kind: .deletion, text: "let second = 2"),
                        GitPatchLine(kind: .addition, text: "let changed = 20"),
                        GitPatchLine(kind: .context, text: "let third = 3")
                    ]
                )
            ],
            isBinary: false
        )
        let preview = GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: .unified
        )
        .frame(width: 900, height: 420)
        let hostingView = NSHostingView(rootView: preview)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        guard let textView = descendantViews(of: hostingView)
            .compactMap({ $0 as? GitDiffSelectableTextViewSurface })
            .first else {
            throw GitDiffMouseCopyVerificationError(
                message: "The selectable Diff text surface was not rendered."
            )
        }
        try require(
            textView.frame.width > 0 && textView.frame.height > 0,
            "The selectable Diff text surface has an empty frame."
        )

        let start = try point(forCharacterAt: 2, in: textView)
        let end = try point(forCharacterAt: max(2, textView.string.utf16.count - 2), in: textView)
        let startInWindow = textView.convert(start, to: nil)
        let endInWindow = textView.convert(end, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = mouseEvent(
            type: .leftMouseDown,
            location: startInWindow,
            timestamp: timestamp,
            window: window
        ), let dragged = mouseEvent(
            type: .leftMouseDragged,
            location: endInWindow,
            timestamp: timestamp + 0.01,
            window: window
        ), let up = mouseEvent(
            type: .leftMouseUp,
            location: endInWindow,
            timestamp: timestamp + 0.02,
            window: window
        ) else {
            throw GitDiffMouseCopyVerificationError(message: "Mouse events could not be created.")
        }

        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.postEvent(dragged, atStart: true)
        guard let themeFrame = hostingView.superview else {
            throw GitDiffMouseCopyVerificationError(message: "The window theme frame was unavailable.")
        }
        let themePoint = themeFrame.convert(startInWindow, from: nil)
        guard let hitTextView = themeFrame.hitTest(themePoint)
            as? GitDiffSelectableTextViewSurface else {
            throw GitDiffMouseCopyVerificationError(
                message: "Window hit testing did not reach the selectable Diff text surface."
            )
        }
        hitTextView.mouseDown(with: down)
        let selection = textView.selectedRange()
        try require(selection.length > 0, "Mouse dragging did not create a text selection.")

        guard let copiedText = textView.selectedCopyText() else {
            throw GitDiffMouseCopyVerificationError(
                message: "The selected Diff text was not accepted by the copy path."
            )
        }
        try require(
            copiedText.contains("first = 1")
                && copiedText.contains("let second = 2")
                && copiedText.contains("let changed = 20")
                && copiedText.contains("let third"),
            "Mouse-selected Diff text was not copied as multi-line code: \(copiedText.debugDescription)"
        )
        try require(
            !copiedText.contains("HEAD") && !copiedText.contains("Working Tree"),
            "Copied Diff text included non-code labels."
        )
        print("Git diff mouse selection and copy verification passed")
    }

    private static func point(
        forCharacterAt location: Int,
        in textView: NSTextView
    ) throws -> NSPoint {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            throw GitDiffMouseCopyVerificationError(message: "Text layout was unavailable.")
        }
        layoutManager.ensureLayout(for: textContainer)
        let characterLocation = min(max(0, location), max(0, textView.string.utf16.count - 1))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterLocation, length: 1),
            actualCharacterRange: nil
        )
        let glyphBounds = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        return NSPoint(
            x: glyphBounds.midX + textView.textContainerOrigin.x,
            y: glyphBounds.midY + textView.textContainerOrigin.y
        )
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        timestamp: TimeInterval,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private static func descendantViews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendantViews)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GitDiffMouseCopyVerificationError(message: message) }
    }
}
