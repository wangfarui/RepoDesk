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
        try verifySingleDirectoryChainCompaction()
        try verifyCompactionStopsAtBranch()
        try verifyDirectFilesRemainVisibleBesideChildDirectories()
        try verifyFlatGrouping()
        try verifyCombinedModuleDirectoryGrouping()
        try verifyGroupingPersistenceCompatibility()
        print("Changes outline verification passed")
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
