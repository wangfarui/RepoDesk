import Foundation

enum ChangesAutoExpansionPolicy {
    static let maximumFileCount = 10

    static func shouldExpandAll(fileCount: Int) -> Bool {
        fileCount > 0 && fileCount <= maximumFileCount
    }
}

enum ChangeOutlineRow: Equatable, Identifiable, Sendable {
    case directory(
        id: String,
        name: String,
        path: String,
        depth: Int,
        count: Int,
        modulePath: String?
    )
    case module(id: String, name: String, path: String, count: Int)
    case file(
        id: String,
        selection: GitChangeSelection,
        depth: Int,
        modulePath: String?,
        operationCode: String
    )

    var id: String {
        switch self {
        case .directory(let id, _, _, _, _, _), .module(let id, _, _, _), .file(let id, _, _, _, _):
            id
        }
    }
}

enum ChangesOutlineBuilder {
    static func directoryExpandableNodeIDs(
        selections: [GitChangeSelection],
        namespace: String,
        directoryPath: (GitChangeSelection) -> String = { $0.path }
    ) -> Set<String> {
        let items = selections.map {
            DirectoryItem(
                selection: $0,
                components: directoryPath($0).split(separator: "/").map(String.init)
            )
        }
        var nodeIDs: Set<String> = []
        appendDirectoryNodeIDs(
            items,
            namespace: namespace,
            prefix: [],
            componentIndex: 0,
            nodeIDs: &nodeIDs
        )
        return nodeIDs
    }

    static func moduleExpandableNodeIDs(
        selections: [GitChangeSelection],
        namespace: String,
        modulePath: (GitChangeSelection) -> String
    ) -> Set<String> {
        Set(selections.map { "\(namespace):module:\(modulePath($0))" })
    }

    static func directoryRows(
        selections: [GitChangeSelection],
        namespace: String,
        statusIsExpanded: Bool,
        expandedNodeIDs: Set<String>,
        baseDepth: Int = 0,
        modulePath: String? = nil,
        directoryPath: (GitChangeSelection) -> String = { $0.path },
        operationCode: (GitChangeSelection) -> String = { _ in "?" }
    ) -> [ChangeOutlineRow] {
        guard statusIsExpanded else { return [] }
        let items = selections.map {
            DirectoryItem(
                selection: $0,
                components: directoryPath($0).split(separator: "/").map(String.init)
            )
        }
        var rows: [ChangeOutlineRow] = []
        appendDirectoryRows(
            items,
            namespace: namespace,
            prefix: [],
            componentIndex: 0,
            visualDepth: baseDepth,
            modulePath: modulePath,
            expandedNodeIDs: expandedNodeIDs,
            operationCode: operationCode,
            rows: &rows
        )
        return rows
    }

    static func flatRows(
        selections: [GitChangeSelection],
        namespace: String,
        statusIsExpanded: Bool,
        operationCode: (GitChangeSelection) -> String = { _ in "?" }
    ) -> [ChangeOutlineRow] {
        guard statusIsExpanded else { return [] }
        return selections.sorted(by: selectionOrder).map {
            .file(
                id: "\(namespace):file:\($0.id)",
                selection: $0,
                depth: 0,
                modulePath: nil,
                operationCode: operationCode($0)
            )
        }
    }

    static func moduleRows(
        selections: [GitChangeSelection],
        namespace: String,
        repositoryName: String,
        statusIsExpanded: Bool,
        expandedNodeIDs: Set<String>,
        operationCode: (GitChangeSelection) -> String = { _ in "?" },
        modulePath: (GitChangeSelection) -> String
    ) -> [ChangeOutlineRow] {
        guard statusIsExpanded else { return [] }
        let modules = Dictionary(grouping: selections, by: modulePath)
        return modules.keys.sorted(by: localizedPathOrder).flatMap { path in
            let moduleID = "\(namespace):module:\(path)"
            let moduleName = path == "."
                ? repositoryName
                : (path.split(separator: "/").last.map(String.init) ?? path)
            var rows: [ChangeOutlineRow] = [
                .module(
                    id: moduleID,
                    name: moduleName,
                    path: path,
                    count: modules[path]?.count ?? 0
                )
            ]
            if expandedNodeIDs.contains(moduleID) {
                rows.append(contentsOf: (modules[path] ?? []).sorted(by: selectionOrder).map {
                    .file(
                        id: "\(moduleID):file:\($0.id)",
                        selection: $0,
                        depth: 1,
                        modulePath: path,
                        operationCode: operationCode($0)
                    )
                })
            }
            return rows
        }
    }

