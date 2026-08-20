import Foundation
import Testing
@testable import RepoDesk

struct CommandRunnerTests {
    @Test func hangingCommandTimesOut() async {
        let runner = SystemCommandRunner(timeout: .milliseconds(100))
        let startedAt = ContinuousClock.now

        do {
            _ = try await runner.run(sleepRequest(seconds: 5))
            Issue.record("Expected the command to time out")
        } catch let error as CommandRunnerError {
            guard case .timedOut = error else {
                Issue.record("Expected a timeout error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected a timeout error, got \(error)")
        }

        #expect(startedAt.duration(to: .now) < .seconds(2))
    }

    @Test func cancellingCommandTerminatesProcessAndReturnsCancellation() async {
        let runner = SystemCommandRunner(timeout: .seconds(10))
        let startedAt = ContinuousClock.now
        let task = Task {
            try await runner.run(sleepRequest(seconds: 5))
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the command to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(startedAt.duration(to: .now) < .seconds(2))
    }

    @Test func timeoutAndCancellationRaceCompletesExactlyOnce() async {
        for _ in 0..<20 {
            let runner = SystemCommandRunner(timeout: .milliseconds(30))
            let task = Task {
                try await runner.run(sleepRequest(seconds: 5))
            }

            try? await Task.sleep(for: .milliseconds(30))
            task.cancel()

            do {
                _ = try await task.value
                Issue.record("Expected timeout or cancellation")
            } catch is CancellationError {
            } catch let error as CommandRunnerError {
                guard case .timedOut = error else {
                    Issue.record("Unexpected command runner error: \(error)")
                    return
                }
            } catch {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    private func sleepRequest(seconds: Int) -> CommandRequest {
        CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: [String(seconds)],
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            environment: nil
        )
    }
}
