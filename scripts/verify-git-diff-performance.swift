import AppKit
import SwiftUI

private struct GitDiffPerformanceVerificationError: Error {
    let message: String
}

@main
@MainActor
enum GitDiffPerformanceVerification {
    static func main() throws {
        let lineCount = 4_000
        let oldLines = (1...lineCount).map {
            "line \($0) " + String(repeating: "0123456789", count: 18)
        }
        var newLines = oldLines
        newLines[lineCount / 2] += " changed"
        let diff = GitFileDiff(
            path: "src/LargeFile.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: oldLines,
            newLines: newLines,
            hunks: [
                GitDiffHunk(
                    oldStart: lineCount / 2,
                    oldCount: 3,
                    newStart: lineCount / 2,
                    newCount: 3,
                    lines: [
                        GitPatchLine(kind: .context, text: oldLines[lineCount / 2 - 1]),
                        GitPatchLine(kind: .deletion, text: oldLines[lineCount / 2]),
                        GitPatchLine(kind: .addition, text: newLines[lineCount / 2]),
                        GitPatchLine(kind: .context, text: oldLines[lineCount / 2 + 1])
                    ]
                )
            ],
            isBinary: false
        )
        let blame = Dictionary(uniqueKeysWithValues: (1...lineCount).map {
            ($0, GitBlameLine(
                lineNumber: $0,
                commitHash: "6346a9c9d9123456789012345678901234567890",
                author: "performance.user",
                authoredAt: Date(timeIntervalSince1970: 1_706_745_600)
            ))
        })

        let modelStart = ProcessInfo.processInfo.systemUptime
        let renderModel = GitDiffRenderModel(diff: diff)
        let modelDuration = ProcessInfo.processInfo.systemUptime - modelStart
        let (hostingView, openDuration) = measureInitialLayout(
            diff: diff,
            renderModel: renderModel
        )
        let blameDuration = measureBlameUpdate(
            hostingView: hostingView,
            diff: diff,
            renderModel: renderModel,
            blame: blame
        )

        report(String(format: "Render model preparation: %.3fs", modelDuration))
        report(String(format: "Comparison layout: %.3fs", openDuration))
        report(String(format: "Blame layout: %.3fs", blameDuration))
        try require(openDuration < 0.35, "Opening comparison exceeded the 350ms budget.")
        try require(blameDuration < 0.35, "Enabling blame exceeded the 350ms budget.")
        print("Git diff performance verification passed")
    }

    private static func measureInitialLayout(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel
    ) -> (NSHostingView<PerformanceDiffRoot>, TimeInterval) {
        let start = ProcessInfo.processInfo.systemUptime
        let hostingView = NSHostingView(rootView: PerformanceDiffRoot(
            diff: diff,
            renderModel: renderModel,
            oldBlame: nil
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 680)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        return (hostingView, ProcessInfo.processInfo.systemUptime - start)
    }

    private static func measureBlameUpdate(
        hostingView: NSHostingView<PerformanceDiffRoot>,
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        blame: [Int: GitBlameLine]
    ) -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        hostingView.rootView = PerformanceDiffRoot(
            diff: diff,
            renderModel: renderModel,
            oldBlame: blame
        )
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        return ProcessInfo.processInfo.systemUptime - start
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GitDiffPerformanceVerificationError(message: message) }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

@MainActor
private struct PerformanceDiffRoot: View {
    let diff: GitFileDiff
    let renderModel: GitDiffRenderModel
    let oldBlame: [Int: GitBlameLine]?

    var body: some View {
        GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: .sideBySide,
            oldBlame: oldBlame,
            newBlame: nil,
            toggleOldBlame: {},
            toggleNewBlame: {},
            renderModel: renderModel
        )
        .frame(width: 1_200, height: 680)
    }
}
