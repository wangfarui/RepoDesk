import AppKit

@main
@MainActor
enum VerifyBranchNameHover {
    static func main() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false, screen: NSScreen.main
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.orderFront(nil)
        defer { window.close() }

        for (index, name) in ["dev_261122_intransit", "origin/dev_261029_process", "origin/release_20261029", "origin/" + String(repeating: "long_branch_name_", count: 30)].enumerated() {
            let view = BranchNameHoverHintView(text: name)
            view.frame = NSRect(x: 20, y: 20, width: 130, height: 24)
            window.contentView?.addSubview(view)
            require(view.window != nil, "Hover view must be attached to a window")
            require(!view.visibleRect.isEmpty, "Hover label must have visible bounds")
            require(view.hitTest(.zero) == nil, "Hints must not intercept branch clicks")
            view.mouseEntered(with: NSEvent())
            try await Task.sleep(for: .milliseconds(100))
            require(view.hintPanel == nil, "Brief pointer movement must not flash a hint")
            try await Task.sleep(for: .milliseconds(250))
            guard let panel = view.hintPanel else { fatalError("Full name must appear within 350 ms") }
            require(panel.ignoresMouseEvents && !panel.isKeyWindow, "Hint must not take pointer or keyboard focus")
            let label = panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first
            if let content = panel.contentView, let label {
                let preview = NSImage(size: content.bounds.size)
                preview.lockFocus()
                NSColor.white.setFill()
                content.bounds.fill()
                let transform = NSAffineTransform()
                transform.translateX(by: label.frame.minX, yBy: label.frame.minY)
                transform.concat()
                NSBezierPath(rect: label.bounds).addClip()
                label.cell?.draw(withFrame: label.bounds, in: label)
                preview.unlockFocus()
                if let tiff = preview.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("build/branch-hover-render-\(index).png"))
                }
            }
            require(label?.stringValue == name, "Hint must retain the full local or remote name")
            require(label?.frame.height ?? 0 > 0, "Full name must have visible text")
            if let label, let cell = label.cell {
                let required = cell.cellSize(forBounds: NSRect(
                    x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude
                ))
                require(label.bounds.width >= ceil(required.width) && label.bounds.height >= ceil(required.height),
                        "Rendered name is clipped: \(name), label=\(label.bounds.size), cell requires=\(required)")
                if name.count < 100 {
                    require(label.bounds.width >= ceil(cell.cellSize.width),
                            "Single-line name loses glyphs to text-cell insets: \(name), label width=\(label.bounds.width), cell width=\(cell.cellSize.width)")
                }
            }
            if name.count > 100 {
                require((label?.frame.height ?? 0) > 24, "Very long names must wrap rather than truncate")
            }
            view.mouseExited(with: NSEvent())
            require(view.hintPanel == nil && panel.parent == nil, "Leaving must immediately remove the hint")

            view.mouseEntered(with: NSEvent())
            view.mouseExited(with: NSEvent())
            try await Task.sleep(for: .milliseconds(300))
            require(view.hintPanel == nil, "Leaving early must cancel delayed hints")

            view.mouseEntered(with: NSEvent())
            view.removeFromSuperview()
            try await Task.sleep(for: .milliseconds(300))
            require(view.hintPanel == nil, "Closing or filtering the row must cancel delayed hints")
        }
        print("Branch name hover verification passed (local/remote full names, 250 ms delay, wrapping, click passthrough, exit and detach cancellation)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
