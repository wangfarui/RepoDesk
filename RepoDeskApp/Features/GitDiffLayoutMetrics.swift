import AppKit

@MainActor
enum GitDiffLayoutMetrics {
    static let minimumUnifiedWidth: CGFloat = 720
    static let minimumSidePaneWidth: CGFloat = 320
    static let sideDividerWidth: CGFloat = 1

    static func sidePaneViewportWidth(containerWidth: CGFloat) -> CGFloat {
        max(0, (containerWidth - sideDividerWidth) / 2)
    }

    static func requiredUnifiedWidth(oldLines: [String], newLines: [String]) -> CGFloat {
        max(maximumTextWidth(oldLines), maximumTextWidth(newLines)) + 150
    }

    static func requiredSidePaneWidth(lines: [String]) -> CGFloat {
        maximumTextWidth(lines) + 78
    }

    static func maximumTextWidth(_ lines: [String]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let cellWidth = ceil(("0" as NSString).size(withAttributes: attributes).width)
        let maximumColumns = lines.reduce(0) { max($0, displayColumns(in: $1)) }
        return CGFloat(maximumColumns) * cellWidth
    }

    private static func displayColumns(in line: String, tabWidth: Int = 4) -> Int {
        var column = 0
        for scalar in line.unicodeScalars {
            if scalar == "\t" {
                column += tabWidth - column % tabWidth
            } else {
                column += scalar.value >= 0x1100 ? 2 : 1
            }
        }
        return column
    }
}
