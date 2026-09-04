import Foundation

private struct VerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct GitReviewVerifier {
    static func main() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskGitReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        let runner = SystemCommandRunner()
        try await git(["init", "-b", "main"], runner: runner, at: repositoryURL)
        try await git(["config", "user.email", "repodesk@example.invalid"], runner: runner, at: repositoryURL)
        try await git(["config", "user.name", "RepoDesk Verification"], runner: runner, at: repositoryURL)
        try await git(["config", "status.renames", "copies"], runner: runner, at: repositoryURL)

        try write("base\n", to: repositoryURL.appendingPathComponent("conflict.txt"))
        try write("source\n", to: repositoryURL.appendingPathComponent("copy source.txt"))
        try write("mixed base\n", to: repositoryURL.appendingPathComponent("mixed.txt"))
        try write("rename base\n", to: repositoryURL.appendingPathComponent("working rename.txt"))
        try Data([0, 1, 2, 3]).write(to: repositoryURL.appendingPathComponent("binary.dat"))
        try await git(["add", "--all"], runner: runner, at: repositoryURL)
        try await git(["commit", "-m", "Initial commit"], runner: runner, at: repositoryURL)

        try write("source\n", to: repositoryURL.appendingPathComponent("committed copy.txt"))
        try await git(["mv", "working rename.txt", "committed rename.txt"], runner: runner, at: repositoryURL)
        try await git(["add", "committed copy.txt"], runner: runner, at: repositoryURL)
        try await git(["commit", "-m", "Copy and rename"], runner: runner, at: repositoryURL)
        let copyCommitHash = try await gitOutput(["rev-parse", "HEAD"], runner: runner, at: repositoryURL)

        try await git(["checkout", "-b", "other"], runner: runner, at: repositoryURL)
        try write("other\n", to: repositoryURL.appendingPathComponent("conflict.txt"))
        try await git(["add", "conflict.txt"], runner: runner, at: repositoryURL)
        try await git(["commit", "-m", "Other conflict change"], runner: runner, at: repositoryURL)
        try await git(["checkout", "main"], runner: runner, at: repositoryURL)
        try write("main\n", to: repositoryURL.appendingPathComponent("conflict.txt"))
        try await git(["add", "conflict.txt"], runner: runner, at: repositoryURL)
        try await git(["commit", "-m", "Main conflict change"], runner: runner, at: repositoryURL)
        try await git(
            ["merge", "other"],
            runner: runner,
            at: repositoryURL,
            allowedStatuses: [0, 1]
        )

        try write("staged\n", to: repositoryURL.appendingPathComponent("mixed.txt"))
        try await git(["add", "mixed.txt"], runner: runner, at: repositoryURL)
        try write("unstaged\n", to: repositoryURL.appendingPathComponent("mixed.txt"))
        try await git(["mv", "committed rename.txt", "working renamed.txt"], runner: runner, at: repositoryURL)
        try write("source\n", to: repositoryURL.appendingPathComponent("working copy.txt"))
        try await git(["add", "working copy.txt"], runner: runner, at: repositoryURL)
        let partiallyStagedPath = "partially staged addition.txt"
        try write("", to: repositoryURL.appendingPathComponent(partiallyStagedPath))
        try await git(["add", partiallyStagedPath], runner: runner, at: repositoryURL)
        try write("current content\n", to: repositoryURL.appendingPathComponent(partiallyStagedPath))
        try Data([0, 1, 9, 3]).write(to: repositoryURL.appendingPathComponent("binary.dat"))
        let specialPath = "line\nbreak.txt"
        let specialURL = repositoryURL.appendingPathComponent(specialPath)
        try write("one\n", to: specialURL)

        let reader = SystemGitRepositoryReader()
        let firstSnapshot = try await reader.snapshot(repositoryURL: repositoryURL)
        try require(firstSnapshot.changes.contains(where: { $0.isConflicted && $0.path == "conflict.txt" }), "Conflict status was not parsed")
        try require(firstSnapshot.changes.contains(where: { $0.indexStatus == .renamed && $0.originalPath == "committed rename.txt" }), "Working rename was not parsed")
        try require(firstSnapshot.changes.contains(where: { $0.indexStatus == .copied && $0.path == "working copy.txt" }), "Working copy was not parsed")
        try require(firstSnapshot.changes.contains(where: { $0.path == specialPath && $0.isUntracked }), "Special untracked filename was not preserved")
        try require(firstSnapshot.changes.contains(where: { $0.path == "mixed.txt" && $0.isStaged && $0.isUnstaged }), "Mixed staged and unstaged status was not parsed")
        try require(
            firstSnapshot.changes.contains {
                $0.path == partiallyStagedPath
                    && $0.indexStatus == .added
                    && $0.workTreeStatus == .modified
                    && $0.presentationKind == .changes
            },
            "Partially staged addition was not parsed as AM"
        )
        try require(
            firstSnapshot.changes.filter { $0.path == partiallyStagedPath }.count == 1,
            "Partially staged addition should be represented by one Changes item"
        )
        let legacySelection = try JSONDecoder().decode(
            GitChangeSelection.self,
            from: Data("{\"path\":\"legacy.txt\",\"kind\":\"Untracked\"}".utf8)
        )
        try require(
            legacySelection.kind == .unversioned,
            "Legacy Untracked selection did not migrate to Unversioned Files"
        )