    static func moduleDirectoryExpandableNodeIDs(
        selections: [GitChangeSelection],
        namespace: String,
        modulePath: (GitChangeSelection) -> String
    ) -> Set<String> {
        let modules = Dictionary(grouping: selections, by: modulePath)
        var nodeIDs = Set(modules.keys.map { "\(namespace):module:\($0)" })
        for (path, moduleSelections) in modules {
            let moduleID = "\(namespace):module:\(path)"
            nodeIDs.formUnion(
                directoryExpandableNodeIDs(
                    selections: moduleSelections,
                    namespace: moduleID,
                    directoryPath: { relativePath($0.path, withinModule: path) }
                )
            )
        }
        return nodeIDs
    }

    static func moduleDirectoryRows(
        selections: [GitChangeSelection],
        namespace: String,
        repositoryName: String,
        statusIsExpanded: Bool,
        expandedNodeIDs: Set<String>,
        operationCode: (GitChangeSelection) -> String = { _ in "?" },
        modulePath: (GitChangeSelection) -> String
    ) -> [ChangeOutlineRow] {
        guard statusIsExpanded else { return [] }
        let modules = Dictionary(grouping: selections, by: modulePath)
        return modules.keys.sorted(by: localizedPathOrder).flatMap { path in
            let moduleID = "\(namespace):module:\(path)"
            let moduleName = path == "."
                ? repositoryName
                : (path.split(separator: "/").last.map(String.init) ?? path)
            var rows: [ChangeOutlineRow] = [
                .module(
                    id: moduleID,
                    name: moduleName,
                    path: path,
                    count: modules[path]?.count ?? 0
                )
            ]
            if expandedNodeIDs.contains(moduleID) {
                rows.append(contentsOf: directoryRows(
                    selections: modules[path] ?? [],
                    namespace: moduleID,
                    statusIsExpanded: true,
                    expandedNodeIDs: expandedNodeIDs,
                    baseDepth: 1,
                    directoryPath: { relativePath($0.path, withinModule: path) },
                    operationCode: operationCode
                ))
            }
            return rows
        }
    }

    private static func appendDirectoryNodeIDs(
        _ items: [DirectoryItem],
        namespace: String,
        prefix: [String],
        componentIndex: Int,
        nodeIDs: inout Set<String>
    ) {
        let visibleItems = items.filter { $0.components.indices.contains(componentIndex) }
        let groups = Dictionary(grouping: visibleItems) { $0.components[componentIndex] }
        for name in groups.keys.sorted(by: localizedPathOrder) {
            guard let group = groups[name] else { continue }
            let pathComponents = prefix + [name]
            let descendants = group.filter { $0.components.count > componentIndex + 1 }
            guard !descendants.isEmpty else { continue }

            let compacted = compactDirectoryChain(
                items: descendants,
                pathComponents: pathComponents,
                componentIndex: componentIndex
            )
            let directoryID = "\(namespace):directory:\(compacted.pathComponents.joined(separator: "/"))"
            nodeIDs.insert(directoryID)
            appendDirectoryNodeIDs(
                compacted.items,
                namespace: namespace,
                prefix: compacted.pathComponents,
                componentIndex: compacted.componentIndex + 1,
                nodeIDs: &nodeIDs
            )
        }
    }

    private static func appendDirectoryRows(
        _ items: [DirectoryItem],
        namespace: String,
        prefix: [String],
        componentIndex: Int,
        visualDepth: Int,
        modulePath: String?,
        expandedNodeIDs: Set<String>,
        operationCode: (GitChangeSelection) -> String,
        rows: inout [ChangeOutlineRow]
    ) {
        let visibleItems = items.filter { $0.components.indices.contains(componentIndex) }
        let groups = Dictionary(grouping: visibleItems) { $0.components[componentIndex] }
        for name in groups.keys.sorted(by: localizedPathOrder) {
            guard let group = groups[name] else { continue }
            let pathComponents = prefix + [name]
            let descendants = group.filter { $0.components.count > componentIndex + 1 }
            if descendants.isEmpty {
                rows.append(contentsOf: group.sorted { selectionOrder($0.selection, $1.selection) }.map {
                    .file(
                        id: "\(namespace):file:\($0.selection.id)",
                        selection: $0.selection,
                        depth: visualDepth,
                        modulePath: modulePath,
                        operationCode: operationCode($0.selection)
                    )
                })
                continue
            }

            let compacted = compactDirectoryChain(
                items: descendants,
                pathComponents: pathComponents,
                componentIndex: componentIndex
            )
            let path = compacted.pathComponents.joined(separator: "/")
            let directoryID = "\(namespace):directory:\(path)"
            rows.append(
                .directory(
                    id: directoryID,
                    name: compacted.displayComponents.joined(separator: "/"),
                    path: path,
                    depth: visualDepth,
                    count: group.count,
                    modulePath: modulePath
                )
            )
            if expandedNodeIDs.contains(directoryID) {
                appendDirectoryRows(
                    compacted.items,
                    namespace: namespace,
                    prefix: compacted.pathComponents,
                    componentIndex: compacted.componentIndex + 1,
                    visualDepth: visualDepth + 1,
                    modulePath: modulePath,
                    expandedNodeIDs: expandedNodeIDs,
                    operationCode: operationCode,
                    rows: &rows
                )
            }
        }
    }

