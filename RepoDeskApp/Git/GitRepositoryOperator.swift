import Foundation

protocol GitRepositoryOperating: Sendable {
    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit
    func createCommit(
        repositoryURL: URL,
        message: String,
        changes: [GitChangeSelection]
    ) async throws -> GitCreatedCommit
    func fetch(repositoryURL: URL) async throws
    func pullCurrentBranch(repositoryURL: URL) async throws
    func pullBranch(repositoryURL: URL, branchName: String) async throws
    func pushCurrentBranch(repositoryURL: URL) async throws
    func pushCurrentBranchOutcome(repositoryURL: URL) async throws -> GitPushOutcome
    func push(
        repositoryURL: URL,
        localBranch: String,
        remote: String,
        remoteBranch: String,
        setUpstream: Bool
    ) async throws -> GitPushOutcome
    func switchBranch(repositoryURL: URL, branch: GitBranch) async throws
    func pushBranch(repositoryURL: URL, branch: GitBranch) async throws
    @discardableResult
    func mergeBranch(repositoryURL: URL, branch: GitBranch) async throws -> GitMergeOutcome
    func renameBranch(repositoryURL: URL, branch: GitBranch, to newName: String) async throws
    func deleteBranch(repositoryURL: URL, branch: GitBranch) async throws
    func abortMerge(repositoryURL: URL) async throws
    func continueMerge(repositoryURL: URL) async throws
    func conflictFiles(repositoryURL: URL) async throws -> [GitConflictFile]
    func resolveConflict(repositoryURL: URL, file: GitConflictFile) async throws
    func saveConflictProgress(repositoryURL: URL, file: GitConflictFile) async throws
    func restoreConflictProgress(repositoryURL: URL, file: GitConflictFile) async throws
    func stashChanges(repositoryURL: URL, message: String?) async throws
    func listStashes(repositoryURL: URL) async throws -> [GitStash]
    func unstashChanges(repositoryURL: URL, stash: GitStash) async throws
    func dropStash(repositoryURL: URL, stash: GitStash) async throws
    func rollbackChanges(repositoryURL: URL, changes: [GitChangeSelection]) async throws
}

extension GitRepositoryOperating {
    func createCommit(
        repositoryURL: URL,
        message: String,
        changes: [GitChangeSelection]
    ) async throws -> GitCreatedCommit {
        try await createCommit(repositoryURL: repositoryURL, message: message)
    }
    func fetch(repositoryURL: URL) async throws {}
    func pullCurrentBranch(repositoryURL: URL) async throws {}
    func pullBranch(repositoryURL: URL, branchName: String) async throws {
        throw GitRepositoryOperationError.commandFailed(operation: .pull, message: "不支持指定分支 Pull。")
    }
    func pushCurrentBranchOutcome(repositoryURL: URL) async throws -> GitPushOutcome {
        try await pushCurrentBranch(repositoryURL: repositoryURL)
        return .pushed
    }
    func push(
        repositoryURL: URL,
        localBranch: String,
        remote: String,
        remoteBranch: String,
        setUpstream: Bool
    ) async throws -> GitPushOutcome {
        try await pushCurrentBranchOutcome(repositoryURL: repositoryURL)
    }
    func pushBranch(repositoryURL: URL, branch: GitBranch) async throws { try await pushCurrentBranch(repositoryURL: repositoryURL) }
    @discardableResult
    func mergeBranch(repositoryURL: URL, branch: GitBranch) async throws -> GitMergeOutcome { .merged }
    func renameBranch(repositoryURL: URL, branch: GitBranch, to newName: String) async throws {}
    func deleteBranch(repositoryURL: URL, branch: GitBranch) async throws {}
    func abortMerge(repositoryURL: URL) async throws {}
    func continueMerge(repositoryURL: URL) async throws {}
    func conflictFiles(repositoryURL: URL) async throws -> [GitConflictFile] { [] }
    func resolveConflict(repositoryURL: URL, file: GitConflictFile) async throws {}
    func saveConflictProgress(repositoryURL: URL, file: GitConflictFile) async throws {}
    func restoreConflictProgress(repositoryURL: URL, file: GitConflictFile) async throws {}
    func stashChanges(repositoryURL: URL, message: String?) async throws {}
    func listStashes(repositoryURL: URL) async throws -> [GitStash] { [] }
    func unstashChanges(repositoryURL: URL, stash: GitStash) async throws {}
    func dropStash(repositoryURL: URL, stash: GitStash) async throws {}
    func rollbackChanges(repositoryURL: URL, changes: [GitChangeSelection]) async throws {}
}