        let partiallyStagedDiff = try await reader.fileDiff(
            repositoryURL: repositoryURL,
            target: .change(
                GitChangeSelection(path: partiallyStagedPath, kind: .changes)
            ),
            ignoringWhitespace: false
        )
        try require(partiallyStagedDiff.oldLines.isEmpty, "AM diff should start from an empty HEAD file")
        try require(
            partiallyStagedDiff.newLines == ["current content"],
            "AM diff should show the complete working file instead of the staged intermediate"
        )

        let mixedDiff = try await reader.fileDiff(
            repositoryURL: repositoryURL,
            target: .change(GitChangeSelection(path: "mixed.txt", kind: .changes)),
            ignoringWhitespace: false
        )
        try require(mixedDiff.oldLines == ["mixed base"], "Combined diff did not read the HEAD version")
        try require(mixedDiff.newLines == ["unstaged"], "Combined diff did not read the working version")

        let renameChange = try value(
            firstSnapshot.changes.first { $0.indexStatus == .renamed },
            "Rename change was unavailable"
        )
        let renameDiff = try await reader.fileDiff(
            repositoryURL: repositoryURL,
            target: .change(
                GitChangeSelection(
                    path: renameChange.path,
                    kind: .changes,
                    originalPath: renameChange.originalPath
                )
            ),
            ignoringWhitespace: false
        )
        try require(renameDiff.originalPath == "committed rename.txt", "Rename diff omitted the original path")

        let binaryDiff = try await reader.fileDiff(
            repositoryURL: repositoryURL,
            target: .change(GitChangeSelection(path: "binary.dat", kind: .changes)),
            ignoringWhitespace: false
        )
        try require(binaryDiff.isBinary, "Binary diff was not detected")

        let firstPage = try await reader.history(
            repositoryURL: repositoryURL,
            limit: 2,
            skip: 0,
            revision: "--all",
            author: nil
        )
        let secondPage = try await reader.history(
            repositoryURL: repositoryURL,
            limit: 2,
            skip: firstPage.count,
            revision: "--all",
            author: nil
        )
        try require(firstPage.count == 2 && secondPage.count == 2, "History pagination did not return full pages")
        try require(Set(firstPage.map(\.hash)).isDisjoint(with: Set(secondPage.map(\.hash))), "History pagination returned duplicate commits")

        let authors = try await reader.authors(repositoryURL: repositoryURL)
        try require(authors == ["RepoDesk Verification"], "Git authors were not listed")
        let authorHistory = try await reader.history(
            repositoryURL: repositoryURL,
            limit: 20,
            skip: 0,
            revision: "--all",
            author: "RepoDesk Verification"
        )
        try require(!authorHistory.isEmpty, "Author-filtered history was empty")
        try require(authorHistory.allSatisfy { $0.author == "RepoDesk Verification" }, "Author filtering returned another user")

        let branches = try await reader.branches(repositoryURL: repositoryURL)
        try require(branches.contains(where: { $0.name == "main" && $0.isCurrent }), "Current branch was not identified")
        try require(branches.contains(where: { $0.name == "other" && !$0.isRemote }), "Secondary branch was not listed")

        let copyCommit = try await reader.commit(repositoryURL: repositoryURL, hash: copyCommitHash)
        try require(copyCommit.files.contains(where: { $0.status == .copied && $0.path == "committed copy.txt" }), "Commit copy status was not parsed")
        try require(copyCommit.files.contains(where: { $0.status == .renamed && $0.path == "committed rename.txt" }), "Commit rename status was not parsed")
        let copiedFile = try value(
            copyCommit.files.first { $0.path == "committed copy.txt" },
            "Copied commit file was unavailable"
        )
        let committedDiff = try await reader.fileDiff(
            repositoryURL: repositoryURL,
            target: .commit(hash: copyCommitHash, file: copiedFile),
            ignoringWhitespace: false
        )
        try require(committedDiff.path == "committed copy.txt", "Commit file diff returned another file")
        try require(committedDiff.newLines == ["source"], "Commit file diff did not load the new blob")
        try require(!committedDiff.hunks.isEmpty, "Commit file diff did not parse content hunks")

