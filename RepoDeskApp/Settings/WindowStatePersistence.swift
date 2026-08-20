import Foundation

struct HistoryCommitFileSelection: Codable, Equatable, Sendable {
    let commitHash: String
    let path: String
}

struct WorkspaceWindowState: Codable, Equatable {
    var selectedSection: AppSection
    var selectedFilePath: String?
    var selectedFileShowsMarkdownPreview: Bool
    var selectedChangesByRepository: [String: GitChangeSelection]
    var selectedChangeRepositoryID: String?
    var historyBranchFiltersByRepository: [String: GitHistoryBranchFilter]
    var historyAuthorFiltersByRepository: [String: String]
    var selectedCommitHashesByRepository: [String: String]
    var selectedCommitFilesByRepository: [String: HistoryCommitFileSelection]
    var mavenSelectionsByRepository: [String: MavenWindowSelection]
    var changesRepositoryScopeID: String?
    var changesGrouping: GitChangesGrouping
    var navigationRepositoryID: String?
    var historyVerticalSplitFraction: Double
    var historyHorizontalSplitFraction: Double

    static let initial = WorkspaceWindowState(
        selectedSection: .overview,
        selectedFilePath: nil,
        selectedFileShowsMarkdownPreview: false,
        selectedChangesByRepository: [:],
        selectedChangeRepositoryID: nil,
        historyBranchFiltersByRepository: [:],
        historyAuthorFiltersByRepository: [:],
        selectedCommitHashesByRepository: [:],
        selectedCommitFilesByRepository: [:],
        mavenSelectionsByRepository: [:],
        changesRepositoryScopeID: nil,
        changesGrouping: .directory,
        navigationRepositoryID: nil,
        historyVerticalSplitFraction: HistorySplitLayout.defaultVerticalFraction,
        historyHorizontalSplitFraction: HistorySplitLayout.defaultHorizontalFraction
    )

    private enum CodingKeys: String, CodingKey {
        case selectedSection
        case selectedFilePath
        case selectedFileShowsMarkdownPreview
        case selectedChangesByRepository
        case selectedChangeRepositoryID
        case historyBranchFiltersByRepository
        case historyAuthorFiltersByRepository
        case selectedCommitHashesByRepository
        case selectedCommitFilesByRepository
        case mavenSelectionsByRepository
        case changesRepositoryScopeID
        case changesGrouping
        case navigationRepositoryID
        case historyVerticalSplitFraction
        case historyHorizontalSplitFraction
    }

