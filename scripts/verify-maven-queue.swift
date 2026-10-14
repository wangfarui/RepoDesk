import Foundation
@testable import RepoDesk

private struct MavenQueueVerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
@MainActor
enum VerifyMavenQueue {
    private static let repository = URL(fileURLWithPath: "/private/tmp/repodesk-queue/repository")
    private static let workspace = URL(fileURLWithPath: "/private/tmp/repodesk-queue")

    static func main() async throws {
        try await verifyFIFOAndRemoval()
        try await verifyRepositoryIsolation()
        try await verifyFailure(throwsError: false)
        try await verifyFailure(throwsError: true)
        try await verifyStop()
        try await verifyImmediateStop()
        try await verifyReset()
        try await verifyAppStateIntegration()
        print("Maven queue verification passed")
    }

    private static func verifyFIFOAndRemoval() async throws {
        let control = QueueRunnerControl()
        let queue = MavenRunQueue(runnerFactory: { QueueRunner(control: control) })
        var finished: [(MavenRunRecord, URL)] = []
        queue.onFinish = { finished.append(($0, $1)) }
        let first = request("first")
        let second = request("second")
        let third = request("third", modulePath: "service")
        let fourth = request("fourth")

        queue.submit(first, repositoryURL: repository, workspaceURL: workspace)
        try await eventually("First command never started") { await control.labels() == ["first"] }
        guard let firstID = queue.activeRecords.first?.id else {
            throw MavenQueueVerificationError(message: "Running command was absent from recent runs")
        }
        try require(queue.activeRecords.first?.activity == .running, "Running record had no live status")
        queue.submit(first, repositoryURL: repository, workspaceURL: workspace)
        try require(queue.activeRecords.count == 1, "Duplicate running command was accepted")
        try require(queue.message(for: repository)?.isEmpty == false, "Duplicate running command had no feedback")

        queue.submit(second, repositoryURL: repository, workspaceURL: workspace)
        queue.submit(third, repositoryURL: repository, workspaceURL: workspace)
        queue.submit(fourth, repositoryURL: repository, workspaceURL: workspace)
        queue.submit(second, repositoryURL: repository, workspaceURL: workspace)
        try require(queue.activeRecords.count == 4, "Different arguments were rejected or queued duplicate was accepted")
        try require(queue.message(for: repository)?.isEmpty == false, "Duplicate queued command had no feedback")
        let waiting = queue.activeRecords.filter { $0.activity == .queued }
        try require(queue.activeRecords.first?.id == firstID, "Running record was not displayed before waiting commands")
        try require(waiting.map(\.arguments) == [second.command.arguments, third.command.arguments, fourth.command.arguments],
                    "Queued command order or repository-wide module sharing was wrong")
        try require(waiting.map(\.queuePosition) == [1, 2, 3], "Queue positions were not sequential")
        queue.remove(waiting[1].id)
        try require(queue.activeRecords.count == 3, "Removing one queued command removed the wrong number of entries")
        try require(queue.activeRecords.first { $0.arguments == fourth.command.arguments }?.queuePosition == 2,
                    "Removing a command did not update remaining queue positions")
        queue.remove(firstID)
        try require(queue.activeRecords.contains { $0.id == firstID && $0.activity == .running },
                    "Removing a queued entry incorrectly allowed removal of the running command")

        try await control.emit("first", text: "live output\n")
        try await eventually("Live log never reached running history and execution presentation") {
            queue.activeRecords.first { $0.id == firstID }?.log?.contains("live output") == true
                && queue.execution(for: repository).log.contains("live output")
        }
        try await control.finish("first")
        try await eventually("FIFO did not start the second command") { await control.labels() == ["first", "second"] }
        try require(finished.count == 1 && finished[0].0.id == firstID, "Completion changed the running history record ID")
        try require(finished[0].1 == workspace, "Completion callback lost its originating workspace")
        try require(finished[0].0.activity == nil && finished[0].0.terminationStatus == 0,
                    "Completed record retained an active state or lost its exit status")
        try require(finished[0].0.log?.contains("live output") == true, "Completion lost live output")
        try await control.finish("second")
        try await eventually("Removed command ran or FIFO skipped the remaining command") {
            await control.labels() == ["first", "second", "fourth"]
        }
        try await control.finish("fourth")
        try await eventually("Queue never returned to idle") { !queue.hasRunningCommands && finished.count == 3 }
        try require(queue.activeRecords.isEmpty, "Completed commands remained in active records")
        queue.submit(first, repositoryURL: repository, workspaceURL: workspace)
        try await eventually("Completed command could not be submitted again") {
            await control.labels() == ["first", "second", "fourth", "first"]
        }
        try await control.finish("first")
        try await eventually("Repeated command did not finish") { !queue.hasRunningCommands }
    }

