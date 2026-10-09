import AppKit
import SwiftUI
import Observation

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

        var toggledSides: [GitHistoryBlameSide] = []
        let annotations = Dictionary(uniqueKeysWithValues: GitHistoryBlameSide.allCases.map { side in
            (side, Dictionary(uniqueKeysWithValues: (1...4).map { number in
                (number, GitBlameLine(lineNumber: number, commitHash: "1234567890abcdef",
                                     author: "\(side.rawValue)-\(number)",
                                     authoredAt: Date(timeIntervalSince1970: 1704067200)))
            }))
        })
        let annotatedPreview = GitMergeDiffView(
            diff: GitMergeFileDiff(target: targetDiff, source: sourceDiff),
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            blame: annotations,
            toggleBlame: { side in { toggledSides.append(side) } }
        )
        .frame(width: 1_440, height: 720)
        let annotatedHostingView = NSHostingView(rootView: annotatedPreview)
        annotatedHostingView.frame = NSRect(x: 0, y: 0, width: 1_440, height: 720)
        annotatedHostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        try require(annotatedHostingView.fittingSize.width <= 1_441,
                    "Annotated Merge Diff exceeded its container")
        let annotatedViews = descendantViews(of: annotatedHostingView)
        for side in GitHistoryBlameSide.allCases {
            guard let text = annotatedViews.compactMap({ $0 as? GitDiffSelectableTextViewSurface }).first(where: {
                $0.accessibilityIdentifier() == "RepoDesk.MergeDiff.\(side.rawValue).SelectableText"
            }), let scroll = annotatedViews.compactMap({ $0 as? NSScrollView }).first(where: {
                $0.identifier?.rawValue == "RepoDesk.MergeDiffHorizontalScroll.\(side.rawValue)"
            }) else { throw VerificationFailure(message: "Annotated pane surface missing") }
            try require(text.contextAction?.title == "Annotate with Git Blame" && text.contextAction?.isOn == true,
                        "Selectable merge code has no checked blame menu")
            text.performContextAction?()
            try require(toggledSides.last == side, "Blame menu toggled the wrong pane")
            try require(scroll.frame.width > 100 && scroll.frame.width < 300,
                        "Annotated pane did not reserve a fixed blame gutter")
        }
        guard let annotatedBitmap = annotatedHostingView.bitmapImageRepForCachingDisplay(in: annotatedHostingView.bounds) else {
            throw VerificationFailure(message: "Could not render annotated Merge Diff")
        }
        annotatedHostingView.cacheDisplay(in: annotatedHostingView.bounds, to: annotatedBitmap)
        guard let annotatedPNG = annotatedBitmap.representation(using: .png, properties: [:]) else {
            throw VerificationFailure(message: "Could not encode annotated Merge Diff")
        }
        try annotatedPNG.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/git-merge-blame-preview.png"))

        try verifyCollapsedContext()
        print("Git merge diff verification passed")
    }

    private static func verifyCollapsedContext() throws {
        let result = (1...120).map { "line \($0)" }
        func fileDiff(changes: [Int], label: String) -> GitFileDiff {
            var old = result
            for number in changes { old[number - 1] = "\(label) \(number)" }
            return GitFileDiff(
                path: "large.txt", originalPath: nil, oldLabel: label, newLabel: "merge",
                oldLines: old, newLines: result,
                hunks: changes.map { number in
                    GitDiffHunk(oldStart: number, oldCount: 1, newStart: number, newCount: 1,
                                lines: [GitPatchLine(kind: .deletion, text: old[number - 1]),
                                        GitPatchLine(kind: .addition, text: result[number - 1])])
                }, isBinary: false
            )
        }
        let diff = GitMergeFileDiff(target: fileDiff(changes: [21, 101], label: "target"),
                                    source: fileDiff(changes: [61, 101], label: "source"))
        let model = GitMergeDiffRenderModel(diff: diff)
        let collapsed = model.displayRows()
        try require(model.gaps.map(\.count) == [17, 33, 33, 16], "Unchanged gaps did not retain three context lines")
        try require(collapsed.compactMap(\.line?.result?.number) == Array(18...24) + Array(58...64) + Array(98...104),
                    "Collapsed merge dropped a change or retained excess context")
        try require(collapsed.compactMap(\.line).filter(\.isChanged).map(\.id) == [20, 60, 100],
                    "Source-only changes were hidden")
        try require(collapsed.enumerated().compactMap { $0.element.line?.isChanged == true ? $0.offset : nil } == [4, 12, 20],
                    "Changed row navigation did not use compacted offsets")
        try require(model.displayRows(expandedGapIDs: model.gapIDs).compactMap(\.line) == model.rows,
                    "Expand all failed to restore complete line alignment")
        let unchanged = GitMergeFileDiff(target: fileDiff(changes: [], label: "target"),
                                         source: fileDiff(changes: [], label: "source"))
        try require(GitMergeDiffRenderModel(diff: unchanged).displayRows().count == 1,
                    "An unchanged file was not represented by an expandable gap")
        let closeChanges = GitMergeDiffRenderModel(diff: GitMergeFileDiff(
            target: fileDiff(changes: [21], label: "target"), source: fileDiff(changes: [28], label: "source")
        ))
        try require(closeChanges.gaps.count == 2, "Overlapping context around nearby changes was folded")
        var whitespace = result
        whitespace[20] += " "
        let whitespaceDiff = GitFileDiff(path: "large.txt", originalPath: nil, oldLabel: "parent", newLabel: "merge",
                                        oldLines: whitespace, newLines: result, hunks: [], isBinary: false)
        let whitespaceModel = GitMergeDiffRenderModel(diff: GitMergeFileDiff(target: unchanged.target, source: whitespaceDiff))
        try require(whitespaceModel.displayRows().contains { $0.line?.result?.number == 21 },
                    "A row with differing parent content was folded")

        let state = MergeGapVerificationState(diff: diff)
        let annotations = Dictionary(uniqueKeysWithValues: GitHistoryBlameSide.allCases.map { side in
            (side, Dictionary(uniqueKeysWithValues: (1...120).map { number in
                (number, GitBlameLine(lineNumber: number, commitHash: "1234567890abcdef",
                                     author: "\(side.rawValue)-\(number)", authoredAt: Date(timeIntervalSince1970: 1704067200)))
            }))
        })
        let hosting = NSHostingView(rootView: MergeGapVerificationPreview(state: state, annotations: annotations))
        hosting.frame = NSRect(x: 0, y: 0, width: 1_440, height: 720)
        func updateLayout() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            hosting.layoutSubtreeIfNeeded()
        }
        func surfaces() -> [GitDiffSelectableTextViewSurface] {
            descendantViews(of: hosting).compactMap { $0 as? GitDiffSelectableTextViewSurface }
        }
        func export(_ name: String) throws {
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw VerificationFailure(message: "Could not render folded merge")
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw VerificationFailure(message: "Could not encode folded merge")
            }
            try png.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/\(name).png"))
        }
        updateLayout()
        try require(surfaces().count == 3 && surfaces().allSatisfy { $0.model.rows.count == 25 },
                    "Three panes did not share the collapsed row layout")
        try export("git-merge-collapsed-preview")
        guard let sourceSurface = surfaces().first(where: {
            $0.accessibilityIdentifier() == "RepoDesk.MergeDiff.source.SelectableText"
        }), let firstGap = model.gaps.first else { throw VerificationFailure(message: "Missing collapsed source pane") }
        sourceSurface.onActivateGap?(firstGap.id)
        updateLayout()
        try require(state.expandedGapIDs == [firstGap.id] && surfaces().allSatisfy { $0.model.rows.count == 41 },
                    "Clicking a source gap did not synchronously expand all three panes")
        try require(surfaces().allSatisfy { $0.model.rows.first?.selectedLine == 1 },
                    "Expanded content lost its original result line numbers")
        try export("git-merge-expanded-blame-preview")

        state.expandedGapIDs = model.gapIDs
        updateLayout()
        try require(surfaces().allSatisfy { $0.model.rows.count == 120 && $0.model.rows.last?.selectedLine == 120 },
                    "Expand all lost native selectable text rows: \(surfaces().map { ($0.model.rows.count, $0.model.rows.last?.selectedLine) }); ids=\(state.expandedGapIDs)")
        state.expandedGapIDs = []
        updateLayout()
        try require(surfaces().allSatisfy { $0.model.rows.count == 25 }, "Restore folding did not refresh native text")
        let toolbarButtons = descendantViews(of: hosting).compactMap { $0 as? NSButton }
        if toolbarButtons.count >= 3 {
            toolbarButtons[2].performClick(nil)
            updateLayout()
            try require(state.expandedGapIDs == model.gapIDs, "Toolbar failed to expand all gaps")
            let buttons = descendantViews(of: hosting).compactMap { $0 as? NSButton }
            buttons[2].performClick(nil)
            updateLayout()
            try require(state.expandedGapIDs.isEmpty, "Toolbar failed to restore folding")
        }

        state.expandedGapIDs = [firstGap.id]
        updateLayout()
        guard let findListener = descendantViews(of: hosting).compactMap({ $0 as? ContentFindCommandListenerView }).first else {
            throw VerificationFailure(message: "Merge search listener missing")
        }
        findListener.requestFind?()
        updateLayout()
        guard let field = descendantViews(of: hosting).compactMap({ $0 as? NSTextField }).first(where: {
            $0.placeholderString == "Find"
        }) else { throw VerificationFailure(message: "Merge find input missing") }
        field.stringValue = "line 50"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        updateLayout()
        try require(state.expandedGapIDs == model.gapIDs && surfaces().allSatisfy {
            $0.model.searchMatches(query: "line 50", options: ContentSearchOptions()).count == 1
        }, "Search could not find content inside a folded gap")
        let closeButtons = descendantViews(of: hosting).compactMap { $0 as? NSButton }
        if let close = closeButtons.first(where: { $0.toolTip == "Close (Escape)" }) {
            close.performClick(nil)
            updateLayout()
        } else {
            field.stringValue = ""
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            updateLayout()
        }
        try require(state.expandedGapIDs == [firstGap.id] && surfaces().allSatisfy { $0.model.rows.count == 41 },
                    "Ending search did not restore the prior partial expansion")

        state.expandedGapIDs = model.gapIDs
        updateLayout()
        state.diff = GitMergeFileDiff(target: fileDiff(changes: [21], label: "new-target"),
                                      source: fileDiff(changes: [61], label: "new-source"))
        updateLayout()
        try require(state.expandedGapIDs.isEmpty && surfaces().allSatisfy { $0.model.rows.count < 120 },
                    "Changing the selected diff retained expanded context")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationFailure(message: message) }
    }

    private static func descendantViews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendantViews)
    }
}

@MainActor
@Observable
private final class MergeGapVerificationState {
    var expandedGapIDs: Set<String> = []
    var diff: GitMergeFileDiff
    init(diff: GitMergeFileDiff) { self.diff = diff }
}

@MainActor
private struct MergeGapVerificationPreview: View {
    @Bindable var state: MergeGapVerificationState
    let annotations: [GitHistoryBlameSide: [Int: GitBlameLine]]
    var body: some View {
        GitMergeDiffView(diff: state.diff, ignoresWhitespace: false, toggleIgnoreWhitespace: {},
                         jumpToSource: { _ in }, blame: annotations, expandedGapIDs: $state.expandedGapIDs)
            .frame(width: 1_440, height: 720)
    }
}
