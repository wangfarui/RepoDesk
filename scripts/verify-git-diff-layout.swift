import AppKit
import SwiftUI

private struct GitDiffLayoutVerificationError: Error {
    let message: String
}

@MainActor
private final class RecordingVerticalScrollView: NSScrollView {
    private(set) var receivedVerticalScrollEventCount = 0

    override func scrollWheel(with event: NSEvent) {
        receivedVerticalScrollEventCount += 1
    }
}

@main
@MainActor
enum GitDiffLayoutVerification {
    static func main() throws {
        _ = NSApplication.shared
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
        try require(
            GitDiffGapExpansionAction.resolve(gapIDs: [], expandedGapIDs: []) == .expandAll,
            "A diff without gaps should keep the default expansion action."
        )
        let gapIDs: Set<String> = ["first", "second"]
        try require(
            GitDiffGapExpansionAction.resolve(
                gapIDs: gapIDs,
                expandedGapIDs: ["first"]
            ) == .expandAll,
            "Partially expanded gaps should offer Expand All."
        )
        try require(
            GitDiffGapExpansionAction.resolve(
                gapIDs: gapIDs,
                expandedGapIDs: gapIDs
            ) == .collapseAll,
            "Fully expanded gaps should offer Collapse All."
        )
        try require(
            GitDiffHunkNavigation.adjacentIndex(
                currentIndex: 0,
                offset: -1,
                targetCount: 2
            ) == nil,
            "Hunk navigation should stop before the first change."
        )
        try require(
            GitDiffHunkNavigation.adjacentIndex(
                currentIndex: 0,
                offset: 1,
                targetCount: 2
            ) == 1,
            "Hunk navigation should advance to the next change."
        )
        try require(
            GitDiffHunkNavigation.adjacentIndex(
                currentIndex: 1,
                offset: 1,
                targetCount: 2
            ) == nil,
            "Hunk navigation should stop after the last change."
        )
        try require(
            GitDiffHunkNavigation.cursor(
                viewportOffset: 300,
                viewportHeight: 200,
                targetCenters: [100, 300, 500]
            ) == GitDiffHunkNavigationCursor(previousIndex: 1, nextIndex: 2),
            "Manual navigation should use the nearest changes around the viewport center."
        )
        try require(
            GitDiffHunkNavigation.cursor(
                viewportOffset: 200,
                viewportHeight: 200,
                targetCenters: [100, 300, 500]
            ) == GitDiffHunkNavigationCursor(previousIndex: 0, nextIndex: 2),
            "A change at the viewport center should be treated as the current change."
        )
        try require(
            GitDiffHunkNavigation.cursor(
                viewportOffset: 500,
                viewportHeight: 200,
                targetCenters: [100, 300, 500]
            ) == GitDiffHunkNavigationCursor(previousIndex: 2, nextIndex: nil),
            "Manual navigation should stop below the final change."
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
                "}",
                "",
                "public static void stop() {",
                "    cleanup();",
                "}"
            ],
            newLines: [
                "private final static Logger logger = LoggerFactory.getLogger(ApplicationMain.class);",
                "public static void main(String[] args) {",
                "    logger.info(\"starting\");",
                "    SpringApplication.run(ApplicationMain.class, args);",
                "}",
                "",
                "public static void stop() {",
                "    logger.info(\"stopping\");",
                "    cleanup();",
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
                ),
                GitDiffHunk(
                    oldStart: 6,
                    oldCount: 3,
                    newStart: 7,
                    newCount: 4,
                    lines: [
                        GitPatchLine(kind: .context, text: "public static void stop() {"),
                        GitPatchLine(kind: .addition, text: "    logger.info(\"stopping\");"),
                        GitPatchLine(kind: .context, text: "    cleanup();"),
                        GitPatchLine(kind: .context, text: "}")
                    ]
                )
            ],
            isBinary: false
        )
        let renderModel = GitDiffRenderModel(diff: diff)
        try require(
            renderModel.navigationTargets.map(\.newLine) == [3, 8],
            "Diff render planning should target the first changed line in each hunk."
        )
        let navigationLongLine = String(repeating: "0123456789", count: 90)
        let oneHunkDiff = GitFileDiff(
            path: "src/TwoChanges.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: ["one", "old \(navigationLongLine)", "three", "four", "old again", "six"],
            newLines: ["one", "new", "three", "four", "new again", "six"],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 6,
                    newStart: 1,
                    newCount: 6,
                    lines: [
                        GitPatchLine(kind: .context, text: "one"),
                        GitPatchLine(kind: .deletion, text: "old \(navigationLongLine)"),
                        GitPatchLine(kind: .addition, text: "new"),
                        GitPatchLine(kind: .context, text: "three"),
                        GitPatchLine(kind: .context, text: "four"),
                        GitPatchLine(kind: .deletion, text: "old again"),
                        GitPatchLine(kind: .addition, text: "new again"),
                        GitPatchLine(kind: .context, text: "six")
                    ]
                )
            ],
            isBinary: false
        )
        let oneHunkRenderModel = GitDiffRenderModel(diff: oneHunkDiff)
        try require(
            oneHunkRenderModel.navigationTargets.map(\.newLine) == [2, 5],
            "Separate change blocks inside one Git hunk should be independently navigable."
        )
        try require(
            renderModel.navigationTargets.allSatisfy {
                !$0.unifiedRowID.isEmpty && !$0.sideRowID.isEmpty
            },
            "Each hunk should have Unified and Side-by-side scroll anchors."
        )
        let anchorOldLines = (1...320).map { "anchor line \($0)" }
        var anchorNewLines = anchorOldLines
        anchorNewLines[299] = "anchored changed line 300"
        let anchorDiff = GitFileDiff(
            path: "src/AnchorExpansion.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: anchorOldLines,
            newLines: anchorNewLines,
            hunks: [
                GitDiffHunk(
                    oldStart: 298,
                    oldCount: 5,
                    newStart: 298,
                    newCount: 5,
                    lines: [
                        GitPatchLine(kind: .context, text: anchorOldLines[297]),
                        GitPatchLine(kind: .context, text: anchorOldLines[298]),
                        GitPatchLine(kind: .deletion, text: anchorOldLines[299]),
                        GitPatchLine(kind: .addition, text: anchorNewLines[299]),
                        GitPatchLine(kind: .context, text: anchorOldLines[300]),
                        GitPatchLine(kind: .context, text: anchorOldLines[301])
                    ]
                )
            ],
            isBinary: false
        )
        let anchorRenderModel = GitDiffRenderModel(diff: anchorDiff)
        let committedAt = Date(timeIntervalSince1970: 1_706_745_600)
        let oldBlame = Dictionary(uniqueKeysWithValues: (1...8).map {
            ($0, GitBlameLine(
                lineNumber: $0,
                commitHash: "6346a9c9d9123456789012345678901234567890",
                author: $0 < 3 ? "dengfeng.wei" : "jingzhouzhao",
                authoredAt: committedAt
            ))
        })
        let newBlame = Dictionary(uniqueKeysWithValues: (1...10).map {
            ($0, GitBlameLine(
                lineNumber: $0,
                commitHash: [3, 8].contains($0) ? String(repeating: "0", count: 40) : "6346a9c9d9123456789012345678901234567890",
                author: [3, 8].contains($0) ? "未提交" : "dengfeng.wei",
                authoredAt: [3, 8].contains($0) ? nil : committedAt
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
            toggleNewBlame: {},
            renderModel: renderModel
        )
        .frame(width: 1_200, height: 680)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 680)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        try writePreview(
            hostingView,
            name: "git-diff-horizontal-preview.png"
        )
        try verifySideBySideFillsAvailableHeight(in: hostingView)
        try verifyHunkNavigationInteraction(
            diff: diff,
            renderModel: renderModel,
            presentation: .unified
        )
        try verifyHunkNavigationInteraction(
            diff: diff,
            renderModel: renderModel,
            presentation: .sideBySide
        )
        try verifyHunkNavigationInteraction(
            diff: oneHunkDiff,
            renderModel: oneHunkRenderModel,
            presentation: .unified
        )
        try verifyHunkNavigationInteraction(
            diff: oneHunkDiff,
            renderModel: oneHunkRenderModel,
            presentation: .sideBySide
        )
        try verifyManualVerticalScrolling(
            diff: diff,
            renderModel: renderModel,
            presentation: .unified
        )
        try verifyManualVerticalScrolling(
            diff: diff,
            renderModel: renderModel,
            presentation: .sideBySide
        )
        try verifyManualHunkNavigationInteraction(
            diff: oneHunkDiff,
            renderModel: oneHunkRenderModel,
            presentation: .unified
        )
        try verifyManualHunkNavigationInteraction(
            diff: oneHunkDiff,
            renderModel: oneHunkRenderModel,
            presentation: .sideBySide
        )
        try verifyGapExpansionPreservesVisibleChange(
            diff: anchorDiff,
            renderModel: anchorRenderModel,
            presentation: .unified,
            expectedText: anchorNewLines[299]
        )
        try verifyGapExpansionPreservesVisibleChange(
            diff: anchorDiff,
            renderModel: anchorRenderModel,
            presentation: .sideBySide,
            expectedText: anchorNewLines[299]
        )
        try verifyBottomContentClearsHorizontalScroller(
            diff: oneHunkDiff,
            renderModel: oneHunkRenderModel,
            presentation: .unified
        )
        try verifyBottomContentClearsHorizontalScroller(
            diff: oneHunkDiff,
            renderModel: oneHunkRenderModel,
            presentation: .sideBySide
        )

        print("Git diff layout verification passed")
    }

    private static func verifyBottomContentClearsHorizontalScroller(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        presentation: GitDiffPresentation
    ) throws {
        let preview = GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: presentation,
            renderModel: renderModel
        )
        .frame(width: 900, height: 180)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let horizontalScrollIdentifier = presentation == .unified
            ? "RepoDesk.UnifiedDiffHorizontalScroll"
            : "RepoDesk.SideBySideDiffHorizontalScroll.old"
        guard let horizontalScrollView = scrollView(
            in: hostingView,
            identifier: horizontalScrollIdentifier
        ), let documentView = horizontalScrollView.documentView,
           let horizontalScroller = horizontalScrollView.horizontalScroller else {
            throw GitDiffLayoutVerificationError(
                message: "The bottom-visibility horizontal Diff scroll view was not rendered."
            )
        }
        try scrollHorizontally(horizontalScrollView, to: 120)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let scrollerOverlap = horizontalScrollView.contentView.frame
            .intersection(horizontalScroller.frame)
            .height
        let unobscuredHeight = horizontalScrollView.contentView.bounds.height - scrollerOverlap
        try require(
            unobscuredHeight + 0.5 >= documentView.bounds.height,
            "The horizontal scroller hides the bottom of the Diff document "
                + "(unobscured: \(unobscuredHeight), "
                + "document: \(documentView.bounds.height))."
        )
    }

    private static func verifyGapExpansionPreservesVisibleChange(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        presentation: GitDiffPresentation,
        expectedText: String
    ) throws {
        let preview = GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: presentation,
            renderModel: renderModel
        )
        .frame(width: 900, height: 180)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let verticalScrollIdentifier = presentation == .unified
            ? "RepoDesk.UnifiedDiffVerticalScroll"
            : "RepoDesk.SideBySideDiffVerticalScroll"
        guard let verticalScrollView = scrollView(
            in: hostingView,
            identifier: verticalScrollIdentifier
        ) else {
            throw GitDiffLayoutVerificationError(
                message: "The anchored \(presentation.rawValue) Diff scroll view was not rendered."
            )
        }
        let maximumOffset = max(
            0,
            (verticalScrollView.documentView?.bounds.height ?? 0)
                - verticalScrollView.contentView.bounds.height
        )
        try require(maximumOffset > 0, "The anchored Diff fixture did not overflow before expansion.")
        scrollVertically(verticalScrollView, to: maximumOffset)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        guard let beforeY = renderedTextMidY(
            expectedText,
            in: hostingView
        ) else {
            throw GitDiffLayoutVerificationError(
                message: "The anchor change was not visible before expanding the upper gap."
            )
        }
        let buttons = descendantViews(of: hostingView).compactMap { $0 as? NSButton }
        guard buttons.indices.contains(2) else {
            try requireSwiftUIToolbarControlsRendered(in: hostingView)
            return
        }
        buttons[2].performClick(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        hostingView.layoutSubtreeIfNeeded()

        guard let afterY = renderedTextMidY(
            expectedText,
            in: hostingView
        ) else {
            throw GitDiffLayoutVerificationError(
                message: "Expanding the upper gap moved the anchor change out of the viewport."
            )
        }
        try require(
            abs(afterY - beforeY) < 2,
            "Expanding the upper gap moved the visible change from y=\(beforeY) to y=\(afterY)."
        )
    }

    private static func verifySideBySideFillsAvailableHeight(in hostingView: NSView) throws {
        guard let verticalScrollView = scrollView(
            in: hostingView,
            identifier: "RepoDesk.SideBySideDiffVerticalScroll"
        ), let oldScrollView = scrollView(
            in: hostingView,
            identifier: "RepoDesk.SideBySideDiffHorizontalScroll.old"
        ), let newScrollView = scrollView(
            in: hostingView,
            identifier: "RepoDesk.SideBySideDiffHorizontalScroll.new"
        ) else {
            throw GitDiffLayoutVerificationError(
                message: "The Side-by-side fill-height scroll views were not rendered."
            )
        }
        let expectedMinimumHeight = verticalScrollView.contentView.bounds.height - 30
        try require(
            oldScrollView.frame.height >= expectedMinimumHeight
                && newScrollView.frame.height >= expectedMinimumHeight,
            "Side-by-side code panes did not fill the available height "
                + "(old: \(oldScrollView.frame.height), new: \(newScrollView.frame.height), "
                + "expected at least: \(expectedMinimumHeight))."
        )
    }

    private static func verifyManualHunkNavigationInteraction(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        presentation: GitDiffPresentation
    ) throws {
        let preview = GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: presentation,
            renderModel: renderModel
        )
        .frame(width: 900, height: 100)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 100)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let verticalScrollIdentifier = presentation == .unified
            ? "RepoDesk.UnifiedDiffVerticalScroll"
            : "RepoDesk.SideBySideDiffVerticalScroll"
        guard let verticalScrollView = scrollView(
            in: hostingView,
            identifier: verticalScrollIdentifier
        ) else {
            throw GitDiffLayoutVerificationError(
                message: "The controlled \(presentation.rawValue) vertical scroll view was not rendered."
            )
        }
        let maximumOffset = max(
            0,
            (verticalScrollView.documentView?.bounds.height ?? 0)
                - verticalScrollView.contentView.bounds.height
        )
        try require(
            maximumOffset > 0,
            "The \(presentation.rawValue) manual hunk navigation fixture did not overflow."
        )

        scrollVertically(verticalScrollView, to: maximumOffset)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        var toolbarButtons = descendantViews(of: hostingView).compactMap { $0 as? NSButton }
        guard toolbarButtons.count >= 2 else {
            try requireSwiftUIToolbarControlsRendered(in: hostingView)
            return
        }
        try require(
            toolbarButtons[0].isEnabled,
            "Manual scrolling below all \(presentation.rawValue) changes did not update hunk navigation "
                + "(offset: \(verticalScrollView.contentView.bounds.origin.y)/\(maximumOffset), "
                + "buttons: \(toolbarButtons.prefix(2).map { ($0.title, $0.isEnabled) }))."
        )
        toolbarButtons[0].performClick(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        try require(
            verticalScrollView.contentView.bounds.origin.y < maximumOffset,
            "The Up action after bottom scrolling did not move to the nearest change above."
        )

        scrollVertically(verticalScrollView, to: 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        toolbarButtons = descendantViews(of: hostingView).compactMap { $0 as? NSButton }
        try require(
            toolbarButtons.count >= 2 && toolbarButtons[1].isEnabled,
            "Manual scrolling above all \(presentation.rawValue) changes did not update hunk navigation "
                + "(offset: \(verticalScrollView.contentView.bounds.origin.y), "
                + "buttons: \(toolbarButtons.prefix(2).map { ($0.title, $0.isEnabled) }))."
        )
        toolbarButtons[1].performClick(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        try require(
            verticalScrollView.contentView.bounds.origin.y > 0,
            "The Down action after top scrolling did not move to the nearest change below."
        )
    }

    private static func verifyManualVerticalScrolling(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        presentation: GitDiffPresentation
    ) throws {
        let preview = GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: presentation,
            renderModel: renderModel
        )
        .frame(width: 900, height: 140)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 140)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let verticalScrollIdentifier = presentation == .unified
            ? "RepoDesk.UnifiedDiffVerticalScroll"
            : "RepoDesk.SideBySideDiffVerticalScroll"
        guard let verticalScrollView = scrollView(
            in: hostingView,
            identifier: verticalScrollIdentifier
        ) else {
            throw GitDiffLayoutVerificationError(
                message: "The controlled \(presentation.rawValue) vertical scroll view was not rendered."
            )
        }
        let horizontalScrollIdentifiers = presentation == .unified
            ? ["RepoDesk.UnifiedDiffHorizontalScroll"]
            : [
                "RepoDesk.SideBySideDiffHorizontalScroll.old",
                "RepoDesk.SideBySideDiffHorizontalScroll.new"
            ]
        for identifier in horizontalScrollIdentifiers {
            guard let horizontalScrollView = scrollView(
                in: hostingView,
                identifier: identifier
            ) as? GitDiffHorizontalScrollViewContainer else {
                throw GitDiffLayoutVerificationError(
                    message: "The controlled horizontal scroll view \(identifier) was not rendered."
                )
            }
            try require(
                horizontalScrollView.enclosingVerticalScrollView() === verticalScrollView,
                "Manual vertical scrolling over \(identifier) was not routed to the outer \(presentation.rawValue) Diff."
            )
        }

        let recordingScrollView = RecordingVerticalScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 400,
            height: 200
        ))
        recordingScrollView.hasVerticalScroller = true
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let horizontalScrollView = GitDiffHorizontalScrollViewContainer(frame: NSRect(
            x: 0,
            y: 0,
            width: 400,
            height: 200
        ))
        documentView.addSubview(horizontalScrollView)
        recordingScrollView.documentView = documentView
        horizontalScrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: -3))
        try require(
            recordingScrollView.receivedVerticalScrollEventCount == 1,
            "A vertical wheel event over horizontal Diff content did not reach the outer vertical scroll view."
        )
        horizontalScrollView.scrollWheel(with: scrollEvent(deltaX: -3, deltaY: 0))
        try require(
            recordingScrollView.receivedVerticalScrollEventCount == 1,
            "A horizontal wheel event was incorrectly forwarded to the outer vertical scroll view."
        )
    }

    private static func verifyHunkNavigationInteraction(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        presentation: GitDiffPresentation
    ) throws {
        let preview = GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: presentation,
            renderModel: renderModel
        )
        .frame(width: 900, height: 170)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 170)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let toolbarButtons = descendantViews(of: hostingView).compactMap { $0 as? NSButton }
        guard toolbarButtons.count >= 2 else {
            try requireSwiftUIToolbarControlsRendered(in: hostingView)
            return
        }
        let previousButton = toolbarButtons[0]
        let nextButton = toolbarButtons[1]
        try require(!previousButton.isEnabled, "Previous hunk should be disabled at the first change.")
        try require(nextButton.isEnabled, "Next hunk button should be enabled for a multi-hunk diff.")
        let verticalScrollIdentifier = presentation == .unified
            ? "RepoDesk.UnifiedDiffVerticalScroll"
            : "RepoDesk.SideBySideDiffVerticalScroll"
        guard let beforeOffset = verticalScrollOffset(
            in: hostingView,
            identifier: verticalScrollIdentifier
        ) else {
            throw GitDiffLayoutVerificationError(
                message: "The controlled \(presentation.rawValue) vertical scroll view was not rendered."
            )
        }
        let horizontalScrollIdentifiers = presentation == .unified
            ? ["RepoDesk.UnifiedDiffHorizontalScroll"]
            : [
                "RepoDesk.SideBySideDiffHorizontalScroll.old",
                "RepoDesk.SideBySideDiffHorizontalScroll.new"
            ]
        let horizontalScrollViews = try horizontalScrollIdentifiers.map { identifier in
            guard let scrollView = scrollView(in: hostingView, identifier: identifier) else {
                throw GitDiffLayoutVerificationError(
                    message: "The controlled horizontal scroll view \(identifier) was not rendered."
                )
            }
            if diff.path == "src/TwoChanges.swift" {
                try require(
                    abs(scrollView.contentView.bounds.origin.x) < 0.5,
                    "The \(presentation.rawValue) Diff should initially be left-aligned."
                )
            }
            return scrollView
        }
        if presentation == .sideBySide, diff.path == "src/TwoChanges.swift" {
            try scrollHorizontally(horizontalScrollViews[0], to: 120)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            try require(
                horizontalScrollViews.allSatisfy {
                    abs($0.contentView.bounds.origin.x - 120) < 0.5
                },
                "Scrolling the old side did not synchronize the new side."
            )
            try scrollHorizontally(horizontalScrollViews[1], to: 240)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            try require(
                horizontalScrollViews.allSatisfy {
                    abs($0.contentView.bounds.origin.x - 240) < 0.5
                },
                "Scrolling the new side did not synchronize the old side."
            )
        } else {
            for scrollView in horizontalScrollViews {
                try scrollHorizontally(scrollView, to: 120)
            }
        }
        let horizontalOffsetsBeforeNavigation = horizontalScrollViews.map {
            $0.contentView.bounds.origin.x
        }
        if diff.path == "src/TwoChanges.swift" {
            try require(
                horizontalOffsetsBeforeNavigation.allSatisfy { $0 > 0 },
                "The horizontal preservation check requires manually scrolled content."
            )
        }
        nextButton.performClick(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hostingView.layoutSubtreeIfNeeded()
        let updatedButtons = descendantViews(of: hostingView).compactMap { $0 as? NSButton }
        try require(
            updatedButtons.count >= 2 && updatedButtons[0].isEnabled && !updatedButtons[1].isEnabled,
            "Hunk navigation state did not advance to the last change."
        )
        guard let afterOffset = verticalScrollOffset(
            in: hostingView,
            identifier: verticalScrollIdentifier
        ) else {
            throw GitDiffLayoutVerificationError(
                message: "The controlled \(presentation.rawValue) vertical scroll view disappeared."
            )
        }
        try require(
            afterOffset > beforeOffset,
            "Next hunk navigation did not advance the \(presentation.rawValue) vertical offset (\(beforeOffset) -> \(afterOffset))."
        )
        let horizontalOffsetsAfterNavigation = horizontalScrollViews.map {
            $0.contentView.bounds.origin.x
        }
        try require(
            zip(horizontalOffsetsBeforeNavigation, horizontalOffsetsAfterNavigation).allSatisfy {
                abs($0 - $1) < 0.5
            },
            "Hunk navigation changed the \(presentation.rawValue) horizontal offsets (\(horizontalOffsetsBeforeNavigation) -> \(horizontalOffsetsAfterNavigation))."
        )
    }

    private static func descendantViews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendantViews)
    }

    private static func requireSwiftUIToolbarControlsRendered(in hostingView: NSView) throws {
        let controlCount = descendantViews(of: hostingView)
            .filter { String(describing: type(of: $0)).contains("FocusRingView") }
            .filter { view in
                let frame = view.convert(view.bounds, to: hostingView)
                return frame.maxY < 47
            }
            .count
        try require(
            controlCount >= 5,
            "The SwiftUI Diff toolbar controls were not rendered (found \(controlCount), expected at least 5)."
        )
    }

    private static func renderedTextMidY(
        _ expectedText: String,
        in hostingView: NSView
    ) -> CGFloat? {
        if let textField = descendantViews(of: hostingView)
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.stringValue == expectedText }) {
            return textField.convert(textField.bounds, to: hostingView).midY
        }
        for textView in descendantViews(of: hostingView)
            .compactMap({ $0 as? GitDiffSelectableTextViewSurface }) {
            let range = (textView.string as NSString).range(of: expectedText)
            guard range.location != NSNotFound,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { continue }
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            var bounds = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            bounds.origin.x += textView.textContainerOrigin.x
            bounds.origin.y += textView.textContainerOrigin.y
            return textView.convert(bounds, to: hostingView).midY
        }
        return nil
    }

    private static func verticalScrollOffset(
        in view: NSView,
        identifier: String
    ) -> CGFloat? {
        descendantViews(of: view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == identifier }?
            .contentView.bounds.origin.y
    }

    private static func scrollView(in view: NSView, identifier: String) -> NSScrollView? {
        descendantViews(of: view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == identifier }
    }

    private static func scrollHorizontally(
        _ scrollView: NSScrollView,
        to requestedOffset: CGFloat
    ) throws {
        let maximumOffset = max(
            0,
            (scrollView.documentView?.bounds.width ?? 0) - scrollView.contentView.bounds.width
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: min(requestedOffset, maximumOffset),
                y: scrollView.contentView.bounds.origin.y
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func scrollVertically(_ scrollView: NSScrollView, to requestedOffset: CGFloat) {
        let maximumOffset = max(
            0,
            (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: min(max(0, requestedOffset), maximumOffset)
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func scrollEvent(deltaX: CGFloat, deltaY: CGFloat) -> NSEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        )
        return NSEvent(cgEvent: event!)!
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GitDiffLayoutVerificationError(message: message) }
    }

    private static func writePreview(_ view: NSView, name: String) throws {
        let pngData = try renderedPNG(view, rect: view.bounds)
        let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/\(name)")
        try pngData.write(to: outputURL, options: .atomic)
    }

    private static func renderedPNG(_ view: NSView, rect: NSRect) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw GitDiffLayoutVerificationError(message: "Diff preview could not be rendered.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else {
            throw GitDiffLayoutVerificationError(message: "Diff preview image could not be created.")
        }
        let scaleX = CGFloat(image.width) / view.bounds.width
        let scaleY = CGFloat(image.height) / view.bounds.height
        let cropRect = CGRect(
            x: rect.minX * scaleX,
            y: (view.bounds.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral
        guard let croppedImage = image.cropping(to: cropRect) else {
            throw GitDiffLayoutVerificationError(message: "Diff preview crop could not be created.")
        }
        let croppedBitmap = NSBitmapImageRep(cgImage: croppedImage)
        guard let pngData = croppedBitmap.representation(using: .png, properties: [:]) else {
            throw GitDiffLayoutVerificationError(message: "Diff preview PNG could not be created.")
        }
        return pngData
    }
}
