import Foundation

struct AppPreferences: Codable, Equatable, Sendable {
    var automaticallyRefreshesWorkspace: Bool
    var refreshesWhenBecomingActive: Bool
    var showsHiddenFiles: Bool
    var compactsSingleChildDirectories: Bool
    var opensMarkdownInPreview: Bool
    var diffPresentation: GitDiffPresentation
    var ignoresWhitespaceInDiff: Bool

    init(
        automaticallyRefreshesWorkspace: Bool = true,
        refreshesWhenBecomingActive: Bool = true,
        showsHiddenFiles: Bool = false,
        compactsSingleChildDirectories: Bool = true,
        opensMarkdownInPreview: Bool = false,
        diffPresentation: GitDiffPresentation = .unified,
        ignoresWhitespaceInDiff: Bool = false
    ) {
        self.automaticallyRefreshesWorkspace = automaticallyRefreshesWorkspace
        self.refreshesWhenBecomingActive = refreshesWhenBecomingActive
        self.showsHiddenFiles = showsHiddenFiles
        self.compactsSingleChildDirectories = compactsSingleChildDirectories
        self.opensMarkdownInPreview = opensMarkdownInPreview
        self.diffPresentation = diffPresentation
        self.ignoresWhitespaceInDiff = ignoresWhitespaceInDiff
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automaticallyRefreshesWorkspace = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyRefreshesWorkspace
        ) ?? true
        refreshesWhenBecomingActive = try container.decodeIfPresent(
            Bool.self,
            forKey: .refreshesWhenBecomingActive
        ) ?? true
        showsHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? false
        compactsSingleChildDirectories = try container.decodeIfPresent(
            Bool.self,
            forKey: .compactsSingleChildDirectories
        ) ?? true
        opensMarkdownInPreview = try container.decodeIfPresent(
            Bool.self,
            forKey: .opensMarkdownInPreview
        ) ?? false
        diffPresentation = try container.decodeIfPresent(
            GitDiffPresentation.self,
            forKey: .diffPresentation
        ) ?? .unified
        ignoresWhitespaceInDiff = try container.decodeIfPresent(
            Bool.self,
            forKey: .ignoresWhitespaceInDiff
        ) ?? false
    }

    static let `default` = AppPreferences()
}

@MainActor
protocol AppPreferencesStoring: AnyObject {
    func preferences() -> AppPreferences
    func save(_ preferences: AppPreferences)
}

@MainActor
final class UserDefaultsAppPreferencesStore: AppPreferencesStoring {
    private let defaults: UserDefaults
    private let key = "app.preferences.v1"
    private let legacyDiffPresentationKey = "git.diff.presentation"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func preferences() -> AppPreferences {
        if let data = defaults.data(forKey: key),
           let preferences = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            return preferences
        }

        var preferences = AppPreferences.default
        if let rawValue = defaults.string(forKey: legacyDiffPresentationKey),
           let presentation = GitDiffPresentation(rawValue: rawValue) {
            preferences.diffPresentation = presentation
        }
        return preferences
    }

    func save(_ preferences: AppPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
        defaults.removeObject(forKey: legacyDiffPresentationKey)
    }
}
