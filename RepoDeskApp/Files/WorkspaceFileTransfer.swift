import Foundation

struct WorkspaceFilePasteItem: Equatable, Sendable {
    let sourceURL: URL
    let isDirectory: Bool

    var proposedName: String { sourceURL.lastPathComponent }
}

struct WorkspaceFilePastePlan: Equatable, Identifiable, Sendable {
    let id = UUID()
    let items: [WorkspaceFilePasteItem]
    let destinationDirectoryURL: URL
    let conflictingDestinationURLs: [URL]
}

enum WorkspaceFilePasteConflictResolution: Equatable, Sendable {
    case replace
    case keepBoth
}

struct WorkspaceFilePasteResultItem: Equatable, Sendable {
    let destinationURL: URL
    let isDirectory: Bool
}

struct WorkspaceFilePasteResult: Equatable, Sendable {
    let items: [WorkspaceFilePasteResultItem]
    let destinationDirectoryURL: URL
}

enum WorkspaceFileTransferError: LocalizedError, Equatable, Sendable {
    case destinationUnavailable(String)
    case sourceUnavailable(String)
    case duplicateSourceName(String)
    case destinationInsideSource(String)
    case destinationChanged
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable(let path):
            return "目标目录不可用：\(path)"
        case .sourceUnavailable(let path):
            return "来源文件或目录不可用：\(path)"
        case .duplicateSourceName(let name):
            return "无法同时粘贴多个名为“\(name)”的项目。"
        case .destinationInsideSource(let name):
            return "不能将目录“\(name)”粘贴到它自身或它的子目录中。"
        case .destinationChanged:
            return "目标目录内容已发生变化，请重新粘贴。"
        case .operationFailed(let message):
            return message
        }
    }
}

protocol WorkspaceFileTransferring: Sendable {
    func preparePaste(
        sourceURLs: [URL],
        destinationDirectoryURL: URL
    ) async throws -> WorkspaceFilePastePlan

    func executePaste(
        _ plan: WorkspaceFilePastePlan,
        resolution: WorkspaceFilePasteConflictResolution
    ) async throws -> WorkspaceFilePasteResult
}

struct FileSystemWorkspaceFileTransfer: WorkspaceFileTransferring {
    func preparePaste(
        sourceURLs: [URL],
        destinationDirectoryURL: URL
    ) async throws -> WorkspaceFilePastePlan {
        try await Task.detached(priority: .userInitiated) {
            try Self.preparePasteSynchronously(
                sourceURLs: sourceURLs,
                destinationDirectoryURL: destinationDirectoryURL
            )
        }.value
    }

