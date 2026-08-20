import Darwin
import Foundation

private struct TaskRunnerVerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class PIDCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.withLock { buffer.append(text) }
    }

    var childPID: pid_t? {
        lock.withLock {
            buffer.split(whereSeparator: { $0.isWhitespace })
                .compactMap { pid_t($0) }
                .first
        }
    }

    var value: String { lock.withLock { buffer } }
}

@main
struct TaskRunnerVerification {
    static func main() async throws {
        try await verifyOutputAndStatus()
        try await verifyProcessGroupStop()
        print("Task runner verification passed")
    }

    private static func verifyOutputAndStatus() async throws {
        let runner = SystemRepoTaskRunner()
        let collector = PIDCollector()
        let result = try await runner.run(
            ResolvedRepoTask(
                definitionID: "output",
                name: "Output verification",
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["RepoDesk output"],
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment,
                confirmation: .none
            )
        ) { collector.append($0.text) }
        guard result.terminationStatus == 0, collector.value == "RepoDesk output" else {
            throw TaskRunnerVerificationFailure(
                message: "Task output or termination status was not preserved."
            )
        }
    }

    private static func verifyProcessGroupStop() async throws {
        let runner = SystemRepoTaskRunner()
        let collector = PIDCollector()
        let task = Task {
            try await runner.run(
                ResolvedRepoTask(
                    definitionID: "process-group",
                    name: "Process group verification",
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
            childPID = collector.childPID
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let childPID else {
            await runner.stop()
            _ = try? await task.value
            throw TaskRunnerVerificationFailure(message: "Task did not report its child PID.")
        }
        defer { _ = Darwin.kill(childPID, SIGKILL) }

        await runner.stop()
        try await Task.sleep(for: .milliseconds(100))

        errno = 0
        let childStillExists = Darwin.kill(childPID, 0) == 0 || errno == EPERM
        guard !childStillExists else {
            throw TaskRunnerVerificationFailure(
                message: "Stopping the task left child process \(childPID) running."
            )
        }
        _ = try? await task.value
    }
}
