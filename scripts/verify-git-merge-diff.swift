import AppKit
import SwiftUI

private struct VerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@main
enum GitMergeDiffVerification {
    static func main() throws {
        let resultLines = ["same", "resolved", "inserted", "tail"]
        let targetDiff = GitFileDiff(
            path: "resolved.txt",
            originalPath: nil,
            oldLabel: "target",
            newLabel: "merge",
            oldLines: ["same", "target", "tail"],
            newLines: resultLines,
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 3,
                    newStart: 1,
                    newCount: 4,
                    lines: [
                        GitPatchLine(kind: .context, text: "same"),
                        GitPatchLine(kind: .deletion, text: "target"),
                        GitPatchLine(kind: .addition, text: "resolved"),
                        GitPatchLine(kind: .addition, text: "inserted"),
                        GitPatchLine(kind: .context, text: "tail")
                    ]
                )
            ],
            isBinary: false
        )
        let sourceDiff = GitFileDiff(
            path: "resolved.txt",
            originalPath: nil,
            oldLabel: "source",
            newLabel: "merge",
            oldLines: ["same", "source", "tail"],
            newLines: resultLines,
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 3,
                    newStart: 1,
                    newCount: 4,
                    lines: [
                        GitPatchLine(kind: .context, text: "same"),
                        GitPatchLine(kind: .deletion, text: "source"),
                        GitPatchLine(kind: .addition, text: "resolved"),
                        GitPatchLine(kind: .addition, text: "inserted"),
                        GitPatchLine(kind: .context, text: "tail")
                    ]
                )
            ],
            isBinary: false
        )
        let model = GitMergeDiffRenderModel(
            diff: GitMergeFileDiff(target: targetDiff, source: sourceDiff)
        )

        try require(model.rows.count == 4, "Three-way alignment returned an unexpected row count")
        try require(
            model.rows[1].target?.text == "target"
                && model.rows[1].result?.text == "resolved"
                && model.rows[1].source?.text == "source",
            "Parent replacements were not aligned with the merge result"
        )
        try require(
            model.rows[2].target == nil
                && model.rows[2].result?.text == "inserted"
                && model.rows[2].source == nil,
            "A result-only insertion did not leave both parent panes empty"
        )
        try require(!model.rows[0].isChanged && !model.rows[3].isChanged, "Context rows were marked as changed")
        try require(model.rows[1].isChanged && model.rows[2].isChanged, "Changed rows were not marked")

        let deletedParentDiff = GitFileDiff(
            path: "deleted.txt",
            originalPath: nil,
            oldLabel: "parent",
            newLabel: "merge",
            oldLines: ["removed"],
            newLines: [],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 1,
                    newStart: 1,
                    newCount: 0,
                    lines: [GitPatchLine(kind: .deletion, text: "removed")]
                )
            ],
            isBinary: false
        )
        let deletedModel = GitMergeDiffRenderModel(
            diff: GitMergeFileDiff(target: deletedParentDiff, source: deletedParentDiff)
        )
        try require(
            deletedModel.rows.count == 1
                && deletedModel.rows[0].target?.text == "removed"
                && deletedModel.rows[0].result == nil
                && deletedModel.rows[0].source?.text == "removed",
            "A deleted Merge result was not aligned without an empty-range failure"
        )

        let preview = GitMergeDiffView(
            diff: GitMergeFileDiff(target: targetDiff, source: sourceDiff),
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in }
        )
        .frame(width: 1_440, height: 720)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_440, height: 720)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        try require(
            hostingView.fittingSize.width <= 1_441 && hostingView.fittingSize.height <= 721,
            "Three-pane Merge Diff exceeded its container"
        )
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw VerificationFailure(message: "Could not create three-pane Merge Diff rendering")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 20_000 else {
            throw VerificationFailure(message: "Three-pane Merge Diff rendering was empty")
        }
        try png.write(
            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/git-merge-diff-preview.png"),
            options: .atomic
        )
        let scrollViews = descendantViews(of: hostingView)
            .compactMap { $0 as? NSScrollView }
        guard let verticalScrollView = scrollViews.first(where: {
            $0.identifier?.rawValue == "RepoDesk.MergeDiffVerticalScroll"
        }) else {
            throw VerificationFailure(message: "Three-pane Merge Diff vertical scroll view was unavailable")
        }
        let expectedMinimumHeight = verticalScrollView.contentView.bounds.height - 32
        for pane in ["target", "result", "source"] {
            guard let scrollView = scrollViews.first(where: {
                $0.identifier?.rawValue == "RepoDesk.MergeDiffHorizontalScroll.\(pane)"
            }) else {
                throw VerificationFailure(message: "Three-pane Merge Diff \(pane) scroll view was unavailable")
            }
            try require(
                scrollView.frame.height >= expectedMinimumHeight,
                "Three-pane Merge Diff \(pane) pane did not fill the available height "
                    + "(actual: \(scrollView.frame.height), expected at least: \(expectedMinimumHeight))"
            )
            guard let documentView = scrollView.documentView,
                  let horizontalScroller = scrollView.horizontalScroller else {
                throw VerificationFailure(
                    message: "Three-pane Merge Diff \(pane) horizontal content was unavailable"
                )
            }
            let scrollerOverlap = scrollView.contentView.frame
                .intersection(horizontalScroller.frame)
                .height
            let unobscuredHeight = scrollView.contentView.bounds.height - scrollerOverlap
            try require(
                unobscuredHeight + 0.5 >= documentView.bounds.height,
                "Three-pane Merge Diff \(pane) bottom content was hidden by the horizontal scroller"
            )
        }

        print("Git merge diff verification passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationFailure(message: message) }
    }

    private static func descendantViews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendantViews)
    }
}
