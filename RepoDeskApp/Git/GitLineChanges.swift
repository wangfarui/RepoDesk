import Foundation
import Observation

enum GitLineChanges {
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func lines(in text: String) -> [String] {
        var text = normalized(text)
        guard !text.isEmpty else { return [] }
        let terminated = text.hasSuffix("\n")
        if terminated { text.removeLast() }
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { offset, line in
            terminated || offset < lines.count - 1 ? line + "\n" : line
        }
    }

    static func markers(baseline: [String], text: String) throws -> [Int: GitLineChangeKind] {
        try Task.checkCancellation()
        let current = lines(in: text)
        let difference = current.difference(from: baseline)
        try Task.checkCancellation()
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Int: GitLineChangeKind] = [:]
        var old = 0
        var new = 0
        while old < baseline.count || new < current.count {
            try Task.checkCancellation()
            var deletions = 0
            while removed.contains(old), old < baseline.count { old += 1; deletions += 1 }
            var additions = 0
            while inserted.contains(new), new < current.count {
                result[new + 1] = additions < deletions ? .modified : .added
                new += 1
                additions += 1
            }
            if old < baseline.count, new < current.count { old += 1; new += 1 }
            else { break }
        }
        return result
    }
    /// Pair replaced lines within each change block; surplus new lines are additions.
    /// Pure deletions have no corresponding line in the current document.
    static func markers(in patch: String) -> [Int: GitLineChangeKind] {
        var markers: [Int: GitLineChangeKind] = [:]
        for hunk in GitDiffParser.parseHunks(patch) {
            var newLine = hunk.newStart
            var deletedCount = 0
            var addedLines: [Int] = []

            func finishBlock() {
                for (offset, line) in addedLines.enumerated() {
                    markers[line] = offset < deletedCount ? .modified : .added
                }
                deletedCount = 0
                addedLines = []
            }

            for line in hunk.lines {
                switch line.kind {
                case .context:
                    finishBlock()
                    newLine += 1
                case .deletion:
                    deletedCount += 1
                case .addition:
                    addedLines.append(newLine)
                    newLine += 1
                }
            }
            finishBlock()
        }
        return markers
    }
}

/// Cache the baseline per file/revision/rename state. Typing compares immutable line snapshots
/// off the main actor, and the latest completed result replaces the gutter atomically.
@MainActor @Observable
final class FileGitLineChanges {
    private(set) var fileIdentity = ""
    private(set) var markers: [Int: GitLineChangeKind] = [:]
    @ObservationIgnored private var baseline: [String]?
    @ObservationIgnored private var currentText = ""
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var comparisonID = UUID()
    @ObservationIgnored private var comparison: Task<[Int: GitLineChangeKind], any Error>?
    var isComputing: Bool { comparison != nil }

    deinit { comparison?.cancel() }

    func load(fileIdentity: String, text: String, using loader: () async throws -> String?) async {
        guard !Task.isCancelled else { return }
        comparison?.cancel()
        comparison = nil
        comparisonID = UUID()
        generation = UUID()
        let request = generation
        self.fileIdentity = fileIdentity
        currentText = text
        baseline = nil
        isReady = false
        markers = [:]
        do {
            let source = try await loader()
            guard generation == request, !Task.isCancelled else { return }
            baseline = source.map(GitLineChanges.lines(in:))
            isReady = true
            update(text: currentText, fileIdentity: fileIdentity)
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            isReady = true
        }
    }

    func update(text: String, fileIdentity: String) {
        guard self.fileIdentity == fileIdentity else { return }
        currentText = text
        guard isReady else { return }
        comparison?.cancel()
        comparisonID = UUID()
        let request = comparisonID
        guard let baseline else { markers = [:]; comparison = nil; return }
        let task = Task.detached(priority: .userInitiated) {
            try GitLineChanges.markers(baseline: baseline, text: text)
        }
        comparison = task
        Task { [weak self] in
            let result = try? await task.value
            guard let self, comparisonID == request, !task.isCancelled else { return }
            if let result, markers != result { markers = result }
            comparison = nil
        }
    }
}
