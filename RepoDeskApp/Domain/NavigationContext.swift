import Foundation

enum NavigationContext: Equatable, Sendable {
    case workspace
    case repository(RegisteredRepository.ID)
}
