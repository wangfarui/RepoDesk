import Foundation

struct GitCommitExecutionContext: Equatable, Sendable {
    let repositoryID: RegisteredRepository.ID
    let repositoryName: String
    let branch: String
    let fileCount: Int
    let shouldPush: Bool
    let pushTarget: String
}

struct GitCommitExecutionResult: Equatable, Sendable {
    let context: GitCommitExecutionContext
    let commitHash: String
    let wasPushed: Bool

    var shortHash: String {
        String(commitHash.prefix(8))
    }
}

enum GitCommitExecutionState: Equatable, Sendable {
    case idle
    case committing(GitCommitExecutionContext)
    case pushing(context: GitCommitExecutionContext, commitHash: String)
    case succeeded(GitCommitExecutionResult)
    case commitFailed(context: GitCommitExecutionContext, message: String)
    case pushFailed(result: GitCommitExecutionResult, message: String)

    var isRunning: Bool {
        switch self {
        case .committing, .pushing:
            true
        default:
            false
        }
    }

    var context: GitCommitExecutionContext? {
        switch self {
        case .idle:
            nil
        case .committing(let context),
             .commitFailed(let context, _):
            context
        case .pushing(let context, _):
            context
        case .succeeded(let result),
             .pushFailed(let result, _):
            result.context
        }
    }
}
