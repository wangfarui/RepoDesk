import Foundation

struct RepositoryWorkspaceState: Codable, Equatable {
    var repositories: [RegisteredRepository]
    var selectedRepositoryID: RegisteredRepository.ID?

    static let empty = RepositoryWorkspaceState(
        repositories: [],
        selectedRepositoryID: nil
    )
}

@MainActor
protocol RepositoryStoring: AnyObject {
    func state(for workspaceURL: URL) -> RepositoryWorkspaceState
    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL)
}

@MainActor
final class UserDefaultsRepositoryStore: RepositoryStoring {
    private enum Keys {
        static let repositoriesByWorkspace = "repository.registrations.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(for workspaceURL: URL) -> RepositoryWorkspaceState {
        allRegistrations()[workspaceURL.standardizedFileURL.path] ?? .empty
    }

    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {
        var registrations = allRegistrations()
        registrations[workspaceURL.standardizedFileURL.path] = state
        guard let data = try? JSONEncoder().encode(registrations) else { return }
        defaults.set(data, forKey: Keys.repositoriesByWorkspace)
    }

    private func allRegistrations() -> [String: RepositoryWorkspaceState] {
        guard
            let data = defaults.data(forKey: Keys.repositoriesByWorkspace),
            let registrations = try? JSONDecoder().decode(
                [String: RepositoryWorkspaceState].self,
                from: data
            )
        else {
            return [:]
        }
        return registrations
    }
}
