import Foundation

struct GitPushPreparation: Equatable, Sendable {
    let localBranch: String
    let remote: String
    let targetRemoteBranch: String
    let remoteBranches: [String]
    let targetExists: Bool
    let commits: [GitCommitSummary]
    let blockingMessage: String?

    var createsRemoteBranch: Bool { !targetExists }

    var canPush: Bool {
        blockingMessage == nil && (!commits.isEmpty || createsRemoteBranch)
    }
}

struct GitPushCommitRange: Equatable, Sendable {
    let commits: [GitCommitSummary]
    let baseRevision: String?
    let headRevision: String
    let files: [GitCommitFile]
}
