import Foundation

enum HistoryFileOutlineRow: Equatable, Identifiable, Sendable {
    case directory(
        id: String,
        name: String,
        path: String,
        depth: Int,
        count: Int,
        modulePath: String?
    )
    case module(id: String, name: String, path: String, count: Int)
    case file(id: String, file: GitCommitFile, depth: Int, modulePath: String?)

    var id: String {
        switch self {
        case .directory(let id, _, _, _, _, _), .module(let id, _, _, _), .file(let id, _, _, _):
            id
        }
    }
}

enum HistoryFileOutlineBuilder {
    static func rows(
        files: [GitCommitFile],
        namespace: String,
        repositoryName: String,
        grouping: GitChangesGrouping,
        expandedNodeIDs: Set<String>,
        modulePath: (GitCommitFile) -> String
    ) -> [HistoryFileOutlineRow] {
        let selections = selections(for: files)
        let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let modulePathsByPath = grouping.contains(.module)
            ? Dictionary(uniqueKeysWithValues: files.map { ($0.path, modulePath($0)) })
            : [:]
        let resolveModulePath: (GitChangeSelection) -> String = { selection in
            modulePathsByPath[selection.path] ?? "."
        }
        let rows: [ChangeOutlineRow]

        if grouping.isEmpty {
            rows = ChangesOutlineBuilder.flatRows(
                selections: selections,
                namespace: namespace,
                statusIsExpanded: true
            )
        } else if grouping == .directory {
            rows = ChangesOutlineBuilder.directoryRows(
                selections: selections,
                namespace: namespace,
                statusIsExpanded: true,
                expandedNodeIDs: expandedNodeIDs
            )
        } else if grouping == .module {
            rows = ChangesOutlineBuilder.moduleRows(
                selections: selections,
                namespace: namespace,
                repositoryName: repositoryName,
                statusIsExpanded: true,
                expandedNodeIDs: expandedNodeIDs,
                modulePath: resolveModulePath
            )
        } else {
            rows = ChangesOutlineBuilder.moduleDirectoryRows(
                selections: selections,
                namespace: namespace,
                repositoryName: repositoryName,
                statusIsExpanded: true,
                expandedNodeIDs: expandedNodeIDs,
                modulePath: resolveModulePath
            )
        }

        return rows.compactMap { row in
            switch row {
            case .directory(let id, let name, let path, let depth, let count, let modulePath):
                .directory(
                    id: id,
                    name: name,
                    path: path,
                    depth: depth,
                    count: count,
                    modulePath: modulePath
                )
            case .module(let id, let name, let path, let count):
                .module(id: id, name: name, path: path, count: count)
            case .file(let id, let selection, let depth, let modulePath, _):
                filesByPath[selection.path].map {
                    .file(id: id, file: $0, depth: depth, modulePath: modulePath)
                }
            }
        }
    }

    static func expandableNodeIDs(
        files: [GitCommitFile],
        namespace: String,
        grouping: GitChangesGrouping,
        modulePath: (GitCommitFile) -> String
    ) -> Set<String> {
        let selections = selections(for: files)
        let modulePathsByPath = grouping.contains(.module)
            ? Dictionary(uniqueKeysWithValues: files.map { ($0.path, modulePath($0)) })
            : [:]
        let resolveModulePath: (GitChangeSelection) -> String = { selection in
            modulePathsByPath[selection.path] ?? "."
        }

        if grouping == .directory {
            return ChangesOutlineBuilder.directoryExpandableNodeIDs(
                selections: selections,
                namespace: namespace
            )
        }
        if grouping == .module {
            return ChangesOutlineBuilder.moduleExpandableNodeIDs(
                selections: selections,
                namespace: namespace,
                modulePath: resolveModulePath
            )
        }
        if grouping == .all {
            return ChangesOutlineBuilder.moduleDirectoryExpandableNodeIDs(
                selections: selections,
                namespace: namespace,
                modulePath: resolveModulePath
            )
        }
        return []
    }

    private static func selections(for files: [GitCommitFile]) -> [GitChangeSelection] {
        files.map {
            GitChangeSelection(path: $0.path, kind: .changes, originalPath: $0.originalPath)
        }
    }
}
