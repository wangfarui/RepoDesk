import Foundation

/// Zip changes in parent-before-child order, preserving versions even for zero net edits.
enum GitBranchChangesCollector {
    static func append(
        _ files: [GitCommitFile], commit: String, parent: String?,
        to changes: inout [GitBranchComparisonFile]
    ) {
        // Resolve against the previous state: simultaneous renames must not consume
        // another change created by the same commit.
        let previous = changes
        var consumed = Set<Int>()
        var cancelled = Set<Int>()
        for file in files {
            let oldPath = file.originalPath ?? file.path
            let match = previous.indices.last { index in
                guard !consumed.contains(index) else { return false }
                let entry = previous[index]
                return file.status == .added
                    ? entry.after == nil && entry.before?.path == file.path
                    : entry.after?.path == oldPath
            }
            let after = file.status == .deleted ? nil : GitFileRevision(commit: commit, path: file.path)
            if let match {
                consumed.insert(match)
                changes[match].after = after
                if !changes[match].contributions.contains(commit) { changes[match].contributions.append(commit) }
                if changes[match].before == nil && after == nil { cancelled.insert(match) }
            } else {
                let before = file.status == .added ? nil : parent.map { GitFileRevision(commit: $0, path: oldPath) }
                changes.append(GitBranchComparisonFile(
                    before: before, after: after, contributions: [commit], initialStatus: file.status
                ))
            }
        }
        for index in cancelled.sorted(by: >) { changes.remove(at: index) }
    }
}
