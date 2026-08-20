import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct WorkspacePersistenceTests {
    @Test func mostRecentlyOpenedWorkspaceIsRestored() throws {
        let suiteName = "RepoDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsWorkspaceStore(defaults: defaults)
        let first = URL(fileURLWithPath: "/tmp/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/second", isDirectory: true)

        store.rememberWorkspace(first)
        store.rememberWorkspace(second)

        #expect(store.recentWorkspaces().map(\.path) == [second.path, first.path])
        #expect(store.restoreLastWorkspace()?.path == second.path)
    }

    @Test func reopeningWorkspaceDoesNotCreateDuplicate() throws {
        let suiteName = "RepoDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsWorkspaceStore(defaults: defaults)
        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)

        store.rememberWorkspace(workspace)
        store.rememberWorkspace(workspace)

        #expect(store.recentWorkspaces().count == 1)
    }
}
