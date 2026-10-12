import Foundation

enum GitRemoteOperationKind: String, Equatable, Sendable {
    case fetch = "Fetch"
    case pull = "Pull"
    case push = "Push"
    case stash = "Stash"
    case unstash = "Unstash"
    case dropStash = "Drop Stash"
    case rollback = "Rollback"
}

struct GitRemoteOperationContext: Equatable, Sendable {
    let id: UUID
    let kind: GitRemoteOperationKind
    let repositoryID: RegisteredRepository.ID
    let repositoryName: String
    let branch: String
    let pullBranchName: String?
    let stashReference: String?
    let stashMessage: String?
    let rollbackSelections: [GitChangeSelection]
    let pushRemote: String?
    let pushTargetBranch: String?
    let pushSetsUpstream: Bool
    let startedAt: Date

    init(
        id: UUID = UUID(),
        kind: GitRemoteOperationKind,
        repositoryID: RegisteredRepository.ID,
        repositoryName: String,
        branch: String,
        pullBranchName: String? = nil,
        stashReference: String? = nil,
        stashMessage: String? = nil,
        rollbackSelections: [GitChangeSelection] = [],
        pushRemote: String? = nil,
        pushTargetBranch: String? = nil,
        pushSetsUpstream: Bool = false,
        startedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.branch = branch
        self.pullBranchName = pullBranchName
        self.stashReference = stashReference
        self.stashMessage = stashMessage
        self.rollbackSelections = rollbackSelections
        self.pushRemote = pushRemote
        self.pushTargetBranch = pushTargetBranch
        self.pushSetsUpstream = pushSetsUpstream
        self.startedAt = startedAt
    }
}

struct GitRemoteOperationResult: Equatable, Sendable {
    let context: GitRemoteOperationContext
    let completedAt: Date

    var duration: TimeInterval {
        max(0, completedAt.timeIntervalSince(context.startedAt))
    }
}

enum GitRemoteOperationState: Equatable, Sendable {
    case idle
    case running(GitRemoteOperationContext)
    case succeeded(GitRemoteOperationResult)
    case noChangesToPush(GitRemoteOperationContext)
    case failed(context: GitRemoteOperationContext, message: String)
    case requiresConflictResolution(context: GitRemoteOperationContext, fileCount: Int)

    var context: GitRemoteOperationContext? {
        switch self {
        case .idle:
            nil
        case .running(let context),
             .noChangesToPush(let context),
             .failed(let context, _),
             .requiresConflictResolution(let context, _):
            context
        case .succeeded(let result):
            result.context
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var blocksGitOperations: Bool {
        switch self {
        case .running, .requiresConflictResolution:
            true
        default:
            false
        }
    }
}
