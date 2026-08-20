import Foundation

enum AppSection: String, CaseIterable, Identifiable, Codable {
    case overview = "Overview"
    case changes = "Changes"
    case files = "Files"
    case history = "History"
    case tasks = "Tasks"

    var id: Self { self }

    var displayName: String {
        self == .tasks ? "Maven" : rawValue
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .changes: "arrow.triangle.2.circlepath"
        case .files: "folder"
        case .history: "clock.arrow.circlepath"
        case .tasks: "shippingbox"
        }
    }

    static let workspaceSections: [AppSection] = [.overview, .changes, .files, .tasks]
    static let repositorySections: [AppSection] = [.changes, .files, .history, .tasks]
}
