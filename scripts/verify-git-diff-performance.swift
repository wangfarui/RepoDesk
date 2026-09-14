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
        var singleGapNewLines = oldLines
        singleGapNewLines[lineCount - 1] += " changed"
        let singleGapDiff = GitFileDiff(
            path: "src/LargeSingleGapFile.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: oldLines,
            newLines: singleGapNewLines,
            hunks: [
                GitDiffHunk(
                    oldStart: lineCount,
                    oldCount: 1,
                    newStart: lineCount,
                    newCount: 1,
                    lines: [
                        GitPatchLine(kind: .deletion, text: oldLines[lineCount - 1]),
                        GitPatchLine(kind: .addition, text: singleGapNewLines[lineCount - 1])
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
        let (singleGapDuration, singleGapViewCount) = try measureGapExpansion(
            diff: singleGapDiff,
            renderModel: GitDiffRenderModel(diff: singleGapDiff),
            presentation: .unified,
            scrollVerification: (offset: CGFloat(1_999 * 22), text: "line 2000")
        )
        let (allGapsDuration, allGapsViewCount) = try measureGapExpansion(
            diff: diff,
            renderModel: renderModel,
            presentation: .sideBySide
        )
        let blameDuration = measureBlameUpdate(
            hostingView: hostingView,
            diff: diff,
            renderModel: renderModel,
            blame: blame
        )
        let denseLineCount = 1_200
        let denseOldLines = (1...denseLineCount).map {
            "old line \($0) " + String(repeating: "0123456789", count: 10)
        }
        let denseNewLines = (1...denseLineCount).map {
            "new line \($0) " + String(repeating: "9876543210", count: 10)
        }
        let densePatchLines = zip(denseOldLines, denseNewLines).flatMap { oldLine, newLine in
            [
                GitPatchLine(kind: .deletion, text: oldLine),
                GitPatchLine(kind: .addition, text: newLine)
            ]
        }
        let denseDiff = GitFileDiff(
            path: "src/DenseChanges.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: denseOldLines,
            newLines: denseNewLines,
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: denseLineCount,
                    newStart: 1,
                    newCount: denseLineCount,
                    lines: densePatchLines
                )
            ],
            isBinary: false
        )
        let denseRenderModel = GitDiffRenderModel(diff: denseDiff)
        let (denseUnifiedView, denseUnifiedDuration) = measureInitialLayout(
            diff: denseDiff,
            renderModel: denseRenderModel,
            presentation: .unified
        )
        let (denseSideBySideView, denseSideBySideDuration) = measureInitialLayout(
            diff: denseDiff,
            renderModel: denseRenderModel,
            presentation: .sideBySide
        )
        try verifyVirtualizedScroll(
            hostingView: denseUnifiedView,
            scrollIdentifier: "RepoDesk.UnifiedDiffVerticalScroll",
            targetOffset: CGFloat(599 * 2 * 22),
            expectedText: "line 600"
        )
        try verifyVirtualizedScroll(
            hostingView: denseSideBySideView,
            scrollIdentifier: "RepoDesk.SideBySideDiffVerticalScroll",
            targetOffset: CGFloat(599 * 22),
            expectedText: "line 600"
        )
        let continuousScrollDuration = try measureContinuousScroll(
            hostingView: denseSideBySideView,
            scrollIdentifier: "RepoDesk.SideBySideDiffVerticalScroll",
            steps: 100,
            stepHeight: 44
        )
        let fragmentedChangeCount = 1_500
        var fragmentedOldLines: [String] = []
        var fragmentedNewLines: [String] = []
        var fragmentedPatchLines: [GitPatchLine] = []
        for index in 1...fragmentedChangeCount {
            let contextLine = "context \(index)"
            let oldLine = "old value \(index)"
            let newLine = "new value \(index)"
            fragmentedOldLines.append(contentsOf: [contextLine, oldLine])
            fragmentedNewLines.append(contentsOf: [contextLine, newLine])
            fragmentedPatchLines.append(contentsOf: [
                GitPatchLine(kind: .context, text: contextLine),
                GitPatchLine(kind: .deletion, text: oldLine),
                GitPatchLine(kind: .addition, text: newLine)
            ])
        }
        let fragmentedDiff = GitFileDiff(
            path: "src/FragmentedChanges.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: fragmentedOldLines,
            newLines: fragmentedNewLines,
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: fragmentedOldLines.count,
                    newStart: 1,
                    newCount: fragmentedNewLines.count,
                    lines: fragmentedPatchLines
                )
            ],
            isBinary: false
        )
        let fragmentedModelStart = ProcessInfo.processInfo.systemUptime
        let fragmentedRenderModel = GitDiffRenderModel(diff: fragmentedDiff)
        let fragmentedModelDuration = ProcessInfo.processInfo.systemUptime - fragmentedModelStart

        report(String(format: "Render model preparation: %.3fs", modelDuration))
        report(String(format: "Comparison layout: %.3fs", openDuration))
        report(String(format: "Single gap expansion: %.3fs (%d native views)", singleGapDuration, singleGapViewCount))
        report(String(format: "All gaps expansion: %.3fs (%d native views)", allGapsDuration, allGapsViewCount))
        report(String(format: "Continuous side-by-side scroll: %.3fs", continuousScrollDuration))
        report(String(format: "Blame layout: %.3fs", blameDuration))
        report(String(format: "Dense Unified layout: %.3fs", denseUnifiedDuration))
        report(String(format: "Dense Side-by-side layout: %.3fs", denseSideBySideDuration))
        report(String(format: "Fragmented model preparation: %.3fs", fragmentedModelDuration))
        try require(openDuration < 0.35, "Opening comparison exceeded the 350ms budget.")
        try require(singleGapDuration < 0.25, "Expanding one unchanged gap exceeded the 250ms budget.")
        try require(singleGapViewCount < 10_000, "Expanding one unchanged gap created too many native views.")
        try require(allGapsDuration < 0.35, "Expanding all unchanged gaps exceeded the 350ms budget.")
        try require(allGapsViewCount < 10_000, "Expanding all unchanged gaps created too many native views.")
        try require(continuousScrollDuration < 0.9, "Continuous side-by-side scrolling exceeded the 900ms budget.")
        try require(blameDuration < 0.35, "Enabling blame exceeded the 350ms budget.")
        try require(denseUnifiedDuration < 0.5, "Dense Unified layout exceeded the 500ms budget.")
        try require(denseSideBySideDuration < 0.5, "Dense Side-by-side layout exceeded the 500ms budget.")
        try require(
            fragmentedRenderModel.navigationTargets.count == fragmentedChangeCount,
            "Fragmented Diff navigation targets were incomplete."
        )
        try require(
            fragmentedModelDuration < 0.25,
            "Fragmented Diff model preparation exceeded the 250ms budget."
        )
        print("Git diff performance verification passed")
    }

    private static func measureInitialLayout(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        presentation: GitDiffPresentation = .sideBySide
    ) -> (NSHostingView<PerformanceDiffRoot>, TimeInterval) {
        let start = ProcessInfo.processInfo.systemUptime
        let hostingView = NSHostingView(rootView: PerformanceDiffRoot(
            diff: diff,
            renderModel: renderModel,
            oldBlame: nil,
            presentation: presentation,
            expansionState: PerformanceExpansionState()
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
            oldBlame: blame,
            presentation: .sideBySide,
            expansionState: PerformanceExpansionState()
        )
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        return ProcessInfo.processInfo.systemUptime - start
    }

    private static func measureGapExpansion(
        diff: GitFileDiff,
        renderModel: GitDiffRenderModel,
        presentation: GitDiffPresentation,
        scrollVerification: (offset: CGFloat, text: String)? = nil
    ) throws -> (TimeInterval, Int) {
        let expansionState = PerformanceExpansionState()
        let hostingView = NSHostingView(rootView: PerformanceDiffRoot(
            diff: diff,
            renderModel: renderModel,
            oldBlame: nil,
            presentation: presentation,
            expansionState: expansionState
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 680)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let start = ProcessInfo.processInfo.systemUptime
        expansionState.gapIDs = renderModel.gapIDs
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let duration = ProcessInfo.processInfo.systemUptime - start
        let viewCount = descendantViews(of: hostingView).count
        if let scrollVerification {
            try verifyVirtualizedScroll(
                hostingView: hostingView,
                scrollIdentifier: presentation == .unified
                    ? "RepoDesk.UnifiedDiffVerticalScroll"
                    : "RepoDesk.SideBySideDiffVerticalScroll",
                targetOffset: scrollVerification.offset,
                expectedText: scrollVerification.text
            )
        }
        return (duration, viewCount)
    }

    private static func measureContinuousScroll(
        hostingView: NSView,
        scrollIdentifier: String,
        steps: Int,
        stepHeight: CGFloat
    ) throws -> TimeInterval {
        guard let scrollView = descendantViews(of: hostingView)
            .compactMap({ $0 as? NSScrollView })
            .first(where: { $0.identifier?.rawValue == scrollIdentifier }) else {
            throw GitDiffPerformanceVerificationError(
                message: "Continuous-scroll Diff view \(scrollIdentifier) was not rendered."
            )
        }
        let maximumOffset = max(
            0,
            (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: 0)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()
        let start = ProcessInfo.processInfo.systemUptime
        for step in 1...steps {
            let requestedOffset = min(maximumOffset, CGFloat(step) * stepHeight)
            scrollView.contentView.scroll(
                to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: requestedOffset)
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
            hostingView.layoutSubtreeIfNeeded()
        }
        return ProcessInfo.processInfo.systemUptime - start
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GitDiffPerformanceVerificationError(message: message) }
    }

    private static func verifyVirtualizedScroll(
        hostingView: NSView,
        scrollIdentifier: String,
        targetOffset: CGFloat,
        expectedText: String
    ) throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        guard let scrollView = descendantViews(of: hostingView)
            .compactMap({ $0 as? NSScrollView })
            .first(where: { $0.identifier?.rawValue == scrollIdentifier }) else {
            throw GitDiffPerformanceVerificationError(
                message: "Virtualized Diff scroll view \(scrollIdentifier) was not rendered."
            )
        }
        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetOffset)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hostingView.layoutSubtreeIfNeeded()

        try require(
            renderedTextIsVisible(
                expectedText,
                in: scrollView.contentView,
                hostingView: hostingView
            ),
            "Virtualized Diff did not render \(expectedText) after scrolling."
        )
        try require(
            descendantViews(of: hostingView).count < 10_000,
            "Virtualized Diff created too many native views."
        )
    }

    private static func descendantViews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendantViews)
    }

    private static func renderedTextIsVisible(
        _ expectedText: String,
        in clipView: NSClipView,
        hostingView: NSView
    ) -> Bool {
        for textField in descendantViews(of: hostingView)
            .compactMap({ $0 as? NSTextField })
            where textField.stringValue.contains(expectedText) {
            if textField.convert(textField.bounds, to: clipView).intersects(clipView.bounds) {
                return true
            }
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
            if textView.convert(bounds, to: clipView).intersects(clipView.bounds) {
                return true
            }
        }
        return false
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
    let presentation: GitDiffPresentation
    @ObservedObject var expansionState: PerformanceExpansionState

    var body: some View {
        GitDiffView(
            diff: diff,
            ignoresWhitespace: false,
            toggleIgnoreWhitespace: {},
            jumpToSource: { _ in },
            lockedPresentation: presentation,
            oldBlame: oldBlame,
            newBlame: nil,
            toggleOldBlame: {},
            toggleNewBlame: {},
            renderModel: renderModel,
            expandedGapIDs: $expansionState.gapIDs
        )
        .frame(width: 1_200, height: 680)
    }
}

@MainActor
private final class PerformanceExpansionState: ObservableObject {
    @Published var gapIDs: Set<String> = []
}
