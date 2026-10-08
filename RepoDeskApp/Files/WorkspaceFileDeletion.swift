import Foundation

struct WorkspaceFileDeletionRequest: Equatable, Sendable {
    let itemURL: URL
    let workspaceRootURL: URL
    let backupDirectoryURL: URL?

    init(
        itemURL: URL,
        workspaceRootURL: URL,
        backupDirectoryURL: URL? = nil
    ) {
        self.itemURL = itemURL
        self.workspaceRootURL = workspaceRootURL
        self.backupDirectoryURL = backupDirectoryURL
    }
}

struct WorkspaceFileDeletionItem: Equatable, Sendable {
    let originalURL: URL
    let backupURL: URL?
}

struct WorkspaceFileDeletionSession: Equatable, Sendable {
    let items: [WorkspaceFileDeletionItem]
    let backupDirectoryURL: URL
    let workspaceRootURL: URL
}

enum WorkspaceFileDeletionError: LocalizedError, Equatable, Sendable {
    case invalidTarget
    case targetUnavailable(String)
    case itemAlreadyExists(String)
    case backupUnavailable(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "不能删除工作区根目录。"
        case .targetUnavailable(let path):
            return "目标不存在或不可用：\(path)"
        case .itemAlreadyExists(let path):
            return "无法恢复，目标位置已存在项目：\(path)"
        case .backupUnavailable(let path):
            return "无法恢复，删除备份不可用：\(path)"
        case .operationFailed(let message):
            return message
        }
    }
}

protocol WorkspaceFileDeleting: Sendable {
    func delete(_ request: WorkspaceFileDeletionRequest) async throws -> WorkspaceFileDeletionItem
    func restore(_ session: WorkspaceFileDeletionSession) async throws
}

struct FileSystemWorkspaceFileDeleter: WorkspaceFileDeleting {
    func delete(_ request: WorkspaceFileDeletionRequest) async throws -> WorkspaceFileDeletionItem {
        try await Task.detached(priority: .userInitiated) {
            try Self.deleteSynchronously(request)
        }.value
    }

    func restore(_ session: WorkspaceFileDeletionSession) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.restoreSynchronously(session)
        }.value
    }

    private static func deleteSynchronously(
        _ request: WorkspaceFileDeletionRequest
    ) throws -> WorkspaceFileDeletionItem {
        let itemURL = request.itemURL.standardizedFileURL
        let workspaceRootURL = request.workspaceRootURL.standardizedFileURL
        guard itemURL != workspaceRootURL,
              itemURL.path != "/",
              itemURL.path != "",
              WorkspaceTreeRefreshPlanner.isSameOrDescendant(itemURL, of: workspaceRootURL) else {
            throw WorkspaceFileDeletionError.invalidTarget
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: itemURL.path) else {
            throw WorkspaceFileDeletionError.targetUnavailable(itemURL.path)
        }

        guard let backupDirectoryURL = request.backupDirectoryURL else {
            do {
                try fileManager.removeItem(at: itemURL)
            } catch {
                throw WorkspaceFileDeletionError.operationFailed(error.localizedDescription)
            }
            return WorkspaceFileDeletionItem(originalURL: itemURL, backupURL: nil)
        }

        do {
            try fileManager.createDirectory(
                at: backupDirectoryURL.standardizedFileURL,
                withIntermediateDirectories: true
            )
            let backupURL = backupDirectoryURL
                .standardizedFileURL
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
            try fileManager.moveItem(at: itemURL, to: backupURL)
            return WorkspaceFileDeletionItem(originalURL: itemURL, backupURL: backupURL)
        } catch {
            throw WorkspaceFileDeletionError.operationFailed(error.localizedDescription)
        }
    }

    private static func restoreSynchronously(_ session: WorkspaceFileDeletionSession) throws {
        let fileManager = FileManager.default
        for item in session.items {
            guard let backupURL = item.backupURL,
                  fileManager.fileExists(atPath: backupURL.path) else {
                throw WorkspaceFileDeletionError.backupUnavailable(item.originalURL.path)
            }
            guard !fileManager.fileExists(atPath: item.originalURL.path) else {
                throw WorkspaceFileDeletionError.itemAlreadyExists(item.originalURL.path)
            }
        }

        do {
            for item in session.items {
                guard let backupURL = item.backupURL else {
                    throw WorkspaceFileDeletionError.backupUnavailable(item.originalURL.path)
                }
                try fileManager.moveItem(at: backupURL, to: item.originalURL)
            }
            try? fileManager.removeItem(at: session.backupDirectoryURL)
        } catch let error as WorkspaceFileDeletionError {
            throw error
        } catch {
            throw WorkspaceFileDeletionError.operationFailed(error.localizedDescription)
        }
    }
}