    init(
        selectedSection: AppSection,
        selectedFilePath: String?,
        selectedFileShowsMarkdownPreview: Bool = false,
        selectedChangesByRepository: [String: GitChangeSelection],
        selectedChangeRepositoryID: String? = nil,
        historyBranchFiltersByRepository: [String: GitHistoryBranchFilter] = [:],
        historyAuthorFiltersByRepository: [String: String] = [:],
        selectedCommitHashesByRepository: [String: String] = [:],
        selectedCommitFilesByRepository: [String: HistoryCommitFileSelection] = [:],
        mavenSelectionsByRepository: [String: MavenWindowSelection] = [:],
        changesRepositoryScopeID: String? = nil,
        changesGrouping: GitChangesGrouping = .directory,
        navigationRepositoryID: String? = nil,
        historyVerticalSplitFraction: Double = HistorySplitLayout.defaultVerticalFraction,
        historyHorizontalSplitFraction: Double = HistorySplitLayout.defaultHorizontalFraction
    ) {
        self.selectedSection = selectedSection
        self.selectedFilePath = selectedFilePath
        self.selectedFileShowsMarkdownPreview = selectedFileShowsMarkdownPreview
        self.selectedChangesByRepository = selectedChangesByRepository
        self.selectedChangeRepositoryID = selectedChangeRepositoryID
        self.historyBranchFiltersByRepository = historyBranchFiltersByRepository
        self.historyAuthorFiltersByRepository = historyAuthorFiltersByRepository
        self.selectedCommitHashesByRepository = selectedCommitHashesByRepository
        self.selectedCommitFilesByRepository = selectedCommitFilesByRepository
        self.mavenSelectionsByRepository = mavenSelectionsByRepository
        self.changesRepositoryScopeID = changesRepositoryScopeID
        self.changesGrouping = changesGrouping
        self.navigationRepositoryID = navigationRepositoryID
        self.historyVerticalSplitFraction = HistorySplitLayout.normalizedFraction(
            historyVerticalSplitFraction,
            fallback: HistorySplitLayout.defaultVerticalFraction
        )
        self.historyHorizontalSplitFraction = HistorySplitLayout.normalizedFraction(
            historyHorizontalSplitFraction,
            fallback: HistorySplitLayout.defaultHorizontalFraction
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedSection = try container.decodeIfPresent(AppSection.self, forKey: .selectedSection) ?? .overview
        selectedFilePath = try container.decodeIfPresent(String.self, forKey: .selectedFilePath)
        selectedFileShowsMarkdownPreview = try container.decodeIfPresent(
            Bool.self,
            forKey: .selectedFileShowsMarkdownPreview
        ) ?? false
        selectedChangesByRepository = try container.decodeIfPresent(
            [String: GitChangeSelection].self,
            forKey: .selectedChangesByRepository
        ) ?? [:]
        selectedChangeRepositoryID = try container.decodeIfPresent(
            String.self,
            forKey: .selectedChangeRepositoryID
        )
        historyBranchFiltersByRepository = try container.decodeIfPresent(
            [String: GitHistoryBranchFilter].self,
            forKey: .historyBranchFiltersByRepository
        ) ?? [:]
        historyAuthorFiltersByRepository = try container.decodeIfPresent(
            [String: String].self,
            forKey: .historyAuthorFiltersByRepository
        ) ?? [:]
        selectedCommitHashesByRepository = try container.decodeIfPresent(
            [String: String].self,
            forKey: .selectedCommitHashesByRepository
        ) ?? [:]
        selectedCommitFilesByRepository = try container.decodeIfPresent(
            [String: HistoryCommitFileSelection].self,
            forKey: .selectedCommitFilesByRepository
        ) ?? [:]
        mavenSelectionsByRepository = try container.decodeIfPresent(
            [String: MavenWindowSelection].self,
            forKey: .mavenSelectionsByRepository
        ) ?? [:]
        changesRepositoryScopeID = try container.decodeIfPresent(
            String.self,
            forKey: .changesRepositoryScopeID
        )
        changesGrouping = try container.decodeIfPresent(
            GitChangesGrouping.self,
            forKey: .changesGrouping
        ) ?? .directory
        navigationRepositoryID = try container.decodeIfPresent(
            String.self,
            forKey: .navigationRepositoryID
        )
        historyVerticalSplitFraction = HistorySplitLayout.normalizedFraction(
            try container.decodeIfPresent(Double.self, forKey: .historyVerticalSplitFraction)
                ?? HistorySplitLayout.defaultVerticalFraction,
            fallback: HistorySplitLayout.defaultVerticalFraction
        )
        historyHorizontalSplitFraction = HistorySplitLayout.normalizedFraction(
            try container.decodeIfPresent(Double.self, forKey: .historyHorizontalSplitFraction)
                ?? HistorySplitLayout.defaultHorizontalFraction,
            fallback: HistorySplitLayout.defaultHorizontalFraction
        )
    }
}

@MainActor
protocol WindowStateStoring: AnyObject {
    func state(for workspaceURL: URL) -> WorkspaceWindowState
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL)
}

@MainActor
final class UserDefaultsWindowStateStore: WindowStateStoring {
    private let defaults: UserDefaults
    private let key = "window.states.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(for workspaceURL: URL) -> WorkspaceWindowState {
        allStates()[workspaceURL.standardizedFileURL.path] ?? .initial
    }

    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {
        var states = allStates()
        states[workspaceURL.standardizedFileURL.path] = state
        if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: key)
        }
    }

    private func allStates() -> [String: WorkspaceWindowState] {
        guard let data = defaults.data(forKey: key),
              let states = try? JSONDecoder().decode([String: WorkspaceWindowState].self, from: data) else {
            return [:]
        }
        return states
    }
}
