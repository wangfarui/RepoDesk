import Foundation
import OSLog

actor AppDiagnosticLogger {
    static let shared = AppDiagnosticLogger()
    nonisolated static let logURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
    .appendingPathComponent("RepoDesk/Logs/RepoDesk.log", isDirectory: false)

    private static let maximumLogSize = 2 * 1_024 * 1_024
    private let destinationURL: URL
    private let systemLogger = Logger(
        subsystem: "com.wangfarui.RepoDesk",
        category: "Diagnostics"
    )

    init(logURL: URL = AppDiagnosticLogger.logURL) {
        destinationURL = logURL
    }

    @discardableResult
    func prepareLogFile() throws -> URL {
        let logURL = destinationURL
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try Data().write(to: logURL, options: .atomic)
        }
        return logURL
    }

    func record(_ message: String) {
        systemLogger.notice("\(message, privacy: .public)")
        do {
            let logURL = try prepareLogFile()
            try rotateIfNeeded(logURL)
            let timestamp = Date.now.formatted(
                .iso8601.year().month().day().dateSeparator(.dash)
                    .time(includingFractionalSeconds: true)
                    .timeSeparator(.colon)
            )
            let data = Data("[\(timestamp)] \(message)\n".utf8)
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            systemLogger.error(
                "Unable to write diagnostics log: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func rotateIfNeeded(_ logURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size >= Self.maximumLogSize else { return }
        let previousURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("RepoDesk.previous.log", isDirectory: false)
        if FileManager.default.fileExists(atPath: previousURL.path) {
            try FileManager.default.removeItem(at: previousURL)
        }
        try FileManager.default.moveItem(at: logURL, to: previousURL)
        try Data().write(to: logURL, options: .atomic)
    }
}
