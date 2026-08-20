import AppKit
import SwiftUI

@MainActor
final class GitDiffComparisonWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func present<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        let hostingController = NSHostingController(rootView: AnyView(content()))
        if let window {
            window.title = title
            window.contentViewController = hostingController
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = GitDiffComparisonWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1_050, height: 680)
        let frameAutosaveName = "RepoDesk.GitDiffComparison"
        if !window.setFrameUsingName(frameAutosaveName) {
            window.setContentSize(NSSize(width: 1_200, height: 760))
            window.center()
        }
        window.setFrameAutosaveName(frameAutosaveName)
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private final class GitDiffComparisonWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MovableWindowBackgroundView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MovableWindowBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
