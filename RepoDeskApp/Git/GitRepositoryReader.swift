import Foundation

protocol GitRepositoryReading: Sendable {
    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot
    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff
    func history(
        repositoryURL: URL,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary]
    func fileHistory(
        repositoryURL: URL,
        path: String,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary]
    func searchHistory(
        repositoryURL: URL,
        hashPrefix: String,
        path: String?,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary]
    func branches(repositoryURL: URL) async throws -> [GitBranch]
    func authors(repositoryURL: URL) async throws -> [String]
    func currentUserName(repositoryURL: URL) async throws -> String?
    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail
    func pushPreparation(
        repositoryURL: URL,
        targetRemoteBranch: String?
    ) async throws -> GitPushPreparation
    func pushCommitRange(
        repositoryURL: URL,
        commits: [GitCommitSummary]
    ) async throws -> GitPushCommitRange
    func mergeFileDiff(
        repositoryURL: URL,
        hash: String,
        parentHashes: [String],
        file: GitCommitFile,
        ignoringWhitespace: Bool
    ) async throws -> GitMergeFileDiff
    func compareBranches(repositoryURL: URL, base: String, compared: String) async throws -> GitBranchComparison
    func blame(
        repositoryURL: URL,
        path: String,
        revision: String,
        contentsPath: String?
    ) async throws -> [GitBlameLine]
}

extension GitRepositoryReading {
    func searchHistory(
        repositoryURL: URL,
        hashPrefix: String,
        path: String?,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] {
        let prefix = hashPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.isEmpty, prefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              limit > 0, skip >= 0 else { return [] }
        var matches: [GitCommitSummary] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page: [GitCommitSummary]
            if let path {
                page = try await fileHistory(
                    repositoryURL: repositoryURL, path: path, limit: 200, skip: offset,
                    revision: revision, author: author
                )
            } else {
                page = try await history(
                    repositoryURL: repositoryURL, limit: 200, skip: offset,
                    revision: revision, author: author
                )
            }
            matches.append(contentsOf: page.filter { $0.hash.lowercased().hasPrefix(prefix) })
            if page.count < 200 || matches.count >= skip + limit { break }
            offset += page.count
        }
        return Array(matches.dropFirst(skip).prefix(limit))
    }

    func fileHistory(
        repositoryURL: URL,
        path: String,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] {
        try await history(
            repositoryURL: repositoryURL,
            limit: limit,
            skip: skip,
            revision: revision,
            author: author
        )
    }

    func currentUserName(repositoryURL: URL) async throws -> String? { nil }
    func pushPreparation(
        repositoryURL: URL,
        targetRemoteBranch: String?
    ) async throws -> GitPushPreparation {
        throw GitRepositoryError.pushPreparationUnavailable
    }
    func pushCommitRange(
        repositoryURL: URL,
        commits: [GitCommitSummary]
    ) async throws -> GitPushCommitRange {
        throw GitRepositoryError.pushPreparationUnavailable
    }
    func mergeFileDiff(
        repositoryURL: URL,
        hash: String,
        parentHashes: [String],
        file: GitCommitFile,
        ignoringWhitespace: Bool
    ) async throws -> GitMergeFileDiff {
        throw GitRepositoryError.unsupportedMergeParentCount(parentHashes.count)
    }
    func compareBranches(repositoryURL: URL, base: String, compared: String) async throws -> GitBranchComparison {
        GitBranchComparison(baseBranch: base, comparedBranch: compared, commits: [], diffText: "")
    }
    func blame(
        repositoryURL: URL,
        path: String,
        revision: String,
        contentsPath: String?
    ) async throws -> [GitBlameLine] { [] }
}

enum GitRepositoryError: LocalizedError {
    case commandFailed(arguments: [String], message: String)
    case unsupportedMergeParentCount(Int)
    case pushPreparationUnavailable

    var errorDescription: String? {
        switch self {
        case .commandFailed(let arguments, let message):
            "git \(arguments.joined(separator: " ")) failed: \(message)"
        case .unsupportedMergeParentCount(let count):
            "暂不支持 \(count) 个父提交的 Merge Diff。"
        case .pushPreparationUnavailable:
            "当前 Repository 无法生成 Push 预览。"
        }
    }
}

struct SystemGitRepositoryReader: GitRepositoryReading {
    private static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    private static let maximumInitialDiffBlobBytes = 8 * 1_048_576

    private let commandRunner: any CommandRunning
    private let gitURL: URL
    private let diagnosticLogger: AppDiagnosticLogger

    init(
        commandRunner: any CommandRunning = SystemCommandRunner(),
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        diagnosticLogger: AppDiagnosticLogger = .shared
    ) {
        self.commandRunner = commandRunner
        self.gitURL = gitURL
        self.diagnosticLogger = diagnosticLogger
    }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        let traceID = String(UUID().uuidString.prefix(8))
        let repository = diagnosticField(repositoryURL.standardizedFileURL.path)
        let clock = ContinuousClock()
        let startedAt = clock.now
        await diagnosticLogger.record(
            "git-snapshot start trace=\(traceID) repository=\(repository)"
        )

