import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct RepositoryPersistenceTests {
    @Test func registrationsAreScopedToWorkspaceAndRestoreSelection() throws {
        let suiteName = "RepoDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRepositoryStore(defaults: defaults)
        let firstWorkspace = URL(fileURLWithPath: "/tmp/first-workspace", isDirectory: true)
        let secondWorkspace = URL(fileURLWithPath: "/tmp/second-workspace", isDirectory: true)
        let repository = RegisteredRepository(
            displayName: "service",
            relativePath: "services/service",
            isPinned: true
        )
        let state = RepositoryWorkspaceState(
            repositories: [repository],
            selectedRepositoryID: repository.id,
            discoverySettings: RepositoryDiscoverySettings(
                ignoredDirectoryPaths: ["generated", "third_party/legacy"]
            )
        )

        store.save(state, for: firstWorkspace)

        #expect(store.state(for: firstWorkspace) == state)
        #expect(store.state(for: secondWorkspace) == .empty)
    }

    @Test func readsLegacyRegistrationsWithDefaultDiscoverySettings() throws {
        let suiteName = "RepoDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceURL = URL(fileURLWithPath: "/tmp/legacy-workspace", isDirectory: true)
        let repository = RegisteredRepository(
            displayName: "repo",
            relativePath: "repo",
            isPinned: false
        )
        let legacyStates = [
            workspaceURL.standardizedFileURL.path: LegacyRepositoryWorkspaceState(
                repositories: [repository],
                selectedRepositoryID: repository.id
            )
        ]
        defaults.set(
            try JSONEncoder().encode(legacyStates),
            forKey: "repository.registrations.v1"
        )
        let store = UserDefaultsRepositoryStore(defaults: defaults)

        let restored = store.state(for: workspaceURL)

        #expect(restored.repositories == [repository])
        #expect(restored.selectedRepositoryID == repository.id)
        #expect(restored.discoverySettings == .default)
    }
}

private struct LegacyRepositoryWorkspaceState: Codable {
    let repositories: [RegisteredRepository]
    let selectedRepositoryID: RegisteredRepository.ID?
}
