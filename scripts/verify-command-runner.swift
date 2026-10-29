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
        try await verifyConcurrentLargeUTF8Output()
        print("Command runner verification passed")
    }

    private static func verifyConcurrentLargeUTF8Output() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-UTF8-output-\(UUID().uuidString).txt")
        let expected = Data(String(repeating: "return \"抵扣\"; // 批次库存中文注释 😀\n", count: 6000).utf8)
        try expected.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var failures = 0
        var invalidUTF8 = 0
        try await withThrowingTaskGroup(of: (Bool, CommandResult).self) { group in
            for stream in 0..<40 {
                let usesStandardError = stream % 2 == 1
                group.addTask {
                    let result = try await SystemCommandRunner().run(CommandRequest(
                        executableURL: URL(fileURLWithPath: usesStandardError ? "/bin/sh" : "/bin/cat"),
                        arguments: usesStandardError
                            ? ["-c", "exec /bin/cat \"$1\" >&2", "fixture", file.path] : [file.path],
                        workingDirectoryURL: file.deletingLastPathComponent(), environment: nil
                    ))
                    return (usesStandardError, result)
                }
            }
            for try await (usesStandardError, result) in group {
                let output = usesStandardError ? result.standardError : result.standardOutput
                let other = usesStandardError ? result.standardOutput : result.standardError
                if result.terminationStatus != 0 || output != expected || !other.isEmpty {
                    failures += 1
                }
                if String(data: result.standardOutput, encoding: .utf8) == nil
                    || String(data: result.standardError, encoding: .utf8) == nil { invalidUTF8 += 1 }
            }
        }
        try require(failures == 0, "Large output corrupted in \(failures)/40 commands (invalid UTF-8: \(invalidUTF8)); expected \(expected.count) exact bytes on stdout/stderr")
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
