import AppKit
import SwiftUI

private struct GitDiffLayoutVerificationError: Error {
    let message: String
}

@main
@MainActor
enum GitDiffLayoutVerification {
    static func main() throws {
        let longLine = String(repeating: "0123456789", count: 90)
        let unifiedWidth = GitDiffLayoutMetrics.requiredUnifiedWidth(
            oldLines: ["short"],
            newLines: [longLine]
        )
        let oldPaneWidth = GitDiffLayoutMetrics.requiredSidePaneWidth(lines: ["short"])
        let newPaneWidth = GitDiffLayoutMetrics.requiredSidePaneWidth(lines: [longLine])

        try require(unifiedWidth > 1_000, "Long unified lines did not create horizontal overflow.")
        try require(
            newPaneWidth > oldPaneWidth,
            "Side-by-side pane width did not account for the longest line."
        )
        let containerWidth: CGFloat = 961
        let viewportWidth = GitDiffLayoutMetrics.sidePaneViewportWidth(
            containerWidth: containerWidth
        )
        try require(
            viewportWidth * 2 + GitDiffLayoutMetrics.sideDividerWidth == containerWidth,
            "Side-by-side divider was not fixed at the container center."
        )

        let diff = GitFileDiff(
            path: "src/ApplicationMain.java",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: [
                "private final static Logger logger = LoggerFactory.getLogger(ApplicationMain.class);",
                "public static void main(String[] args) {",
                "    SpringApplication.run(ApplicationMain.class, args);",
                "}"
            ],
            newLines: [
                "private final static Logger logger = LoggerFactory.getLogger(ApplicationMain.class);",
                "public static void main(String[] args) {",
                "    logger.info(\"starting\");",
                "    SpringApplication.run(ApplicationMain.class, args);",
                "}"
            ],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 4,
                    newStart: 1,
                    newCount: 5,
                    lines: [
                        GitPatchLine(kind: .context, text: "private final static Logger logger = LoggerFactory.getLogger(ApplicationMain.class);"),
                        GitPatchLine(kind: .context, text: "public static void main(String[] args) {"),
                        GitPatchLine(kind: .addition, text: "    logger.info(\"starting\");"),
                        GitPatchLine(kind: .context, text: "    SpringApplication.run(ApplicationMain.class, args);"),
                        GitPatchLine(kind: .context, text: "}")
                    ]
                )
            ],
            isBinary: false
        )
        let committedAt = Date(timeIntervalSince1970: 1_706_745_600)
        let oldBlame = Dictionary(uniqueKeysWithValues: (1...4).map {
            ($0, GitBlameLine(
                lineNumber: $0,
                commitHash: "6346a9c9d9123456789012345678901234567890",
                author: $0 < 3 ? "dengfeng.wei" : "jingzhouzhao",
                authoredAt: committedAt
            ))
        })
        let newBlame = Dictionary(uniqueKeysWithValues: (1...5).map {
            ($0, GitBlameLine(
                lineNumber: $0,
                commitHash: $0 == 3 ? String(repeating: "0", count: 40) : "6346a9c9d9123456789012345678901234567890",
                author: $0 == 3 ? "未提交" : "dengfeng.wei",
                authoredAt: $0 == 3 ? nil : committedAt
            ))
        })
        let preview = GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: .sideBySide,
            oldBlame: oldBlame,
            newBlame: newBlame,
            toggleOldBlame: {},
            toggleNewBlame: {}
        )
        .frame(width: 1_200, height: 680)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 680)
        hostingView.layoutSubtreeIfNeeded()
        try writePreview(
            hostingView,
            name: "git-diff-horizontal-preview.png"
        )

        print("Git diff horizontal layout verification passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GitDiffLayoutVerificationError(message: message) }
    }

    private static func writePreview(_ view: NSView, name: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw GitDiffLayoutVerificationError(message: "Diff preview could not be rendered.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw GitDiffLayoutVerificationError(message: "Diff preview PNG could not be created.")
        }
        let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/\(name)")
        try pngData.write(to: outputURL, options: .atomic)
    }
}