        try await verifySnapshotDiagnostics(in: repositoryURL)
        try await verifyUnbornRepositoryDiff(runner: runner)
        try await verifyCombinedMergeHistory(runner: runner)

        print("Git review verification passed")
    }

    private static func verifyCombinedMergeHistory(runner: SystemCommandRunner) async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskMergeHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        try await git(["init", "-b", "main"], runner: runner, at: repositoryURL)
        try await git(["config", "user.email", "repodesk@example.invalid"], runner: runner, at: repositoryURL)
        try await git(["config", "user.name", "RepoDesk Verification"], runner: runner, at: repositoryURL)
        try write("base\n", to: repositoryURL.appendingPathComponent("resolved.txt"))
        try write("base\n", to: repositoryURL.appendingPathComponent("source-only.txt"))
        try await git(["add", "--all"], runner: runner, at: repositoryURL)
        try await git(["commit", "-m", "Base"], runner: runner, at: repositoryURL)

        try await git(["checkout", "-b", "source"], runner: runner, at: repositoryURL)
        try write("source\n", to: repositoryURL.appendingPathComponent("resolved.txt"))
        try write("source\n", to: repositoryURL.appendingPathComponent("source-only.txt"))
        try await git(["add", "--all"], runner: runner, at: repositoryURL)
        try await git(["commit", "-m", "Source"], runner: runner, at: repositoryURL)

        try await git(["checkout", "main"], runner: runner, at: repositoryURL)
        try write("target\n", to: repositoryURL.appendingPathComponent("resolved.txt"))
        try await git(["add", "resolved.txt"], runner: runner, at: repositoryURL)
        try await git(["commit", "-m", "Target"], runner: runner, at: repositoryURL)
        try await git(
            ["merge", "--no-ff", "source", "-m", "Merge source"],
            runner: runner,
            at: repositoryURL,
            allowedStatuses: [0, 1]
        )
        try write("resolved\n", to: repositoryURL.appendingPathComponent("resolved.txt"))
        try await git(["add", "resolved.txt"], runner: runner, at: repositoryURL)
        try await git(["commit", "--no-edit"], runner: runner, at: repositoryURL)

        let mergeHash = try await gitOutput(["rev-parse", "HEAD"], runner: runner, at: repositoryURL)
        let detail = try await SystemGitRepositoryReader().commit(
            repositoryURL: repositoryURL,
            hash: mergeHash
        )

        try require(
            detail.files.map(\.path) == ["resolved.txt"],
            "Merge History should expose only files changed from every parent"
        )
        try require(detail.parentHashes.count == 2, "Merge parent hashes were not exposed")
        let resolvedFile = try value(detail.files.first, "Combined merge file was unavailable")
        let mergeDiff = try await SystemGitRepositoryReader().mergeFileDiff(
            repositoryURL: repositoryURL,
            hash: mergeHash,
            parentHashes: detail.parentHashes,
            file: resolvedFile,
            ignoringWhitespace: false
        )
        try require(mergeDiff.target.oldLines == ["target"], "Target parent content was not loaded")
        try require(mergeDiff.source.oldLines == ["source"], "Source parent content was not loaded")
        try require(mergeDiff.resultLines == ["resolved"], "Merge result content was not loaded")
        try require(
            !mergeDiff.target.hunks.isEmpty && !mergeDiff.source.hunks.isEmpty,
            "Three-way Merge Diff did not parse both parent comparisons"
        )
    }

    private static func verifyUnbornRepositoryDiff(runner: SystemCommandRunner) async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskUnbornGit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        try await git(["init", "-b", "main"], runner: runner, at: repositoryURL)
        try write("first content\n", to: repositoryURL.appendingPathComponent("first.txt"))
        try await git(["add", "first.txt"], runner: runner, at: repositoryURL)

        let diff = try await SystemGitRepositoryReader().fileDiff(
            repositoryURL: repositoryURL,
            target: .change(GitChangeSelection(path: "first.txt", kind: .changes)),
            ignoringWhitespace: false
        )
        try require(diff.oldLines.isEmpty, "Unborn repository diff should use an empty tree")
        try require(diff.newLines == ["first content"], "Unborn repository diff omitted the working file")
    }

    private static func verifySnapshotDiagnostics(in repositoryURL: URL) async throws {
        let diagnosticLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskGitDiagnostics-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: diagnosticLogURL) }
        let diagnostics = AppDiagnosticLogger(logURL: diagnosticLogURL)
        let runner = SnapshotDiagnosticsRunner()
        let diagnosticReader = SystemGitRepositoryReader(
            commandRunner: runner,
            diagnosticLogger: diagnostics
        )

        _ = try await diagnosticReader.snapshot(repositoryURL: repositoryURL)

        let maximumConcurrency = await runner.maximumConcurrency()
        try require(maximumConcurrency == 3, "Snapshot Git commands no longer run concurrently")
        let log = try String(contentsOf: diagnosticLogURL, encoding: .utf8)
        try require(log.contains("git-snapshot start"), "Snapshot start was not logged")
        try require(log.contains("git-snapshot end"), "Snapshot completion was not logged")
        for operation in ["status", "last-commit", "staged-diff"] {
            try require(
                log.contains("git-snapshot-command start") && log.contains("operation=\(operation)"),
                "Snapshot operation \(operation) was not logged"
            )
        }
        try require(!log.contains("secret subject"), "Commit content leaked into diagnostics")
        try require(!log.contains("secret author"), "Author content leaked into diagnostics")
        try require(!log.contains("secret-file.txt"), "File content leaked into diagnostics")

        let failureLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskGitDiagnosticsFailure-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: failureLogURL) }
        let failureDiagnostics = AppDiagnosticLogger(logURL: failureLogURL)
        let failingReader = SystemGitRepositoryReader(
            commandRunner: SnapshotDiagnosticsRunner(failingOperation: "status"),
            diagnosticLogger: failureDiagnostics
        )
        do {
            _ = try await failingReader.snapshot(repositoryURL: repositoryURL)
            throw VerificationFailure(message: "Failing snapshot unexpectedly succeeded")
        } catch is GitRepositoryError {
            // Expected. Diagnostics must identify the operation without recording stderr.
        }
        let failureLog = try String(contentsOf: failureLogURL, encoding: .utf8)
        try require(
            failureLog.contains("git-snapshot-command error")
                && failureLog.contains("operation=status"),
            "Failing snapshot operation was not identified"
        )
        try require(failureLog.contains("git-snapshot error"), "Snapshot failure was not logged")
        try require(!failureLog.contains("secret stderr"), "Git stderr leaked into diagnostics")
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func git(
        _ arguments: [String],
        runner: SystemCommandRunner,
        at repositoryURL: URL,
        allowedStatuses: Set<Int32> = [0]
    ) async throws {
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: nil
            )
        )
        guard allowedStatuses.contains(result.terminationStatus) else {
            throw VerificationFailure(
                message: "git \(arguments.joined(separator: " ")) failed: "
                    + String(decoding: result.standardError, as: UTF8.self)
            )
        }
    }

    private static func gitOutput(
        _ arguments: [String],
        runner: SystemCommandRunner,
        at repositoryURL: URL
    ) async throws -> String {
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                workingDirectoryURL: repositoryURL,
                environment: nil
            )
        )
        guard result.terminationStatus == 0 else {
            throw VerificationFailure(message: String(decoding: result.standardError, as: UTF8.self))
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationFailure(message: message) }
    }

    private static func value<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw VerificationFailure(message: message) }
        return value
    }
}

private actor SnapshotDiagnosticsRunner: CommandRunning {
    private let failingOperation: String?
    private var activeCount = 0
    private var highestActiveCount = 0

    init(failingOperation: String? = nil) {
        self.failingOperation = failingOperation
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        activeCount += 1
        highestActiveCount = max(highestActiveCount, activeCount)
        defer { activeCount -= 1 }
        try await Task.sleep(for: .milliseconds(50))

        let operation = switch request.arguments.first {
        case "status": "status"
        case "log": "last-commit"
        default: "staged-diff"
        }
        if operation == failingOperation {
            return CommandResult(
                standardOutput: Data(),
                standardError: Data("secret stderr".utf8),
                terminationStatus: 1
            )
        }

        let output: Data
        switch request.arguments.first {
        case "status":
            output = Data("# branch.oid abc123\0# branch.head main\0? secret-file.txt\0".utf8)
        case "log":
            output = Data("abc123\0secret subject\0secret author\02026-08-10T00:00:00Z".utf8)
        default:
            output = Data()
        }
        return CommandResult(
            standardOutput: output,
            standardError: Data(),
            terminationStatus: 0
        )
    }

    func maximumConcurrency() -> Int {
        highestActiveCount
    }
}