    private static func verifyRepositoryIsolation() async throws {
        let control = QueueRunnerControl()
        let queue = MavenRunQueue(runnerFactory: { QueueRunner(control: control) })
        let other = URL(fileURLWithPath: "/private/tmp/repodesk-queue/other")
        queue.submit(request("repository-one"), repositoryURL: repository, workspaceURL: workspace)
        queue.submit(request("repository-two", repositoryURL: other), repositoryURL: other, workspaceURL: workspace)
        queue.submit(request("repository-one-next"), repositoryURL: repository, workspaceURL: workspace)
        try await eventually("Different repositories did not run concurrently") {
            Set(await control.labels()) == Set(["repository-one", "repository-two"])
        }
        try await control.finish("repository-one", status: 1)
        try await eventually("Failed repository did not clear its pending commands") {
            !queue.activeRecords.contains { $0.repositoryPath == repository.path }
        }
        try require(queue.activeRecords.contains { $0.repositoryPath == other.path && $0.activity == .running },
                    "Failure in one repository stopped the other repository")
        try await control.emit("repository-two", text: "other repository still running")
        try await eventually("Independent repository stopped receiving output") {
            queue.execution(for: other).log.contains("other repository still running")
        }
        try await control.finish("repository-two")
        try await eventually("Independent repository did not finish") { !queue.hasRunningCommands }
    }

    private static func verifyFailure(throwsError: Bool) async throws {
        let control = QueueRunnerControl()
        let queue = MavenRunQueue(runnerFactory: { QueueRunner(control: control) })
        var finished: [MavenRunRecord] = []
        queue.onFinish = { record, _ in finished.append(record) }
        queue.submit(request("failure"), repositoryURL: repository, workspaceURL: workspace)
        queue.submit(request("cancelled-one"), repositoryURL: repository, workspaceURL: workspace)
        queue.submit(request("cancelled-two"), repositoryURL: repository, workspaceURL: workspace)
        try await eventually("Failure command never started") { await control.labels() == ["failure"] }
        if throwsError {
            try await control.fail("failure")
        } else {
            try await control.finish("failure", status: 7)
        }
        try await eventually("Failure did not clear the queue") { queue.activeRecords.isEmpty && !queue.hasRunningCommands }
        try require(await control.labels() == ["failure"], "Failed execution started a pending command")
        try require(queue.message(for: repository)?.isEmpty == false, "Failure did not explain queue cancellation")
        try require(finished.count == 1, "Failure did not produce exactly one completion record")
        if throwsError {
            try require(queue.execution(for: repository).errorMessage?.contains("controlled launch failure") == true,
                        "Launch failure reason was lost")
        } else {
            try require(finished[0].terminationStatus == 7, "Nonzero exit code was lost")
        }
        queue.submit(request("recovered"), repositoryURL: repository, workspaceURL: workspace)
        try await eventually("Queue could not accept a new command after failure") {
            await control.labels() == ["failure", "recovered"]
        }
        try await control.finish("recovered")
        try await eventually("Recovered queue did not finish") { !queue.hasRunningCommands }
    }

