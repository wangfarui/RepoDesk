import Foundation

struct HistorySplitLayout: Equatable, Sendable {
    static let defaultVerticalFraction = 0.56
    static let defaultHorizontalFraction = 0.48

    static func normalizedFraction(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0.05), 0.95)
    }
}
