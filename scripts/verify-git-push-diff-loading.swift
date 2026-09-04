import Foundation
@testable import RepoDesk

private struct VerificationError: Error, Sendable {
    let message: String
}

@main
    @MainActor
enum VerifyGitPushDiffLoading {
    static func main() async throws {
        try await verifyRangeDiffDoesNotScanCopies()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Push-Diff-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = root.appendingPathComponent("repository", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main"], in: repositoryURL)
        try git(["config", "user.name", "RepoDesk Verification"], in: repositoryURL)
        try git(["config", "user.email", "repodesk@example.test"], in: repositoryURL)

        let path = "src/main/java/com/internet/invoice/dao/invoice/SalesUnInvoiceDao.java"
        let fileURL = repositoryURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<80_000).map { index in "    private String field\(index);\n" }.joined().utf8)
            .write(to: fileURL)
        try git(["add", "--all"], in: repositoryURL)
        try git(["commit", "--message", "Base DAO"], in: repositoryURL)
        let baseHash = try gitOutput(["rev-parse", "HEAD"], in: repositoryURL)

        try Data((0..<80_000).map { index in
            index == 40_000 ? "    private Long purchaserId;\n" : "    private String field\(index);\n"
        }.joined().utf8).write(to: fileURL)
        try git(["add", "--all"], in: repositoryURL)
        try git(["commit", "--message", "Add purchaser"], in: repositoryURL)
        let headHash = try gitOutput(["rev-parse", "HEAD"], in: repositoryURL)
        let reader = SystemGitRepositoryReader(
            commandRunner: SystemCommandRunner(timeout: .seconds(5))
        )
        let file = GitCommitFile(path: path, originalPath: nil, status: .modified)
        let startedAt = ContinuousClock.now
        let diff = try await reader.fileDiff(
            repositoryURL: repositoryURL,
            target: .revisionRange(base: baseHash, head: headHash, file: file),
            ignoringWhitespace: false
        )
        let elapsed = ContinuousClock.now - startedAt
        let renderStartedAt = ContinuousClock.now
        _ = GitDiffRenderModel(diff: diff)
        let renderElapsed = ContinuousClock.now - renderStartedAt
        try require(!diff.isBinary, "Generated DAO Diff was incorrectly classified as binary.")
        try require(diff.newLines.count == 80_000, "Generated DAO Diff did not load the full file.")
        print("Push Diff loaded in \(elapsed); render model built in \(renderElapsed)")
    }

    private static func verifyRangeDiffDoesNotScanCopies() async throws {
        let runner = RecordingCommandRunner(results: [
            CommandResult(standardOutput: Data(), standardError: Data(), terminationStatus: 0),
            CommandResult(standardOutput: Data("old\n".utf8), standardError: Data(), terminationStatus: 0),
            CommandResult(standardOutput: Data("new\n".utf8), standardError: Data(), terminationStatus: 0)
        ])
        let reader = SystemGitRepositoryReader(commandRunner: runner)
        _ = try await reader.fileDiff(
            repositoryURL: URL(fileURLWithPath: "/tmp/repo"),
            target: .revisionRange(
                base: "11111111",
                head: "22222222",
                file: GitCommitFile(path: "SalesUnInvoiceDao.java", originalPath: nil, status: .modified)
            ),
            ignoringWhitespace: false
        )
        let requests = await runner.requests()
        guard let diffArguments = requests.first?.arguments else {
            throw VerificationError(message: "Range Diff did not invoke Git.")
        }
        try require(
            !diffArguments.contains("--find-copies-harder"),
            "Range Diff still enables the repository-wide copy scan."
        )
        try require(
            diffArguments.contains("--no-textconv"),
            "Range Diff must disable Git textconv filters so a configured external converter cannot block the UI."
        )
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        _ = try gitResult(arguments, in: directory)
    }

    private static func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        String(decoding: try gitResult(arguments, in: directory), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gitResult(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VerificationError(message: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError(message: message) }
    }
}

private actor RecordingCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private var recordedRequests: [CommandRequest] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        recordedRequests.append(request)
        return results.isEmpty
            ? CommandResult(standardOutput: Data(), standardError: Data(), terminationStatus: 0)
            : results.removeFirst()
    }

    func requests() -> [CommandRequest] {
        recordedRequests
    }
}