    private static func verifyStop() async throws {
        let control = QueueRunnerControl()
        let queue = MavenRunQueue(runnerFactory: { QueueRunner(control: control) })
        queue.submit(request("stopped"), repositoryURL: repository, workspaceURL: workspace)
        queue.submit(request("must-not-start"), repositoryURL: repository, workspaceURL: workspace)
        try await eventually("Stopped command never started") { await control.labels() == ["stopped"] }
        queue.stop(repositoryURL: repository)
        try await eventually("Stop never reached the task runner") { await control.stops() == 1 }
        try require(!queue.activeRecords.contains { $0.activity == .queued }, "Stop retained pending commands")
        // A process can exit successfully while stopping. Explicit stop must still suppress draining.
        try await control.finish("stopped", status: 0)
        try await eventually("Stopped queue did not finish") { !queue.hasRunningCommands }
        try require(await control.labels() == ["stopped"], "Successful exit after stop resumed pending commands")
    }

    private static func verifyReset() async throws {
        let control = QueueRunnerControl()
        let queue = MavenRunQueue(runnerFactory: { QueueRunner(control: control) })
        var finished: [MavenRunRecord] = []
        queue.onFinish = { record, _ in finished.append(record) }
        queue.submit(request("old"), repositoryURL: repository, workspaceURL: workspace)
        queue.submit(request("old-pending"), repositoryURL: repository, workspaceURL: workspace)
        try await eventually("Old execution never started") { await control.labels() == ["old"] }
        queue.reset()
        try require(queue.activeRecords.isEmpty && !queue.hasRunningCommands, "Reset retained active execution state")
        queue.submit(request("new"), repositoryURL: repository, workspaceURL: workspace)
        try await eventually("New execution could not start after reset") { await control.labels() == ["old", "new"] }
        try await control.emit("new", text: "new output\n")
        try await eventually("New execution output missing") { queue.execution(for: repository).log.contains("new output") }
        try await control.emit("old", text: "stale output\n")
        try await control.finish("old")
        // Let the invalidated task deliver both its output and completion before observing the replacement.
        for _ in 0..<20 { await Task.yield() }
        try require(finished.isEmpty, "Reset execution leaked a completion callback")
        try require(queue.activeRecords.count == 1 && queue.activeRecords[0].arguments == request("new").command.arguments,
                    "Late completion changed the replacement execution")
        try require(!queue.execution(for: repository).log.contains("stale output"), "Reset execution leaked output")
        try await control.finish("new")
        try await eventually("Replacement execution did not complete") { !queue.hasRunningCommands && finished.count == 1 }
        try require(finished[0].arguments == request("new").command.arguments, "Replacement completion recorded stale command")
        try require(await control.labels() == ["old", "new"], "Reset started an obsolete pending command")
    }

    private static func verifyImmediateStop() async throws {
        let control = QueueRunnerControl()
        let queue = MavenRunQueue(runnerFactory: { QueueRunner(control: control) })
        queue.submit(request("immediate-stop"), repositoryURL: repository, workspaceURL: workspace)
        queue.submit(request("immediate-pending"), repositoryURL: repository, workspaceURL: workspace)
        queue.stop(repositoryURL: repository)
        try await eventually("Stop before process launch retained running state") { !queue.hasRunningCommands }
        try require(await control.labels().isEmpty, "Stopping before launch still started a process")
        try require(queue.activeRecords.isEmpty, "Immediate stop retained queued commands")
    }

