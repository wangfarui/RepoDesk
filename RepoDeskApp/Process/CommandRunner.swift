import Foundation

struct CommandRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let environment: [String: String]?
}

struct CommandResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
}

enum CommandRunnerError: LocalizedError, Sendable {
    case timedOut(Duration)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "命令执行超时，已终止进程。"
        }
    }
}

struct SystemCommandRunner: CommandRunning {
    private let timeout: Duration

    init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let execution = CommandExecution(request: request, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class CommandExecution: @unchecked Sendable {
    private let request: CommandRequest
    private let timeout: Duration
    private let process = Process()
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let standardOutput = OutputAccumulator()
    private let standardError = OutputAccumulator()
    private let lock = NSLock()

    private var continuation: CheckedContinuation<CommandResult, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingError: (any Error)?
    private var didComplete = false

    init(request: CommandRequest, timeout: Duration) {
        self.request = request
        self.timeout = timeout
    }

    func start(continuation: CheckedContinuation<CommandResult, any Error>) {
        configureProcess()

        lock.lock()
        if didComplete {
            let error = pendingError ?? CancellationError()
            lock.unlock()
            continuation.resume(throwing: error)
            return
        }
        self.continuation = continuation
        do {
            try process.run()
            lock.unlock()
            scheduleTimeout()
        } catch {
            didComplete = true
            self.continuation = nil
            lock.unlock()
            stopReadingOutput()
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        finishAbnormally(with: CancellationError())
    }

    private func configureProcess() {
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectoryURL
        if let environment = request.environment {
            process.environment = environment
        }
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        standardOutputPipe.fileHandleForReading.readabilityHandler = { [standardOutput] handle in
            standardOutput.append(handle.availableData)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { [standardError] handle in
            standardError.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(process)
        }
    }

    private func scheduleTimeout() {
        let task = Task { [weak self, timeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finishAbnormally(with: CommandRunnerError.timedOut(timeout))
        }

        lock.lock()
        if didComplete {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    private func processDidTerminate(_ process: Process) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        stopReadingOutput()
        standardOutput.append(standardOutputPipe.fileHandleForReading.availableData)
        standardError.append(standardErrorPipe.fileHandleForReading.availableData)
        continuation?.resume(
            returning: CommandResult(
                standardOutput: standardOutput.data,
                standardError: standardError.data,
                terminationStatus: process.terminationStatus
            )
        )
    }

    private func finishAbnormally(with error: any Error) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        pendingError = error
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        let shouldTerminate = process.isRunning
        lock.unlock()

        timeoutTask?.cancel()
        stopReadingOutput()
        process.terminationHandler = nil
        if shouldTerminate {
            process.terminate()
        }
        continuation?.resume(throwing: error)
    }

    private func stopReadingOutput() {
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
    }
}

private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            storage.append(data)
        }
    }
}
