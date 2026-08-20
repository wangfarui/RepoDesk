import Foundation
import Testing
@testable import RepoDesk

@MainActor
struct WindowStatePersistenceTests {
    @Test func stateIsRestoredPerWorkspace() throws {
        let suiteName = "RepoDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsWindowStateStore(defaults: defaults)
        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let runID = UUID()
        let state = WorkspaceWindowState(
            selectedSection: .changes,
            selectedFilePath: "/tmp/workspace/README.md",
            selectedFileShowsMarkdownPreview: true,
            selectedChangesByRepository: [
                "repo": GitChangeSelection(path: "file.swift", kind: .changes)
            ],
            selectedChangeRepositoryID: "repo",
            historyBranchFiltersByRepository: ["repo": .branch("release")],
            historyAuthorFiltersByRepository: ["repo": "RepoDesk"],
            selectedCommitHashesByRepository: ["repo": "abc123"],
            selectedCommitFilesByRepository: [
                "repo": HistoryCommitFileSelection(commitHash: "abc123", path: "Sources/App.swift")
            ],
            mavenSelectionsByRepository: ["repo": .recentRun(runID)],
            changesRepositoryScopeID: "repo",
            changesGrouping: [.directory, .module],
            navigationRepositoryID: "repo",
            historyVerticalSplitFraction: 0.64,
            historyHorizontalSplitFraction: 0.43
        )

        store.save(state, for: workspace)

        #expect(store.state(for: workspace) == state)
        #expect(store.state(for: URL(fileURLWithPath: "/tmp/other")) == .initial)
    }

    @Test func groupingOptionsRoundTripIncludingFlatView() throws {
        let groupings: [GitChangesGrouping] = [
            [],
            .directory,
            .module,
            [.directory, .module]
        ]
        for grouping in groupings {
            let state = WorkspaceWindowState(
                selectedSection: .changes,
                selectedFilePath: nil,
                selectedChangesByRepository: [:],
                changesGrouping: grouping
            )

            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(WorkspaceWindowState.self, from: data)

            #expect(decoded.changesGrouping == grouping)
        }
    }

    @Test func legacyStateDecodesWithHistoryDefaults() throws {
        let data = Data(
            """
            {
              "selectedSection": "Changes",
              "selectedFilePath": null,
              "selectedChangesByRepository": {},
              "reviewedChangeFingerprints": {}
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(WorkspaceWindowState.self, from: data)

        #expect(state.selectedSection == .changes)
        #expect(state.historyBranchFiltersByRepository.isEmpty)
        #expect(state.historyAuthorFiltersByRepository.isEmpty)
        #expect(state.selectedCommitHashesByRepository.isEmpty)
        #expect(state.selectedCommitFilesByRepository.isEmpty)
        #expect(state.mavenSelectionsByRepository.isEmpty)
        #expect(state.selectedChangeRepositoryID == nil)
        #expect(!state.selectedFileShowsMarkdownPreview)
        #expect(state.changesRepositoryScopeID == nil)
        #expect(state.changesGrouping == .directory)
        #expect(state.navigationRepositoryID == nil)
        #expect(state.historyVerticalSplitFraction == HistorySplitLayout.defaultVerticalFraction)
        #expect(state.historyHorizontalSplitFraction == HistorySplitLayout.defaultHorizontalFraction)
    }

    @Test func legacySingleGroupingValueStillDecodes() throws {
        let data = Data(
            """
            {
              "selectedSection": "Changes",
              "selectedChangesByRepository": {},
              "changesGrouping": "module"
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(WorkspaceWindowState.self, from: data)

        #expect(state.changesGrouping == .module)
    }

    @Test func legacyGitChangeKindsMigrateToCommitStyleGroups() throws {
        let data = Data(
            """
            {
              "selectedSection": "Changes",
              "selectedChangesByRepository": {
                "staged": {"path": "A.swift", "kind": "Staged"},
                "unstaged": {"path": "B.swift", "kind": "Unstaged"},
                "conflicted": {"path": "C.swift", "kind": "Conflicted"},
                "untracked": {"path": "D.swift", "kind": "Untracked"}
              }
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(WorkspaceWindowState.self, from: data)

        #expect(state.selectedChangesByRepository["staged"]?.kind == .changes)
        #expect(state.selectedChangesByRepository["unstaged"]?.kind == .changes)
        #expect(state.selectedChangesByRepository["conflicted"]?.kind == .changes)
        #expect(state.selectedChangesByRepository["untracked"]?.kind == .unversioned)
    }

    @Test func historySplitFractionsAreKeptWithinUsableBounds() {
        let state = WorkspaceWindowState(
            selectedSection: .history,
            selectedFilePath: nil,
            selectedChangesByRepository: [:],
            historyVerticalSplitFraction: 2,
            historyHorizontalSplitFraction: -1
        )

        #expect(state.historyVerticalSplitFraction == 0.95)
        #expect(state.historyHorizontalSplitFraction == 0.05)
    }
}
