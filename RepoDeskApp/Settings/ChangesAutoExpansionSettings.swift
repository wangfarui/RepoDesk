import Foundation

struct ChangesAutoExpansionSettings: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case byCount
        case always
        case never

        var id: Self { self }

        var title: String {
            switch self {
            case .byCount: "按改动数量"
            case .always: "始终展开"
            case .never: "不自动展开"
            }
        }
    }

    static let fileCountRange = 1...10_000
    static let `default` = ChangesAutoExpansionSettings()

    var mode: Mode
    private(set) var maximumFileCount: Int

    init(mode: Mode = .byCount, maximumFileCount: Int = 10) {
        self.mode = mode
        self.maximumFileCount = min(
            max(maximumFileCount, Self.fileCountRange.lowerBound),
            Self.fileCountRange.upperBound
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .byCount,
            maximumFileCount: try container.decodeIfPresent(Int.self, forKey: .maximumFileCount) ?? 10
        )
    }
}
