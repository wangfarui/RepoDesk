import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct AppPreferencesTests {
    @Test func preferencesRoundTripThroughUserDefaults() throws {
        let suiteName = "RepoDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)
        let preferences = AppPreferences(
            automaticallyRefreshesWorkspace: false,
            refreshesWhenBecomingActive: false,
            showsHiddenFiles: true,
            compactsSingleChildDirectories: false,
            opensMarkdownInPreview: true,
            diffPresentation: .sideBySide,
            ignoresWhitespaceInDiff: true
        )

        store.save(preferences)

        #expect(store.preferences() == preferences)
    }

    @Test func legacyDiffPresentationMigratesWhenPreferencesAreMissing() throws {
        let suiteName = "RepoDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(GitDiffPresentation.sideBySide.rawValue, forKey: "git.diff.presentation")
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)

        let preferences = store.preferences()

        #expect(preferences.diffPresentation == .sideBySide)
        #expect(preferences.automaticallyRefreshesWorkspace)
        #expect(preferences.compactsSingleChildDirectories)
    }

    @Test func legacyPreferencesDecodeWithNewDefaults() throws {
        let data = Data(
            """
            {
              "showsHiddenFiles": true
            }
            """.utf8
        )

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)

        #expect(preferences.showsHiddenFiles)
        #expect(preferences.automaticallyRefreshesWorkspace)
        #expect(preferences.refreshesWhenBecomingActive)
        #expect(preferences.compactsSingleChildDirectories)
        #expect(!preferences.opensMarkdownInPreview)
        #expect(preferences.diffPresentation == .unified)
        #expect(!preferences.ignoresWhitespaceInDiff)
    }

    @Test func appStateLoadsAndPersistsCentralSettings() throws {
        let suiteName = "RepoDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)
        let state = AppState(
            appPreferencesStore: store,
            restoresWorkspaceOnLaunch: false
        )

        state.setAutomaticallyRefreshesWorkspace(false)
        state.setRefreshesWhenBecomingActive(false)
        state.setShowsHiddenFiles(true)
        state.setCompactsSingleChildDirectories(false)
        state.setOpensMarkdownInPreview(true)
        state.setDiffPresentation(.sideBySide)
        state.setIgnoresWhitespaceInDiff(true)

        let restored = AppState(
            appPreferencesStore: store,
            restoresWorkspaceOnLaunch: false
        )
        #expect(!restored.automaticallyRefreshesWorkspace)
        #expect(!restored.refreshesWhenBecomingActive)
        #expect(restored.showsHiddenFiles)
        #expect(!restored.compactsSingleChildDirectories)
        #expect(restored.opensMarkdownInPreview)
        #expect(restored.diffPresentation == .sideBySide)
        #expect(restored.ignoresWhitespaceInDiff)
    }

    @Test func workspaceMonitorTaskIdentityChangesWithAutomaticRefresh() {
        let state = AppState(restoresWorkspaceOnLaunch: false)
        let view = RootView(appState: state)

        #expect(view.workspaceMonitorTaskID.isEnabled)

        state.setAutomaticallyRefreshesWorkspace(false)

        #expect(!view.workspaceMonitorTaskID.isEnabled)
    }
}
