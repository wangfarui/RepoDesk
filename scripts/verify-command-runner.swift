import Foundation

private struct VerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct CommandRunnerVerifier {
    static func main() async throws {
        try await verifyTimeout()
        try await verifyCancellation()
        try await verifyTimeoutCancellationRace()
        try await verifySuccessfulCommand()
        print("Command runner verification passed")
    }

    private static func verifyTimeout() async throws {
        let runner = SystemCommandRunner(timeout: .milliseconds(100))
        let startedAt = ContinuousClock.now

        do {
            _ = try await runner.run(sleepRequest(seconds: 5))
            throw VerificationFailure(message: "Hanging command did not time out")
        } catch let error as CommandRunnerError {
            guard case .timedOut = error else { throw error }
        }

        try require(
            startedAt.duration(to: .now) < .seconds(2),
            "Timeout did not return promptly"
        )
    }

    private static func verifyCancellation() async throws {
        let runner = SystemCommandRunner(timeout: .seconds(10))
        let startedAt = ContinuousClock.now
        let task = Task {
            try await runner.run(sleepRequest(seconds: 5))
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            throw VerificationFailure(message: "Cancelled command returned successfully")
        } catch is CancellationError {
        }

        try require(
            startedAt.duration(to: .now) < .seconds(2),
            "Cancellation did not return promptly"
        )
    }

    private static func verifySuccessfulCommand() async throws {
        let runner = SystemCommandRunner(timeout: .seconds(2))
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["RepoDesk"],
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                environment: nil
            )
        )
        try require(result.terminationStatus == 0, "Successful command returned a failure status")
        try require(
            String(decoding: result.standardOutput, as: UTF8.self) == "RepoDesk\n",
            "Successful command output was not preserved"
        )
    }

    private static func verifyTimeoutCancellationRace() async throws {
        for _ in 0..<20 {
            let runner = SystemCommandRunner(timeout: .milliseconds(30))
            let task = Task {
                try await runner.run(sleepRequest(seconds: 5))
            }

            try await Task.sleep(for: .milliseconds(30))
            task.cancel()

            do {
                _ = try await task.value
                throw VerificationFailure(message: "Timeout/cancellation race returned successfully")
            } catch is CancellationError {
            } catch let error as CommandRunnerError {
                guard case .timedOut = error else { throw error }
            }
        }
    }

    private static func sleepRequest(seconds: Int) -> CommandRequest {
        CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: [String(seconds)],
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            environment: nil
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw VerificationFailure(message: message) }
    }
}
