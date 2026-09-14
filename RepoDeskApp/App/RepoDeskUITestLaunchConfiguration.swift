import Foundation

@MainActor
enum RepoDeskUITestLaunchConfiguration {
    static func makeAppState(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppState? {
        guard let workspacePath = value(after: "--repodesk-ui-test-workspace", in: arguments),
              let repositoryPath = value(after: "--repodesk-ui-test-repository", in: arguments),
              let filePath = value(after: "--repodesk-ui-test-file", in: arguments),
              !repositoryPath.isEmpty,
              repositoryPath != ".",
              !repositoryPath.hasPrefix("/"),
              !repositoryPath.split(separator: "/").contains(".."),
              !filePath.hasPrefix("/"),
              !filePath.split(separator: "/").contains("..") else {
            return nil
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
        let repositoryURL = workspaceURL
            .appendingPathComponent(repositoryPath, isDirectory: true)
            .standardizedFileURL
        let fileURL = repositoryURL
            .appendingPathComponent(filePath, isDirectory: false)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: workspaceURL.path),
              FileManager.default.fileExists(atPath: repositoryURL.path),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let repository = RegisteredRepository(
            displayName: repositoryURL.lastPathComponent,
            relativePath: repositoryPath,
            isPinned: true
        )
        let defaults = UserDefaults(
            suiteName: "com.wangfarui.RepoDesk.UITests.\(ProcessInfo.processInfo.processIdentifier)"
        ) ?? .standard
        let appState = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            selectedSection: .files,
            workspaceStore: UserDefaultsWorkspaceStore(defaults: defaults),
            repositoryStore: UserDefaultsRepositoryStore(defaults: defaults),
            taskStore: UserDefaultsRepoTaskStore(defaults: defaults),
            mavenSettingsStore: UserDefaultsMavenSettingsStore(defaults: defaults),
            mavenRunHistoryStore: UserDefaultsMavenRunHistoryStore(defaults: defaults),
            windowStateStore: UserDefaultsWindowStateStore(defaults: defaults),
            appPreferencesStore: UserDefaultsAppPreferencesStore(defaults: defaults),
            restoresWorkspaceOnLaunch: false
        )
        appState.navigationContext = .repository(repository.id)
        appState.selectFile(fileURL)
        return appState
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let optionIndex = arguments.firstIndex(of: option) else { return nil }
        let valueIndex = arguments.index(after: optionIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}