struct GitCreatedCommit: Equatable, Sendable {
    let hash: String
}

enum GitPushOutcome: Equatable, Sendable {
    case pushed
    case upToDate
}

enum GitMergeOutcome: Equatable, Sendable {
    case merged
    case upToDate
}

enum GitRepositoryOperation: String, Equatable, Sendable {
    case stageChanges
    case createCommit
    case resolveBranch
    case switchBranch
    case fetch
    case pull
    case push
    case merge
    case rename
    case delete
    case abortMerge
    case continueMerge
    case resolveConflict
    case stash
    case unstash
    case dropStash
    case rollback

    var displayName: String {
        switch self {
        case .stageChanges: "暂存改动"
        case .createCommit: "创建 Commit"
        case .resolveBranch: "检查 Branch"
        case .switchBranch: "切换 Branch"
        case .fetch: "Fetch"
        case .pull: "Pull"
        case .push: "Push"
        case .merge: "Merge"
        case .rename: "Rename Branch"
        case .delete: "Delete Branch"
        case .abortMerge: "Abort Merge"
        case .continueMerge: "Continue Merge"
        case .resolveConflict: "Resolve Conflict"
        case .stash: "暂存改动"
        case .unstash: "恢复暂存"
        case .dropStash: "删除暂存"
        case .rollback: "Rollback"
        }
    }
}

enum GitRepositoryOperationError: LocalizedError, Equatable, Sendable {
    case emptyCommitMessage
    case invalidRemoteBranch(String)
    case invalidPushTarget(String)
    case missingUpstream(String)
    case missingPullUpstream(String)
    case pullCurrentBranchConflict(String)
    case commandFailed(operation: GitRepositoryOperation, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyCommitMessage:
            "请输入 Commit 信息。"
        case .invalidRemoteBranch(let name):
            "无法从远程 Branch \(name) 创建本地 tracking Branch。"
        case .invalidPushTarget(let name):
            "'\(name)' 不是有效的远程 Branch 名称。"
        case .missingUpstream(let name):
            "Branch \(name) 没有配置 upstream，无法 Push。"
        case .missingPullUpstream(let name):
            "本地分支 \(name) 未配置远程分支，无法 Pull。"
        case .pullCurrentBranchConflict(let name):
            "Pull \(name) 需要解决合并冲突。"
        case .commandFailed(let operation, let message):
            "\(operation.displayName)失败：\(message)"
        }
    }
}

struct SystemGitRepositoryOperator: GitRepositoryOperating {
    private let commandRunner: any CommandRunning
    private let gitURL: URL

    init(
        commandRunner: any CommandRunning = SystemCommandRunner(timeout: .seconds(120)),
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git")
    ) {
        self.commandRunner = commandRunner
        self.gitURL = gitURL
    }

    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit {
        try await createCommit(
            repositoryURL: repositoryURL,
            message: message,
            changes: []
        )
    }

    func createCommit(
        repositoryURL: URL,
        message: String,
        changes: [GitChangeSelection]
    ) async throws -> GitCreatedCommit {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty else {
            throw GitRepositoryOperationError.emptyCommitMessage
        }

        let paths = Array(Set(changes.flatMap { [$0.path, $0.originalPath].compactMap { $0 } })).sorted()
        if paths.isEmpty {
            _ = try await runGit(
                ["add", "--all"],
                operation: .stageChanges,
                repositoryURL: repositoryURL
            )
        } else {
            _ = try await runGit(
                ["add", "--all", "--"] + paths,
                operation: .stageChanges,
                repositoryURL: repositoryURL
            )
        }
        var commitArguments = ["commit", "--message", normalizedMessage]
        if !paths.isEmpty {
            commitArguments.append("--only")
            commitArguments.append("--")
            commitArguments.append(contentsOf: paths)
        }
        _ = try await runGit(
            commitArguments,
            operation: .createCommit,
            repositoryURL: repositoryURL,
            redacting: [message, normalizedMessage]
        )
        let result = try await runGit(
            ["rev-parse", "--verify", "HEAD"],
            operation: .createCommit,
            repositoryURL: repositoryURL,
            redacting: [message, normalizedMessage]
        )
        let hash = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else {
            throw GitRepositoryOperationError.commandFailed(
                operation: .createCommit,
                message: "Git 未返回新 Commit 的 Hash。"
            )
        }
        return GitCreatedCommit(hash: hash)
    }

