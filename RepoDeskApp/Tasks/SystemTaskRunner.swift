import Darwin
import Foundation

protocol RepoTaskRunning: Sendable {
    func run(
        _ task: ResolvedRepoTask,
        output: @escaping @Sendable (TaskOutputChunk) -> Void
    ) async throws -> TaskRunResult
    func stop() async
}

actor SystemRepoTaskRunner: RepoTaskRunning {
    private var activeExecution: TaskProcessExecution?

    deinit {
        activeExecution?.forceTerminate()
    }

    func run(
        _ task: ResolvedRepoTask,
        output: @escaping @Sendable (TaskOutputChunk) -> Void
    ) async throws -> TaskRunResult {
        guard activeExecution == nil else {
            throw CocoaError(.executableLoad)
        }
        let execution = TaskProcessExecution(task: task, output: output)
        let startedAt = Date()
        do {
            try execution.start()
        } catch {
            throw error
        }
        activeExecution = execution

        let status = await withTaskCancellationHandler {
            await execution.waitForExit()
        } onCancel: {
            execution.requestTermination()
        }
        if activeExecution === execution {
            activeExecution = nil
        }
        return TaskRunResult(
            terminationStatus: status,
            startedAt: startedAt,
            finishedAt: .now
        )
    }

    func stop() async {
        guard let execution = activeExecution else { return }
        execution.requestTermination()
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            execution.forceTerminate()
            return
        }
        execution.forceTerminateIfRunning()
    }
}

private final class TaskProcessExecution: @unchecked Sendable {
    private let task: ResolvedRepoTask
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let outputDispatcher: TaskOutputDispatcher
    private let lock = NSLock()
    private var processIdentifier: pid_t?
    private var terminationRequested = false

    init(
        task: ResolvedRepoTask,
        output: @escaping @Sendable (TaskOutputChunk) -> Void
    ) {
        self.task = task
        outputDispatcher = TaskOutputDispatcher(output: output)
    }

    func start() throws {
        standardOutputPipe.fileHandleForReading.readabilityHandler = { [outputDispatcher] handle in
            outputDispatcher.emit(channel: .standardOutput, data: handle.availableData)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { [outputDispatcher] handle in
            outputDispatcher.emit(channel: .standardError, data: handle.availableData)
        }

        do {
            let pid = try spawnProcess()
            lock.withLock { processIdentifier = pid }
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
        } catch {
            stopReadingOutput()
            throw error
        }
    }

    func waitForExit() async -> Int32 {
        guard let pid = lock.withLock({ processIdentifier }) else { return -1 }
        let status = await Task.detached(priority: .userInitiated) {
            waitForProcess(pid)
        }.value
        if lock.withLock({ terminationRequested }) {
            await waitForProcessGroupToExit(pid)
        }
        finishReadingOutput()
        return terminationStatus(from: status)
    }

    func requestTermination() {
        let pid = lock.withLock { () -> pid_t? in
            terminationRequested = true
            return processIdentifier
        }
        guard let pid else { return }
        _ = Darwin.kill(-pid, SIGTERM)
    }

    func forceTerminateIfRunning() {
        guard let pid = lock.withLock({ processIdentifier }), processGroupExists(pid) else { return }
        _ = Darwin.kill(-pid, SIGKILL)
    }

    func forceTerminate() {
        guard let pid = lock.withLock({ processIdentifier }) else { return }
        _ = Darwin.kill(-pid, SIGKILL)
    }

    private func spawnProcess() throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutputPipe.fileHandleForWriting.fileDescriptor,
                STDOUT_FILENO
            )
        )
        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardErrorPipe.fileHandleForWriting.fileDescriptor,
                STDERR_FILENO
            )
        )
        try task.workingDirectoryURL.path.withCString { path in
            try check(posix_spawn_file_actions_addchdir_np(&fileActions, path))
        }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, flags))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let argumentStrings = [task.executableURL.path] + task.arguments
        let environmentStrings = task.environment.map { "\($0.key)=\($0.value)" }.sorted()
        let arguments = CStringArray(argumentStrings)
        let environment = CStringArray(environmentStrings)
        defer {
            arguments.release()
            environment.release()
        }

        var pid = pid_t()
        let result = task.executableURL.path.withCString { executablePath in
            arguments.withUnsafeMutableBufferPointer { argumentBuffer in
                environment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &pid,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        try check(result)
        return pid
    }

    private func finishReadingOutput() {
        stopReadingOutput()
        outputDispatcher.emit(
            channel: .standardOutput,
            data: standardOutputPipe.fileHandleForReading.availableData
        )
        outputDispatcher.emit(
            channel: .standardError,
            data: standardErrorPipe.fileHandleForReading.availableData
        )
        outputDispatcher.synchronize()
        try? standardOutputPipe.fileHandleForReading.close()
        try? standardErrorPipe.fileHandleForReading.close()
    }

    private func stopReadingOutput() {
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func check(_ result: Int32) throws {
        guard result != 0 else { return }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
    }
}

private final class CStringArray {
    private var storage: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        storage = strings.map { strdup($0) }
        storage.append(nil)
    }

    func withUnsafeMutableBufferPointer<Result>(
        _ body: (inout UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeMutableBufferPointer { buffer in
            var buffer = buffer
            return try body(&buffer)
        }
    }

    func release() {
        for pointer in storage where pointer != nil {
            free(pointer)
        }
        storage = []
    }
}

private func waitForProcess(_ pid: pid_t) -> Int32 {
    var status = Int32()
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    return status
}

private func terminationStatus(from waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7f
    if signal == 0 {
        return (waitStatus >> 8) & 0xff
    }
    return 128 + signal
}

private func processGroupExists(_ processGroupID: pid_t) -> Bool {
    errno = 0
    return Darwin.kill(-processGroupID, 0) == 0 || errno == EPERM
}

private func waitForProcessGroupToExit(_ processGroupID: pid_t) async {
    for _ in 0..<150 where processGroupExists(processGroupID) {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private final class TaskOutputDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let output: @Sendable (TaskOutputChunk) -> Void

    init(output: @escaping @Sendable (TaskOutputChunk) -> Void) {
        self.output = output
    }

    func emit(channel: TaskOutputChannel, data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            output(
                TaskOutputChunk(
                    channel: channel,
                    text: String(decoding: data, as: UTF8.self)
                )
            )
        }
    }

    func synchronize() {
        lock.withLock {}
    }
}
