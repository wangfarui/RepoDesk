import Foundation
@testable import RepoDesk

private struct SettingsVerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifySettings {
    static func main() throws {
        let suiteName = "RepoDeskSettingsVerification.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SettingsVerificationError(message: "Could not create isolated UserDefaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(GitDiffPresentation.sideBySide.rawValue, forKey: "git.diff.presentation")
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)
        let legacyPreferences = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data("{\"showsHiddenFiles\":true}".utf8)
        )
        try require(
            legacyPreferences.changesAutoExpansion == .default,
            "Older preferences did not retain the default Changes threshold"
        )
        try require(
            store.preferences().diffPresentation == .sideBySide,
            "Legacy Diff presentation did not migrate"
        )

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
        state.setJavaIndexSettings(
            JavaIndexSettings(
                maximumJVMCount: 2,
                processorCountPerJVM: 3,
                maximumHeapMegabytes: 3_072,
                cacheLimitGigabytes: 20
            )
        )

        let restored = AppState(
            appPreferencesStore: store,
            restoresWorkspaceOnLaunch: false
        )
        try require(!restored.automaticallyRefreshesWorkspace, "Automatic refresh was not restored")
        try require(!restored.refreshesWhenBecomingActive, "Foreground refresh was not restored")
        try require(restored.showsHiddenFiles, "Hidden-file preference was not restored")
        try require(!restored.compactsSingleChildDirectories, "Compact-folder preference was not restored")
        try require(restored.opensMarkdownInPreview, "Markdown preference was not restored")
        try require(restored.diffPresentation == .sideBySide, "Diff presentation was not restored")
        try require(restored.ignoresWhitespaceInDiff, "Whitespace preference was not restored")
        try require(
            restored.changesAutoExpansion == ChangesAutoExpansionSettings(mode: .always, maximumFileCount: 42),
            "Changes expansion settings were not restored"
        )
        for mode in ChangesAutoExpansionSettings.Mode.allCases {
            restored.setChangesAutoExpansionMode(mode)
            try require(
                store.preferences().changesAutoExpansion.mode == mode,
                "Changes expansion mode was not persisted"
            )
            try require(
                store.preferences().changesAutoExpansion.maximumFileCount == 42,
                "Switching modes discarded the custom threshold"
            )
        }
        restored.setChangesAutoExpansionMaximumFileCount(0)
        try require(
            store.preferences().changesAutoExpansion.maximumFileCount == 1,
            "Changes threshold allowed a value below its range"
        )
        restored.setChangesAutoExpansionMaximumFileCount(Int.max)
        try require(
            store.preferences().changesAutoExpansion.maximumFileCount == 10_000,
            "Changes threshold allowed a value above its range"
        )
        let invalidThreshold = try JSONDecoder().decode(
            ChangesAutoExpansionSettings.self,
            from: Data("{\"mode\":\"byCount\",\"maximumFileCount\":-1}".utf8)
        )
        try require(invalidThreshold.maximumFileCount == 1, "Decoded threshold was not normalized")
        restored.resetChangesAutoExpansion()
        try require(
            store.preferences().changesAutoExpansion == .default,
            "Changes expansion defaults were not restored"
        )
        try require(restored.sidebarFontSize == 10, "Sidebar font size was not restored")
        try require(restored.interfaceFontSize == 15, "Interface font size was not restored")
        try require(restored.fileContentFontSize == 16, "File content font size was not restored")
        try require(restored.javaIndexSettings.maximumJVMCount == 2, "Java JVM limit was not restored")
        try require(restored.javaIndexSettings.processorCountPerJVM == 3, "Java CPU limit was not restored")
        try require(restored.javaIndexSettings.maximumHeapMegabytes == 3_072, "Java heap was not restored")
        try require(restored.javaIndexSettings.cacheLimitGigabytes == 20, "Java cache limit was not restored")
        try require(
            !RootView(appState: restored).workspaceMonitorTaskID.isEnabled,
            "Disabled automatic refresh did not stop the monitor task"
        )

        restored.resetFontSizes()
        try require(restored.sidebarFontSize == 13, "Sidebar font size was not reset")
        try require(restored.interfaceFontSize == 13, "Interface font size was not reset")
        try require(restored.fileContentFontSize == 13, "File content font size was not reset")

        print("Settings persistence verification passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SettingsVerificationError(message: message) }
    }
}