    func fetch(repositoryURL: URL) async throws {
        _ = try await runGit(
            ["fetch", "--all", "--prune"],
            operation: .fetch,
            repositoryURL: repositoryURL
        )
    }

    func pullCurrentBranch(repositoryURL: URL) async throws {
        _ = try await runGit(
            ["pull"],
            operation: .pull,
            repositoryURL: repositoryURL
        )
    }

    /// Merge in a detached worktree before atomically advancing a non-current branch.
    /// The original worktree's HEAD, index and files are never switched or stashed.
    func pullBranch(repositoryURL: URL, branchName: String) async throws {
        _ = try await runGit(["check-ref-format", "--branch", branchName], operation: .pull, repositoryURL: repositoryURL)
        let localRef = "refs/heads/\(branchName)"
        let oldHash = try await pullGitOutput(["rev-parse", "--verify", localRef], repositoryURL: repositoryURL)
        let configuration = try await pullGitOutput(
            ["for-each-ref", "--format=%(upstream)%09%(upstream:remotename)%09%(upstream:remoteref)", localRef],
            repositoryURL: repositoryURL
        ).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard configuration.count == 3,
              configuration.allSatisfy({ !$0.isEmpty }), configuration[1] != "." else {
            throw GitRepositoryOperationError.missingPullUpstream(branchName)
        }
        let currentRef = try await pullGitOutput(
            ["symbolic-ref", "--quiet", "HEAD"], repositoryURL: repositoryURL, allowedStatuses: [0, 1]
        )
        if currentRef != localRef {
            try await ensurePullBranchIsNotCheckedOut(localRef, repositoryURL: repositoryURL)
        }
        _ = try await runGit(
            ["fetch", "--no-tags", "--no-write-fetch-head", "--", configuration[1],
             "+\(configuration[2]):\(configuration[0])"],
            operation: .pull, repositoryURL: repositoryURL
        )
        let upstreamHash = try await pullGitOutput(
            ["rev-parse", "--verify", "\(configuration[0])^{commit}"], repositoryURL: repositoryURL
        )
        let mergeArguments = ["-c", "merge.autoStash=false", "-c", "core.editor=true", "merge", "--no-edit", "--ff", upstreamHash]
        if currentRef == localRef {
            // Recheck after the network request; an external checkout must not redirect the merge.
            guard try await pullGitOutput(["symbolic-ref", "--quiet", "HEAD"], repositoryURL: repositoryURL, allowedStatuses: [0, 1]) == localRef else {
                throw GitRepositoryOperationError.commandFailed(operation: .pull, message: "当前分支已变化，请重试。")
            }
            do {
                _ = try await runGit(mergeArguments, operation: .pull, repositoryURL: repositoryURL)
            } catch {
                if let files = try? await conflictFiles(repositoryURL: repositoryURL), !files.isEmpty {
                    throw GitRepositoryOperationError.pullCurrentBranchConflict(branchName)
                }
                throw error
            }
            return
        }

        let worktreeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Pull-\(UUID().uuidString)", isDirectory: true)
        _ = try await runGit(
            ["worktree", "add", "--detach", worktreeURL.path, oldHash],
            operation: .pull, repositoryURL: repositoryURL
        )
        let newHash: String
        do {
            do {
                _ = try await runGit(mergeArguments, operation: .pull, repositoryURL: worktreeURL)
            } catch {
                let conflicts = try await pullGitOutput(
                    ["diff", "--name-only", "--diff-filter=U"], repositoryURL: worktreeURL
                )
                if !conflicts.isEmpty {
                    throw GitRepositoryOperationError.commandFailed(
                        operation: .pull,
                        message: "分支 \(branchName) 与上游合并存在冲突，本次合并已取消，目标分支未更新。请 Checkout 该分支后 Pull 并解决冲突。\n\(conflicts)"
                    )
                }
                throw error
            }
            newHash = try await pullGitOutput(["rev-parse", "--verify", "HEAD"], repositoryURL: worktreeURL)
        } catch {
            try await removePullWorktree(worktreeURL, repositoryURL: repositoryURL, failure: error.localizedDescription)
            throw error
        }
        try await removePullWorktree(worktreeURL, repositoryURL: repositoryURL)
        try await ensurePullBranchIsNotCheckedOut(localRef, repositoryURL: repositoryURL)
        // Compare-and-swap refuses to overwrite commits made while Pull was running.
        _ = try await runGit(
            ["update-ref", "-m", "RepoDesk Pull \(branchName)", localRef, newHash, oldHash],
            operation: .pull, repositoryURL: repositoryURL
        )
    }

