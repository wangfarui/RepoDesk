import Foundation

struct WorkspaceFileRenameRequest: Equatable, Sendable {
    let itemURL: URL
    let newName: String
    let workspaceRootURL: URL
}

enum WorkspaceFileRenameError: LocalizedError, Equatable, Sendable {
    case invalidName
    case invalidTarget
    case targetUnavailable(String)
    case itemAlreadyExists(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "名称不能为空，且不能包含路径分隔符。"
        case .invalidTarget:
            return "不能重命名工作区根目录。"
        case .targetUnavailable(let path):
            return "目标不存在或不可用：\(path)"
        case .itemAlreadyExists(let name):
            return "“\(name)”已经存在。"
        case .operationFailed(let message):
            return message
        }
    }
}

protocol WorkspaceFileRenaming: Sendable {
    func rename(_ request: WorkspaceFileRenameRequest) async throws -> URL
}

struct FileSystemWorkspaceFileRenamer: WorkspaceFileRenaming {
    func rename(_ request: WorkspaceFileRenameRequest) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Self.renameSynchronously(request)
        }.value
    }

    private static func renameSynchronously(_ request: WorkspaceFileRenameRequest) throws -> URL {
        let itemURL = request.itemURL.standardizedFileURL
        let workspaceRootURL = request.workspaceRootURL.standardizedFileURL
        let name = request.newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw WorkspaceFileRenameError.invalidName
        }
        guard itemURL != workspaceRootURL,
              itemURL.path != "/",
              itemURL.path != "",
              WorkspaceTreeRefreshPlanner.isSameOrDescendant(itemURL, of: workspaceRootURL) else {
            throw WorkspaceFileRenameError.invalidTarget
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: itemURL.path) else {
            throw WorkspaceFileRenameError.targetUnavailable(itemURL.path)
        }

        let destinationURL = itemURL.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: requestIsDirectory(itemURL, fileManager: fileManager))
            .standardizedFileURL
        if destinationURL.path == itemURL.path {
            return destinationURL
        }

        let siblingURLs = try fileManager.contentsOfDirectory(
            at: itemURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: []
        )
        if siblingURLs.contains(where: {
            $0.standardizedFileURL != itemURL
                && $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }) {
            throw WorkspaceFileRenameError.itemAlreadyExists(name)
        }

        do {
            if destinationURL.path.caseInsensitiveCompare(itemURL.path) == .orderedSame {
                let temporaryURL = itemURL.deletingLastPathComponent().appendingPathComponent(
                    ".\(itemURL.lastPathComponent).repodesk-rename-\(UUID().uuidString)",
                    isDirectory: requestIsDirectory(itemURL, fileManager: fileManager)
                )
                try fileManager.moveItem(at: itemURL, to: temporaryURL)
                do {
                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                } catch {
                    try? fileManager.moveItem(at: temporaryURL, to: itemURL)
                    throw error
                }
            } else {
                try fileManager.moveItem(at: itemURL, to: destinationURL)
            }
        } catch let error as WorkspaceFileRenameError {
            throw error
        } catch {
            throw WorkspaceFileRenameError.operationFailed(error.localizedDescription)
        }
        return destinationURL
    }

    private static func requestIsDirectory(_ itemURL: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
