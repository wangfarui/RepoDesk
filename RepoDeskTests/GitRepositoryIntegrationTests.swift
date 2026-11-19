import Foundation
import Testing
@testable import RepoDesk

struct GitRepositoryIntegrationTests {
    @Test func blameNormalizesExternalContentsAuthorForUncommittedLines() {
        let porcelain = String(repeating: "0", count: 40)
            + " 1 1 1\nauthor External file (--contents)\n\tnew line\n"
        let lines = GitBlameParser.parse(Data(porcelain.utf8))
        #expect(lines.count == 1)
        #expect(lines.first?.isUncommitted == true)
        #expect(lines.first?.author == "未提交")
    }

    @Test func snapshotReadsRealTemporaryRepository() async throws {
        let fixture = try await GitRepositoryFixture()
        defer { fixture.remove() }

        try Data("changed\n".utf8).write(to: fixture.url.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: fixture.url.appendingPathComponent("untracked.txt"))

        let snapshot = try await SystemGitRepositoryReader().snapshot(repositoryURL: fixture.url)

        #expect(snapshot.branch == "main")
        #expect(snapshot.unstagedCount == 1)
        #expect(snapshot.untrackedCount == 1)
        #expect(snapshot.lastCommit?.subject == "Initial commit")
    }

    @Test func blameDistinguishesCommittedAndWorkingTreeLines() async throws {
        let fixture = try await GitRepositoryFixture()
        defer { fixture.remove() }
        try Data("initial\nworking tree\n".utf8).write(
            to: fixture.url.appendingPathComponent("tracked.txt")
        )
        let reader = SystemGitRepositoryReader()

        let oldLines = try await reader.blame(
            repositoryURL: fixture.url,
            path: "tracked.txt",
            revision: "HEAD",
            contentsPath: nil
        )
        let newLines = try await reader.blame(
            repositoryURL: fixture.url,
            path: "tracked.txt",
            revision: "HEAD",
            contentsPath: "tracked.txt"
        )

        #expect(oldLines.count == 1)
        #expect(oldLines[0].author == "RepoDesk Tests")
        #expect(newLines.count == 2)
        #expect(newLines[1].isUncommitted)
        #expect(newLines[1].author == "未提交")
    }

    @Test func currentUserNameReadsEffectiveRepositoryConfiguration() async throws {
        let fixture = try await GitRepositoryFixture()
        defer { fixture.remove() }

        let userName = try await SystemGitRepositoryReader().currentUserName(
            repositoryURL: fixture.url
        )

        #expect(userName == "RepoDesk Tests")
    }

    @Test func currentUserNameReturnsNilWhenConfigurationIsMissing() async throws {
        let repositoryURL = URL(fileURLWithPath: "/tmp/repository", isDirectory: true)
        let runner = FixedCommandRunner(
            result: CommandResult(
                standardOutput: Data(),
                standardError: Data(),
                terminationStatus: 1
            )
        )
        let reader = SystemGitRepositoryReader(commandRunner: runner)

        let userName = try await reader.currentUserName(repositoryURL: repositoryURL)
        let request = await runner.recordedRequest()

        #expect(userName == nil)
        #expect(request?.arguments == ["config", "--get", "user.name"])
        #expect(request?.workingDirectoryURL == repositoryURL)
    }

    @Test func conflictFilesReadsGitBaseAndBothSidesFromIndexStages() async throws {
        let fixture = try await GitRepositoryFixture()
        defer { fixture.remove() }

        let runner = SystemCommandRunner()
        try await GitRepositoryFixture.run(["switch", "-c", "feature"], with: runner, at: fixture.url)
        try Data("feature\n".utf8).write(to: fixture.url.appendingPathComponent("tracked.txt"))
        try await GitRepositoryFixture.run(["add", "tracked.txt"], with: runner, at: fixture.url)
        try await GitRepositoryFixture.run(["commit", "-m", "Feature change"], with: runner, at: fixture.url)

        try await GitRepositoryFixture.run(["switch", "main"], with: runner, at: fixture.url)
        try Data("main\n".utf8).write(to: fixture.url.appendingPathComponent("tracked.txt"))
        try await GitRepositoryFixture.run(["add", "tracked.txt"], with: runner, at: fixture.url)
        try await GitRepositoryFixture.run(["commit", "-m", "Main change"], with: runner, at: fixture.url)

        let mergeResult = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["merge", "feature"],
                workingDirectoryURL: fixture.url,
                environment: nil
            )
        )
        #expect(mergeResult.terminationStatus != 0)

        let files = try await SystemGitRepositoryOperator().conflictFiles(repositoryURL: fixture.url)
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.path == "tracked.txt")
        #expect(file.base == "initial\n")
        #expect(file.ours == "main\n")
        #expect(file.theirs == "feature\n")
        #expect(file.result.contains("<<<<<<<"))
        #expect(file.hasBase)
        #expect(file.hasOurs)
        #expect(file.hasTheirs)
        #expect(!file.isBinary)
    }

    @Test func fileHistoryFollowsRenames() async throws {
        let fixture = try await GitRepositoryFixture()
        defer { fixture.remove() }

        try Data("updated\n".utf8).write(to: fixture.url.appendingPathComponent("tracked.txt"))
        try await fixture.commit("Update tracked")
        try await fixture.renameTrackedFile()

        let history = try await SystemGitRepositoryReader().fileHistory(
            repositoryURL: fixture.url,
            path: "renamed.txt",
            limit: 50,
            skip: 0,
            revision: nil,
            author: nil
        )

        #expect(history.map(\.subject) == ["Rename tracked", "Update tracked", "Initial commit"])
    }
}

private actor FixedCommandRunner: CommandRunning {
    private let result: CommandResult
    private var request: CommandRequest?

    init(result: CommandResult) {
        self.result = result
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        self.request = request
        return result
    }

    func recordedRequest() -> CommandRequest? { request }
}

private struct GitRepositoryFixture: Sendable {
    let url: URL

    init() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let runner = SystemCommandRunner()
        try await Self.run(["init", "-b", "main"], with: runner, at: url)
        try await Self.run(["config", "user.email", "repodesk@example.invalid"], with: runner, at: url)
        try await Self.run(["config", "user.name", "RepoDesk Tests"], with: runner, at: url)
        try Data("initial\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
        try await Self.run(["add", "tracked.txt"], with: runner, at: url)
        try await Self.run(["commit", "-m", "Initial commit"], with: runner, at: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func commit(_ subject: String) async throws {
        let runner = SystemCommandRunner()
        try await Self.run(["add", "-A"], with: runner, at: url)
        try await Self.run(["commit", "-m", subject], with: runner, at: url)
    }

    func renameTrackedFile() async throws {
        let runner = SystemCommandRunner()
        try await Self.run(["mv", "tracked.txt", "renamed.txt"], with: runner, at: url)
        try await Self.run(["commit", "-m", "Rename tracked"], with: runner, at: url)
    }

    fileprivate static func run(
        _ arguments: [String],
        with runner: SystemCommandRunner,
        at url: URL
    ) async throws {
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                workingDirectoryURL: url,
                environment: nil
            )
        )
        guard result.terminationStatus == 0 else {
            throw GitRepositoryError.commandFailed(
                arguments: arguments,
                message: String(decoding: result.standardError, as: UTF8.self)
            )
        }
    }
}