    private func ensurePullBranchIsNotCheckedOut(_ localRef: String, repositoryURL: URL) async throws {
        let worktrees = try await pullGitOutput(["worktree", "list", "--porcelain"], repositoryURL: repositoryURL)
        guard !worktrees.split(separator: "\n").contains(Substring("branch \(localRef)")) else {
            throw GitRepositoryOperationError.commandFailed(operation: .pull, message: "目标分支已在工作区中检出，请在对应工作区执行 Pull。")
        }
    }

    private func removePullWorktree(_ worktreeURL: URL, repositoryURL: URL, failure: String? = nil) async throws {
        do {
            _ = try await runGit(["worktree", "remove", "--force", worktreeURL.path], operation: .pull, repositoryURL: repositoryURL)
        } catch {
            throw GitRepositoryOperationError.commandFailed(
                operation: .pull,
                message: [failure, "临时工作区清理失败：\(worktreeURL.path)", error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            )
        }
    }

    private func pullGitOutput(_ arguments: [String], repositoryURL: URL, allowedStatuses: Set<Int32> = [0]) async throws -> String {
        let result = try await runGit(arguments, operation: .pull, repositoryURL: repositoryURL, allowedStatuses: allowedStatuses)
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stashChanges(repositoryURL: URL, message: String?) async throws {
        let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var arguments = ["stash", "push", "--include-untracked"]
        if !normalizedMessage.isEmpty {
            arguments += ["--message", normalizedMessage]
        }
        _ = try await runGit(
            arguments,
            operation: .stash,
            repositoryURL: repositoryURL,
            redacting: normalizedMessage.isEmpty ? [] : [normalizedMessage]
        )
    }

    func listStashes(repositoryURL: URL) async throws -> [GitStash] {
        let result = try await runGit(
            ["stash", "list", "--format=%H%x00%gd%x00%gs"],
            operation: .stash,
            repositoryURL: repositoryURL
        )
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            let message = fields.count > 2 ? String(fields[2]) : String(fields[1])
            return GitStash(reference: String(fields[1]), message: message, hash: String(fields[0]))
        }
    }

    func unstashChanges(repositoryURL: URL, stash: GitStash) async throws {
        _ = try await runGit(
            ["stash", "pop", stash.reference],
            operation: .unstash,
            repositoryURL: repositoryURL
        )
    }

    func dropStash(repositoryURL: URL, stash: GitStash) async throws {
        _ = try await runGit(
            ["stash", "drop", stash.reference],
            operation: .dropStash,
            repositoryURL: repositoryURL
        )
    }

    func rollbackChanges(repositoryURL: URL, changes: [GitChangeSelection]) async throws {
        let paths = Array(Set(changes.flatMap { [$0.path, $0.originalPath].compactMap { $0 } }.filter {
            !$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..")
        })).sorted()
        let untrackedPaths = Set(changes.filter { $0.kind == .unversioned }.map(\.path))
        let trackedPaths = paths.filter { !untrackedPaths.contains($0) }

        if !trackedPaths.isEmpty {
            _ = try await runGit(
                ["restore", "--source=HEAD", "--staged", "--worktree", "--"] + trackedPaths,
                operation: .rollback,
                repositoryURL: repositoryURL
            )
        }

        for path in untrackedPaths.sorted() {
            let fileURL = repositoryURL.appendingPathComponent(path).standardizedFileURL
            let repositoryRoot = repositoryURL.standardizedFileURL
            let prefix = repositoryRoot.path.hasSuffix("/") ? repositoryRoot.path : repositoryRoot.path + "/"
            guard fileURL.path.hasPrefix(prefix) else { continue }
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                throw GitRepositoryOperationError.commandFailed(
                    operation: .rollback,
                    message: "无法删除未跟踪文件 (path)：(error.localizedDescription)"
                )
            }
        }
    }

