import AppKit
import Foundation
@testable import RepoDesk

private struct PerformanceVerificationError: Error {
    let message: String
}

@main
@MainActor
enum PerformanceSuiteVerification {
    static func main() async throws {
        let fixture = try PerformanceWorkspaceFixture()
        defer { fixture.remove() }

        try await verifyRepositoryDiscovery(in: fixture)
        try await verifyFileBrowsingAndSearch(in: fixture)
        try verifyGitSnapshotAndChangesPlanning()
        try verifyDiffBlameAndHistoryParsing()
        try await verifyGitOperationPlanning(in: fixture)
        try verifyStreamingLogPerformance()

        print("Performance suite verification passed")
    }

    private static func verifyRepositoryDiscovery(
        in fixture: PerformanceWorkspaceFixture
    ) async throws {
        let (repositories, duration) = await measure {
            await FileSystemRepositoryDiscoverer().discoverRepositories(in: fixture.rootURL)
        }
        try require(repositories.count == fixture.repositoryCount, "Repository discovery returned an incorrect count.")
        try require(duration < 2, "Repository discovery exceeded the 2s budget: \(format(duration))s.")
        report("Repository discovery", duration)
    }

    private static func verifyFileBrowsingAndSearch(
        in fixture: PerformanceWorkspaceFixture
    ) async throws {
        let (entries, browseDuration) = try await measure {
            try await FileSystemWorkspaceBrowser().children(of: fixture.largeDirectoryURL)
        }
        try require(entries.count == fixture.largeDirectoryFileCount, "File browsing returned an incorrect count.")
        try require(browseDuration < 1, "File browsing exceeded the 1s budget: \(format(browseDuration))s.")

        let (matches, searchDuration) = await measure {
            await FileSystemWorkspaceSearch().search(
                in: fixture.rootURL,
                query: "PerformanceNeedle",
                limit: 100
            )
        }
        try require(matches.count == 100, "File search did not stop at its result limit.")
        try require(searchDuration < 2, "File search exceeded the 2s budget: \(format(searchDuration))s.")
        report("File browsing", browseDuration)
        report("File search", searchDuration)
    }

    private static func verifyGitSnapshotAndChangesPlanning() throws {
        var statusData = Data("# branch.head main\0# branch.ab +3 -2\0".utf8)
        let selections = (0..<10_000).map { index in
            let path = "module-\(index % 40)/src/main/java/example/File\(index).java"
            statusData.append(Data("? \(path)\0".utf8))
            return GitChangeSelection(path: path, kind: .unversioned)
        }

        let (status, snapshotDuration) = measure {
            GitStatusParser.parse(statusData)
        }
        try require(status.changes.count == selections.count, "Git Snapshot parsing lost changes.")
        try require(snapshotDuration < 0.75, "Git Snapshot parsing exceeded the 750ms budget: \(format(snapshotDuration))s.")

        let ((nodeIDs, rows), changesDuration) = measure {
            let nodeIDs = ChangesOutlineBuilder.directoryExpandableNodeIDs(
                selections: selections,
                namespace: "performance"
            )
            let rows = ChangesOutlineBuilder.directoryRows(
                selections: selections,
                namespace: "performance",
                statusIsExpanded: true,
                expandedNodeIDs: nodeIDs
            )
            return (nodeIDs, rows)
        }
        try require(!nodeIDs.isEmpty && rows.count > selections.count, "Changes outline was not fully materialized.")
        try require(changesDuration < 1.5, "Changes planning exceeded the 1.5s budget: \(format(changesDuration))s.")
        report("Git Snapshot parsing", snapshotDuration)
        report("Changes planning", changesDuration)
    }

    private static func verifyDiffBlameAndHistoryParsing() throws {
        var patch = ""
        patch.reserveCapacity(1_000_000)
        for index in 1...2_000 {
            patch += "@@ -\(index),2 +\(index),2 @@\n context \(index)\n-old \(index)\n+new \(index)\n"
        }
        let (hunks, diffDuration) = measure { GitDiffParser.parseHunks(patch) }
        try require(hunks.count == 2_000, "Diff parsing returned an incorrect hunk count.")
        try require(diffDuration < 1, "Diff parsing exceeded the 1s budget: \(format(diffDuration))s.")

        var blameData = Data()
        blameData.reserveCapacity(2_000_000)
        for index in 1...10_000 {
            let hash = String(format: "%040llx", Int64(index))
            blameData.append(Data("\(hash) \(index) \(index) 1\nauthor Performance User\nauthor-time 1706745600\n\tline \(index)\n".utf8))
        }
        let (blame, blameDuration) = measure { GitBlameParser.parse(blameData) }
        try require(blame.count == 10_000, "Blame parsing returned an incorrect line count.")
        try require(blameDuration < 1, "Blame parsing exceeded the 1s budget: \(format(blameDuration))s.")

        var historyData = Data()
        historyData.reserveCapacity(1_000_000)
        for index in 1...5_000 {
            historyData.append(0x1e)
            historyData.append(
                Data("hash-\(index)\u{1f}subject \(index)\u{1f}Performance User\u{1f}2026-08-17T00:00:00Z\u{1f}main, tag\n".utf8)
            )
        }
        let (history, historyDuration) = measure { GitHistoryParser.parse(historyData) }
        try require(history.count == 5_000, "History parsing returned an incorrect commit count.")
        try require(historyDuration < 1, "History parsing exceeded the 1s budget: \(format(historyDuration))s.")
        report("Diff parsing", diffDuration)
        report("Blame parsing", blameDuration)
        report("History parsing", historyDuration)
    }

