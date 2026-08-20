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
    func branches(repositoryURL: URL) async throws -> [GitBranch]
    func authors(repositoryURL: URL) async throws -> [String]
    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail
    func compareBranches(repositoryURL: URL, base: String, compared: String) async throws -> GitBranchComparison
    func blame(
        repositoryURL: URL,
        path: String,
        revision: String,
        contentsPath: String?
    ) async throws -> [GitBlameLine]
}

extension GitRepositoryReading {
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

    var errorDescription: String? {
        switch self {
        case .commandFailed(let arguments, let message):
            "git \(arguments.joined(separator: " ")) failed: \(message)"
        }
    }
}

struct SystemGitRepositoryReader: GitRepositoryReading {
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
        return GitBlameParser.parse(data)
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
            "show", "--no-ext-diff", "--no-color", "--format=", "--unified=3"
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
        let oldData = try await readBlob("\(hash)^:\(oldPath)", repositoryURL: repositoryURL)
        let newData = try await readBlob("\(hash):\(file.path)", repositoryURL: repositoryURL)
        return makeFileDiff(
            path: file.path,
            originalPath: file.originalPath,
            oldLabel: "\(hash.prefix(8))^",
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
        var arguments = [
            "log", "--max-count=\(limit)", "--skip=\(skip)",
            "--format=%x1e%H%x1f%s%x1f%an%x1f%aI%x1f%D"
        ]
        if let author {
            arguments.append("--extended-regexp")
            arguments.append("--author=^\(escapedExtendedRegularExpression(author)) <")
        }
        if let revision { arguments.append(revision) }
        let data = try await runGit(
            arguments,
            in: repositoryURL,
            allowsEmptyOutput: true
        )
        return GitHistoryParser.parse(data)
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

    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        async let summaryData = runGit(
            ["show", "-s", "--format=%H%x00%s%x00%an%x00%aI%x00%D", hash],
            in: repositoryURL
        )
        async let filesData = runGit(
            [
                "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z",
                "-M", "-C", "--find-copies-harder", hash
            ],
            in: repositoryURL
        )
        guard let summary = parseCommit(try await summaryData) else {
            throw GitRepositoryError.commandFailed(arguments: ["show", hash], message: "Commit metadata was empty")
        }
        return GitCommitDetail(
            summary: summary,
            files: parseCommitFiles(try await filesData)
        )
    }

    private func makeFileDiff(
        path: String,
        originalPath: String?,
        oldLabel: String,
        newLabel: String,
        oldData: Data?,
        newData: Data?,
        patch: String
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
            hunks: isBinary ? [] : GitDiffParser.parseHunks(patch),
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
            let status = GitStatusCode(character: statusText.first)
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
