import AppKit
import SwiftUI

@main
@MainActor
struct OutputFollowVerification {
    static func main() throws {
        let state = OutputFollowState(
            text: (1...120).map { "line \($0)" }.joined(separator: "\n")
                + "\n" + String(repeating: "horizontal-content-", count: 40),
            followsTail: true
        )
        let coordinator = NativeCodeEditor(
            text: Binding(
                get: { state.text },
                set: { state.text = $0 }
            ),
            isEditable: false,
            followsTail: Binding(
                get: { state.followsTail },
                set: { state.followsTail = $0 }
            )
        ).makeCoordinator()

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scrollView.hasVerticalScroller = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 2_000))
        textView.string = state.text
        scrollView.documentView = textView
        coordinator.textView = textView
        coordinator.startObserving(scrollView)

        coordinator.scrollToTail()
        try require(
            NativeTextTailFollowPolicy.isAtTail(
                documentHeight: textView.bounds.height,
                visibleMaxY: scrollView.contentView.bounds.maxY
            ),
            .jumpDidNotReachTail
        )

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 240))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        try require(!state.followsTail, .manualScrollDidNotPauseFollowing)

        state.followsTail = true
        coordinator.scrollToTailIfFollowing()
        try require(
            NativeTextTailFollowPolicy.isAtTail(
                documentHeight: textView.bounds.height,
                visibleMaxY: scrollView.contentView.bounds.maxY
            ),
            .resumeDidNotReachTail
        )

        let preview = StreamingOutputView(
            text: state.text,
            emptyMessage: "暂无输出",
            emptyMessageColor: .secondary,
            enablesTailFollowing: true,
            contentIdentity: "verification",
            followsTail: .constant(false)
        )
        .frame(width: 720, height: 420)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 420)
        hostingView.layoutSubtreeIfNeeded()
        guard let renderedTextView = findTextView(in: hostingView),
              let renderedScrollView = renderedTextView.enclosingScrollView else {
            throw VerificationError.sourceEditorWasNotRendered
        }
        try require(
            renderedScrollView.hasHorizontalScroller
                && renderedTextView.isHorizontallyResizable
                && renderedTextView.textContainer?.widthTracksTextView == false,
            .sourceEditorDoesNotSupportHorizontalScrolling
        )
        renderedTextView.layoutManager?.ensureLayout(for: renderedTextView.textContainer!)
        let maximumHorizontalOffset = renderedTextView.bounds.width
            - renderedScrollView.contentView.bounds.width
        try require(maximumHorizontalOffset > 100, .sourceEditorContentDidNotOverflow)
        renderedScrollView.contentView.scroll(
            to: NSPoint(x: maximumHorizontalOffset, y: renderedScrollView.contentView.bounds.origin.y)
        )
        renderedScrollView.reflectScrolledClipView(renderedScrollView.contentView)
        try require(
            renderedScrollView.contentView.bounds.origin.x > 100,
            .sourceEditorCouldNotScrollHorizontally
        )
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw VerificationError.previewRenderingFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw VerificationError.previewRenderingFailed
        }
        let previewURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/output-follow-preview.png")
        try pngData.write(to: previewURL, options: .atomic)

        print("Output follow verification passed")
    }

    private static func require(_ condition: Bool, _ error: VerificationError) throws {
        guard condition else { throw error }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap(findTextView).first
    }
}

@MainActor
private final class OutputFollowState {
    var text: String
    var followsTail: Bool

    init(text: String, followsTail: Bool) {
        self.text = text
        self.followsTail = followsTail
    }
}

private enum VerificationError: Error {
    case jumpDidNotReachTail
    case manualScrollDidNotPauseFollowing
    case resumeDidNotReachTail
    case sourceEditorWasNotRendered
    case sourceEditorDoesNotSupportHorizontalScrolling
    case sourceEditorContentDidNotOverflow
    case sourceEditorCouldNotScrollHorizontally
    case previewRenderingFailed
}
