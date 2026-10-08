import AppKit
import SwiftUI
@testable import RepoDesk

@main
@MainActor
enum VerifyFileTreeHorizontalScrolling {
    static func main() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskFileTreeScroll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let directoryNames = ["sql", "2026", "1015"]
        var directoryURLs: [URL] = []
        var parentURL = rootURL
        for name in directoryNames {
            let directoryURL = parentURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            directoryURLs.append(directoryURL)
            parentURL = directoryURL
        }
        let fileName = "20261015_" + String(repeating: "inventory_goods_price_hash_", count: 5) + ".sql"
        let fileURL = parentURL.appendingPathComponent(fileName)
        try "SELECT 1;".write(to: fileURL, atomically: true, encoding: .utf8)

        let state = AppState(
            workspace: WorkspaceSummary(url: rootURL),
            restoresWorkspaceOnLaunch: false
        )
        for (index, directoryURL) in directoryURLs.enumerated() {
            let parent = index == 0 ? rootURL : directoryURLs[index - 1]
            state.fileChildren[parent] = [
                WorkspaceFileEntry(url: directoryURL, name: directoryNames[index], isDirectory: true)
            ]
        }
        state.fileChildren[parentURL] = [
            WorkspaceFileEntry(url: fileURL, name: fileName, isDirectory: false)
        ]
        state.expandedDirectoryURLs = Set(directoryURLs)

        _ = NSApplication.shared
        let hostingView = NSHostingView(rootView: FilesView(appState: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 520)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.alphaValue = 0.01
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        hostingView.layoutSubtreeIfNeeded()

        guard let scrollView = descendants(of: hostingView)
            .compactMap({ $0 as? NSScrollView })
            .first(where: { $0.contentView.bounds.width >= 230 && $0.contentView.bounds.width <= 450 }),
              let documentView = scrollView.documentView else {
            throw VerificationError.failed("Files tree scroll view was not rendered")
        }
        guard documentView.frame.height >= scrollView.contentView.bounds.height - 1,
              scrollView.contentView.bounds.minY >= -1 else {
            throw VerificationError.failed("Files tree content is vertically centered below its header")
        }
        let nameWidth = (fileName as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).width
        let requiredWidth = nameWidth + CGFloat(directoryNames.count) * 14 + 40
        guard documentView.frame.width >= requiredWidth else {
            throw VerificationError.failed(
                "Tree content width \(Int(documentView.frame.width)) is shorter than long row \(Int(requiredWidth))"
            )
        }
        let maximumOffset = documentView.frame.width - scrollView.contentView.bounds.width
        guard maximumOffset > 100 else {
            throw VerificationError.failed("Files tree cannot scroll far enough to reveal the filename")
        }
        scrollView.contentView.scroll(to: NSPoint(x: maximumOffset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        guard scrollView.contentView.bounds.origin.x >= maximumOffset - 1 else {
            throw VerificationError.failed("Files tree did not reach its rightmost offset")
        }
        print("Files tree horizontal scrolling verification passed")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private enum VerificationError: Error {
        case failed(String)
    }
}
