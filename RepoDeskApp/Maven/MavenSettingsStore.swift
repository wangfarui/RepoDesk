import Foundation

@MainActor
protocol MavenSettingsStoring: AnyObject {
    func settings(for workspaceURL: URL) -> MavenSettings
    func save(_ settings: MavenSettings, for workspaceURL: URL) throws
}

enum MavenSettingsPersistenceError: LocalizedError {
    case verificationFailed

    var errorDescription: String? {
        "Maven 配置保存失败，请检查应用偏好设置的写入权限。"
    }
}

@MainActor
final class UserDefaultsMavenSettingsStore: MavenSettingsStoring {
    private enum Keys {
        static let settingsByWorkspace = "maven.settingsByWorkspace.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func settings(for workspaceURL: URL) -> MavenSettings {
        allSettings()[workspaceKey(for: workspaceURL)] ?? .empty
    }

    func save(_ settings: MavenSettings, for workspaceURL: URL) throws {
        var settingsByWorkspace = allSettings()
        settingsByWorkspace[workspaceKey(for: workspaceURL)] = settings
        let data = try JSONEncoder().encode(settingsByWorkspace)
        defaults.set(data, forKey: Keys.settingsByWorkspace)
        guard defaults.data(forKey: Keys.settingsByWorkspace) == data else {
            throw MavenSettingsPersistenceError.verificationFailed
        }
    }

    private func allSettings() -> [String: MavenSettings] {
        guard let data = defaults.data(forKey: Keys.settingsByWorkspace),
              let settings = try? JSONDecoder().decode([String: MavenSettings].self, from: data) else {
            return [:]
        }
        return settings
    }

    private func workspaceKey(for workspaceURL: URL) -> String {
        workspaceURL.standardizedFileURL.path
    }
}
