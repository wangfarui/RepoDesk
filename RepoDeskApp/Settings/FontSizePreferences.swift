import SwiftUI

enum RepoDeskFontSize {
    static let minimum = 10.0
    static let maximum = 16.0
    static let `default` = 13.0

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return `default` }
        return min(max(value.rounded(), minimum), maximum)
    }

    static func dynamicTypeSize(for value: Double) -> DynamicTypeSize {
        switch normalized(value) {
        case ...10: .xSmall
        case 11: .small
        case 12: .medium
        case 13: .large
        case 14: .xLarge
        case 15: .xxLarge
        default: .xxxLarge
        }
    }
}

extension View {
    func repoDeskFontSize(_ value: Double) -> some View {
        let value = RepoDeskFontSize.normalized(value)
        return font(.system(size: value))
            .dynamicTypeSize(RepoDeskFontSize.dynamicTypeSize(for: value))
    }
}
