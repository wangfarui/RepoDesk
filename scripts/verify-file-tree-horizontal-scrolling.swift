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
        let extraFileCount = 40
        var leafEntries = [
            WorkspaceFileEntry(url: fileURL, name: fileName, isDirectory: false)
        ]
        for index in 0..<extraFileCount {
            let name = String(format: "row-%02d.sql", index)
            let extraURL = parentURL.appendingPathComponent(name)
            try "SELECT \(index);".write(to: extraURL, atomically: true, encoding: .utf8)
            leafEntries.append(
                WorkspaceFileEntry(url: extraURL, name: name, isDirectory: false)
            )
        }

        let rootFileCount = 12
        var rootEntries: [WorkspaceFileEntry] = []
        for index in 0..<rootFileCount {
            let name = String(format: "root-%02d.txt", index)
            let rootFileURL = rootURL.appendingPathComponent(name)
            try "root \(index)".write(to: rootFileURL, atomically: true, encoding: .utf8)
            rootEntries.append(
                WorkspaceFileEntry(url: rootFileURL, name: name, isDirectory: false)
            )
        }

        let state = AppState(
            workspace: WorkspaceSummary(url: rootURL),
            restoresWorkspaceOnLaunch: false
        )
        for (index, directoryURL) in directoryURLs.enumerated() {
            let parent = index == 0 ? rootURL : directoryURLs[index - 1]
            let child = WorkspaceFileEntry(url: directoryURL, name: directoryNames[index], isDirectory: true)
            state.fileChildren[parent] = index == 0 ? rootEntries + [child] : [child]
        }
        state.fileChildren[parentURL] = leafEntries
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

        state.fileTreeRevealRequest = FileTreeRevealRequest(fileURL: fileURL)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        hostingView.layoutSubtreeIfNeeded()
        guard let revealedScrollView = descendants(of: hostingView)
            .compactMap({ $0 as? NSScrollView })
            .first(where: { $0.contentView.bounds.width >= 230 && $0.contentView.bounds.width <= 450 }),
              let revealedDocument = revealedScrollView.documentView else {
            throw VerificationError.failed("Files tree scroll view disappeared after locating a file")
        }
        let revealedViewport = revealedScrollView.contentView.bounds.height
        let visibleRowCount = rootFileCount + directoryNames.count + extraFileCount + 1
        let rowBudget = max(revealedViewport, CGFloat(visibleRowCount) * 36 + 48) + 24
        guard revealedDocument.frame.height <= rowBudget else {
            throw VerificationError.failed(
                "Locating a file stretched the tree to \(Int(revealedDocument.frame.height)), "
                    + "above the \(Int(rowBudget)) row budget"
            )
        }
        var stableHeight = revealedDocument.frame.height
        for _ in 0..<6 {
            let maximumVerticalOffset = max(
                0,
                revealedDocument.frame.height - revealedViewport
            )
            revealedScrollView.contentView.scroll(
                to: NSPoint(x: revealedScrollView.contentView.bounds.origin.x, y: maximumVerticalOffset)
            )
            revealedScrollView.reflectScrolledClipView(revealedScrollView.contentView)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            hostingView.layoutSubtreeIfNeeded()
            guard revealedDocument.frame.height <= stableHeight + 1 else {
                throw VerificationError.failed(
                    "Files tree kept growing while scrolling down "
                        + "(\(Int(stableHeight)) -> \(Int(revealedDocument.frame.height)))"
                )
            }
            stableHeight = revealedDocument.frame.height
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
