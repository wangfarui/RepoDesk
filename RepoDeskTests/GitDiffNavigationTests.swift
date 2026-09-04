import CoreGraphics
import Testing
@testable import RepoDesk

@MainActor
struct GitDiffNavigationTests {
    @Test func adjacentNavigationStopsAtHunkBoundaries() {
        #expect(GitDiffHunkNavigation.adjacentIndex(
            currentIndex: 0,
            offset: -1,
            targetCount: 2
        ) == nil)
        #expect(GitDiffHunkNavigation.adjacentIndex(
            currentIndex: 0,
            offset: 1,
            targetCount: 2
        ) == 1)
        #expect(GitDiffHunkNavigation.adjacentIndex(
            currentIndex: 1,
            offset: 1,
            targetCount: 2
        ) == nil)
    }

    @Test func manualNavigationUsesChangesAroundTheViewportCenter() {
        let targetCenters: [CGFloat] = [100, 300, 500]

        #expect(GitDiffHunkNavigation.cursor(
            viewportOffset: 300,
            viewportHeight: 200,
            targetCenters: targetCenters
        ) == GitDiffHunkNavigationCursor(previousIndex: 1, nextIndex: 2))
        #expect(GitDiffHunkNavigation.cursor(
            viewportOffset: 200,
            viewportHeight: 200,
            targetCenters: targetCenters
        ) == GitDiffHunkNavigationCursor(previousIndex: 0, nextIndex: 2))
        #expect(GitDiffHunkNavigation.cursor(
            viewportOffset: 500,
            viewportHeight: 200,
            targetCenters: targetCenters
        ) == GitDiffHunkNavigationCursor(previousIndex: 2, nextIndex: nil))
    }

    @Test func renderModelCreatesNavigationTargetsForEveryHunk() {
        let diff = GitFileDiff(
            path: "Sources/App.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: ["one", "old", "three", "four", "old again", "six"],
            newLines: ["one", "new", "three", "four", "new again", "six"],
            hunks: [
                GitDiffHunk(
                    oldStart: 2,
                    oldCount: 1,
                    newStart: 2,
                    newCount: 1,
                    lines: [
                        GitPatchLine(kind: .deletion, text: "old"),
                        GitPatchLine(kind: .addition, text: "new")
                    ]
                ),
                GitDiffHunk(
                    oldStart: 5,
                    oldCount: 1,
                    newStart: 5,
                    newCount: 1,
                    lines: [
                        GitPatchLine(kind: .deletion, text: "old again"),
                        GitPatchLine(kind: .addition, text: "new again")
                    ]
                )
            ],
            isBinary: false
        )

        let targets = GitDiffRenderModel(diff: diff).navigationTargets

        #expect(targets.map(\.newLine) == [2, 5])
        #expect(targets.allSatisfy { !$0.unifiedRowID.isEmpty && !$0.sideRowID.isEmpty })
    }

    @Test func renderModelCreatesNavigationTargetsForSeparateChangesInsideOneHunk() {
        let diff = GitFileDiff(
            path: "Sources/App.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: ["one", "old", "three", "four", "old again", "six"],
            newLines: ["one", "new", "three", "four", "new again", "six"],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 6,
                    newStart: 1,
                    newCount: 6,
                    lines: [
                        GitPatchLine(kind: .context, text: "one"),
                        GitPatchLine(kind: .deletion, text: "old"),
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

        #expect(GitDiffRenderModel(diff: diff).navigationTargets.map(\.newLine) == [2, 5])
    }

    @Test func deletionOnlyChangeUsesTheFollowingNewLineForSourceNavigation() {
        let diff = GitFileDiff(
            path: "Sources/App.swift",
            originalPath: nil,
            oldLabel: "HEAD",
            newLabel: "Working Tree",
            oldLines: ["one", "removed", "three"],
            newLines: ["one", "three"],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 3,
                    newStart: 1,
                    newCount: 2,
                    lines: [
                        GitPatchLine(kind: .context, text: "one"),
                        GitPatchLine(kind: .deletion, text: "removed"),
                        GitPatchLine(kind: .context, text: "three")
                    ]
                )
            ],
            isBinary: false
        )

        #expect(GitDiffRenderModel(diff: diff).navigationTargets.map(\.newLine) == [2])
    }
}
