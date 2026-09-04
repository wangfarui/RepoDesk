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
        state.setSidebarFontSize(10)
        state.setInterfaceFontSize(15)
        state.setFileContentFontSize(16)

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
        try require(restored.sidebarFontSize == 10, "Sidebar font size was not restored")
        try require(restored.interfaceFontSize == 15, "Interface font size was not restored")
        try require(restored.fileContentFontSize == 16, "File content font size was not restored")
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
