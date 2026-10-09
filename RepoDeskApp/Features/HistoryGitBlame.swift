import Foundation
import Observation

struct HistoryGitBlameTarget: Equatable, Sendable {
    let revision: String
    let path: String
}

struct HistoryGitBlameContext: Equatable, Sendable {
    let repositoryURL: URL
    let commitHash: String
    let path: String
    let targets: [GitHistoryBlameSide: HistoryGitBlameTarget]

    init(repositoryURL: URL, detail: GitCommitDetail, diff: GitFileDiff, source: GitFileDiff? = nil) {
        self.repositoryURL = repositoryURL
        commitHash = detail.summary.hash
        path = diff.path
        var targets: [GitHistoryBlameSide: HistoryGitBlameTarget] = [:]
        if !diff.isBinary, source?.isBinary != true {
            if let parent = detail.parentHashes.first, !diff.oldLines.isEmpty {
                targets[.target] = HistoryGitBlameTarget(
                    revision: parent,
                    path: diff.originalPath ?? diff.path
                )
            }
            if !diff.newLines.isEmpty {
                targets[.result] = HistoryGitBlameTarget(revision: commitHash, path: diff.path)
            }
            if let source, detail.parentHashes.count == 2, !source.oldLines.isEmpty {
                targets[.source] = HistoryGitBlameTarget(
                    revision: detail.parentHashes[1],
                    path: source.originalPath ?? source.path
                )
            }
        }
        self.targets = targets
    }
}

@MainActor
@Observable
final class HistoryGitBlame {
    private(set) var context: HistoryGitBlameContext?
    private(set) var visibleSides: Set<GitHistoryBlameSide> = []
    private(set) var loadingSides: Set<GitHistoryBlameSide> = []
    private(set) var errors: [GitHistoryBlameSide: String] = [:]
    private var cache: [GitHistoryBlameSide: [Int: GitBlameLine]] = [:]
    private var generation = UUID()

    var availableSides: Set<GitHistoryBlameSide> {
        Set(context?.targets.keys.map { $0 } ?? [])
    }

    var allSidesVisible: Bool {
        !availableSides.isEmpty && availableSides.isSubset(of: visibleSides)
    }

    func annotations(for side: GitHistoryBlameSide) -> [Int: GitBlameLine]? {
        visibleSides.contains(side) ? (cache[side] ?? [:]) : nil
    }

    func configure(_ context: HistoryGitBlameContext) {
        guard self.context != context else { return }
        reset()
        self.context = context
    }

    func reset() {
        generation = UUID()
        context = nil
        visibleSides = []
        loadingSides = []
        errors = [:]
        cache = [:]
    }

    func toggleAll(using reader: any GitRepositoryReading) {
        if allSidesVisible {
            visibleSides = []
        } else {
            for side in GitHistoryBlameSide.allCases where availableSides.contains(side) {
                show(side, using: reader)
            }
        }
    }

    func toggle(_ side: GitHistoryBlameSide, using reader: any GitRepositoryReading) {
        if visibleSides.remove(side) == nil {
            show(side, using: reader)
        }
    }

    private func show(_ side: GitHistoryBlameSide, using reader: any GitRepositoryReading) {
        guard let context, let target = context.targets[side] else { return }
        visibleSides.insert(side)
        errors[side] = nil
        guard cache[side] == nil, !loadingSides.contains(side) else { return }
        loadingSides.insert(side)
        let requestGeneration = generation
        Task {
            do {
                let lines = try await reader.blame(
                    repositoryURL: context.repositoryURL,
                    path: target.path,
                    revision: target.revision,
                    contentsPath: nil
                )
                let indexed = await Task.detached(priority: .userInitiated) {
                    lines.indexedByLineNumber
                }.value
                guard generation == requestGeneration else { return }
                cache[side] = indexed
            } catch {
                guard generation == requestGeneration else { return }
                if visibleSides.remove(side) != nil {
                    errors[side] = error.localizedDescription
                }
            }
            guard generation == requestGeneration else { return }
            loadingSides.remove(side)
        }
    }
}
