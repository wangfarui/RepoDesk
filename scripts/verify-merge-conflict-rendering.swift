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
        try verifyHorizontalScrollingPerformance()
        print("Merge conflict rendering verification passed")
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
            isResolved: false
        )
    }

    private static func render<Content: View>(
        _ content: Content,
        size: NSSize,
        filename: String,
        minimumByteCount: Int
    ) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
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
        hostingView.displayIfNeeded()
        guard hostingView.fittingSize.width <= size.width + 1,
              hostingView.fittingSize.height <= size.height + 1 else {
            throw VerificationError(message: "\(filename) overflowed its target size.")
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
        window.contentView = nil
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

        let scrollViewsByPane = Dictionary(uniqueKeysWithValues: [
            "yours",
            "result",
            "theirs"
        ].map { pane in
            (
                pane,
                descendants(of: hostingView)
                    .compactMap { $0 as? NSScrollView }
                    .filter {
                        $0.identifier?.rawValue.contains(
                            "MergeConflictEditor.\(pane)."
                        ) == true
                    }
            )
        })
        guard let yoursScrollViews = scrollViewsByPane["yours"],
              let resultScrollViews = scrollViewsByPane["result"],
              let theirsScrollViews = scrollViewsByPane["theirs"],
              yoursScrollViews.count >= 10,
              !resultScrollViews.isEmpty,
              !theirsScrollViews.isEmpty,
              let source = yoursScrollViews.max(by: {
                  ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0)
              }) else {
            throw VerificationError(message: "Could not find merge conflict horizontal scrollers.")
        }
        let maximumOffset = max(
            0,
            (source.documentView?.frame.width ?? 0) - source.contentView.bounds.width
        )
        guard maximumOffset > 100 else {
            throw VerificationError(message: "Merge conflict scrolling fixture did not overflow.")
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        for step in 0..<6 {
            let progress = CGFloat(step) / 5
            source.contentView.scroll(to: NSPoint(x: maximumOffset * progress, y: 0))
            source.reflectScrolledClipView(source.contentView)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            let synchronizedOffsets = (yoursScrollViews + resultScrollViews + theirsScrollViews)
                .map { $0.contentView.bounds.origin.x }
            guard let minimumOffset = synchronizedOffsets.min(),
                  let maximumSynchronizedOffset = synchronizedOffsets.max(),
                  maximumSynchronizedOffset - minimumOffset < 1 else {
                throw VerificationError(
                    message: "Merge conflict panes did not share a horizontal offset."
                )
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
