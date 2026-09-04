import Foundation

struct WorkspaceFileCreationRequest: Equatable, Sendable {
    let directoryURL: URL
    let name: String
    let isDirectory: Bool
}

enum WorkspaceFileCreationError: LocalizedError, Equatable, Sendable {
    case invalidName
    case destinationUnavailable(String)
    case itemAlreadyExists(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "名称不能为空，且不能包含路径分隔符。"
        case .destinationUnavailable(let path):
            return "目标目录不可用：\(path)"
        case .itemAlreadyExists(let name):
            return "“\(name)”已经存在。"
        case .operationFailed(let message):
            return message
        }
    }
}

protocol WorkspaceFileCreating: Sendable {
    func create(_ request: WorkspaceFileCreationRequest) async throws -> URL
}

struct FileSystemWorkspaceFileCreator: WorkspaceFileCreating {
    func create(_ request: WorkspaceFileCreationRequest) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Self.createSynchronously(request)
        }.value
    }

    private static func createSynchronously(_ request: WorkspaceFileCreationRequest) throws -> URL {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw WorkspaceFileCreationError.invalidName
        }

        let directoryURL = request.directoryURL.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceFileCreationError.destinationUnavailable(directoryURL.path)
        }

        let destinationURL = directoryURL.appendingPathComponent(name, isDirectory: request.isDirectory)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceFileCreationError.itemAlreadyExists(name)
        }

        do {
            if request.isDirectory {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: false)
            } else {
                guard fileManager.createFile(atPath: destinationURL.path, contents: Data()) else {
                    throw WorkspaceFileCreationError.operationFailed("无法创建文件。")
                }
            }
        } catch let error as WorkspaceFileCreationError {
            throw error
        } catch {
            throw WorkspaceFileCreationError.operationFailed(error.localizedDescription)
        }
        return destinationURL.standardizedFileURL
    }
}
