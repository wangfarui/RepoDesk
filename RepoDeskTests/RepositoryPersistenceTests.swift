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
            selectedRepositoryID: repository.id
        )

        store.save(state, for: firstWorkspace)

        #expect(store.state(for: firstWorkspace) == state)
        #expect(store.state(for: secondWorkspace) == .empty)
    }
}
