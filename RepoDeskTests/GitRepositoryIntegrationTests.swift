import Foundation
import Testing
@testable import RepoDesk

struct GitRepositoryIntegrationTests {
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

    private static func run(
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
