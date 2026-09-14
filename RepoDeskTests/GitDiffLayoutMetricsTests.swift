import CoreGraphics
import Testing
@testable import RepoDesk

@MainActor
struct GitDiffLayoutMetricsTests {
    @Test func longLineRequiresHorizontalOverflow() {
        let longLine = String(repeating: "0123456789", count: 80)

        let unifiedWidth = GitDiffLayoutMetrics.requiredUnifiedWidth(
            oldLines: ["short"],
            newLines: [longLine]
        )
        let sidePaneWidth = GitDiffLayoutMetrics.requiredSidePaneWidth(lines: [longLine])

        #expect(unifiedWidth > 900)
        #expect(sidePaneWidth > GitDiffLayoutMetrics.minimumSidePaneWidth)
    }

    @Test func tabsAndWideCharactersIncreaseMeasuredWidth() {
        let shortWidth = GitDiffLayoutMetrics.maximumTextWidth(["value"])
        let tabbedWidth = GitDiffLayoutMetrics.maximumTextWidth(["value\tvalue\tvalue"])
        let wideWidth = GitDiffLayoutMetrics.maximumTextWidth(["这是一个需要水平滚动查看的长内容"])

        #expect(tabbedWidth > shortWidth)
        #expect(wideWidth > shortWidth)
    }

    @Test func sidePaneViewportsKeepDividerAtContainerCenter() {
        let containerWidth: CGFloat = 1_201
        let paneWidth = GitDiffLayoutMetrics.sidePaneViewportWidth(
            containerWidth: containerWidth
        )

        #expect(paneWidth == 600)
        #expect(paneWidth * 2 + GitDiffLayoutMetrics.sideDividerWidth == containerWidth)
    }
}
