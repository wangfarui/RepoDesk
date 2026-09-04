import Foundation

struct WorkspaceFileDeletionRequest: Equatable, Sendable {
    let itemURL: URL
    let workspaceRootURL: URL
}

enum WorkspaceFileDeletionError: LocalizedError, Equatable, Sendable {
    case invalidTarget
    case targetUnavailable(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "不能删除工作区根目录。"
        case .targetUnavailable(let path):
            return "目标不存在或不可用：\(path)"
        case .operationFailed(let message):
            return message
        }
    }
}

protocol WorkspaceFileDeleting: Sendable {
    func delete(_ request: WorkspaceFileDeletionRequest) async throws
}

struct FileSystemWorkspaceFileDeleter: WorkspaceFileDeleting {
    func delete(_ request: WorkspaceFileDeletionRequest) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.deleteSynchronously(request)
        }.value
    }

    private static func deleteSynchronously(_ request: WorkspaceFileDeletionRequest) throws {
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
        do {
            try fileManager.removeItem(at: itemURL)
        } catch {
            throw WorkspaceFileDeletionError.operationFailed(error.localizedDescription)
        }
    }
}