    private static func verifyAppStateIntegration() async throws {
        let suite = "RepoDeskMavenQueueVerification.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw MavenQueueVerificationError(message: "Could not create isolated verification defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = UserDefaultsMavenRunHistoryStore(defaults: defaults)
        let firstRepository = RegisteredRepository(displayName: "first", relativePath: "repository", isPinned: false)
        let secondRepository = RegisteredRepository(displayName: "second", relativePath: "other", isPinned: false)
        let otherURL = workspace.appendingPathComponent(secondRepository.relativePath)
        let control = QueueRunnerControl()
        let state = makeState(workspaceURL: workspace, control: control, defaults: defaults, history: history,
                              repositories: [firstRepository, secondRepository])
        state.selectRepositoryContext(firstRepository.id)
        state.runMaven(request("state-first"))
        state.runMaven(request("state-waiting"))
        try await eventually("AppState did not start its selected repository command") {
            await control.labels() == ["state-first"]
        }
        guard let firstID = state.recentMavenRuns.first(where: { $0.activity == .running })?.id else {
            throw MavenQueueVerificationError(message: "AppState recent history omitted running command")
        }
        state.selectRepositoryContext(secondRepository.id)
        try require(state.mavenExecution == .idle, "Repository selection leaked another repository execution")
        state.runMaven(request("state-second", repositoryURL: otherURL))
        try await eventually("AppState serialized different repositories") {
            Set(await control.labels()) == Set(["state-first", "state-second"])
        }
        try require(state.mavenExecution.log.contains("state-second"), "Selected repository presentation showed the wrong command")
        state.clearMavenRunHistory()
        try require(state.recentMavenRuns.count == 3, "Clearing persisted history removed active commands")
        guard let waitingID = state.recentMavenRuns.first(where: { $0.activity == .queued })?.id else {
            throw MavenQueueVerificationError(message: "AppState omitted its queued history record")
        }
        state.removeMavenRun(waitingID)
        try require(state.recentMavenRuns.count == 2, "AppState did not remove a waiting command")
        state.stopMaven()
        try await eventually("AppState stop did not reach the selected repository") { await control.stops() == 1 }
        try await control.finish("state-second")
        try await eventually("Selected repository stop never completed") {
            state.mavenExecution.runningRequestID == nil && history.recentRuns(for: workspace).count == 1
        }
        state.selectRepositoryContext(firstRepository.id)
        try require(state.mavenExecution.runningRequestID != nil, "Stopping the selected repository stopped another repository")
        try await control.finish("state-first")
        try await eventually("AppState failed to persist both completed runs") {
            !state.mavenQueue.hasRunningCommands && history.recentRuns(for: workspace).count == 2
        }
        try require(state.recentMavenRuns.count == 2 && state.recentMavenRuns.allSatisfy { $0.activity == nil },
                    "AppState did not replace active history with completed records")
        try require(state.recentMavenRuns.contains { $0.id == firstID }, "AppState completion changed the history selection ID")

        let otherWorkspace = URL(fileURLWithPath: "/private/tmp/repodesk-queue-other-workspace")
        let otherControl = QueueRunnerControl()
        let otherState = makeState(workspaceURL: otherWorkspace, control: otherControl, defaults: defaults, history: history,
                                   repositories: [firstRepository])
        otherState.selectRepositoryContext(firstRepository.id)
        otherState.runMaven(request("other-workspace", repositoryURL: otherWorkspace.appendingPathComponent("repository")))
        try await eventually("Other workspace execution never started") { await otherControl.labels() == ["other-workspace"] }
        try await otherControl.finish("other-workspace")
        try await eventually("Other workspace completion was not persisted") {
            history.recentRuns(for: otherWorkspace).count == 1
        }
        try require(history.recentRuns(for: workspace).count == 2, "Completion history leaked across workspaces")
        try require(otherState.recentMavenRuns.count == 1, "New workspace displayed previous workspace history")
    }