    private static func verifyGitOperationPlanning(
        in fixture: PerformanceWorkspaceFixture
    ) async throws {
        let runner = RecordingCommandRunner()
        let operatorUnderTest = SystemGitRepositoryOperator(
            commandRunner: runner,
            gitURL: URL(fileURLWithPath: "/usr/bin/git")
        )
        let changes = (0..<1_000).map {
            GitChangeSelection(path: "src/File\($0).swift", kind: .changes)
        }
        let (_, duration) = try await measure {
            try await operatorUnderTest.createCommit(
                repositoryURL: fixture.rootURL,
                message: "Performance verification",
                changes: changes
            )
        }
        let requests = await runner.recordedArguments()
        try require(requests.count == 3, "Git operation did not execute the expected stages.")
        try require(requests[0].count > changes.count, "Git staging did not preserve the selected file scope.")
        try require(duration < 0.5, "Git operation planning exceeded the 500ms budget: \(format(duration))s.")
        report("Git operation planning", duration)
    }

    private static func verifyStreamingLogPerformance() throws {
        let buffer = StreamingTaskOutputBuffer()
        var scheduledFlushes = 0
        let (bufferedText, bufferDuration) = measure {
            for index in 0..<10_000 where buffer.append("line \(index)\n") {
                scheduledFlushes += 1
            }
            return buffer.take()
        }
        try require(scheduledFlushes == 1, "Streaming output scheduled redundant UI flushes.")
        try require(bufferedText.contains("line 9999"), "Streaming output lost buffered text.")
        try require(buffer.append("next\n"), "Streaming output did not re-arm after a flush.")
        _ = buffer.take()

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        var log = (0..<20_000).map { "existing log line \($0)" }.joined(separator: "\n") + "\n"
        textView.string = log
        let (_, appendDuration) = measure {
            for index in 0..<300 {
                log.append("streamed log line \(index)\n")
                NativeTextStorageUpdater.update(
                    log,
                    style: .plain,
                    styleChanged: false,
                    mode: .appendOnly,
                    in: textView
                )
            }
        }
        try require(textView.string == log, "Incremental log rendering lost content.")
        try require(bufferDuration < 0.25, "Log buffering exceeded the 250ms budget: \(format(bufferDuration))s.")
        try require(appendDuration < 1.5, "Incremental log rendering exceeded the 1.5s budget: \(format(appendDuration))s.")
        report("Log buffering", bufferDuration)
        report("Incremental log rendering", appendDuration)
    }

    private static func measure<T>(_ body: () throws -> T) rethrows -> (T, TimeInterval) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let value = try body()
        return (value, ProcessInfo.processInfo.systemUptime - startedAt)
    }

    private static func measure<T: Sendable>(
        _ body: () async throws -> T
    ) async rethrows -> (T, TimeInterval) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let value = try await body()
        return (value, ProcessInfo.processInfo.systemUptime - startedAt)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PerformanceVerificationError(message: message) }
    }

    private static func report(_ name: String, _ duration: TimeInterval) {
        FileHandle.standardError.write(Data("\(name): \(format(duration))s\n".utf8))
    }

    private static func format(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }
}

private final class PerformanceWorkspaceFixture {
    let rootURL: URL
    let largeDirectoryURL: URL
    let repositoryCount = 60
    let largeDirectoryFileCount = 2_000

    init() throws {
        let fileManager = FileManager.default
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("RepoDeskPerformance-\(UUID().uuidString)", isDirectory: true)
        largeDirectoryURL = rootURL.appendingPathComponent("large-directory", isDirectory: true)
        try fileManager.createDirectory(at: largeDirectoryURL, withIntermediateDirectories: true)

        let emptyData = Data()
        for index in 0..<largeDirectoryFileCount {
            let name = index < 100 ? "PerformanceNeedle-\(index).txt" : "File-\(index).txt"
            try emptyData.write(to: largeDirectoryURL.appendingPathComponent(name))
        }
        for repositoryIndex in 0..<repositoryCount {
            let repositoryURL = rootURL.appendingPathComponent(
                "group-\(repositoryIndex / 10)/repository-\(repositoryIndex)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: repositoryURL.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
            let sourceURL = repositoryURL.appendingPathComponent("src/main/java", isDirectory: true)
            try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            for fileIndex in 0..<40 {
                let name = fileIndex == 0
                    ? "PerformanceNeedle-\(repositoryIndex).java"
                    : "Source-\(fileIndex).java"
                try emptyData.write(to: sourceURL.appendingPathComponent(name))
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor RecordingCommandRunner: CommandRunning {
    private var arguments: [[String]] = []

    func run(_ request: CommandRequest) async throws -> CommandResult {
        arguments.append(request.arguments)
        let output = request.arguments.first == "rev-parse"
            ? Data("0123456789012345678901234567890123456789\n".utf8)
            : Data()
        return CommandResult(
            standardOutput: output,
            standardError: Data(),
            terminationStatus: 0
        )
    }

    func recordedArguments() -> [[String]] {
        arguments
    }
}
