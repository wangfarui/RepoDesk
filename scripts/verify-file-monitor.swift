import Foundation

enum FileMonitorVerificationError: LocalizedError {
    case monitorFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .monitorFailed(let message): message
        case .timedOut: "Timed out waiting for a recursive workspace file event."
        }
    }
}

private enum VerificationOutcome: Sendable {
    case passed
    case failed(String)
}

private actor VerificationResult {
    private var fileEventObserved = false
    private var gitEventObserved = false
    private var failureMessage: String?

    func recordFileEvent() {
        fileEventObserved = true
    }

    func recordGitEvent() {
        gitEventObserved = true
    }

    func recordFailure(_ message: String) {
        failureMessage = message
    }

    func current() -> VerificationOutcome? {
        if let failureMessage { return .failed(failureMessage) }
        return fileEventObserved && gitEventObserved ? .passed : nil
    }
}

@main
struct FileMonitorVerification {
    static func main() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskFileMonitor-\(UUID().uuidString)", isDirectory: true)
        let nestedURL = rootURL.appendingPathComponent("Sources/Feature", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("Repository", isDirectory: true)
        let gitRefsURL = repositoryURL.appendingPathComponent(".git/refs/heads", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitRefsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stream = SystemWorkspaceChangeMonitor(debounceInterval: 0.1).events(in: rootURL)
        let changedFileURL = nestedURL.appendingPathComponent("Observed.swift")
        let result = VerificationResult()
        let observer = Task {
            for await batch in stream {
                if let monitoringError = batch.monitoringError {
                    await result.recordFailure(monitoringError)
                    return
                }
                if batch.requiresFullRescan || batch.changedURLs.contains(changedFileURL) {
                    await result.recordFileEvent()
                }
                if batch.requiresFullRescan || batch.changedURLs.contains(repositoryURL) {
                    await result.recordGitEvent()
                }
            }
            await result.recordFailure(FileMonitorVerificationError.timedOut.localizedDescription)
        }

        try await Task.sleep(for: .milliseconds(250))
        try Data("let observed = true\n".utf8).write(to: changedFileURL)
        try await Task.sleep(for: .milliseconds(250))
        try Data("0123456789abcdef\n".utf8).write(to: gitRefsURL.appendingPathComponent("main"))

        for _ in 0..<50 {
            if let outcome = await result.current() {
                observer.cancel()
                switch outcome {
                case .passed:
                    print("Workspace file monitor verification passed")
                    return
                case .failed(let message):
                    throw FileMonitorVerificationError.monitorFailed(message)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        observer.cancel()
        throw FileMonitorVerificationError.timedOut
    }
}