    func pushCurrentBranch(repositoryURL: URL) async throws {
        _ = try await pushCurrentBranchOutcome(repositoryURL: repositoryURL)
    }

    func pushCurrentBranchOutcome(repositoryURL: URL) async throws -> GitPushOutcome {
        let result = try await runGit(
            ["push", "--porcelain"],
            operation: .push,
            repositoryURL: repositoryURL
        )
        let output = String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
        return output.contains("[up to date]") || output.contains("Everything up-to-date")
            ? .upToDate
            : .pushed
    }

    func push(
        repositoryURL: URL,
        localBranch: String,
        remote: String,
        remoteBranch: String,
        setUpstream: Bool
    ) async throws -> GitPushOutcome {
        let validation = try await runGit(
            ["check-ref-format", "--branch", remoteBranch],
            operation: .push,
            repositoryURL: repositoryURL,
            allowedStatuses: [0, 1]
        )
        guard validation.terminationStatus == 0 else {
            throw GitRepositoryOperationError.invalidPushTarget(remoteBranch)
        }
        var arguments = ["push", "--porcelain"]
        if setUpstream {
            arguments.append("--set-upstream")
        }
        arguments.append(contentsOf: [
            remote,
            "refs/heads/\(localBranch):refs/heads/\(remoteBranch)"
        ])
        let result = try await runGit(
            arguments,
            operation: .push,
            repositoryURL: repositoryURL
        )
        let output = String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
        return output.contains("[up to date]") || output.contains("Everything up-to-date")
            ? .upToDate
            : .pushed
    }

    func pushBranch(repositoryURL: URL, branch: GitBranch) async throws {
        guard let upstream = branch.upstream else {
            throw GitRepositoryOperationError.missingUpstream(branch.name)
        }
        let components = upstream.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else {
            throw GitRepositoryOperationError.missingUpstream(branch.name)
        }
        let remote = String(components[0])
        let remoteBranch = String(components[1])
        _ = try await runGit(
            ["push", remote, "\(branch.name):refs/heads/\(remoteBranch)"],
            operation: .push,
            repositoryURL: repositoryURL
        )
    }

