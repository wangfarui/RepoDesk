import AppKit
import SwiftUI
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyMergeConflictRendering {
    static func main() throws {
        _ = NSApplication.shared
        GitMergeAppearance.registerFonts(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Support/Resources/MergeFonts"))
        let repository = RegisteredRepository(
            displayName: "online.base.item.service",
            relativePath: ".",
            isPinned: false
        )
        let state = AppState(
            workspace: WorkspaceSummary(name: "pangmaoyun", path: "/tmp"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            restoresWorkspaceOnLaunch: false
        )
        state.navigationContext = .repository(repository.id)
        state.repositorySnapshots[repository.id] = GitRepositorySnapshot(
            branch: "test",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: [],
            lastCommit: nil
        )
        state.mergeSourceBranch = "uat"
        state.conflictFiles = conflictPaths.map { path in
            GitConflictFile(
                path: path,
                ours: ours,
                theirs: theirs,
                result: result,
                isResolved: false
            )
        }

        try render(
            MergeConflictResolverSheet(appState: state),
            size: NSSize(width: 780, height: 520),
            filename: "merge-conflict-list.png",
            minimumByteCount: 20_000
        )
        try render(
            MergeConflictEditorSheet(
                file: longConflictFile,
                yoursBranch: "test",
                theirsBranch: "uat",
                fontSize: 13,
                apply: { _ in true }
            ),
            size: NSSize(width: 1_440, height: 820),
            filename: "merge-conflict-editor.png",
            minimumByteCount: 45_000
        )
        try render(
            MergeConflictEditorSheet(
                file: longConflictFile,
                yoursBranch: "test",
                theirsBranch: "uat",
                fontSize: 13,
                apply: { _ in true }
            ),
            size: NSSize(width: 1100, height: 600),
            filename: "merge-conflict-editor-minimum.png",
            minimumByteCount: 30_000
        )
        try verifyResizablePresentation(
            MergeConflictResolverSheet(appState: state),
            minimumSize: NSSize(width: 780, height: 520)
        )
        try verifyResizablePresentation(
            MergeConflictEditorSheet(
                file: longConflictFile,
                yoursBranch: "test",
                theirsBranch: "uat",
                fontSize: 13,
                apply: { _ in true }
            ),
            minimumSize: NSSize(width: 1100, height: 600)
        )
        try verifyHorizontalScrollingPerformance()
        print("Merge conflict rendering verification passed")
    }

    private static func verifyResizablePresentation<Content: View>(
        _ content: Content,
        minimumSize: NSSize
    ) throws {
        let controller = NSHostingController(rootView: content)
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.alphaValue = 0.01
        parent.contentView = NSView(frame: parent.contentLayoutRect)
        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: minimumSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.isReleasedWhenClosed = false
        sheet.animationBehavior = .none
        sheet.contentViewController = controller
        sheet.alphaValue = 0.01
        parent.beginSheet(sheet)
        defer {
            parent.endSheet(sheet)
            sheet.close()
            parent.close()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        guard sheet.sheetParent === parent,
              let sheetContent = sheet.contentView else {
            throw VerificationError(message: "Conflict sheet was not presented.")
        }
        guard sheet.styleMask.contains(.resizable),
              sheet.contentMinSize == minimumSize else {
            throw VerificationError(message: "Conflict sheet has no native resizing or minimum size.")
        }

        // Verify layout proposals on the same content without relying on sheet animations in a CLI process.
        let expandedSize = NSSize(width: minimumSize.width + 200, height: minimumSize.height + 120)
        for size in [
            minimumSize,
            NSSize(width: expandedSize.width, height: minimumSize.height),
            expandedSize,
            NSSize(width: minimumSize.width, height: expandedSize.height),
            minimumSize
        ] {
            let fittedSize = controller.sizeThatFits(in: size)
            sheetContent.setFrameSize(size)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            sheetContent.layoutSubtreeIfNeeded()
            guard fittedSize.width <= size.width + 1,
                  fittedSize.height <= size.height + 1 else {
                throw VerificationError(message: "Conflict sheet content did not fit \(size): \(fittedSize).")
            }
        }
        guard sheet.sheetParent === parent, sheet.contentView === sheetContent else {
            throw VerificationError(message: "Resizing replaced the presented conflict sheet.")
        }
        print("Merge conflict sheet configuration and flexible layout passed (minimum \(minimumSize))")
    }

    private static var longConflictFile: GitConflictFile {
        conflictFile(totalLineCount: 850)
    }

    private static func conflictFile(totalLineCount: Int) -> GitConflictFile {
        let prefix = (1...24).map { "line-\($0) = value" }
        let suffix = (26...totalLineCount).map { "line-\($0) = value" }
        let longValue = String(repeating: "long-value-", count: 12)
        let oursLine = "revision = test-\(longValue)"
        let theirsLine = "revision = uat-\(longValue)"
        let ours = (prefix + [oursLine] + suffix).joined(separator: "\n") + "\n"
        let theirs = (prefix + [theirsLine] + suffix).joined(separator: "\n") + "\n"
        let base = (prefix + ["revision = base"] + suffix).joined(separator: "\n") + "\n"
        let result = (
            prefix
                + [
                    "<<<<<<< HEAD",
                    oursLine,
                    "=======",
                    theirsLine,
                    ">>>>>>> uat"
                ]
                + suffix
        ).joined(separator: "\n") + "\n"
        return GitConflictFile(
            path: "pom.xml",
            ours: ours,
            theirs: theirs,
            result: result,
            isResolved: false,
            base: base
        )
    }

    private static func render<Content: View>(
        _ content: Content,
        size: NSSize,
        filename: String,
        minimumByteCount: Int
    ) throws {
        let hostingController = NSHostingController(rootView: content)
        let hostingView = hostingController.view
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        hostingView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let fittedSize = hostingController.sizeThatFits(in: size)
        guard fittedSize.width <= size.width + 1,
              fittedSize.height <= size.height + 1 else {
            throw VerificationError(message: "\(filename) overflowed its target size: \(fittedSize).")
        }
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw VerificationError(message: "Could not create \(filename).")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]),
              png.count >= minimumByteCount else {
            throw VerificationError(message: "\(filename) was blank or incomplete.")
        }
        try png.write(
            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/\(filename)"),
            options: .atomic
        )
        window.contentViewController = nil
    }

    private static func verifyHorizontalScrollingPerformance() throws {
        let performanceLineCount = ProcessInfo.processInfo.environment[
            "REPODESK_MERGE_PERF_LINES"
        ].flatMap(Int.init) ?? 850
        let editor = MergeConflictEditorSheet(
            file: conflictFile(totalLineCount: performanceLineCount),
            yoursBranch: "test",
            theirsBranch: "uat",
            fontSize: 13,
            apply: { _ in true }
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_440, height: 820)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        hostingView.layoutSubtreeIfNeeded()

        let panes = descendants(of: hostingView).compactMap { $0 as? NSScrollView }.filter {
            $0.identifier?.rawValue.hasPrefix("RepoDesk.MergeConflictEditor.") == true
        }
        guard panes.count == 3,
              let source = panes.first(where: { $0.identifier?.rawValue.contains(".yours.") == true }),
              let resultPane = panes.first(where: { $0.identifier?.rawValue.contains(".result.") == true }),
              let theirsPane = panes.first(where: { $0.identifier?.rawValue.contains(".theirs.") == true }),
              let yoursText = source.documentView as? NSTextView,
              let resultText = resultPane.documentView as? NSTextView,
              let theirsText = theirsPane.documentView as? NSTextView else {
            throw VerificationError(message: "Expected three continuous merge documents.")
        }
        let fixture = conflictFile(totalLineCount: performanceLineCount)
        guard yoursText.string == fixture.ours, theirsText.string == fixture.theirs,
              resultText.string == fixture.base, resultText.isEditable,
              !yoursText.isEditable, !theirsText.isEditable else {
            throw VerificationError(message: "Merge sources or result editability are incorrect.")
        }
        let minimumOffset: CGFloat = 0
        let maximumOffset = max(minimumOffset, yoursText.frame.maxX - source.contentView.bounds.width)
        guard maximumOffset > 100 else {
            throw VerificationError(message: "Merge conflict scrolling fixture did not overflow.")
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        for step in 0..<6 {
            let progress = CGFloat(step) / 5
            source.contentView.scroll(to: NSPoint(x: minimumOffset + (maximumOffset - minimumOffset) * progress, y: 0))
            source.reflectScrolledClipView(source.contentView)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            for pane in panes {
                let minOffset: CGFloat = 0
                let maxOffset = max(minOffset, (pane.documentView?.frame.maxX ?? 0) - pane.contentView.bounds.width)
                let expected = max(minOffset, min(minimumOffset + (maximumOffset - minimumOffset) * progress, maxOffset))
                guard abs(pane.contentView.bounds.minX - expected) < 1 else {
                    throw VerificationError(message: "Continuous merge panes did not share clamped horizontal scrolling.")
                }
            }
        }
        hostingView.displayIfNeeded()
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        print(String(
            format: "Merge conflict horizontal scrolling (%d lines): %.3fs",
            performanceLineCount,
            elapsed
        ))
        guard elapsed < 0.5 else {
            throw VerificationError(
                message: String(
                    format: "Merge conflict horizontal scrolling was too slow: %.3fs",
                    elapsed
                )
            )
        }
        source.contentView.scroll(to: NSPoint(x: minimumOffset, y: 200))
        source.reflectScrolledClipView(source.contentView)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        guard panes.allSatisfy({ abs($0.contentView.bounds.minY - 200) < 1 }) else {
            throw VerificationError(message: "Source-aware vertical scroll lost the within-line offset.")
        }
        resultText.setSelectedRange(NSRange(location: 0, length: 0))
        resultText.insertText("edited\n", replacementRange: NSRange(location: 0, length: 0))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        guard resultText.string.hasPrefix("edited\n"), yoursText.string == fixture.ours, theirsText.string == fixture.theirs,
              resultText.undoManager?.canUndo == true else {
            throw VerificationError(message: "Continuous edit did not preserve sources or register undo.")
        }
        resultText.undoManager?.undo()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        guard resultText.string == fixture.base else {
            throw VerificationError(message: "Native editor undo did not restore the continuous result.")
        }
        resultText.setSelectedRange(NSRange(location: 0, length: 0))
        resultText.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        resultText.unmarkText()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        guard resultText.string.hasPrefix("中文"), resultText.undoManager?.canUndo == true else {
            throw VerificationError(message: "Input method completion was not committed to merge state.")
        }
        resultText.undoManager?.undo()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        guard resultText.string == fixture.base else {
            throw VerificationError(message: "Input method undo did not restore merge state.")
        }
        window.contentView = nil
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static let conflictPaths = [
        "itemcenter-client/pom.xml",
        "itemcenter-common/pom.xml",
        "itemcenter-starter/pom.xml",
        "shop-biz/pom.xml",
        "itemmanager-biz/pom.xml",
        "itemmanager-api/pom.xml"
    ]

    private static let ours = """
    <project>
      <parent>
        <artifactId>itemcenter</artifactId>
        <groupId>online.base.item.service</groupId>
        <version>5.1.3-SNAPSHOT</version>
      </parent>
      <modelVersion>4.0.0</modelVersion>

      <dependencies>
        <dependency>
          <groupId>com.internet.util</groupId>
          <artifactId>common-util</artifactId>
        </dependency>
        <dependency>
          <groupId>com.internet.logging</groupId>
          <artifactId>logging-api</artifactId>
        </dependency>
        <dependency>
          <groupId>com.internet.tenant</groupId>
          <artifactId>tenant-client</artifactId>
        </dependency>
        <dependency>
          <groupId>com.internet.workflow</groupId>
          <artifactId>workflow-client</artifactId>
        </dependency>
      </dependencies>
    </project>
    """

    private static let theirs = """
    <project>
      <parent>
        <artifactId>itemcenter</artifactId>
        <groupId>online.base.item.service</groupId>
        <version>uat-SNAPSHOT</version>
      </parent>
      <modelVersion>4.0.0</modelVersion>

      <dependencies>
        <dependency>
          <groupId>com.internet.util</groupId>
          <artifactId>common-util</artifactId>
        </dependency>
        <dependency>
          <groupId>com.internet.logging</groupId>
          <artifactId>logging-api</artifactId>
        </dependency>
        <dependency>
          <groupId>commons-collections</groupId>
          <artifactId>commons-collections</artifactId>
        </dependency>
      </dependencies>
    </project>
    """

    private static let result = """
    <project>
      <parent>
        <artifactId>itemcenter</artifactId>
        <groupId>online.base.item.service</groupId>
    <<<<<<< HEAD
        <version>5.1.3-SNAPSHOT</version>
    =======
        <version>uat-SNAPSHOT</version>
    >>>>>>> uat
      </parent>
      <modelVersion>4.0.0</modelVersion>

      <dependencies>
        <dependency>
          <groupId>com.internet.util</groupId>
          <artifactId>common-util</artifactId>
        </dependency>
        <dependency>
          <groupId>com.internet.logging</groupId>
          <artifactId>logging-api</artifactId>
        </dependency>
    <<<<<<< HEAD
        <dependency>
          <groupId>com.internet.tenant</groupId>
          <artifactId>tenant-client</artifactId>
        </dependency>
        <dependency>
          <groupId>com.internet.workflow</groupId>
          <artifactId>workflow-client</artifactId>
        </dependency>
    =======
        <dependency>
          <groupId>commons-collections</groupId>
          <artifactId>commons-collections</artifactId>
        </dependency>
    >>>>>>> uat
      </dependencies>
    </project>
    """
}
