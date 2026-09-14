import Foundation

struct RepositoryWorkspaceState: Codable, Equatable {
    var repositories: [RegisteredRepository]
    var selectedRepositoryID: RegisteredRepository.ID?
    var discoverySettings: RepositoryDiscoverySettings = .default

    static let empty = RepositoryWorkspaceState(
        repositories: [],
        selectedRepositoryID: nil,
        discoverySettings: .default
    )
}

extension RepositoryWorkspaceState {
    private enum CodingKeys: String, CodingKey {
        case repositories
        case selectedRepositoryID
        case discoverySettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try container.decode([RegisteredRepository].self, forKey: .repositories)
        selectedRepositoryID = try container.decodeIfPresent(
            RegisteredRepository.ID.self,
            forKey: .selectedRepositoryID
        )
        discoverySettings = try container.decodeIfPresent(
            RepositoryDiscoverySettings.self,
            forKey: .discoverySettings
        ) ?? .default
    }
}

@MainActor
protocol RepositoryStoring: AnyObject {
    func state(for workspaceURL: URL) -> RepositoryWorkspaceState
    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL)
}

@MainActor
final class UserDefaultsRepositoryStore: RepositoryStoring {
    private enum Keys {
        static let workspaceState = "repository.workspace-state.v2"
        static let legacyRegistrations = "repository.registrations.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(for workspaceURL: URL) -> RepositoryWorkspaceState {
        allWorkspaceStates()[workspaceURL.standardizedFileURL.path] ?? .empty
    }

    func save(_ state: RepositoryWorkspaceState, for workspaceURL: URL) {
        var states = allWorkspaceStates()
        states[workspaceURL.standardizedFileURL.path] = state
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: Keys.workspaceState)
    }

    private func allWorkspaceStates() -> [String: RepositoryWorkspaceState] {
        var states = decodedStates(forKey: Keys.legacyRegistrations)
        states.merge(decodedStates(forKey: Keys.workspaceState)) { _, current in current }
        return states
    }

    private func decodedStates(forKey key: String) -> [String: RepositoryWorkspaceState] {
        guard
            let data = defaults.data(forKey: key),
            let states = try? JSONDecoder().decode(
                [String: RepositoryWorkspaceState].self,
                from: data
            )
        else {
            return [:]
        }
        return states
    }
}
