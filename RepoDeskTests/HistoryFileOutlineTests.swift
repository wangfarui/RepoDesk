import Testing
@testable import RepoDesk

struct HistoryFileOutlineTests {
    private let files = [
        GitCommitFile(path: "client/src/App.swift", originalPath: nil, status: .added),
        GitCommitFile(path: "service/src/API.swift", originalPath: "service/src/OldAPI.swift", status: .renamed)
    ]

    @Test func supportsFlatDirectoryModuleAndCombinedGrouping() {
        let namespace = "history:abc"
        let modulePath: (GitCommitFile) -> String = {
            $0.path.split(separator: "/").first.map(String.init) ?? "."
        }

        let flatRows = HistoryFileOutlineBuilder.rows(
            files: files,
            namespace: namespace,
            repositoryName: "repo",
            grouping: [],
            expandedNodeIDs: [],
            modulePath: modulePath
        )
        let directoryRows = HistoryFileOutlineBuilder.rows(
            files: files,
            namespace: namespace,
            repositoryName: "repo",
            grouping: .directory,
            expandedNodeIDs: [
                "\(namespace):directory:client/src",
                "\(namespace):directory:service/src"
            ],
            modulePath: modulePath
        )
        let moduleRows = HistoryFileOutlineBuilder.rows(
            files: files,
            namespace: namespace,
            repositoryName: "repo",
            grouping: .module,
            expandedNodeIDs: [
                "\(namespace):module:client",
                "\(namespace):module:service"
            ],
            modulePath: modulePath
        )
        let combinedRows = HistoryFileOutlineBuilder.rows(
            files: files,
            namespace: namespace,
            repositoryName: "repo",
            grouping: .all,
            expandedNodeIDs: HistoryFileOutlineBuilder.expandableNodeIDs(
                files: files,
                namespace: namespace,
                grouping: .all,
                modulePath: modulePath
            ),
            modulePath: modulePath
        )

        #expect(flatRows.compactMap { file(from: $0) }.count == 2)
        #expect(directoryRows.contains { if case .directory = $0 { true } else { false } })
        #expect(moduleRows.contains { if case .module = $0 { true } else { false } })
        #expect(combinedRows.contains { if case .module = $0 { true } else { false } })
        #expect(combinedRows.contains { if case .directory = $0 { true } else { false } })
        #expect(combinedRows.compactMap { file(from: $0) }.contains(files[1]))
    }

    @Test func flatRowsPreserveCommitFileStatusAndRenameSource() {
        let rows = HistoryFileOutlineBuilder.rows(
            files: files,
            namespace: "history:abc",
            repositoryName: "repo",
            grouping: [],
            expandedNodeIDs: [],
            modulePath: { _ in "." }
        )

        #expect(rows.compactMap { file(from: $0) } == files)
    }

    private func file(from row: HistoryFileOutlineRow) -> GitCommitFile? {
        guard case .file(_, let file, _, _) = row else { return nil }
        return file
    }
}
