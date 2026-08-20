import Foundation

enum MavenPathKind: Sendable {
    case userSettingsFile
    case localRepository
}

enum MavenPathValidationResult: Equatable, Sendable {
    case unconfigured
    case valid
    case invalid(message: String)
}

protocol MavenPathValidating {
    func validate(path: String, kind: MavenPathKind) -> MavenPathValidationResult
}

struct MavenPathValidator: MavenPathValidating {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func validate(path: String, kind: MavenPathKind) -> MavenPathValidationResult {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return .unconfigured }

        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return .invalid(message: "路径有误：路径不存在")
        }

        switch kind {
        case .userSettingsFile:
            guard !isDirectory.boolValue else {
                return .invalid(message: "路径有误：User settings file 必须是文件")
            }
            guard fileManager.isReadableFile(atPath: expandedPath) else {
                return .invalid(message: "路径有误：User settings file 不可读取")
            }
        case .localRepository:
            guard isDirectory.boolValue else {
                return .invalid(message: "路径有误：Local repository 必须是目录")
            }
            guard fileManager.isWritableFile(atPath: expandedPath) else {
                return .invalid(message: "路径有误：Local repository 不可写入")
            }
        }
        return .valid
    }
}
