import Foundation

struct AppPreferences: Codable, Equatable, Sendable {
    var automaticallyRefreshesWorkspace: Bool
    var refreshesWhenBecomingActive: Bool
    var showsHiddenFiles: Bool
    var compactsSingleChildDirectories: Bool
    var opensMarkdownInPreview: Bool
    var diffPresentation: GitDiffPresentation
    var ignoresWhitespaceInDiff: Bool
    var sidebarFontSize: Double
    var interfaceFontSize: Double
    var fileContentFontSize: Double
    var maximumOpenFileTabs: Int
    var javaIndexSettings: JavaIndexSettings
    var shortcuts: [AppShortcutID: ShortcutBinding]

    init(
        automaticallyRefreshesWorkspace: Bool = true,
        refreshesWhenBecomingActive: Bool = true,
        showsHiddenFiles: Bool = false,
        compactsSingleChildDirectories: Bool = true,
        opensMarkdownInPreview: Bool = false,
        diffPresentation: GitDiffPresentation = .unified,
        ignoresWhitespaceInDiff: Bool = false,
        sidebarFontSize: Double = RepoDeskFontSize.default,
        interfaceFontSize: Double = RepoDeskFontSize.default,
        fileContentFontSize: Double = RepoDeskFontSize.default,
        maximumOpenFileTabs: Int = 5,
        javaIndexSettings: JavaIndexSettings = .default,
        shortcuts: [AppShortcutID: ShortcutBinding] = ShortcutBinding.defaults()
    ) {
        self.automaticallyRefreshesWorkspace = automaticallyRefreshesWorkspace
        self.refreshesWhenBecomingActive = refreshesWhenBecomingActive
        self.showsHiddenFiles = showsHiddenFiles
        self.compactsSingleChildDirectories = compactsSingleChildDirectories
        self.opensMarkdownInPreview = opensMarkdownInPreview
        self.diffPresentation = diffPresentation
        self.ignoresWhitespaceInDiff = ignoresWhitespaceInDiff
        self.sidebarFontSize = RepoDeskFontSize.normalized(sidebarFontSize)
        self.interfaceFontSize = RepoDeskFontSize.normalized(interfaceFontSize)
        self.fileContentFontSize = RepoDeskFontSize.normalized(fileContentFontSize)
        self.maximumOpenFileTabs = min(max(maximumOpenFileTabs, 1), 50)
        self.javaIndexSettings = javaIndexSettings
        self.shortcuts = AppPreferences.normalizedShortcuts(shortcuts)
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
        sidebarFontSize = RepoDeskFontSize.normalized(
            try container.decodeIfPresent(Double.self, forKey: .sidebarFontSize)
                ?? RepoDeskFontSize.default
        )
        interfaceFontSize = RepoDeskFontSize.normalized(
            try container.decodeIfPresent(Double.self, forKey: .interfaceFontSize)
                ?? RepoDeskFontSize.default
        )
        fileContentFontSize = RepoDeskFontSize.normalized(
            try container.decodeIfPresent(Double.self, forKey: .fileContentFontSize)
                ?? RepoDeskFontSize.default
        )
        maximumOpenFileTabs = min(
            max(try container.decodeIfPresent(Int.self, forKey: .maximumOpenFileTabs) ?? 5, 1),
            50
        )
        javaIndexSettings = try container.decodeIfPresent(
            JavaIndexSettings.self,
            forKey: .javaIndexSettings
        ) ?? .default
        shortcuts = AppPreferences.normalizedShortcuts(
            try container.decodeIfPresent(
                [AppShortcutID: ShortcutBinding].self,
                forKey: .shortcuts
            ) ?? [:]
        )
    }

    private static func normalizedShortcuts(
        _ shortcuts: [AppShortcutID: ShortcutBinding]
    ) -> [AppShortcutID: ShortcutBinding] {
        var result = ShortcutBinding.defaults()
        for (id, binding) in shortcuts {
            result[id] = binding
        }
        return result
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
