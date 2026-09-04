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
    func mergeBranch(repositoryURL: URL, branch: GitBranch) async throws
    func renameBranch(repositoryURL: URL, branch: GitBranch, to newName: String) async throws
    func deleteBranch(repositoryURL: URL, branch: GitBranch) async throws
    func abortMerge(repositoryURL: URL) async throws
    func continueMerge(repositoryURL: URL) async throws
    func conflictFiles(repositoryURL: URL) async throws -> [GitConflictFile]
    func resolveConflict(repositoryURL: URL, file: GitConflictFile) async throws
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
    func mergeBranch(repositoryURL: URL, branch: GitBranch) async throws {}
    func renameBranch(repositoryURL: URL, branch: GitBranch, to newName: String) async throws {}
    func deleteBranch(repositoryURL: URL, branch: GitBranch) async throws {}
    func abortMerge(repositoryURL: URL) async throws {}
    func continueMerge(repositoryURL: URL) async throws {}
    func conflictFiles(repositoryURL: URL) async throws -> [GitConflictFile] { [] }
    func resolveConflict(repositoryURL: URL, file: GitConflictFile) async throws {}
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

    func mergeBranch(repositoryURL: URL, branch: GitBranch) async throws {
        _ = try await runGit(["merge", "--no-edit", branch.name], operation: .merge, repositoryURL: repositoryURL)
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
            let ours = try await conflictBlob(stage: 2, path: path, repositoryURL: repositoryURL)
            let theirs = try await conflictBlob(stage: 3, path: path, repositoryURL: repositoryURL)
            let fileURL = repositoryURL.appendingPathComponent(path)
            let result = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            files.append(GitConflictFile(path: path, ours: ours, theirs: theirs, result: result, isResolved: false))
        }
        return files
    }

    func resolveConflict(repositoryURL: URL, file: GitConflictFile) async throws {
        let fileURL = repositoryURL.appendingPathComponent(file.path)
        try file.result.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try await runGit(["add", "--", file.path], operation: .resolveConflict, repositoryURL: repositoryURL)
    }

    private func conflictBlob(stage: Int, path: String, repositoryURL: URL) async throws -> String {
        let result = try await runGit(
            ["show", ":\(stage):\(path)"],
            operation: .resolveConflict,
            repositoryURL: repositoryURL,
            allowedStatuses: [0, 128]
        )
        return result.terminationStatus == 0 ? String(decoding: result.standardOutput, as: UTF8.self) : ""
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