        do {
            async let statusResult = runSnapshotGit(
                operation: "status",
                arguments: [
                    "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"
                ],
                repositoryURL: repositoryURL,
                traceID: traceID
            )
            async let commitResult = runSnapshotGit(
                operation: "last-commit",
                arguments: ["log", "-1", "--format=%H%x00%s%x00%an%x00%aI"],
                repositoryURL: repositoryURL,
                traceID: traceID,
                allowsEmptyOutput: true
            )
            async let stagedNameStatusResult = runSnapshotGit(
                operation: "staged-diff",
                arguments: [
                    "diff", "--cached", "--name-status", "-z", "-M", "-C",
                    "--find-copies-harder"
                ],
                repositoryURL: repositoryURL,
                traceID: traceID,
                allowsEmptyOutput: true
            )

            let status = GitStatusParser.parse(try await statusResult)
            let commit = parseCommit(try await commitResult)
            let stagedFiles = parseCommitFiles(try await stagedNameStatusResult)
            let changes = applyDetectedStagedMoves(stagedFiles, to: status.changes)
            let snapshot = GitRepositorySnapshot(
                branch: status.branch,
                isDetachedHEAD: status.isDetachedHEAD,
                aheadCount: status.aheadCount,
                behindCount: status.behindCount,
                changes: changes,
                lastCommit: commit
            )
            await diagnosticLogger.record(
                "git-snapshot end trace=\(traceID) repository=\(repository) "
                    + "duration=\(diagnosticDuration(startedAt.duration(to: clock.now)))s"
            )
            return snapshot
        } catch {
            await diagnosticLogger.record(
                "git-snapshot error trace=\(traceID) repository=\(repository) "
                    + "duration=\(diagnosticDuration(startedAt.duration(to: clock.now)))s "
                    + "errorType=\(diagnosticField(String(reflecting: type(of: error))))"
            )
            throw error
        }
    }

    private func runSnapshotGit(
        operation: String,
        arguments: [String],
        repositoryURL: URL,
        traceID: String,
        allowsEmptyOutput: Bool = false
    ) async throws -> Data {
        let repository = diagnosticField(repositoryURL.standardizedFileURL.path)
        let clock = ContinuousClock()
        let startedAt = clock.now
        await diagnosticLogger.record(
            "git-snapshot-command start trace=\(traceID) repository=\(repository) "
                + "operation=\(operation)"
        )
        do {
            let data = try await runGit(
                arguments,
                in: repositoryURL,
                allowsEmptyOutput: allowsEmptyOutput
            )
            await diagnosticLogger.record(
                "git-snapshot-command end trace=\(traceID) repository=\(repository) "
                    + "operation=\(operation) "
                    + "duration=\(diagnosticDuration(startedAt.duration(to: clock.now)))s"
            )
            return data
        } catch {
            await diagnosticLogger.record(
                "git-snapshot-command error trace=\(traceID) repository=\(repository) "
                    + "operation=\(operation) "
                    + "duration=\(diagnosticDuration(startedAt.duration(to: clock.now)))s "
                    + "errorType=\(diagnosticField(String(reflecting: type(of: error))))"
            )
            throw error
        }
    }

    private func diagnosticDuration(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        return String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            seconds
        )
    }

    private func diagnosticField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: " ", with: "\\s")
    }


    func fileDiff(
        repositoryURL: URL,
        target: GitDiffTarget,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        switch target {
        case .change(let selection):
            return try await changedFileDiff(
                repositoryURL: repositoryURL,
                selection: selection,
                ignoringWhitespace: ignoringWhitespace
            )
        case .commit(let hash, let file):
            return try await committedFileDiff(
                repositoryURL: repositoryURL,
                hash: hash,
                file: file,
                ignoringWhitespace: ignoringWhitespace
            )
        case .revisionRange(let base, let head, let file):
            return try await revisionRangeFileDiff(
                repositoryURL: repositoryURL,
                base: base,
                head: head,
                file: file,
                ignoringWhitespace: ignoringWhitespace
            )
        }
    }

    func compareBranches(repositoryURL: URL, base: String, compared: String) async throws -> GitBranchComparison {
        async let logResult = commandRunner.run(CommandRequest(
            executableURL: gitURL,
            arguments: ["log", "--left-right", "--format=%m%x00%H%x00%s%x00%an%x00%aI", "--no-merges", "\(base)...\(compared)"],
            workingDirectoryURL: repositoryURL,
            environment: gitEnvironment
        ))
        async let diffResult = commandRunner.run(CommandRequest(
            executableURL: gitURL,
            arguments: ["diff", "--no-color", "--unified=3", base, compared],
            workingDirectoryURL: repositoryURL,
            environment: gitEnvironment
        ))
        let log = try await logResult
        let diff = try await diffResult
        guard log.terminationStatus == 0, diff.terminationStatus == 0 else {
            throw GitRepositoryError.commandFailed(arguments: ["compare", base, compared], message: "无法比较分支。")
        }
        let fields = String(decoding: log.standardOutput, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> GitCommitSummary? in
                let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
                guard parts.count >= 5 else { return nil }
                let side = String(parts[0]) == "<" ? base : compared
                return GitCommitSummary(hash: String(parts[1]), subject: String(parts[2]), author: String(parts[3]), authoredAt: ISO8601DateFormatter().date(from: String(parts[4])), refs: [side])
            }
        return GitBranchComparison(baseBranch: base, comparedBranch: compared, commits: fields, diffText: String(decoding: diff.standardOutput, as: UTF8.self))
    }

    func blame(
        repositoryURL: URL,
        path: String,
        revision: String,
        contentsPath: String?
    ) async throws -> [GitBlameLine] {
        var arguments = ["blame", "--line-porcelain"]
        if let contentsPath {
            arguments.append(contentsOf: ["--contents", contentsPath])
        } else {
            arguments.append(revision)
        }
        arguments.append(contentsOf: ["--", path])
        let data = try await runGit(arguments, in: repositoryURL, allowsEmptyOutput: true)
        let lines = GitBlameParser.parse(data)
        let hashes = Set(lines.lazy.filter { !$0.isUncommitted }.map(\.commitHash)).sorted()
        var messages: [String: String] = [:]
        // Fetch full messages once per commit, in bounded batches rather than per annotated line.
        for start in stride(from: 0, to: hashes.count, by: 256) {
            let batch = Array(hashes[start..<min(start + 256, hashes.count)])
            let metadata = try await runGit(
                ["log", "--no-walk=unsorted", "--format=%H%x00%B%x00"] + batch + ["--"],
                in: repositoryURL, allowsEmptyOutput: true
            )
            let fields = String(decoding: metadata, as: UTF8.self)
                .split(separator: "\0", omittingEmptySubsequences: false)
            for index in stride(from: 0, to: max(0, fields.count - 1), by: 2) {
                let hash = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                messages[hash] = fields[index + 1].trimmingCharacters(in: .newlines)
            }
        }
        return lines.map { line in
            GitBlameLine(lineNumber: line.lineNumber, commitHash: line.commitHash,
                         author: line.author, authoredAt: line.authoredAt,
                         authorEmail: line.authorEmail, message: messages[line.commitHash] ?? line.message)
        }
    }

    private func loadHistory(
        repositoryURL: URL,
        path: String?,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] {
        var arguments = ["log"]
        if path != nil {
            arguments.append("--follow")
        }
        arguments.append(contentsOf: [
            "--max-count=\(limit)", "--skip=\(skip)",
            "--format=%x1e%H%x1f%s%x1f%an%x1f%aI%x1f%D"
        ])
        if let author {
            arguments.append("--extended-regexp")
            arguments.append("--author=^\(escapedExtendedRegularExpression(author)) <")
        }
        if let revision { arguments.append(revision) }
        if let path {
            arguments.append(contentsOf: ["--", path])
        }
        let data = try await runGit(
            arguments,
            in: repositoryURL,
            allowsEmptyOutput: true
        )
        return GitHistoryParser.parse(data)
    }

    private func changedFileDiff(
        repositoryURL: URL,
        selection: GitChangeSelection,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        var arguments = [
            "diff", "--no-ext-diff", "--no-color", "-M", "-C", "--find-copies-harder"
        ]
        arguments.append("--unified=3")
        if ignoringWhitespace {
            arguments.append("--ignore-all-space")
        }
        if selection.kind == .unversioned {
            arguments.append(contentsOf: ["--no-index", "--", "/dev/null", selection.path])
        } else {
            arguments.append(try await workingTreeBaseRevision(repositoryURL: repositoryURL))
            arguments.append("--")
            if let originalPath = selection.originalPath {
                arguments.append(originalPath)
            }
            arguments.append(selection.path)
        }

        let result = try await commandRunner.run(
            CommandRequest(
                executableURL: gitURL,
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: gitEnvironment
            )
        )
        let allowedStatus: Int32 = selection.kind == .unversioned ? 1 : 0
        guard result.terminationStatus == 0 || result.terminationStatus == allowedStatus else {
            throw GitRepositoryError.commandFailed(
                arguments: arguments,
                message: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let patch = String(decoding: result.standardOutput, as: UTF8.self)
        let oldPath = selection.originalPath ?? selection.path
        let oldData: Data?
        let newData: Data?
        let oldLabel: String
        let newLabel: String
        switch selection.kind {
        case .changes:
            oldData = try await readBlob("HEAD:\(oldPath)", repositoryURL: repositoryURL)
            newData = try readWorkingFile(selection.path, repositoryURL: repositoryURL)
            oldLabel = "HEAD"
            newLabel = "Working Tree"
        case .unversioned:
            oldData = nil
            newData = try readWorkingFile(selection.path, repositoryURL: repositoryURL)
            oldLabel = "Empty"
            newLabel = "Working Tree"
        }
        return makeFileDiff(
            path: selection.path,
            originalPath: selection.originalPath,
            oldLabel: oldLabel,
            newLabel: newLabel,
            oldData: oldData,
            newData: newData,
            patch: patch
        )
    }

    private func workingTreeBaseRevision(repositoryURL: URL) async throws -> String {
        let headArguments = ["rev-parse", "--verify", "HEAD^{tree}"]
        let headResult = try await commandRunner.run(
            CommandRequest(
                executableURL: gitURL,
                arguments: headArguments,
                workingDirectoryURL: repositoryURL,
                environment: gitEnvironment
            )
        )
        if headResult.terminationStatus == 0 {
            return "HEAD"
        }

        let emptyTreeArguments = ["hash-object", "-t", "tree", "/dev/null"]
        let emptyTreeResult = try await commandRunner.run(
            CommandRequest(
                executableURL: gitURL,
                arguments: emptyTreeArguments,
                workingDirectoryURL: repositoryURL,
                environment: gitEnvironment
            )
        )
        guard emptyTreeResult.terminationStatus == 0 else {
            let message = String(decoding: headResult.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitRepositoryError.commandFailed(arguments: headArguments, message: message)
        }
        return String(decoding: emptyTreeResult.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func committedFileDiff(
        repositoryURL: URL,
        hash: String,
        file: GitCommitFile,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        var arguments = [
            "show", "--no-ext-diff", "--no-textconv", "--no-color", "--format=", "--unified=3"
        ]
        if ignoringWhitespace {
            arguments.append("--ignore-all-space")
        }
        arguments.append(hash)
        arguments.append("--")
        if let originalPath = file.originalPath {
            arguments.append(originalPath)
        }
        arguments.append(file.path)
        let patch = String(
            decoding: try await runGit(arguments, in: repositoryURL, allowsEmptyOutput: true),
            as: UTF8.self
        )
        let oldPath = file.originalPath ?? file.path
        async let oldData = readBlobIfReasonable(
            "\(hash)^:\(oldPath)",
            repositoryURL: repositoryURL
        )
        async let newData = readBlobIfReasonable(
            "\(hash):\(file.path)",
            repositoryURL: repositoryURL
        )
        let parsedHunks = GitDiffParser.parseHunks(patch)
        let oldLineCount = parsedHunks.map {
            $0.oldStart + max($0.oldCount, 1) - 1
        }.max() ?? 0
        let newLineCount = parsedHunks.map {
            $0.newStart + max($0.newCount, 1) - 1
        }.max() ?? 0
        return makeFileDiff(
            path: file.path,
            originalPath: file.originalPath,
            oldLabel: "\(hash.prefix(8))^",
            newLabel: String(hash.prefix(8)),
            oldData: try await oldData,
            newData: try await newData,
            oldLineCount: oldLineCount,
            newLineCount: newLineCount,
            patch: patch,
            hunks: parsedHunks
        )
    }

    private func revisionRangeFileDiff(
        repositoryURL: URL,
        base: String?,
        head: String,
        file: GitCommitFile,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        let diffBase = base ?? Self.emptyTreeHash
        var arguments = [
            "diff", "--no-ext-diff", "--no-textconv", "--no-color", "-M",
            "--unified=3"
        ]
        if ignoringWhitespace {
            arguments.append("--ignore-all-space")
        }
        arguments.append(contentsOf: [diffBase, head, "--"])
        if let originalPath = file.originalPath {
            arguments.append(originalPath)
        }
        arguments.append(file.path)
        let patch = String(
            decoding: try await runGit(arguments, in: repositoryURL, allowsEmptyOutput: true),
            as: UTF8.self
        )
        let oldPath = file.originalPath ?? file.path
        async let oldData = readRangeBlobIfReasonable(
            revision: base == nil ? nil : diffBase,
            path: oldPath,
            repositoryURL: repositoryURL
        )
        async let newData = readBlobIfReasonable(
            "\(head):\(file.path)",
            repositoryURL: repositoryURL
        )
        let parsedHunks = GitDiffParser.parseHunks(patch)
        let oldLineCount = parsedHunks.map {
            $0.oldStart + max($0.oldCount, 1) - 1
        }.max() ?? 0
        let newLineCount = parsedHunks.map {
            $0.newStart + max($0.newCount, 1) - 1
        }.max() ?? 0
        return makeFileDiff(
            path: file.path,
            originalPath: file.originalPath,
            oldLabel: base.map { String($0.prefix(8)) } ?? "Empty",
            newLabel: String(head.prefix(8)),
            oldData: try await oldData,
            newData: try await newData,
            oldLineCount: oldLineCount,
            newLineCount: newLineCount,
            patch: patch,
            hunks: parsedHunks
        )
    }

    func mergeFileDiff(
        repositoryURL: URL,
        hash: String,
        parentHashes: [String],
        file: GitCommitFile,
        ignoringWhitespace: Bool
    ) async throws -> GitMergeFileDiff {
        guard parentHashes.count == 2 else {
            throw GitRepositoryError.unsupportedMergeParentCount(parentHashes.count)
        }
        async let target = committedFileDiff(
            repositoryURL: repositoryURL,
            baseHash: parentHashes[0],
            hash: hash,
            file: file,
            ignoringWhitespace: ignoringWhitespace
        )
        async let source = committedFileDiff(
            repositoryURL: repositoryURL,
            baseHash: parentHashes[1],
            hash: hash,
            file: file,
            ignoringWhitespace: ignoringWhitespace
        )
        return try await GitMergeFileDiff(target: target, source: source)
    }

    private func committedFileDiff(
        repositoryURL: URL,
        baseHash: String,
        hash: String,
        file: GitCommitFile,
        ignoringWhitespace: Bool
    ) async throws -> GitFileDiff {
        var arguments = [
            "diff", "--no-ext-diff", "--no-color", "--unified=3"
        ]
        if ignoringWhitespace {
            arguments.append("--ignore-all-space")
        }
        arguments.append(contentsOf: [baseHash, hash, "--"])
        if let originalPath = file.originalPath {
            arguments.append(originalPath)
        }
        arguments.append(file.path)
        let patch = String(
            decoding: try await runGit(arguments, in: repositoryURL, allowsEmptyOutput: true),
            as: UTF8.self
        )
        let oldPath = file.originalPath ?? file.path
        async let oldData = readBlob("\(baseHash):\(oldPath)", repositoryURL: repositoryURL)
        async let newData = readBlob("\(hash):\(file.path)", repositoryURL: repositoryURL)
        return try await makeFileDiff(
            path: file.path,
            originalPath: file.originalPath,
            oldLabel: String(baseHash.prefix(8)),
            newLabel: String(hash.prefix(8)),
            oldData: oldData,
            newData: newData,
            patch: patch
        )
    }

    func history(
        repositoryURL: URL,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] {
        try await loadHistory(
            repositoryURL: repositoryURL,
            path: nil,
            limit: limit,
            skip: skip,
            revision: revision,
            author: author
        )
    }

    func searchHistory(
        repositoryURL: URL,
        hashPrefix: String,
        path: String?,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] {
        let prefix = hashPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.isEmpty, prefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              limit > 0, skip >= 0 else { return [] }

        // Enumerate hashes in the filtered history before paginating matches. Loading only
        // hashes keeps repository-wide searches small even when the target is very old.
        var arguments = ["log", "--format=%H"]
        if path != nil { arguments.append("--follow") }
        if let author {
            arguments.append(contentsOf: [
                "--extended-regexp", "--author=^\(escapedExtendedRegularExpression(author)) <"
            ])
        }
        if let revision { arguments.append(revision) }
        if let path { arguments.append(contentsOf: ["--", path]) }
        let data = try await runGit(arguments, in: repositoryURL, allowsEmptyOutput: true)
        try Task.checkCancellation()
        let hashes = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .lazy.filter { $0.hasPrefix(prefix) }.dropFirst(skip).prefix(limit).map(String.init)
        guard !hashes.isEmpty else { return [] }
        let summaries = try await runGit(
            ["show", "--no-patch", "--no-walk=unsorted", "--format=%x1e%H%x1f%s%x1f%an%x1f%aI%x1f%D"]
                + hashes + ["--"],
            in: repositoryURL,
            allowsEmptyOutput: true
        )
        return GitHistoryParser.parse(summaries)
    }

    func fileHistory(
        repositoryURL: URL,
        path: String,
        limit: Int,
        skip: Int,
        revision: String?,
        author: String?
    ) async throws -> [GitCommitSummary] {
        try await loadHistory(
            repositoryURL: repositoryURL,
            path: path,
            limit: limit,
            skip: skip,
            revision: revision,
            author: author
        )
    }

    func branches(repositoryURL: URL) async throws -> [GitBranch] {
        let data = try await runGit(
            [
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(upstream:short)%00%(HEAD)",
                "refs/heads", "refs/remotes"
            ],
            in: repositoryURL
        )
        return parseBranches(data)
    }

    func pushPreparation(
        repositoryURL: URL,
        targetRemoteBranch: String?
    ) async throws -> GitPushPreparation {
        let localBranchData = try await runGit(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: repositoryURL
        )
        let localBranch = decodedLine(localBranchData)
        guard !localBranch.isEmpty else {
            throw GitRepositoryError.commandFailed(
                arguments: ["symbolic-ref", "--short", "HEAD"],
                message: "Detached HEAD 状态下不能准备 Push。"
            )
        }

        let remoteData = try await runGit(["remote"], in: repositoryURL)
        let remotes = String(decoding: remoteData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard !remotes.isEmpty else {
            throw GitRepositoryError.commandFailed(
                arguments: ["remote"],
                message: "当前 Repository 没有配置远程仓库。"
            )
        }

        let upstream = try await optionalGitLine(
            ["for-each-ref", "--format=%(upstream:short)", "refs/heads/\(localBranch)"],
            in: repositoryURL
        )
        let upstreamComponents = upstream?.split(separator: "/", maxSplits: 1).map(String.init)
        let branchPushRemote = try await optionalGitLine(
            ["config", "--get", "branch.\(localBranch).pushRemote"],
            in: repositoryURL
        )
        let remotePushDefault = try await optionalGitLine(
            ["config", "--get", "remote.pushDefault"],
            in: repositoryURL
        )
        let configuredRemote = branchPushRemote ?? remotePushDefault
        let upstreamRemote = upstreamComponents?.count == 2 ? upstreamComponents?[0] : nil
        let remote = configuredRemote
            ?? upstreamRemote
            ?? (remotes.contains("origin") ? "origin" : nil)
            ?? (remotes.count == 1 ? remotes[0] : nil)
        guard let remote, remotes.contains(remote) else {
            throw GitRepositoryError.commandFailed(
                arguments: ["config", "remote.pushDefault"],
                message: "存在多个远程仓库，但当前 Branch 没有明确的 push remote。"
            )
        }

        let remoteBranchNames = try await branches(repositoryURL: repositoryURL)
            .filter { $0.isRemote && $0.name.hasPrefix("\(remote)/") && $0.name != "\(remote)/HEAD" }
            .map { String($0.name.dropFirst(remote.count + 1)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let upstreamTarget = upstreamComponents?.count == 2 && upstreamRemote == remote
            ? upstreamComponents?[1]
            : nil
        let requestedTarget = targetRemoteBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = requestedTarget?.isEmpty == false
            ? requestedTarget!
            : (upstreamTarget ?? localBranch)

        let validation = try await runGitResult(
            ["check-ref-format", "--branch", target],
            in: repositoryURL
        )
        guard validation.terminationStatus == 0 else {
            return GitPushPreparation(
                localBranch: localBranch,
                remote: remote,
                targetRemoteBranch: target,
                remoteBranches: remoteBranchNames,
                targetExists: remoteBranchNames.contains(target),
                commits: [],
                blockingMessage: "'\(target)' 不是有效的远程 Branch 名称。"
            )
        }

        let targetExists = remoteBranchNames.contains(target)
        let localRevision = "refs/heads/\(localBranch)"
        let logRevision: [String]
        var blockingMessage: String?
        if targetExists {
            let remoteRevision = "refs/remotes/\(remote)/\(target)"
            let ancestry = try await runGitResult(
                ["merge-base", "--is-ancestor", remoteRevision, localRevision],
                in: repositoryURL
            )
            if ancestry.terminationStatus == 1 {
                blockingMessage = "远程 Branch 包含当前本地 Branch 没有的提交，普通 Push 会被拒绝。请先 Pull 或合并远程改动。"
            } else if ancestry.terminationStatus != 0 {
                throw GitRepositoryError.commandFailed(
                    arguments: ["merge-base", "--is-ancestor", remoteRevision, localRevision],
                    message: decodedError(ancestry)
                )
            }
            logRevision = ["\(remoteRevision)..\(localRevision)"]
        } else {
            logRevision = [localRevision, "--not", "--remotes=\(remote)"]
        }
        let commitData = try await runGit(
            ["log", "--format=%x1e%H%x1f%s%x1f%an%x1f%aI%x1f%D"] + logRevision,
            in: repositoryURL,
            allowsEmptyOutput: true
        )
        return GitPushPreparation(
            localBranch: localBranch,
            remote: remote,
            targetRemoteBranch: target,
            remoteBranches: remoteBranchNames,
            targetExists: targetExists,
            commits: GitHistoryParser.parse(commitData),
            blockingMessage: blockingMessage
        )
    }

    func pushCommitRange(
        repositoryURL: URL,
        commits: [GitCommitSummary]
    ) async throws -> GitPushCommitRange {
        guard let newest = commits.first, let oldest = commits.last else {
            throw GitRepositoryError.commandFailed(
                arguments: ["diff"],
                message: "请至少选择一个 Commit。"
            )
        }
        let parentData = try await runGit(
            ["rev-list", "--parents", "--max-count=1", oldest.hash],
            in: repositoryURL
        )
        let revisions = decodedLine(parentData).split(whereSeparator: \.isWhitespace).map(String.init)
        let baseRevision = revisions.count > 1 ? revisions[1] : nil
        let diffBase = baseRevision ?? Self.emptyTreeHash
        let filesData = try await runGit(
            [
                "diff", "--name-status", "-z", "-M",
                diffBase, newest.hash
            ],
            in: repositoryURL,
            allowsEmptyOutput: true
        )
        return GitPushCommitRange(
            commits: commits,
            baseRevision: baseRevision,
            headRevision: newest.hash,
            files: parseCommitFiles(filesData)
        )
    }

    func authors(repositoryURL: URL) async throws -> [String] {
        let data = try await runGit(
            ["log", "--all", "--format=%an%x00"],
            in: repositoryURL,
            allowsEmptyOutput: true
        )
        return Array(
            Set(
                data.split(separator: 0, omittingEmptySubsequences: true)
                    .map {
                        String(decoding: $0, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .filter { !$0.isEmpty }
            )
        ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func currentUserName(repositoryURL: URL) async throws -> String? {
        let arguments = ["config", "--get", "user.name"]
        let result = try await commandRunner.run(
            CommandRequest(
                executableURL: gitURL,
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: gitEnvironment
            )
        )
        if result.terminationStatus == 1, result.standardOutput.isEmpty {
            return nil
        }
        guard result.terminationStatus == 0 else {
            let message = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitRepositoryError.commandFailed(arguments: arguments, message: message)
        }
        let name = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        let summaryData = try await runGit(
            ["show", "-s", "--format=%H%x00%s%x00%an%x00%aI%x00%D%x00%P", hash],
            in: repositoryURL
        )
        guard let summary = parseCommit(summaryData) else {
            throw GitRepositoryError.commandFailed(arguments: ["show", hash], message: "Commit metadata was empty")
        }
        let parentHashes = parseCommitParentHashes(summaryData)
        let fileArguments: [String]
        if parentHashes.count > 1 {
            fileArguments = [
                "diff-tree", "--root", "--cc", "--no-commit-id", "--name-status", "-r", "-z",
                hash
            ]
        } else {
            fileArguments = [
                "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z",
                "-M", "-C", "--find-copies-harder", hash
            ]
        }
        let filesData = try await runGit(fileArguments, in: repositoryURL)
        return GitCommitDetail(
            summary: summary,
            files: parseCommitFiles(filesData),
            parentHashes: parentHashes
        )
    }

    private func makeFileDiff(
        path: String,
        originalPath: String?,
        oldLabel: String,
        newLabel: String,
        oldData: Data?,
        newData: Data?,
        oldLineCount: Int? = nil,
        newLineCount: Int? = nil,
        patch: String,
        hunks: [GitDiffHunk]? = nil
    ) -> GitFileDiff {
        let isBinary = patch.contains("Binary files ")
            || patch.contains("GIT binary patch")
            || oldData?.contains(0) == true
            || newData?.contains(0) == true
        return GitFileDiff(
            path: path,
            originalPath: originalPath,
            oldLabel: oldLabel,
            newLabel: newLabel,
            oldLines: isBinary ? [] : GitDiffParser.lines(from: oldData),
            newLines: isBinary ? [] : GitDiffParser.lines(from: newData),
            oldLineCount: isBinary ? 0 : oldLineCount,
            newLineCount: isBinary ? 0 : newLineCount,
            hunks: isBinary ? [] : (hunks ?? GitDiffParser.parseHunks(patch)),
            isBinary: isBinary
        )
    }

    private func readWorkingFile(_ path: String, repositoryURL: URL) throws -> Data? {
        let fileURL = repositoryURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    private func readBlob(_ revisionAndPath: String, repositoryURL: URL) async throws -> Data? {
        let arguments = ["show", revisionAndPath]
        let result = try await commandRunner.run(
            CommandRequest(
                executableURL: gitURL,
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: gitEnvironment
            )
        )
        if result.terminationStatus == 0 {
            return result.standardOutput
        }
        let message = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let missingBlob = message.contains("does not exist")
            || message.contains("exists on disk, but not in")
            || message.contains("invalid object name")
            || message.contains("bad revision")
            || message.contains("unknown revision")
        if missingBlob { return nil }
        throw GitRepositoryError.commandFailed(arguments: arguments, message: message)
    }

    private func readRangeBlobIfReasonable(
        revision: String?,
        path: String,
        repositoryURL: URL
    ) async throws -> Data? {
        guard let revision else { return nil }
        return try await readBlobIfReasonable(
            "\(revision):\(path)",
            repositoryURL: repositoryURL
        )
    }

    private func readBlobIfReasonable(
        _ revisionAndPath: String,
        repositoryURL: URL
    ) async throws -> Data? {
        let sizeResult = try await runGitResult(
            ["cat-file", "-s", revisionAndPath],
            in: repositoryURL
        )
        guard sizeResult.terminationStatus == 0 else {
            let message = decodedError(sizeResult)
            if message.contains("does not exist")
                || message.contains("exists on disk, but not in")
                || message.contains("invalid object name")
                || message.contains("bad revision") {
                return nil
            }
            throw GitRepositoryError.commandFailed(
                arguments: ["cat-file", "-s", revisionAndPath],
                message: message
            )
        }
        let size = Int(decodedLine(sizeResult.standardOutput)) ?? .max
        guard size <= Self.maximumInitialDiffBlobBytes else { return nil }
        return try await readBlob(revisionAndPath, repositoryURL: repositoryURL)
    }

    private func runGit(
        _ arguments: [String],
        in repositoryURL: URL,
        allowsEmptyOutput: Bool = false
    ) async throws -> Data {
        let result = try await commandRunner.run(
            CommandRequest(
                executableURL: gitURL,
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: gitEnvironment
            )
        )
        guard result.terminationStatus == 0 else {
            let message = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if allowsEmptyOutput && result.terminationStatus == 128 && message.contains("does not have any commits yet") {
                return Data()
            }
            throw GitRepositoryError.commandFailed(arguments: arguments, message: message)
        }
        return result.standardOutput
    }

    private func runGitResult(
        _ arguments: [String],
        in repositoryURL: URL
    ) async throws -> CommandResult {
        try await commandRunner.run(
            CommandRequest(
                executableURL: gitURL,
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: gitEnvironment
            )
        )
    }

    private func optionalGitLine(
        _ arguments: [String],
        in repositoryURL: URL
    ) async throws -> String? {
        let result = try await runGitResult(arguments, in: repositoryURL)
        if result.terminationStatus == 1, result.standardOutput.isEmpty {
            return nil
        }
        guard result.terminationStatus == 0 else {
            throw GitRepositoryError.commandFailed(
                arguments: arguments,
                message: decodedError(result)
            )
        }
        let value = decodedLine(result.standardOutput)
        return value.isEmpty ? nil : value
    }

    private func decodedLine(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodedError(_ result: CommandResult) -> String {
        let data = result.standardError.isEmpty ? result.standardOutput : result.standardError
        let message = decodedLine(data)
        return message.isEmpty ? "Git 未返回错误信息。" : message
    }

    private func parseCommit(_ data: Data) -> GitCommitSummary? {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 4 else { return nil }
        let dateText = String(decoding: fields[3], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = fields.count > 4
            ? String(decoding: fields[4], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            : []
        return GitCommitSummary(
            hash: String(decoding: fields[0], as: UTF8.self),
            subject: String(decoding: fields[1], as: UTF8.self),
            author: String(decoding: fields[2], as: UTF8.self),
            authoredAt: ISO8601DateFormatter().date(from: dateText),
            refs: refs
        )
    }

    private func parseCommitParentHashes(_ data: Data) -> [String] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count > 5 else { return [] }
        return String(decoding: fields[5], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private var gitEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    private func parseBranches(_ data: Data) -> [GitBranch] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count >= 4 else { return nil }
                let refName = String(fields[0])
                let isRemote = refName.hasPrefix("refs/remotes/")
                let prefix = isRemote ? "refs/remotes/" : "refs/heads/"
                return GitBranch(
                    name: String(refName.dropFirst(prefix.count)),
                    hash: String(fields[1]),
                    upstream: fields[2].isEmpty ? nil : String(fields[2]),
                    isRemote: isRemote,
                    isCurrent: fields[3] == "*"
                )
            }
            .sorted {
                if $0.isRemote != $1.isRemote { return !$0.isRemote }
                if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private func parseCommitFiles(_ data: Data) -> [GitCommitFile] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var files: [GitCommitFile] = []
        var index = 0
        while index < records.count {
            let statusText = String(decoding: records[index], as: UTF8.self)
            let status = parseCommitStatus(statusText)
            guard index + 1 < records.count else { break }
            let firstPath = String(decoding: records[index + 1], as: UTF8.self)
            if status == .renamed || status == .copied, index + 2 < records.count {
                let newPath = String(decoding: records[index + 2], as: UTF8.self)
                files.append(GitCommitFile(path: newPath, originalPath: firstPath, status: status))
                index += 3
            } else {
                files.append(GitCommitFile(path: firstPath, originalPath: nil, status: status))
                index += 2
            }
        }
        return files
    }

    private func parseCommitStatus(_ statusText: String) -> GitStatusCode {
        guard statusText.count > 1,
              !statusText.dropFirst().allSatisfy(\.isNumber) else {
            return GitStatusCode(character: statusText.first)
        }
        let statuses = statusText.map { GitStatusCode(character: $0) }
        if statuses.allSatisfy({ $0 == .added }) { return .added }
        if statuses.allSatisfy({ $0 == .deleted }) { return .deleted }
        return .modified
    }

    private func escapedExtendedRegularExpression(_ value: String) -> String {
        let metacharacters = Set(".[]\\*^$+?{}|()")
        return value.reduce(into: "") { result, character in
            if metacharacters.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }

    private func applyDetectedStagedMoves(
        _ stagedFiles: [GitCommitFile],
        to changes: [GitFileChange]
    ) -> [GitFileChange] {
        var movesByPath: [String: GitCommitFile] = [:]
        for file in stagedFiles where file.status == .renamed || file.status == .copied {
            movesByPath[file.path] = file
        }
        return changes.map { change in
            guard let move = movesByPath[change.path] else { return change }
            var change = change
            change.indexStatus = move.status
            change.originalPath = move.originalPath
            return change
        }
    }
}
