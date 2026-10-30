import AppKit
import SwiftUI

/// A per-label delay keeps branch hints quick without changing system-wide tooltip settings.
struct BranchNameHoverHint: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> BranchNameHoverHintView {
        BranchNameHoverHintView(text: text)
    }

    func updateNSView(_ nsView: BranchNameHoverHintView, context: Context) {
        if nsView.text != text {
            nsView.dismissHint()
            nsView.text = text
        }
    }

    static func dismantleNSView(_ nsView: BranchNameHoverHintView, coordinator: ()) {
        nsView.dismissHint()
    }
}

@MainActor
final class BranchNameHoverHintView: NSView {
    var text: String
    private(set) var hintPanel: NSPanel?
    private var pendingHint: Task<Void, Never>?
    private var hoverTrackingArea: NSTrackingArea?
    private var inputMonitor: Any?

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    // The label's button retains all click handling.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissHint() }
    }

    override func mouseEntered(with event: NSEvent) {
        dismissHint()
        guard window != nil, !text.isEmpty else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            self?.dismissHint()
            return event
        }
        pendingHint = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            self?.showHint()
        }
    }

    override func mouseExited(with event: NSEvent) { dismissHint() }

    func dismissHint() {
        pendingHint?.cancel()
        pendingHint = nil
        if let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
            self.inputMonitor = nil
        }
        if let hintPanel {
            hintPanel.parent?.removeChildWindow(hintPanel)
            hintPanel.orderOut(nil)
            self.hintPanel = nil
        }
    }

    private func showHint() {
        guard let window, !visibleRect.isEmpty else { return }
        let visibleFrame = (window.screen?.visibleFrame ?? window.frame).insetBy(dx: 8, dy: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let title = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        let label = NSTextField(wrappingLabelWithString: text)
        label.attributedStringValue = title
        // NSTextFieldCell adds its own text insets. Measuring the string alone can
        // push the last glyph onto a second line whose height was never reserved.
        let maximumWidth = min(520, visibleFrame.width - 16)
        let textWidth = min(ceil(label.cell?.cellSize.width ?? label.fittingSize.width) + 2, maximumWidth)
        let fittedSize = label.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude
        )) ?? label.fittingSize
        let textHeight = ceil(fittedSize.height) + 2
        label.frame = NSRect(x: 8, y: 6, width: textWidth, height: textHeight)
        let size = NSSize(width: textWidth + 16, height: textHeight + 12)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let x = min(max(anchor.minX, visibleFrame.minX), visibleFrame.maxX - size.width)
        let below = anchor.minY - size.height - 4
        let y = below >= visibleFrame.minY ? below : min(anchor.maxY + 4, visibleFrame.maxY - size.height)
        let panel = NSPanel(
            contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.contentView?.addSubview(label)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        hintPanel = panel
    }
}
