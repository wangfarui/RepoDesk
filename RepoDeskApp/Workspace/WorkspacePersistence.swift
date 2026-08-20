import Foundation

struct RecentWorkspace: Codable, Equatable, Identifiable {
    let path: String
    let bookmark: Data?
    let lastOpenedAt: Date

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor
protocol WorkspaceStoring: AnyObject {
    func restoreLastWorkspace() -> URL?
    func recentWorkspaces() -> [RecentWorkspace]
    func rememberWorkspace(_ url: URL)
    func resolve(_ workspace: RecentWorkspace) -> URL
}

@MainActor
final class UserDefaultsWorkspaceStore: WorkspaceStoring {
    private enum Keys {
        static let recentWorkspaces = "workspace.recent.v1"
    }

    private let defaults: UserDefaults
    private let maximumRecentWorkspaceCount: Int

    init(defaults: UserDefaults = .standard, maximumRecentWorkspaceCount: Int = 8) {
        self.defaults = defaults
        self.maximumRecentWorkspaceCount = maximumRecentWorkspaceCount
    }

    func restoreLastWorkspace() -> URL? {
        guard let workspace = recentWorkspaces().first else { return nil }
        return resolve(workspace)
    }

    func recentWorkspaces() -> [RecentWorkspace] {
        guard
            let data = defaults.data(forKey: Keys.recentWorkspaces),
            let workspaces = try? JSONDecoder().decode([RecentWorkspace].self, from: data)
        else {
            return []
        }

        return workspaces
    }

    func rememberWorkspace(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        let bookmark = try? normalizedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let workspace = RecentWorkspace(
            path: normalizedURL.path,
            bookmark: bookmark,
            lastOpenedAt: .now
        )
        var workspaces = recentWorkspaces().filter { $0.path != workspace.path }
        workspaces.insert(workspace, at: 0)
        workspaces = Array(workspaces.prefix(maximumRecentWorkspaceCount))

        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(data, forKey: Keys.recentWorkspaces)
    }

    func resolve(_ workspace: RecentWorkspace) -> URL {
        guard let bookmark = workspace.bookmark else {
            return URL(fileURLWithPath: workspace.path, isDirectory: true)
        }

        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return URL(fileURLWithPath: workspace.path, isDirectory: true)
        }

        if isStale {
            rememberWorkspace(resolvedURL)
        }
        return resolvedURL
    }
}
