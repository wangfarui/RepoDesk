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
            ignoresWhitespaceInDiff: true,
            changesAutoExpansion: ChangesAutoExpansionSettings(mode: .always, maximumFileCount: 42),
            sidebarFontSize: 10,
            interfaceFontSize: 15,
            fileContentFontSize: 16,
            javaIndexSettings: JavaIndexSettings(
                maximumJVMCount: 2,
                processorCountPerJVM: 3,
                maximumHeapMegabytes: 3_072,
                cacheLimitGigabytes: 20
            ),
            shortcuts: [
                .save: ShortcutBinding(key: "k", modifiers: [.command, .shift]),
                .closeFileTab: ShortcutBinding(key: "q", modifiers: [.command])
            ]
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
        #expect(preferences.changesAutoExpansion == .default)
        #expect(preferences.sidebarFontSize == RepoDeskFontSize.default)
        #expect(preferences.interfaceFontSize == RepoDeskFontSize.default)
        #expect(preferences.fileContentFontSize == RepoDeskFontSize.default)
        #expect(preferences.maximumOpenFileTabs == 5)
        #expect(preferences.javaIndexSettings == .default)
        #expect(preferences.shortcuts == ShortcutBinding.defaults())
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
        state.setChangesAutoExpansionMaximumFileCount(42)
        state.setChangesAutoExpansionMode(.always)
        state.setSidebarFontSize(10)
        state.setInterfaceFontSize(15)
        state.setFileContentFontSize(16)
        state.setMaximumOpenFileTabs(8)
        state.setJavaIndexSettings(
            JavaIndexSettings(
                maximumJVMCount: 2,
                processorCountPerJVM: 3,
                maximumHeapMegabytes: 3_072,
                cacheLimitGigabytes: 20
            )
        )
        state.setShortcut(
            ShortcutBinding(key: "k", modifiers: [.command, .shift]),
            for: .save
        )

        let restored = AppState(
            appPreferencesStore: store,
            restoresWorkspaceOnLaunch: false
        )
        #expect(!restored.automaticallyRefreshesWorkspace)
        #expect(!restored.refreshesWhenBecomingActive)
        #expect(restored.showsHiddenFiles)
        #expect(restored.shortcut(for: .save) == ShortcutBinding(key: "k", modifiers: [.command, .shift]))
        #expect(!restored.compactsSingleChildDirectories)
        #expect(restored.opensMarkdownInPreview)
        #expect(restored.diffPresentation == .sideBySide)
        #expect(restored.ignoresWhitespaceInDiff)
        #expect(restored.changesAutoExpansion == ChangesAutoExpansionSettings(mode: .always, maximumFileCount: 42))
        #expect(restored.sidebarFontSize == 10)
        #expect(restored.interfaceFontSize == 15)
        #expect(restored.fileContentFontSize == 16)
        #expect(restored.maximumOpenFileTabs == 8)
        #expect(restored.javaIndexSettings.maximumJVMCount == 2)
        #expect(restored.javaIndexSettings.processorCountPerJVM == 3)
        #expect(restored.javaIndexSettings.maximumHeapMegabytes == 3_072)
        #expect(restored.javaIndexSettings.cacheLimitGigabytes == 20)
    }

    @Test func fontSizesAreRoundedAndClampedBeforePersistence() {
        let state = AppState(restoresWorkspaceOnLaunch: false)

        state.setSidebarFontSize(9)
        state.setInterfaceFontSize(14.6)
        state.setFileContentFontSize(30)

        #expect(state.sidebarFontSize == RepoDeskFontSize.minimum)
        #expect(state.interfaceFontSize == 15)
        #expect(state.fileContentFontSize == RepoDeskFontSize.maximum)

        state.resetFontSizes()

        #expect(state.sidebarFontSize == RepoDeskFontSize.default)
        #expect(state.interfaceFontSize == RepoDeskFontSize.default)
        #expect(state.fileContentFontSize == RepoDeskFontSize.default)
    }

    @Test func workspaceMonitorTaskIdentityChangesWithAutomaticRefresh() {
        let state = AppState(restoresWorkspaceOnLaunch: false)
        let view = RootView(appState: state)

        #expect(view.workspaceMonitorTaskID.isEnabled)

        state.setAutomaticallyRefreshesWorkspace(false)

        #expect(!view.workspaceMonitorTaskID.isEnabled)
    }
}
