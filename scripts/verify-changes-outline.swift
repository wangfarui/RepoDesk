import Foundation

enum ChangesOutlineVerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

@main
enum ChangesOutlineVerification {
    static func main() throws {
        try verifyAutomaticExpansion()
        try verifySingleDirectoryChainCompaction()
        try verifyCompactionStopsAtBranch()
        try verifyDirectFilesRemainVisibleBesideChildDirectories()
        try verifyFlatGrouping()
        try verifyCombinedModuleDirectoryGrouping()
        try verifyDirectoryCommitSelectionScope()
        try verifyCommitCheckboxAggregation()
        try verifyGroupingPersistenceCompatibility()
        print("Changes outline verification passed")
    }

    private static func verifyAutomaticExpansion() throws {
        try expect(!ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 0), "Empty scope expanded")
        try expect(ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 10), "Default threshold excluded 10")
        try expect(!ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 11), "Default threshold included 11")
        let custom = ChangesAutoExpansionSettings(maximumFileCount: 25)
        try expect(
            ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 25, settings: custom)
                && !ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 26, settings: custom),
            "Custom Changes threshold did not control expansion"
        )
        let always = ChangesAutoExpansionSettings(mode: .always)
        let never = ChangesAutoExpansionSettings(mode: .never)
        try expect(
            ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 20_000, settings: always),
            "Always mode used the numeric threshold"
        )
        try expect(
            !ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 1, settings: never),
            "Never mode expanded changes"
        )
        var session = ChangesAutoExpansionSession()
        session.beginIfNeeded(contextID: "repo-a", settings: custom)
        session.beginIfNeeded(contextID: "repo-a", settings: never)
        try expect(session.shouldExpandAll(fileCount: 20), "Settings changed the active scope immediately")
        session.recordManualInteraction()
        session.beginIfNeeded(contextID: "repo-a", settings: always)
        try expect(!session.shouldExpandAll(fileCount: 2), "Refresh overrode manual expansion choices")
        session.beginIfNeeded(contextID: "repo-b", settings: always)
        try expect(session.shouldExpandAll(fileCount: 100), "New scope did not adopt new defaults")
        session.beginIfNeeded(contextID: "repo-a", settings: never)
        try expect(!session.shouldExpandAll(fileCount: 1), "Returning to a scope ignored new defaults")
        session = ChangesAutoExpansionSession()
        session.beginIfNeeded(contextID: "repo-a", settings: custom)
        try expect(session.shouldExpandAll(fileCount: 20), "Re-entering Changes did not adopt new defaults")
    }

    private static func verifySingleDirectoryChainCompaction() throws {
        let namespace = "repo:unstaged"
        let selection = GitChangeSelection(
            path: "src/main/java/com/example/App.java",
            kind: .changes
        )
        let directoryID = "\(namespace):directory:src/main/java/com/example"
        let collapsedRows = ChangesOutlineBuilder.directoryRows(
            selections: [selection],
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: []
        )
        let expandedRows = ChangesOutlineBuilder.directoryRows(
            selections: [selection],
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: [directoryID]
        )

        try expect(
            collapsedRows == [
                .directory(
                    id: directoryID,
                    name: "src/main/java/com/example",
                    path: "src/main/java/com/example",
                    depth: 0,
                    count: 1,
                    modulePath: nil
                )
            ],
            "A single changed file should compact its directory chain."
        )
        try expect(
            expandedRows.contains { row in
                if case .file(_, let file, let depth, _, _) = row {
                    return file == selection && depth == 1
                }
                return false
            },
            "Expanding a compact directory should reveal its file one visual level deeper."
        )
    }

    private static func verifyCompactionStopsAtBranch() throws {
        let namespace = "repo:unstaged"
        let rows = ChangesOutlineBuilder.directoryRows(
            selections: [
                GitChangeSelection(path: "src/main/App.java", kind: .changes),
                GitChangeSelection(path: "src/test/AppTests.java", kind: .changes)
            ],
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: ["\(namespace):directory:src"]
        )

        try expect(
            rows.map(\.id) == [
                "\(namespace):directory:src",
                "\(namespace):directory:src/main",
                "\(namespace):directory:src/test"
            ],
            "Directory compaction should stop where changed paths branch."
        )
    }

    private static func verifyDirectFilesRemainVisibleBesideChildDirectories() throws {
        let namespace = "repo:unstaged"
        let rows = ChangesOutlineBuilder.directoryRows(
            selections: [
                GitChangeSelection(path: "src/README.md", kind: .changes),
                GitChangeSelection(path: "src/main/App.java", kind: .changes)
            ],
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: ["\(namespace):directory:src"]
        )

        try expect(
            rows.contains { row in
                if case .file(_, let file, _, _, _) = row {
                    return file.path == "src/README.md"
                }
                return false
            },
            "A direct changed file should remain visible beside a child directory."
        )
        try expect(
            rows.contains { $0.id == "\(namespace):directory:src/main" },
            "A child directory should remain independently collapsible beside a direct file."
        )
    }

    private static func verifyFlatGrouping() throws {
        let namespace = "repo:changes"
        let first = GitChangeSelection(path: "src/A.swift", kind: .changes)
        let second = GitChangeSelection(path: "tests/B.swift", kind: .changes)
        let rows = ChangesOutlineBuilder.flatRows(
            selections: [second, first],
            namespace: namespace,
            statusIsExpanded: true
        )

        try expect(
            rows.map(\.id) == [
                "\(namespace):file:\(first.id)",
                "\(namespace):file:\(second.id)"
            ],
            "Disabling all grouping should show a sorted flat file list."
        )
    }

    private static func verifyCombinedModuleDirectoryGrouping() throws {
        let namespace = "repo:changes"
        let client = GitChangeSelection(path: "client/src/main/Client.java", kind: .changes)
        let service = GitChangeSelection(path: "service/src/Service.java", kind: .changes)
        let clientModuleID = "\(namespace):module:client"
        let clientDirectoryID = "\(clientModuleID):directory:src/main"
        let serviceModuleID = "\(namespace):module:service"
        let serviceDirectoryID = "\(serviceModuleID):directory:src"
        let rows = ChangesOutlineBuilder.moduleDirectoryRows(
            selections: [service, client],
            namespace: namespace,
            repositoryName: "repo",
            statusIsExpanded: true,
            expandedNodeIDs: [
                clientModuleID,
                clientDirectoryID,
                serviceModuleID,
                serviceDirectoryID
            ]
        ) { selection in
            selection.path.split(separator: "/").first.map(String.init) ?? "."
        }

        try expect(
            rows.map(\.id) == [
                clientModuleID,
                clientDirectoryID,
                "\(clientModuleID):file:\(client.id)",
                serviceModuleID,
                serviceDirectoryID,
                "\(serviceModuleID):file:\(service.id)"
            ],
            "Combined grouping should nest directories inside modules."
        )
        try expect(
            rows.contains { row in
                if case .directory(_, _, _, _, _, let modulePath) = row {
                    return modulePath == "client"
                }
                return false
            },
            "Combined grouping directory rows should preserve their module context."
        )
    }

    private static func verifyDirectoryCommitSelectionScope() throws {
        let clientDirect = GitChangeSelection(path: "client/src/App.swift", kind: .changes)
        let clientNested = GitChangeSelection(path: "client/src/feature/Feature.swift", kind: .changes)
        let clientDocs = GitChangeSelection(path: "client/docs/README.md", kind: .changes)
        let serviceSource = GitChangeSelection(path: "service/src/API.swift", kind: .changes)
        let selections = ChangesCommitSelectionScope.directorySelections(
            path: "src",
            modulePath: "client",
            selections: [clientDirect, clientNested, clientDocs, serviceSource]
        )

        try expect(
            Set(selections) == [clientDirect, clientNested],
            "A module directory commit scope should contain only its direct and nested descendants."
        )
    }

    private static func verifyCommitCheckboxAggregation() throws {
        let first = GitChangeSelection(path: "src/First.swift", kind: .changes)
        let second = GitChangeSelection(path: "src/Second.swift", kind: .changes)
        let selections = [first, second]
        let checked = CommitCheckboxState.resolve(selections: selections) { _ in true }
        let unchecked = CommitCheckboxState.resolve(selections: selections) { _ in false }
        let mixed = CommitCheckboxState.resolve(selections: selections) { $0 == first }

        try expect(checked == .checked, "All included descendants should check their directory.")
        try expect(unchecked == .unchecked, "No included descendants should uncheck their directory.")
        try expect(mixed == .mixed, "Partially included descendants should mix their directory.")
        try expect(
            !checked.includesSelectionsAfterToggle
                && unchecked.includesSelectionsAfterToggle
                && mixed.includesSelectionsAfterToggle,
            "Directory toggles should clear checked scopes and include unchecked or mixed scopes."
        )
    }

    private static func verifyGroupingPersistenceCompatibility() throws {
        let grouping: GitChangesGrouping = [.directory, .module]
        let encoded = try JSONEncoder().encode(grouping)
        let decoded = try JSONDecoder().decode(GitChangesGrouping.self, from: encoded)
        let legacyModule = try JSONDecoder().decode(
            GitChangesGrouping.self,
            from: Data("\"module\"".utf8)
        )
        let flat = try JSONDecoder().decode(
            GitChangesGrouping.self,
            from: Data("[]".utf8)
        )

        try expect(decoded == grouping, "Combined grouping should survive persistence.")
        try expect(legacyModule == .module, "Legacy single grouping values should still decode.")
        try expect(flat.isEmpty, "An empty persisted grouping should restore flat view.")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw ChangesOutlineVerificationError.failed(message)
        }
    }
}