    func executePaste(
        _ plan: WorkspaceFilePastePlan,
        resolution: WorkspaceFilePasteConflictResolution
    ) async throws -> WorkspaceFilePasteResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.executePasteSynchronously(plan, resolution: resolution)
        }.value
    }

    private static func preparePasteSynchronously(
        sourceURLs: [URL],
        destinationDirectoryURL: URL
    ) throws -> WorkspaceFilePastePlan {
        let fileManager = FileManager.default
        let destinationDirectoryURL = destinationDirectoryURL.standardizedFileURL
        guard isDirectory(destinationDirectoryURL) else {
            throw WorkspaceFileTransferError.destinationUnavailable(destinationDirectoryURL.path)
        }

        var seenPaths: Set<String> = []
        var seenNames: Set<String> = []
        var items: [WorkspaceFilePasteItem] = []
        for sourceURL in sourceURLs.map(\.standardizedFileURL) {
            guard seenPaths.insert(sourceURL.path).inserted else { continue }
            guard let item = pasteItem(at: sourceURL) else {
                throw WorkspaceFileTransferError.sourceUnavailable(sourceURL.path)
            }
            guard seenNames.insert(item.proposedName).inserted else {
                throw WorkspaceFileTransferError.duplicateSourceName(item.proposedName)
            }
            if item.isDirectory,
               WorkspaceTreeRefreshPlanner.isSameOrDescendant(
                   destinationDirectoryURL,
                   of: sourceURL
               ) {
                throw WorkspaceFileTransferError.destinationInsideSource(item.proposedName)
            }
            items.append(item)
        }

        let conflicts = items.compactMap { item -> URL? in
            let destinationURL = destinationDirectoryURL
                .appendingPathComponent(item.proposedName, isDirectory: item.isDirectory)
            return fileManager.fileExists(atPath: destinationURL.path) ? destinationURL : nil
        }
        return WorkspaceFilePastePlan(
            items: items,
            destinationDirectoryURL: destinationDirectoryURL,
            conflictingDestinationURLs: conflicts
        )
    }

    private static func executePasteSynchronously(
        _ plan: WorkspaceFilePastePlan,
        resolution: WorkspaceFilePasteConflictResolution
    ) throws -> WorkspaceFilePasteResult {
        let refreshedPlan = try preparePasteSynchronously(
            sourceURLs: plan.items.map(\.sourceURL),
            destinationDirectoryURL: plan.destinationDirectoryURL
        )
        if resolution == .replace {
            let approvedConflictPaths = Set(plan.conflictingDestinationURLs.map(\.path))
            let currentConflictPaths = Set(refreshedPlan.conflictingDestinationURLs.map(\.path))
            guard currentConflictPaths.isSubset(of: approvedConflictPaths) else {
                throw WorkspaceFileTransferError.destinationChanged
            }
        }
        let fileManager = FileManager.default
        let stagingRootURL = refreshedPlan.destinationDirectoryURL.appendingPathComponent(
            ".repodesk-paste-\(UUID().uuidString)",
            isDirectory: true
        )
        let copiesURL = stagingRootURL.appendingPathComponent("copies", isDirectory: true)
        let backupsURL = stagingRootURL.appendingPathComponent("backups", isDirectory: true)

        do {
            try fileManager.createDirectory(at: copiesURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceFileTransferError.operationFailed(error.localizedDescription)
        }

        var stagedItems: [(item: WorkspaceFilePasteItem, url: URL)] = []
        var committedDestinationURLs: [URL] = []
        var backups: [(destinationURL: URL, backupURL: URL)] = []

        do {
            for item in refreshedPlan.items {
                let stagedURL = copiesURL.appendingPathComponent(UUID().uuidString)
                try fileManager.copyItem(at: item.sourceURL, to: stagedURL)
                stagedItems.append((item, stagedURL))
            }

            var reservedDestinationPaths: Set<String> = []
            var results: [WorkspaceFilePasteResultItem] = []
            for stagedItem in stagedItems {
                let destinationURL: URL
                switch resolution {
                case .replace:
                    destinationURL = refreshedPlan.destinationDirectoryURL.appendingPathComponent(
                        stagedItem.item.proposedName,
                        isDirectory: stagedItem.item.isDirectory
                    )
                case .keepBoth:
                    destinationURL = availableDestinationURL(
                        for: stagedItem.item,
                        in: refreshedPlan.destinationDirectoryURL,
                        reservedPaths: reservedDestinationPaths,
                        fileManager: fileManager
                    )
                }
                reservedDestinationPaths.insert(destinationURL.path)

                if fileManager.fileExists(atPath: destinationURL.path) {
                    let backupURL = backupsURL.appendingPathComponent(UUID().uuidString)
                    try fileManager.moveItem(at: destinationURL, to: backupURL)
                    backups.append((destinationURL, backupURL))
                }
                try fileManager.moveItem(at: stagedItem.url, to: destinationURL)
                committedDestinationURLs.append(destinationURL)
                results.append(
                    WorkspaceFilePasteResultItem(
                        destinationURL: destinationURL,
                        isDirectory: stagedItem.item.isDirectory
                    )
                )
            }

            try? fileManager.removeItem(at: stagingRootURL)
            return WorkspaceFilePasteResult(
                items: results,
                destinationDirectoryURL: refreshedPlan.destinationDirectoryURL
            )
        } catch {
            for destinationURL in committedDestinationURLs.reversed() {
                try? fileManager.removeItem(at: destinationURL)
            }
            for backup in backups.reversed() {
                if fileManager.fileExists(atPath: backup.destinationURL.path) {
                    try? fileManager.removeItem(at: backup.destinationURL)
                }
                try? fileManager.moveItem(at: backup.backupURL, to: backup.destinationURL)
            }
            try? fileManager.removeItem(at: stagingRootURL)
            throw WorkspaceFileTransferError.operationFailed(error.localizedDescription)
        }
    }

    private static func pasteItem(at url: URL) -> WorkspaceFilePasteItem? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory == true
                || values.isRegularFile == true
                || values.isSymbolicLink == true else {
            return nil
        }
        return WorkspaceFilePasteItem(
            sourceURL: url,
            isDirectory: values.isDirectory == true
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func availableDestinationURL(
        for item: WorkspaceFilePasteItem,
        in directoryURL: URL,
        reservedPaths: Set<String>,
        fileManager: FileManager
    ) -> URL {
        let originalURL = directoryURL.appendingPathComponent(
            item.proposedName,
            isDirectory: item.isDirectory
        )
        guard fileManager.fileExists(atPath: originalURL.path)
                || reservedPaths.contains(originalURL.path) else {
            return originalURL
        }

        let sourceURL = item.sourceURL
        let pathExtension = item.isDirectory ? "" : sourceURL.pathExtension
        let baseName: String
        if pathExtension.isEmpty {
            baseName = item.proposedName
        } else {
            baseName = sourceURL.deletingPathExtension().lastPathComponent
        }

        var copyNumber = 1
        while true {
            let suffix = copyNumber == 1 ? " copy" : " copy \(copyNumber)"
            let fileName = pathExtension.isEmpty
                ? baseName + suffix
                : baseName + suffix + "." + pathExtension
            let candidateURL = directoryURL.appendingPathComponent(
                fileName,
                isDirectory: item.isDirectory
            )
            if !fileManager.fileExists(atPath: candidateURL.path),
               !reservedPaths.contains(candidateURL.path) {
                return candidateURL
            }
            copyNumber += 1
        }
    }
}
