import Foundation

struct RegisteredRepository: Codable, Equatable, Identifiable, Sendable {
    var displayName: String
    let relativePath: String
    var isPinned: Bool

    var id: String { relativePath }
    var name: String { displayName }
}

enum RepositoryRegistrationError: LocalizedError, Equatable, Identifiable {
    case workspaceUnavailable
    case directoryUnavailable(String)
    case outsideWorkspace(String)
    case notGitRepository(String)
    case alreadyRegistered(String)

    var id: String { errorDescription ?? String(describing: self) }

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "The workspace directory is unavailable."
        case .directoryUnavailable(let path):
            "The selected repository directory is unavailable: \(path)"
        case .outsideWorkspace(let path):
            "The selected directory is outside the current workspace: \(path)"
        case .notGitRepository(let path):
            "No .git directory or .git file was found in: \(path)"
        case .alreadyRegistered(let path):
            "A repository is already registered at: \(path)"
        }
    }
}
