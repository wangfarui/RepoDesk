import Darwin
import Foundation
import Testing
@testable import RepoDesk

struct TaskModuleTests {
    @Test func outputTailPolicyUsesToleranceAroundLatestContent() {
        #expect(
            NativeTextTailFollowPolicy.isAtTail(
                documentHeight: 1_000,
                visibleMaxY: 990,
                tolerance: 18
            )
        )
        #expect(
            !NativeTextTailFollowPolicy.isAtTail(
                documentHeight: 1_000,
                visibleMaxY: 900,
                tolerance: 18
            )
        )
    }

    @Test func resolverExpandsVariablesWithoutShellConcatenation() throws {
        let workspace = FileManager.default.temporaryDirectory
        let repository = workspace.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let definition = RepoTaskDefinition(
            id: "verify",
            name: "Verify",
            executable: "mvn",
            arguments: ["-s", "${workspaceRoot}/settings.xml", "-pl", "module one", "verify"],
            workingDirectory: "${repositoryRoot}",
            environment: ["JAVA_HOME": "${env:TEST_JAVA_HOME}"],
            confirmation: .none
        )

        let resolved = try RepoTaskResolver.resolve(
            definition,
            context: TaskResolutionContext(
                workspaceURL: workspace,
                repositoryURL: repository,
                selectedFileURL: nil,
                userHomeURL: workspace,
                processEnvironment: ["TEST_JAVA_HOME": "/jdk"]
            )
        )

        #expect(resolved.executableURL.path == "/usr/bin/env")
        #expect(resolved.arguments == ["mvn", "-s", "\(workspace.path)/settings.xml", "-pl", "module one", "verify"])
        #expect(resolved.environment["JAVA_HOME"] == "/jdk")
    }

    @Test func runnerStreamsOutputAndReturnsExitStatus() async throws {
        let collector = TaskOutputCollector()
        let runner = SystemRepoTaskRunner()
        let result = try await runner.run(
            ResolvedRepoTask(
                definitionID: "print",
                name: "Print",
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["RepoDesk output"],
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment,
                confirmation: .none
            )
        ) { collector.append($0.text) }

        #expect(result.terminationStatus == 0)
        #expect(collector.value == "RepoDesk output")
    }

    @Test func stoppingRunnerTerminatesSpawnedChildProcess() async throws {
        let collector = TaskOutputCollector()
        let runner = SystemRepoTaskRunner()
        let task = Task {
            try await runner.run(
                ResolvedRepoTask(
                    definitionID: "process-group",
                    name: "Process group",
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "sh -c 'trap \"\" TERM HUP; sleep 30' & child=$!; echo $child; wait $child"
                    ],
                    workingDirectoryURL: FileManager.default.temporaryDirectory,
                    environment: ProcessInfo.processInfo.environment,
                    confirmation: .none
                )
            ) { collector.append($0.text) }
        }

        var childPID: pid_t?
        for _ in 0..<100 where childPID == nil {
            childPID = collector.firstPID
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(childPID)
        defer { _ = Darwin.kill(pid, SIGKILL) }

        await runner.stop()
        try await Task.sleep(for: .milliseconds(100))

        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        _ = try? await task.value
    }
}

private final class TaskOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String { lock.withLock { storage } }

    var firstPID: pid_t? {
        lock.withLock {
            storage.split(whereSeparator: { $0.isWhitespace })
                .compactMap { pid_t($0) }
                .first
        }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

@MainActor
struct TaskPersistenceTests {
    @Test func applicationSupportStoreScopesAndRestoresTasks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskTaskStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ApplicationSupportRepoTaskStore(applicationSupportURL: directory)
        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let task = RepoTaskDefinition(
            id: "verify",
            name: "Verify",
            executable: "mvn",
            arguments: ["verify"],
            workingDirectory: "${workspaceRoot}",
            environment: [:],
            confirmation: .none
        )

        store.save(task, scope: .workspace, workspaceURL: workspace, repositoryURL: nil)

        #expect(store.catalog(workspaceURL: workspace, repositoryURL: nil).workspace == [task])
    }
}