    private static func compactDirectoryChain(
        items: [DirectoryItem],
        pathComponents: [String],
        componentIndex: Int
    ) -> CompactedDirectory {
        var compactedItems = items
        var compactedPath = pathComponents
        var displayComponents = [pathComponents.last ?? ""]
        var currentIndex = componentIndex

        while true {
            let childIndex = currentIndex + 1
            let children = Dictionary(
                grouping: compactedItems.filter { $0.components.indices.contains(childIndex) }
            ) { $0.components[childIndex] }
            guard children.count == 1,
                  let childName = children.keys.first,
                  let childItems = children[childName],
                  childItems.allSatisfy({ $0.components.count > childIndex + 1 }) else {
                break
            }

            compactedItems = childItems
            compactedPath.append(childName)
            displayComponents.append(childName)
            currentIndex = childIndex
        }

        return CompactedDirectory(
            items: compactedItems,
            pathComponents: compactedPath,
            displayComponents: displayComponents,
            componentIndex: currentIndex
        )
    }

    private static func localizedPathOrder(_ left: String, _ right: String) -> Bool {
        left.localizedStandardCompare(right) == .orderedAscending
    }

    private static func relativePath(_ filePath: String, withinModule modulePath: String) -> String {
        guard modulePath != ".", filePath.hasPrefix(modulePath + "/") else { return filePath }
        return String(filePath.dropFirst(modulePath.count + 1))
    }

    private static func selectionOrder(
        _ left: GitChangeSelection,
        _ right: GitChangeSelection
    ) -> Bool {
        localizedPathOrder(left.path, right.path)
    }

    private struct DirectoryItem {
        let selection: GitChangeSelection
        let components: [String]
    }

    private struct CompactedDirectory {
        let items: [DirectoryItem]
        let pathComponents: [String]
        let displayComponents: [String]
        let componentIndex: Int
    }
}

struct ChangeModulePathResolver {
    private static let markers = [
        "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "Package.swift", "package.json", "project.yml"
    ]

    private let repositoryURL: URL
    private let fileExists: (String) -> Bool
    private var resolvedDirectories: [String: String] = [:]

    init(
        repositoryURL: URL,
        fileExists: @escaping (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) {
        self.repositoryURL = repositoryURL
        self.fileExists = fileExists
    }

    mutating func modulePath(for filePath: String) -> String {
        let directoryComponents = Array(filePath.split(separator: "/").dropLast()).map(String.init)
        let directoryPath = directoryComponents.joined(separator: "/")
        if let cached = resolvedDirectories[directoryPath] { return cached }

        var checkedPaths: [String] = []
        for depth in stride(from: directoryComponents.count, through: 0, by: -1) {
            let candidate = directoryComponents.prefix(depth).joined(separator: "/")
            if let cached = resolvedDirectories[candidate] {
                checkedPaths.forEach { resolvedDirectories[$0] = cached }
                return cached
            }
            checkedPaths.append(candidate)
            let directoryURL = candidate.isEmpty
                ? repositoryURL
                : repositoryURL.appendingPathComponent(candidate, isDirectory: true)
            if Self.markers.contains(where: { fileExists(directoryURL.appendingPathComponent($0).path) }) {
                let resolved = candidate.isEmpty ? "." : candidate
                checkedPaths.forEach { resolvedDirectories[$0] = resolved }
                return resolved
            }
        }

        let fallback = directoryComponents.first ?? "."
        checkedPaths
            .filter { fallback == "." ? $0.isEmpty : ($0 == fallback || $0.hasPrefix(fallback + "/")) }
            .forEach { resolvedDirectories[$0] = fallback }
        return fallback
    }
}
