import AppKit
import SwiftUI

enum FileTabStripMetrics {
    static let tabWidth: CGFloat = 258
    static let tabHeight: CGFloat = 40
    static let spacing: CGFloat = 4
    static let inset: CGFloat = 8
    static let stripHeight: CGFloat = 50
}

/// A horizontal-only viewport. Legacy scrollers must not reserve vertical space
/// when the tabs overflow: hiding their indicator in SwiftUI still reserves it.
@MainActor
struct FileTabStripScrollView<Content: View>: NSViewRepresentable {
    let contextID: String?
    let tabIDs: [URL]
    let selectedID: URL?
    @ViewBuilder let content: Content
    @Environment(\.font) private var font
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    private var contentWidth: CGFloat {
        CGFloat(tabIDs.count) * FileTabStripMetrics.tabWidth
            + CGFloat(max(0, tabIDs.count - 1)) * FileTabStripMetrics.spacing + 2 * FileTabStripMetrics.inset
    }

    private var hostedContent: AnyView {
        AnyView(content
            .frame(width: contentWidth, height: FileTabStripMetrics.stripHeight)
            .environment(\.font, font)
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.isEnabled, isEnabled))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TabStripViewport()
        scroll.identifier = NSUserInterfaceItemIdentifier("RepoDesk.FileTabs.Scroll")
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        let host = NSHostingView(rootView: hostedContent)
        host.sizingOptions = []
        scroll.documentView = host
        context.coordinator.host = host
        scroll.didLayout = { [weak coordinator = context.coordinator] scroll in
            coordinator?.revealSelection(in: scroll)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let host = context.coordinator.host else { return }
        let coordinator = context.coordinator
        if coordinator.contextID != contextID || coordinator.tabIDs != tabIDs
            || coordinator.selectedID != selectedID {
            coordinator.needsReveal = true
        }
        coordinator.contextID = contextID
        coordinator.tabIDs = tabIDs
        coordinator.selectedID = selectedID
        host.rootView = hostedContent
        host.frame = NSRect(x: 0, y: 0, width: contentWidth, height: FileTabStripMetrics.stripHeight)
        coordinator.revealSelection(in: scroll)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? contentWidth, height: FileTabStripMetrics.stripHeight)
    }

    @MainActor
    final class Coordinator {
        var host: NSHostingView<AnyView>?
        var contextID: String?
        var tabIDs: [URL] = []
        var selectedID: URL?
        var needsReveal = true
        private var lastViewportWidth: CGFloat = 0

        func revealSelection(in scroll: NSScrollView) {
            let viewport = scroll.contentView.bounds
            guard viewport.width > 0, let host else { return }
            if lastViewportWidth != viewport.width {
                needsReveal = true
                lastViewportWidth = viewport.width
            }
            let maximumX = max(0, host.frame.width - viewport.width)
            var x = min(maximumX, max(0, viewport.minX))
            if needsReveal, let selectedID, let index = tabIDs.firstIndex(of: selectedID) {
                let center = FileTabStripMetrics.inset
                    + CGFloat(index) * (FileTabStripMetrics.tabWidth + FileTabStripMetrics.spacing)
                    + FileTabStripMetrics.tabWidth / 2
                x = min(maximumX, max(0, center - viewport.width / 2))
                needsReveal = false
            }
            if viewport.minX != x || viewport.minY != 0 {
                scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
}

@MainActor
private final class TabStripViewport: NSScrollView {
    var didLayout: ((NSScrollView) -> Void)?
    override func layout() {
        super.layout()
        didLayout?(self)
    }
}