    @discardableResult
    func mergeBranch(repositoryURL: URL, branch: GitBranch) async throws -> GitMergeOutcome {
        let result = try await runGit(["merge", "--no-edit", branch.name], operation: .merge, repositoryURL: repositoryURL)
        // runGit fixes LC_ALL to C, so Git's no-op result has a stable message.
        let lines = String(decoding: result.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        return lines.contains("Already up to date.") ? .upToDate : .merged
    }

    func renameBranch(repositoryURL: URL, branch: GitBranch, to newName: String) async throws {
        _ = try await runGit(["branch", "--move", branch.name, newName], operation: .rename, repositoryURL: repositoryURL)
    }

    func deleteBranch(repositoryURL: URL, branch: GitBranch) async throws {
        _ = try await runGit(["branch", "--delete", branch.name], operation: .delete, repositoryURL: repositoryURL)
    }

    func abortMerge(repositoryURL: URL) async throws {
        _ = try await runGit(["merge", "--abort"], operation: .abortMerge, repositoryURL: repositoryURL)
    }

    func continueMerge(repositoryURL: URL) async throws {
        _ = try await runGit(["-c", "core.editor=true", "merge", "--continue"], operation: .continueMerge, repositoryURL: repositoryURL)
    }

    func conflictFiles(repositoryURL: URL) async throws -> [GitConflictFile] {
        let result = try await runGit(
            ["diff", "--name-only", "--diff-filter=U", "-z"],
            operation: .resolveConflict,
            repositoryURL: repositoryURL
        )
        let paths = result.standardOutput.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [GitConflictFile] = []
        for path in paths {
            let baseData = try await conflictBlob(stage: 1, path: path, repositoryURL: repositoryURL)
            let oursData = try await conflictBlob(stage: 2, path: path, repositoryURL: repositoryURL)
            let theirsData = try await conflictBlob(stage: 3, path: path, repositoryURL: repositoryURL)
            let fileURL = repositoryURL.appendingPathComponent(path)
            let resultData = try? Data(contentsOf: fileURL)
            let isBinary = [baseData, oursData, theirsData, resultData]
                .compactMap { $0 }
                .contains(where: Self.isBinaryData)
            let result = resultData.flatMap(Self.text(from:)) ?? ""
            files.append(
                GitConflictFile(
                    path: path,
                    ours: Self.text(from: oursData) ?? "",
                    theirs: Self.text(from: theirsData) ?? "",
                    result: result,
                    isResolved: false,
                    base: Self.text(from: baseData),
                    baseData: isBinary ? baseData : nil,
                    oursData: isBinary ? oursData : nil,
                    theirsData: isBinary ? theirsData : nil,
                    resultData: isBinary ? resultData : nil,
                    hasBase: baseData != nil,
                    hasOurs: oursData != nil,
                    hasTheirs: theirsData != nil,
                    isBinary: isBinary
                )
            )
        }
        return files
    }

    func resolveConflict(repositoryURL: URL, file: GitConflictFile) async throws {
        let fileURL = repositoryURL.appendingPathComponent(file.path)
        if let resultData = file.resultData {
            try resultData.write(to: fileURL, options: .atomic)
        } else {
            try file.result.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        _ = try await runGit(["add", "--", file.path], operation: .resolveConflict, repositoryURL: repositoryURL)
    }

    func saveConflictProgress(repositoryURL: URL, file: GitConflictFile) async throws {
        let fileURL = repositoryURL.appendingPathComponent(file.path)
        try file.result.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func restoreConflictProgress(repositoryURL: URL, file: GitConflictFile) async throws {
        _ = try await runGit(
            ["checkout", "--conflict=merge", "--", file.path],
            operation: .resolveConflict,
            repositoryURL: repositoryURL
        )
    }

    private func conflictBlob(stage: Int, path: String, repositoryURL: URL) async throws -> Data? {
        let result = try await runGit(
            ["show", ":\(stage):\(path)"],
            operation: .resolveConflict,
            repositoryURL: repositoryURL,
            allowedStatuses: [0, 128]
        )
        return result.terminationStatus == 0 ? result.standardOutput : nil
    }

    private static func text(from data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isBinaryData(_ data: Data) -> Bool {
        data.contains(0) || String(data: data, encoding: .utf8) == nil
    }

    func switchBranch(
        repositoryURL: URL,
        branch: GitBranch
    ) async throws {
        guard branch.isRemote else {
            _ = try await runGit(
                ["switch", branch.name],
                operation: .switchBranch,
                repositoryURL: repositoryURL
            )
            return
        }

        let localBranchName = try localBranchName(forRemoteBranch: branch.name)
        let localRef = "refs/heads/\(localBranchName)"
        let localBranchResult = try await runGit(
            ["show-ref", "--verify", "--quiet", localRef],
            operation: .resolveBranch,
            repositoryURL: repositoryURL,
            allowedStatuses: [0, 1]
        )

        if localBranchResult.terminationStatus == 0 {
            _ = try await runGit(
                ["switch", localBranchName],
                operation: .switchBranch,
                repositoryURL: repositoryURL
            )
            return
        }

        _ = try await runGit(
            ["switch", "--track", "--create", localBranchName, branch.name],
            operation: .switchBranch,
            repositoryURL: repositoryURL
        )
    }

    private func localBranchName(forRemoteBranch name: String) throws -> String {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.last != "HEAD",
              components.dropFirst().allSatisfy({ !$0.isEmpty }) else {
            throw GitRepositoryOperationError.invalidRemoteBranch(name)
        }
        return components.dropFirst().joined(separator: "/")
    }

    private func runGit(
        _ arguments: [String],
        operation: GitRepositoryOperation,
        repositoryURL: URL,
        allowedStatuses: Set<Int32> = [0],
        redacting secrets: [String] = []
    ) async throws -> CommandResult {
        let result = try await commandRunner.run(
            CommandRequest(
                executableURL: gitURL,
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: gitEnvironment
            )
        )
        guard allowedStatuses.contains(result.terminationStatus) else {
            throw GitRepositoryOperationError.commandFailed(
                operation: operation,
                message: failureMessage(from: result, redacting: secrets)
            )
        }
        return result
    }

    private func failureMessage(from result: CommandResult, redacting secrets: [String]) -> String {
        let data = result.standardError.isEmpty ? result.standardOutput : result.standardError
        var message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for secret in secrets where !secret.isEmpty {
            message = message.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return message.isEmpty ? "Git 未返回错误信息。" : message
    }

    private var gitEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }
}
