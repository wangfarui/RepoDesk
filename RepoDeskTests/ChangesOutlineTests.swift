import Foundation
import Testing
@testable import RepoDesk

struct ChangesOutlineTests {
    @Test func autoExpansionAppliesOnlyToSmallNonemptyChangeSets() {
        #expect(!ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 0))
        #expect(ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 1))
        #expect(ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 10))
        #expect(!ChangesAutoExpansionPolicy.shouldExpandAll(fileCount: 11))
    }

    @Test func collapsedDirectoryStatusDoesNotMaterializeFileRows() {
        let rows = ChangesOutlineBuilder.directoryRows(
            selections: selections(count: 1_290),
            namespace: "repo:unstaged",
            statusIsExpanded: false,
            expandedNodeIDs: []
        )

        #expect(rows.isEmpty)
    }

    @Test func flatGroupingShowsSortedFilesWithoutDirectoryOrModuleNodes() {
        let namespace = "repo:changes"
        let first = GitChangeSelection(path: "src/A.swift", kind: .changes)
        let second = GitChangeSelection(path: "tests/B.swift", kind: .changes)

        let rows = ChangesOutlineBuilder.flatRows(
            selections: [second, first],
            namespace: namespace,
            statusIsExpanded: true
        )

        #expect(rows == [
            .file(
                id: "\(namespace):file:\(first.id)",
                selection: first,
                depth: 0,
                modulePath: nil,
                operationCode: "?"
            ),
            .file(
                id: "\(namespace):file:\(second.id)",
                selection: second,
                depth: 0,
                modulePath: nil,
                operationCode: "?"
            )
        ])
    }

    @Test func compactDirectoryStatusBuildsFilesOnlyAfterCompactNodeExpansion() {
        let changes = selections(count: 1_290)
        let namespace = "repo:unstaged"
        let compactDirectoryID = "\(namespace):directory:src/main/java/com/example"

        let rootRows = ChangesOutlineBuilder.directoryRows(
            selections: changes,
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: []
        )
        let srcRows = ChangesOutlineBuilder.directoryRows(
            selections: changes,
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: [compactDirectoryID]
        )

        #expect(rootRows.count == 1)
        #expect(rootRows.first == .directory(
            id: compactDirectoryID,
            name: "src/main/java/com/example",
            path: "src/main/java/com/example",
            depth: 0,
            count: 1_290,
            modulePath: nil
        ))
        #expect(srcRows.count == 1_291)
        #expect(rootRows.allSatisfy { row in
            if case .file = row { return false }
            return true
        })
    }

    @Test func singleChangedFileCompactsItsDirectoryChainIntoOneNode() {
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

        #expect(collapsedRows == [
            .directory(
                id: directoryID,
                name: "src/main/java/com/example",
                path: "src/main/java/com/example",
                depth: 0,
                count: 1,
                modulePath: nil
            )
        ])
        #expect(expandedRows.contains { row in
            if case .file(_, let file, let depth, _, _) = row {
                return file == selection && depth == 1
            }
            return false
        })
    }

    @Test func directoryCompactionStopsWhereChangedPathsBranch() {
        let namespace = "repo:unstaged"
        let changes = [
            GitChangeSelection(path: "src/main/App.java", kind: .changes),
            GitChangeSelection(path: "src/test/AppTests.java", kind: .changes)
        ]

        let rootRows = ChangesOutlineBuilder.directoryRows(
            selections: changes,
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: []
        )
        let expandedRows = ChangesOutlineBuilder.directoryRows(
            selections: changes,
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: ["\(namespace):directory:src"]
        )

        #expect(rootRows.map(\.id) == ["\(namespace):directory:src"])
        #expect(expandedRows.map(\.id) == [
            "\(namespace):directory:src",
            "\(namespace):directory:src/main",
            "\(namespace):directory:src/test"
        ])
    }

    @Test func directoryRowsRevealAndHideNestedPathsByExpansionState() {
        let namespace = "repo:unstaged"
        let changes = [
            GitChangeSelection(path: "src/main/App.java", kind: .changes),
            GitChangeSelection(path: "src/test/AppTests.java", kind: .changes),
            GitChangeSelection(path: "docs/README.md", kind: .changes)
        ]

        let collapsedRows = ChangesOutlineBuilder.directoryRows(
            selections: changes,
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: []
        )
        let expandedRootRows = ChangesOutlineBuilder.directoryRows(
            selections: changes,
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: ["\(namespace):directory:src"]
        )
        let expandedMainRows = ChangesOutlineBuilder.directoryRows(
            selections: changes,
            namespace: namespace,
            statusIsExpanded: true,
            expandedNodeIDs: [
                "\(namespace):directory:src",
                "\(namespace):directory:src/main"
            ]
        )

        #expect(collapsedRows.map(\.id) == [
            "\(namespace):directory:docs",
            "\(namespace):directory:src"
        ])
        #expect(expandedRootRows.map(\.id) == [
            "\(namespace):directory:docs",
            "\(namespace):directory:src",
            "\(namespace):directory:src/main",
            "\(namespace):directory:src/test"
        ])
        #expect(expandedMainRows.contains { row in
            if case .file(_, let selection, _, _, _) = row {
                return selection.path == "src/main/App.java"
            }
            return false
        })
    }

    @Test func directoryExpandableNodeIDsIncludeCompactedAndNestedDirectories() {
        let namespace = "repo:changes"
        let changes = [
            GitChangeSelection(path: "src/main/java/com/example/App.java", kind: .changes),
            GitChangeSelection(path: "src/test/java/com/example/AppTests.java", kind: .changes),
            GitChangeSelection(path: "docs/guide/README.md", kind: .changes)
        ]

        let nodeIDs = ChangesOutlineBuilder.directoryExpandableNodeIDs(
            selections: changes,
            namespace: namespace
        )

        #expect(nodeIDs == [
            "\(namespace):directory:docs/guide",
            "\(namespace):directory:src",
            "\(namespace):directory:src/main/java/com/example",
            "\(namespace):directory:src/test/java/com/example"
        ])
    }

    @Test func collapsedModuleStatusDoesNotResolveModulesOrMaterializeRows() {
        var resolutionCount = 0
        let rows = ChangesOutlineBuilder.moduleRows(
            selections: selections(count: 1_290),
            namespace: "repo:unstaged",
            repositoryName: "repo",
            statusIsExpanded: false,
            expandedNodeIDs: []
        ) { _ in
            resolutionCount += 1
            return "."
        }

        #expect(rows.isEmpty)
        #expect(resolutionCount == 0)
    }

    @Test func expandedModuleStatusBuildsFilesOnlyForExpandedModule() {
        let changes = selections(count: 1_290)
        let namespace = "repo:unstaged"
        let moduleID = "\(namespace):module:."

        let collapsedModuleRows = ChangesOutlineBuilder.moduleRows(
            selections: changes,
            namespace: namespace,
            repositoryName: "repo",
            statusIsExpanded: true,
            expandedNodeIDs: []
        ) { _ in "." }
        let expandedModuleRows = ChangesOutlineBuilder.moduleRows(
            selections: changes,
            namespace: namespace,
            repositoryName: "repo",
            statusIsExpanded: true,
            expandedNodeIDs: [moduleID]
        ) { _ in "." }

        #expect(collapsedModuleRows.count == 1)
        #expect(expandedModuleRows.count == 1_291)
    }

    @Test func moduleExpandableNodeIDsIncludeEveryResolvedModuleOnce() {
        let namespace = "repo:changes"
        let changes = [
            GitChangeSelection(path: "client/src/Client.java", kind: .changes),
            GitChangeSelection(path: "client/src/Other.java", kind: .changes),
            GitChangeSelection(path: "service/src/Service.java", kind: .changes)
        ]

        let nodeIDs = ChangesOutlineBuilder.moduleExpandableNodeIDs(
            selections: changes,
            namespace: namespace,
            modulePath: { $0.path.split(separator: "/").first.map(String.init) ?? "." }
        )

        #expect(nodeIDs == [
            "\(namespace):module:client",
            "\(namespace):module:service"
        ])
    }

    @Test func combinedGroupingNestsDirectoriesInsideModules() {
        let namespace = "repo:changes"
        let client = GitChangeSelection(path: "client/src/main/Client.java", kind: .changes)
        let service = GitChangeSelection(path: "service/src/Service.java", kind: .changes)
        let clientModuleID = "\(namespace):module:client"
        let clientDirectoryID = "\(clientModuleID):directory:src/main"
        let serviceModuleID = "\(namespace):module:service"
        let serviceDirectoryID = "\(serviceModuleID):directory:src"
        let expandedNodeIDs: Set<String> = [
            clientModuleID,
            clientDirectoryID,
            serviceModuleID,
            serviceDirectoryID
        ]

        let rows = ChangesOutlineBuilder.moduleDirectoryRows(
            selections: [service, client],
            namespace: namespace,
            repositoryName: "repo",
            statusIsExpanded: true,
            expandedNodeIDs: expandedNodeIDs
        ) { selection in
            selection.path.split(separator: "/").first.map(String.init) ?? "."
        }

        #expect(rows.map(\.id) == [
            clientModuleID,
            clientDirectoryID,
            "\(clientModuleID):file:\(client.id)",
            serviceModuleID,
            serviceDirectoryID,
            "\(serviceModuleID):file:\(service.id)"
        ])
        #expect(rows.contains { row in
            if case .directory(_, _, _, let depth, _, let modulePath) = row {
                return depth == 1 && modulePath != nil
            }
            return false
        })
        #expect(rows.contains { row in
            if case .file(_, _, let depth, _, _) = row { return depth == 2 }
            return false
        })
    }

    @Test func moduleDirectoryCommitScopeIncludesOnlyDirectoryDescendants() {
        let clientDirect = GitChangeSelection(path: "client/src/App.swift", kind: .changes)
        let clientNested = GitChangeSelection(path: "client/src/feature/Feature.swift", kind: .changes)
        let clientDocs = GitChangeSelection(path: "client/docs/README.md", kind: .changes)
        let serviceSource = GitChangeSelection(path: "service/src/API.swift", kind: .changes)

        let selections = ChangesCommitSelectionScope.directorySelections(
            path: "src",
            modulePath: "client",
            selections: [clientDirect, clientNested, clientDocs, serviceSource]
        )

        #expect(Set(selections) == [clientDirect, clientNested])
    }

    @Test func commitCheckboxStateAggregatesDescendantsAndDefinesToggleTarget() {
        let first = GitChangeSelection(path: "src/First.swift", kind: .changes)
        let second = GitChangeSelection(path: "src/Second.swift", kind: .changes)
        let selections = [first, second]

        let checked = CommitCheckboxState.resolve(selections: selections) { _ in true }
        let unchecked = CommitCheckboxState.resolve(selections: selections) { _ in false }
        let mixed = CommitCheckboxState.resolve(selections: selections) { $0 == first }

        #expect(checked == .checked)
        #expect(unchecked == .unchecked)
        #expect(mixed == .mixed)
        #expect(!checked.includesSelectionsAfterToggle)
        #expect(unchecked.includesSelectionsAfterToggle)
        #expect(mixed.includesSelectionsAfterToggle)
    }

    @Test func combinedGroupingExpansionIncludesModuleAndNestedDirectoryNodes() {
        let namespace = "repo:changes"
        let changes = [
            GitChangeSelection(path: "client/src/main/Client.java", kind: .changes),
            GitChangeSelection(path: "service/src/Service.java", kind: .changes)
        ]

        let nodeIDs = ChangesOutlineBuilder.moduleDirectoryExpandableNodeIDs(
            selections: changes,
            namespace: namespace
        ) { selection in
            selection.path.split(separator: "/").first.map(String.init) ?? "."
        }

        #expect(nodeIDs == [
            "\(namespace):module:client",
            "\(namespace):module:client:directory:src/main",
            "\(namespace):module:service",
            "\(namespace):module:service:directory:src"
        ])
    }

    @Test func modulePathResolverCachesRepeatedDirectoryAndAncestorLookups() {
        var fileExistenceChecks = 0
        var resolver = ChangeModulePathResolver(
            repositoryURL: URL(fileURLWithPath: "/repo", isDirectory: true)
        ) { path in
            fileExistenceChecks += 1
            return path == "/repo/module/pom.xml"
        }

        let paths = (0..<1_290).map {
            resolver.modulePath(for: "module/src/main/java/com/example/Type\($0).java")
        }

        #expect(Set(paths) == ["module"])
        #expect(fileExistenceChecks < 100)
    }

    @Test func modulePathResolverKeepsMarkerlessTopLevelDirectoriesIndependent() {
        var resolver = ChangeModulePathResolver(
            repositoryURL: URL(fileURLWithPath: "/repo", isDirectory: true),
            fileExists: { _ in false }
        )

        #expect(resolver.modulePath(for: "first/src/One.java") == "first")
        #expect(resolver.modulePath(for: "second/src/Two.java") == "second")
    }

    private func selections(count: Int) -> [GitChangeSelection] {
        (0..<count).map {
            GitChangeSelection(
                path: "src/main/java/com/example/Type\($0).java",
                kind: .changes
            )
        }
    }
}