    private static func makeState(
        workspaceURL: URL,
        control: QueueRunnerControl,
        defaults: UserDefaults,
        history: MavenRunHistoryStoring,
        repositories: [RegisteredRepository]
    ) -> AppState {
        AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: repositories,
            selectedRepositoryID: repositories.first?.id,
            workspaceStore: UserDefaultsWorkspaceStore(defaults: defaults),
            repositoryStore: UserDefaultsRepositoryStore(defaults: defaults),
            taskStore: UserDefaultsRepoTaskStore(defaults: defaults),
            mavenRunnerFactory: { QueueRunner(control: control) },
            mavenSettingsStore: UserDefaultsMavenSettingsStore(defaults: defaults),
            mavenRunHistoryStore: history,
            windowStateStore: UserDefaultsWindowStateStore(defaults: defaults),
            appPreferencesStore: UserDefaultsAppPreferencesStore(defaults: defaults),
            restoresWorkspaceOnLaunch: false
        )
    }

    private static func request(
        _ label: String,
        modulePath: String = ".",
        repositoryURL: URL = repository
    ) -> MavenRunRequest {
        let module = MavenModule(
            modulePath: modulePath,
            pomURL: repositoryURL.appendingPathComponent(modulePath).appendingPathComponent("pom.xml"),
            displayName: modulePath,
            groupID: "verification",
            artifactID: "queue",
            version: "1",
            packaging: "jar",
            hasPOM: true,
            children: []
        )
        return MavenRunRequest(
            module: module,
            goal: .compile,
            command: MavenCommand(
                executableURL: URL(fileURLWithPath: "/verification-only/mvn"),
                arguments: ["compile", label],
                workingDirectoryURL: repositoryURL,
                environment: ["JAVA_HOME": "/verification-only/jdk"]
            )
        )
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw MavenQueueVerificationError(message: message) }
    }

    private static func eventually(_ message: String, condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw MavenQueueVerificationError(message: "Timed out: \(message)")
    }
}

private actor QueueRunner: RepoTaskRunning {
    private let control: QueueRunnerControl
    private let id = UUID()

    init(control: QueueRunnerControl) { self.control = control }

    func run(
        _ task: ResolvedRepoTask,
        output: @escaping @Sendable (TaskOutputChunk) -> Void
    ) async throws -> TaskRunResult {
        try await control.run(task, runnerID: id, output: output)
    }

    func stop() async { await control.stop(runnerID: id) }
}

private actor QueueRunnerControl {
    private struct Pending {
        let label: String
        let runnerID: UUID
        let output: @Sendable (TaskOutputChunk) -> Void
        let continuation: CheckedContinuation<TaskRunResult, any Error>
    }

    private var startedLabels: [String] = []
    private var pending: [Pending] = []
    private var stopCount = 0

    func run(
        _ task: ResolvedRepoTask,
        runnerID: UUID,
        output: @escaping @Sendable (TaskOutputChunk) -> Void
    ) async throws -> TaskRunResult {
        guard let label = task.arguments.last else {
            throw MavenQueueVerificationError(message: "Queue dropped command arguments")
        }
        return try await withCheckedThrowingContinuation { continuation in
            startedLabels.append(label)
            pending.append(Pending(label: label, runnerID: runnerID, output: output, continuation: continuation))
        }
    }

    func labels() -> [String] { startedLabels }
    func stops() -> Int { stopCount }

    func stop(runnerID: UUID) {
        if pending.contains(where: { $0.runnerID == runnerID }) { stopCount += 1 }
    }

    func emit(_ label: String, text: String) throws {
        guard let execution = pending.first(where: { $0.label == label }) else {
            throw MavenQueueVerificationError(message: "No active fake command for output: \(label)")
        }
        execution.output(TaskOutputChunk(channel: .standardOutput, text: text))
    }

    func finish(_ label: String, status: Int32 = 0) throws {
        let execution = try take(label)
        execution.continuation.resume(returning: TaskRunResult(
            terminationStatus: status,
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_001)
        ))
    }

    func fail(_ label: String) throws {
        let execution = try take(label)
        execution.continuation.resume(throwing: MavenQueueVerificationError(message: "controlled launch failure"))
    }

    private func take(_ label: String) throws -> Pending {
        guard let index = pending.firstIndex(where: { $0.label == label }) else {
            throw MavenQueueVerificationError(message: "No active fake command to complete: \(label)")
        }
        return pending.remove(at: index)
    }
}
