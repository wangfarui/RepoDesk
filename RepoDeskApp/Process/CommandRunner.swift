import Foundation
import Darwin

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
        lock.lock()
        if didComplete {
            let error = pendingError ?? CancellationError()
            lock.unlock()
            continuation.resume(throwing: error)
            return
        }
        self.continuation = continuation
        do {
            try configureProcess()
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

    private func configureProcess() throws {
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectoryURL
        if let environment = request.environment {
            process.environment = environment
        }
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        try standardOutput.prepare(standardOutputPipe.fileHandleForReading)
        try standardError.prepare(standardErrorPipe.fileHandleForReading)
        standardOutputPipe.fileHandleForReading.readabilityHandler = { [standardOutput] handle in
            standardOutput.readAvailable(from: handle)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { [standardError] handle in
            standardError.readAvailable(from: handle)
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
        do {
            let output = try standardOutput.finishReading(from: standardOutputPipe.fileHandleForReading)
            let errors = try standardError.finishReading(from: standardErrorPipe.fileHandleForReading)
            continuation?.resume(returning: CommandResult(
                standardOutput: output, standardError: errors, terminationStatus: process.terminationStatus
            ))
        } catch {
            stopReadingOutput()
            continuation?.resume(throwing: error)
        }
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
        standardOutput.stop()
        standardError.stop()
    }
}

private final class OutputAccumulator: @unchecked Sendable {
    // Darwin's _IOR('f', 127, int), declared as FIONREAD in sys/filio.h.
    // Swift cannot import the sizeof-based C macro.
    private static let bytesAvailableRequest: UInt = 0x4000_0000
        | (UInt(MemoryLayout<CInt>.size) << 16) | (UInt(102) << 8) | 127
    private let lock = NSLock()
    private var storage = Data()
    private var isFinished = false

    func prepare(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags != -1, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func readAvailable(from handle: FileHandle) {
        lock.withLock {
            guard !isFinished else { return }
            _ = readChunk(from: handle)
        }
    }

    func finishReading(from handle: FileHandle) throws -> Data {
        handle.readabilityHandler = nil
        return try lock.withLock {
            // Serialize the read itself with callbacks, then drain every remaining
            // byte before publishing the result. Queued callbacks cannot append later.
            if !isFinished {
                var available: Int32 = 0
                guard ioctl(handle.fileDescriptor, Self.bytesAvailableRequest, &available) != -1 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                // Bound the final drain to bytes already buffered at process exit;
                // a descendant that inherited the pipe must not prolong completion.
                var remaining = Int(available)
                while remaining > 0 {
                    let count = readChunk(from: handle, limit: remaining)
                    guard count > 0 else { break }
                    remaining -= count
                }
                isFinished = true
            }
            return storage
        }
    }

    func stop() {
        lock.withLock { isFinished = true }
    }

    private func readChunk(from handle: FileHandle, limit: Int = 65_536) -> Int {
        var buffer = [UInt8](repeating: 0, count: min(65_536, limit))
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                storage.append(contentsOf: buffer.prefix(count))
                return count
            }
            if count < 0, errno == EINTR { continue }
            // Nonblocking reads stop at EOF/EAGAIN, including when a descendant
            // inherits a pipe. Cancellation and completion never wait for that child.
            return 0
        }
    }
}
