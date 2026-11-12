import Foundation
@testable import RepoDesk

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}

struct Fixture {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("RepoDesk-Comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Comparison Verification"])
        try git(["config", "user.email", "compare@example.test"])
        try git(["config", "commit.gpgsign", "false"])
    }
    @discardableResult func git(_ args: [String]) throws -> String {
        let p = Process(); let out = Pipe(); let err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
        p.currentDirectoryURL = url; p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(message: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func write(_ path: String, _ content: String) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: target)
    }
    @discardableResult func commit(_ message: String) throws -> String {
        try git(["add", "-A"]); try git(["commit", "--allow-empty", "-m", message])
        return try git(["rev-parse", "HEAD"])
    }
}

@main @MainActor
enum VerifyGitBranchComparison {
    static let reader = SystemGitRepositoryReader()
    static func main() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.url) }
        try f.write("dir/original name\tfile.txt", "one\ntwo\nthree\n")
        try f.write("restore.txt", "original\n")
        try f.write("delete.txt", "delete me\n")
        try f.write("shared.txt", "a\nb\nc\nd\n")
        let root = try f.commit("base")
        try f.git(["checkout", "-b", "feature"])
        try f.write("dir/original name\tfile.txt", "one\nchanged\nthree\n")
        try f.write("restore.txt", "changed\n")
        try f.write("temporary.txt", "temporary\n")
        let first = try f.commit("feature one")
        try f.git(["mv", "dir/original name\tfile.txt", "dir/renamed file.txt"])
        let rename = try f.commit("rename")
        try f.git(["mv", "dir/renamed file.txt", "dir/final\nname.txt"])
        try f.write("restore.txt", "original\n")
        try f.git(["rm", "temporary.txt", "delete.txt"])
        try f.write("added.txt", "new\n")
        try f.write("shared.txt", "feature\nb\nc\nd\n")
        let last = try f.commit("feature final")
        let empty = try f.commit("empty unique")
        try f.git(["checkout", "main"])
        try f.write("remote only.txt", "remote\n")
        try f.write("shared.txt", "a\nb\nc\nremote\n")
        let remote = try f.commit("remote side")
        try f.git(["update-ref", "refs/remotes/origin/main", remote])
        try f.git(["checkout", "feature"])
        let local = try await compare(f, "refs/heads/main")
        let remoteComparison = try await compare(f, "refs/remotes/origin/main")
        try require(local.commits == remoteComparison.commits && local.files == remoteComparison.files, "Local/remote comparison differs")
        try require(local.commits.map(\.hash) == [first, rename, last, empty], "Range must be current-only, parent first, including empty commits")
        try require(local.baseSHA == empty && local.comparedSHA == remote, "Endpoints not pinned")
        try require(Set(local.files.map { $0.file.path }) == Set(["dir/final\nname.txt", "restore.txt", "delete.txt", "added.txt", "shared.txt"]), "Incorrect aggregate files")
        let renamed = try file(local, "dir/final\nname.txt")
        try require(renamed.file.status == .renamed && renamed.before == GitFileRevision(commit: root, path: "dir/original name\tfile.txt") && renamed.after?.commit == last, "Rename versions lost")
        try require(renamed.contributions == [first, rename, last], "Contributing commits lost")
        let renamedDiff = try await diff(f, renamed)
        try require(renamedDiff.oldLines == ["one", "two", "three"] && renamedDiff.newLines == ["one", "changed", "three"] && renamedDiff.hunks.count == 1, "Rename content diff incorrect")
        let restored = try file(local, "restore.txt")
        let restoredDiff = try await diff(f, restored)
        try require(restored.contributions == [first, last] && restoredDiff.hunks.isEmpty && restoredDiff.oldLines == restoredDiff.newLines, "Restored file must retain history with zero net diff")
        try require(restored.isNetUnchanged && restored.statusLabel == "≡", "Restored file must use the unchanged marker")
        try require(local.unchangedFileCount == 1 && local.netChangedFileCount == 4
            && !local.visibleFiles(includingUnchanged: false).contains(restored)
            && local.visibleFiles(includingUnchanged: true) == local.files, "Default hidden / expanded summary or counts incorrect")
        let addedDiff = try await diff(f, file(local, "added.txt"))
        let deletedDiff = try await diff(f, file(local, "delete.txt"))
        try require(addedDiff.oldLines.isEmpty && addedDiff.newLines == ["new"] && !addedDiff.hunks.isEmpty, "Added side incorrect")
        try require(deletedDiff.oldLines == ["delete me"] && deletedDiff.newLines.isEmpty && !deletedDiff.hunks.isEmpty, "Deleted side incorrect")
        let noCommits = try await compare(f, "refs/heads/feature")
        try require(noCommits.commits.isEmpty && noCommits.files.isEmpty, "Zero unique result incorrect")
        // Working tree/index never participate; old path re-use must not pollute a renamed file's patch.
        try f.write("dir/original name\tfile.txt", "unrelated new file\n")
        try f.write("added.txt", "dirty worktree\n")
        try f.git(["add", "added.txt"])
        let dirtyDiff = try await diff(f, renamed)
        try require(dirtyDiff == renamedDiff, "Committed diff used worktree/index")
        try f.git(["reset", "--hard", "HEAD"])
        try f.git(["clean", "-fd"])
        // A real merge imports remote-only changes but also creates a merge-only file.
        try f.git(["merge", "--no-ff", "--no-commit", "main"])
        try f.write("merge only.txt", "resolution\n")
        let merge = try f.commit("merge main plus manual change")
        let merged = try await compare(f, "refs/remotes/origin/main")
        try require(merged.commits.map(\.hash) == [first, rename, last, empty, merge], "Merge omitted or remote commit leaked")
        try require(!merged.files.contains { $0.file.path == "remote only.txt" }, "Imported remote file must be excluded")
        let mergeOnly = try file(merged, "merge only.txt")
        try require(mergeOnly.file.status == .added && mergeOnly.contributions == [merge], "Merge-authored file missing")
        let mergedShared = try file(merged, "shared.txt")
        try require(mergedShared.contributions == [last, merge], "Merge changed relative to both parents must contribute")
        let mergedDiff = try await diff(f, mergedShared)
        try require(mergedDiff.newLines == ["feature", "b", "c", "remote"], "Final file version must include actual merge content")
        try require(merged.records.filter { $0.commit == merge }.map(\.parent) == [empty, remote], "Per-parent records lost")
        let detail = try await reader.commit(repositoryURL: f.url, hash: merge)
        let mergeFile = try requireFile(detail.files, "shared.txt")
        let threeWay = try await reader.mergeFileDiff(repositoryURL: f.url, hash: merge, parentHashes: detail.parentHashes, file: mergeFile, ignoringWhitespace: false)
        try require(threeWay.target.newLines == mergedDiff.newLines && threeWay.source.newLines == mergedDiff.newLines, "Single merge diff unavailable")
        try await verifyComparisonBlame(f, comparison: local, root: root, first: first, last: last,
            merged: merged, mergeDetail: detail, mergeFile: mergeFile, remote: remote)
        // SHA binding survives moving refs after opening.
        try f.git(["update-ref", "refs/heads/feature", root])
        let pinnedDiff = try await diff(f, mergedShared)
        try require(pinnedDiff == mergedDiff, "Ref movement changed pinned diff")
        do {
            _ = try await compare(f, "refs/remotes/missing/main")
            throw Failure(message: "Missing ref displayed as empty")
        } catch is GitRepositoryError { }
        try await verifyCancellation(f)
        try await verifyCancellationAndRecreation()
        try await verifyRequestIsolation()
        try await verifyCherryPickAndOldPathReuse()
        try await verifySharedResultPath()
        try await verifyUnchangedClassification()
        let failedHistory = BranchComparisonSession(repositoryURL: f.url, current: "refs/heads/feature", selected: "refs/heads/main",
            reader: SystemGitRepositoryReader(commandRunner: HistoryFailureRunner()))
        await failedHistory.load()
        try require(failedHistory.error?.contains("history read failed") == true && failedHistory.comparison == nil && !failedHistory.isLoading,
            "History failure displayed as normal empty result")
        print("Branch comparison verification passed: local/remote, divergence, versions, NUL paths, rename chains, cancellation, reverts, merges, pinned refs and errors")
    }

    static func waitForBlame(_ state: BranchComparisonDiffState) async throws {
        for _ in 0..<400 {
            if state.blame.loadingSides.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "Blame load timed out")
    }

    static func verifyComparisonBlame(_ f: Fixture, comparison: GitBranchComparison, root: String,
        first: String, last: String, merged: GitBranchComparison, mergeDetail: GitCommitDetail,
        mergeFile: GitCommitFile, remote: String) async throws {
        let tracking = ComparisonBlameReader()
        let session = BranchComparisonSession(repositoryURL: f.url, current: "feature", selected: "main", reader: tracking)
        let state = BranchComparisonDiffState()
        let renamed = try file(comparison, "dir/final\nname.txt")
        await state.load(session: session, file: renamed.file, commit: nil, target: renamed.target, ignoringWhitespace: false)
        let initialRequests = await tracking.requests()
        try require(state.blame.visibleSides.isEmpty && initialRequests.isEmpty, "Blame loaded without user request")
        state.annotate(using: tracking)
        try await waitForBlame(state)
        try require(state.blame.allSidesVisible && state.blame.errors.isEmpty, "Summary annotate-all failed")
        let requests = await tracking.requests()
        try require(Set(requests.map(\.revision)) == [root, last] && requests.allSatisfy { $0.repositoryURL == f.url && $0.contentsPath == nil },
            "Summary blame used branch endpoints or worktree")
        try require(requests.contains { $0.revision == root && $0.path == "dir/original name\tfile.txt" }
            && requests.contains { $0.revision == last && $0.path == "dir/final\nname.txt" }, "Rename blame used wrong historical paths")
        try require(state.blame.annotations(for: .target)?[2]?.commitHash == root
            && state.blame.annotations(for: .result)?[2]?.commitHash == first
            && state.blame.annotations(for: .result)?[1]?.commitHash == root, "Summary line attribution excluded common history")
        try require(state.blame.annotations(for: .result)?[2]?.authorEmail == "compare@example.test"
            && state.blame.annotations(for: .result)?[2]?.message?.contains("feature one") == true, "Blame hover metadata missing")
        state.blame.toggle(.target, using: tracking)
        try require(state.blame.visibleSides == [.result], "Per-pane toggle changed both panes")
        await state.load(session: session, file: renamed.file, commit: nil, target: renamed.target, ignoringWhitespace: true)
        let cachedRequests = await tracking.requests()
        try require(state.blame.visibleSides == [.result] && state.blame.annotations(for: .result)?[2]?.commitHash == first
            && cachedRequests.count == 2, "Whitespace reload reset annotations or reissued blame")
        state.annotate(using: tracking)
        try require(state.blame.allSidesVisible, "File menu did not restore all sides")
        state.annotate(using: tracking)
        try require(state.blame.visibleSides.isEmpty, "File menu did not hide all sides")

        for (path, sides) in [("added.txt", Set<GitHistoryBlameSide>([.result])), ("delete.txt", [.target]), ("restore.txt", [.target, .result])] {
            let entry = try file(comparison, path)
            state.cancel()
            // File menu can request annotations before the lazy Diff finishes loading.
            state.annotate(using: tracking)
            await state.load(session: session, file: entry.file, commit: nil, target: entry.target, ignoringWhitespace: false)
            try await waitForBlame(state)
            try require(state.blame.availableSides == sides && state.blame.visibleSides == sides && state.blame.errors.isEmpty,
                "Missing/empty side annotated for \(path)")
        }
        let commitDetail = try await reader.commit(repositoryURL: f.url, hash: first)
        let commitFile = try requireFile(commitDetail.files, "restore.txt")
        state.cancel(); state.annotate(using: tracking)
        await state.load(session: session, file: commitFile, commit: commitDetail, target: nil, ignoringWhitespace: false)
        try await waitForBlame(state)
        try require(state.blame.context?.targets[.target]?.revision == root
            && state.blame.context?.targets[.result]?.revision == first && state.blame.errors.isEmpty, "Single commit blame used wrong versions")
        state.cancel(); state.annotate(using: tracking)
        await state.load(session: session, file: mergeFile, commit: mergeDetail, target: nil, ignoringWhitespace: false)
        try await waitForBlame(state)
        try require(state.blame.visibleSides == [.target, .result, .source]
            && state.blame.context?.targets[.source]?.revision == remote && state.blame.errors.isEmpty, "Merge three-pane blame failed")
        try require(state.blame.annotations(for: .result)?[1]?.commitHash == last
            && state.blame.annotations(for: .result)?[4]?.commitHash == remote, "Merge result blamed wrong branch")
        let shared = try file(merged, "shared.txt")
        state.cancel(); state.annotate(using: tracking)
        await state.load(session: session, file: shared.file, commit: nil, target: shared.target, ignoringWhitespace: false)
        try await waitForBlame(state)
        try require(state.blame.annotations(for: .result)?[4]?.commitHash == remote, "Summary lost imported-line attribution")

        // A reader that returns after reset must not contaminate the next file/window.
        await tracking.setHolding(true)
        state.cancel(); state.annotate(using: tracking)
        await state.load(session: session, file: renamed.file, commit: nil, target: renamed.target, ignoringWhitespace: false)
        for _ in 0..<100 {
            if await tracking.heldCount() == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let heldCount = await tracking.heldCount()
        try require(heldCount == 2 && !state.blame.loadingSides.isEmpty, "Blame loading state missing")
        state.cancel()
        let added = try file(comparison, "added.txt")
        await state.load(session: session, file: added.file, commit: nil, target: added.target, ignoringWhitespace: false)
        await tracking.release()
        try await Task.sleep(for: .milliseconds(30))
        try require(state.blame.visibleSides.isEmpty && state.blame.loadingSides.isEmpty
            && state.blame.annotations(for: .target) == nil, "Stale blame survived file/window reset")
        await tracking.setFailing(true)
        state.annotate(using: tracking); try await waitForBlame(state)
        try require(state.blame.errors[.result] != nil && state.blame.visibleSides.isEmpty && state.diff != nil,
            "Blame error hid Diff or appeared successful")
        await tracking.setFailing(false)
        state.blame.toggle(.result, using: tracking); try await waitForBlame(state)
        try require(state.blame.errors.isEmpty && state.blame.annotations(for: .result)?[1]?.commitHash == last, "Blame retry failed")
        state.cancel()
        await tracking.release()
        try require(state.blame.context == nil && state.blame.visibleSides.isEmpty, "Closed comparison retained blame")
        try await verifyEmptyAndBinaryBlame()
        print("Branch comparison Blame passed: pinned rename versions, attribution, metadata, lazy/all/per-pane toggles, whitespace retention, single/merge commits, stale results, errors and retry")
    }

    static func verifyEmptyAndBinaryBlame() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.url) }
        try f.commit("root"); try f.git(["checkout", "-b", "feature"])
        try f.write("empty.txt", "")
        try Data([0, 1, 2]).write(to: f.url.appendingPathComponent("binary.bin"))
        try f.commit("empty and binary")
        let result = try await compare(f, "refs/heads/main")
        let session = BranchComparisonSession(repositoryURL: f.url, current: "feature", selected: "main", reader: reader)
        let state = BranchComparisonDiffState()
        for entry in result.files {
            state.cancel(); state.annotate(using: reader)
            await state.load(session: session, file: entry.file, commit: nil, target: entry.target, ignoringWhitespace: false)
            try require(state.blame.availableSides.isEmpty && state.blame.visibleSides.isEmpty && state.blame.errors.isEmpty,
                "Empty/binary file offered invalid blame")
        }
    }

    static func compare(_ f: Fixture, _ selected: String) async throws -> GitBranchComparison {
        try await reader.compareBranches(repositoryURL: f.url, base: "refs/heads/feature", compared: selected)
    }
    static func file(_ comparison: GitBranchComparison, _ path: String) throws -> GitBranchComparisonFile {
        guard let value = comparison.files.first(where: { $0.file.path == path }) else { throw Failure(message: "Missing \(path)") }; return value
    }
    static func requireFile(_ files: [GitCommitFile], _ path: String) throws -> GitCommitFile {
        guard let file = files.first(where: { $0.path == path }) else { throw Failure(message: "Missing commit file \(path)") }; return file
    }
    static func diff(_ f: Fixture, _ file: GitBranchComparisonFile) async throws -> GitFileDiff {
        try await reader.fileDiff(repositoryURL: f.url, target: file.target, ignoringWhitespace: false)
    }
    static func verifyCancellation(_ f: Fixture) async throws {
        let session = BranchComparisonSession(repositoryURL: f.url, current: "refs/heads/feature", selected: "refs/heads/main", reader: reader)
        let task = Task { await session.load() }; task.cancel(); await task.value
        try require(session.comparison == nil && session.error == nil, "Cancelled session published data")
    }
    static func verifySharedResultPath() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.url) }
        try f.write("a", "first\n"); try f.write("b", "second\n"); try f.commit("base")
        try f.git(["checkout", "-b", "feature"])
        try f.git(["rm", "a"]); try f.commit("delete a")
        try f.git(["mv", "b", "a"]); try f.commit("move b into a")
        let comparison = try await compare(f, "refs/heads/main")
        try require(comparison.files.count == 2 && Set(comparison.files.map(\.id)).count == 2,
            "Distinct chains with same resulting path lost identity")
        let rows = HistoryFileOutlineBuilder.rows(files: comparison.files.map(\.file), namespace: "test",
            repositoryName: "fixture", grouping: .directory, expandedNodeIDs: [], modulePath: { _ in "." })
        try require(rows.count == 2 && Set(rows.map(\.id)).count == 2, "Same-path outline chains collapsed or duplicated identity")
        for entry in comparison.files {
            let result = try await diff(f, entry)
            if entry.file.status == .deleted {
                try require(result.oldLines == ["first"] && result.newLines.isEmpty, "Deleted path version lost")
            } else {
                try require(entry.file.status == .renamed && result.oldLines == ["second"] && result.newLines == ["second"], "Renamed path version lost")
            }
        }
    }
    static func verifyCherryPickAndOldPathReuse() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.url) }
        try f.write("old", "one\ntwo\nthree\n"); try f.commit("base")
        try f.git(["checkout", "-b", "feature"])
        try f.git(["mv", "old", "new"]); let renamed = try f.commit("rename")
        try f.write("old", "unrelated replacement\n"); try f.commit("reuse old path")
        let comparison = try await compare(f, "refs/heads/main")
        let entry = try file(comparison, "new")
        let result = try await diff(f, entry)
        try require(entry.after?.commit == renamed && result.hunks.isEmpty && result.oldLines == result.newLines,
            "Committed old-path reuse polluted rename diff")
        try f.git(["checkout", "main"])
        try f.write("cherry", "same patch\n"); let original = try f.commit("source patch")
        try f.git(["checkout", "feature"])
        try f.git(["cherry-pick", original]); let picked = try f.git(["rev-parse", "HEAD"])
        let cherryComparison = try await compare(f, "refs/heads/main")
        try require(original != picked && cherryComparison.commits.contains { $0.hash == picked }
            && !cherryComparison.commits.contains { $0.hash == original }, "Cherry-pick was compared by patch identity")
        // A merge that only imports the other branch still counts as a unique commit,
        // but none of those imported files belongs to its per-parent intersection.
        let pure = try Fixture(); defer { try? FileManager.default.removeItem(at: pure.url) }
        try pure.commit("empty base"); try pure.git(["branch", "feature"])
        try pure.write("remote", "imported\n"); try pure.commit("remote file")
        try pure.git(["checkout", "feature"]); try pure.git(["merge", "--no-ff", "main", "-m", "pure merge"])
        let onlyMerge = try await compare(pure, "refs/heads/main")
        try require(onlyMerge.commits.count == 1 && onlyMerge.commits[0].isMerge && onlyMerge.files.isEmpty,
            "Pure imported merge produced aggregate files")
    }
    static func verifyRequestIsolation() async throws {
        let url = URL(fileURLWithPath: "/tmp/comparison-isolation")
        let oldSession = BranchComparisonSession(repositoryURL: url, current: "old", selected: "main", reader: DelayedReader(slow: true))
        let newSession = BranchComparisonSession(repositoryURL: url, current: "new", selected: "main", reader: DelayedReader(slow: false))
        let old = Task { await oldSession.load() }
        await Task.yield()
        old.cancel()
        await newSession.load(); await old.value
        try require(oldSession.comparison == nil && newSession.comparison?.baseSHA == "new", "Recompare published old session")
        let state = BranchComparisonDiffState()
        let slowFile = GitCommitFile(path: "slow", originalPath: nil, status: .modified)
        let fastFile = GitCommitFile(path: "fast", originalPath: nil, status: .modified)
        let slow = Task { await state.load(session: newSession, file: slowFile, commit: nil,
            target: .commit(hash: "sha", file: slowFile), ignoringWhitespace: false) }
        try await Task.sleep(for: .milliseconds(10))
        await state.load(session: newSession, file: fastFile, commit: nil,
            target: .commit(hash: "sha", file: fastFile), ignoringWhitespace: true)
        await slow.value
        try require(state.diff?.path == "fast" && state.diff?.newLines == ["ignored"], "Fast file/whitespace selection showed old result")
        let closing = Task { await state.load(session: newSession, file: slowFile, commit: nil,
            target: .commit(hash: "sha", file: slowFile), ignoringWhitespace: false) }
        try await Task.sleep(for: .milliseconds(10))
        state.cancel(); await closing.value
        try require(state.diff == nil && state.error == nil, "Closed view published result")
        let errorFile = GitCommitFile(path: "error", originalPath: nil, status: .modified)
        await state.load(session: newSession, file: errorFile, commit: nil,
            target: .commit(hash: "sha", file: errorFile), ignoringWhitespace: false)
        try require(state.error != nil && state.diff == nil, "Read error shown as empty diff")
    }
    static func verifyCancellationAndRecreation() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.url) }
        try f.write("existing", "old\n"); let root = try f.commit("base")
        try f.git(["checkout", "-b", "feature"])
        try f.git(["rm", "existing"]); try f.commit("delete")
        try f.write("existing", "replacement\n"); try f.commit("recreate")
        try f.write("gone", "temporary\n"); try f.commit("add temporary")
        try f.git(["rm", "gone"]); try f.commit("delete temporary")
        let comparison = try await compare(f, "refs/heads/main")
        try require(comparison.files.count == 1, "Add-delete did not cancel")
        let replaced = try file(comparison, "existing")
        let result = try await diff(f, replaced)
        try require(replaced.file.status == .modified && replaced.before?.commit == root && result.oldLines == ["old"] && result.newLines == ["replacement"], "Delete-recreate did not zip")
        try f.git(["branch", "-f", "main", "HEAD~2"])
        let noFiles = try await compare(f, "refs/heads/main")
        try require(noFiles.commits.count == 2 && noFiles.files.isEmpty, "Unique commits with no aggregate files not represented")
        try f.write("space", "a b\n"); try f.commit("space base")
        try f.git(["branch", "-f", "main", "HEAD"])
        try f.write("space", "ab\n"); try f.commit("space only")
        let whitespace = try file(await compare(f, "refs/heads/main"), "space")
        let ignored = try await reader.fileDiff(repositoryURL: f.url, target: whitespace.target, ignoringWhitespace: true)
        try require(ignored.hunks.isEmpty, "Ignore whitespace ineffective")
        try require(!whitespace.isNetUnchanged, "Whitespace filtering changed the file classification")
    }

    static func verifyUnchangedClassification() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.url) }
        let path = "dir/tab\tline\n[original]*.txt"
        try f.write(path, "original\n")
        try Data([0, 1, 2]).write(to: f.url.appendingPathComponent("binary"))
        try f.write("mode", "same\n"); try f.write("old", "same\n")
        try f.write("space", "a b\n"); try f.write("empty deleted", "")
        try f.commit("base"); try f.git(["checkout", "-b", "feature"])
        try f.write(path, "changed\n")
        try Data([0, 3, 4]).write(to: f.url.appendingPathComponent("binary"))
        let first = try f.commit("change text and binary")
        try f.write(path, "original\n")
        try Data([0, 1, 2]).write(to: f.url.appendingPathComponent("binary"))
        let last = try f.commit("restore text and binary")
        let unchanged = try await compare(f, "refs/heads/main")
        try require(unchanged.netChangedFileCount == 0 && unchanged.unchangedFileCount == 2
            && unchanged.visibleFiles(includingUnchanged: false).isEmpty
            && unchanged.visibleFiles(includingUnchanged: true).count == 2, "All-unchanged summary cannot be expanded")
        for entry in unchanged.files {
            try require(entry.isNetUnchanged && entry.statusLabel == "≡" && entry.contributions == [first, last],
                "NUL paths / binary restoration classification lost versions or history")
        }
        try f.git(["config", "core.filemode", "true"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url.appendingPathComponent("mode").path)
        try f.commit("mode only")
        try f.git(["rm", "empty deleted"]); try f.commit("delete empty file")
        try f.git(["mv", "old", "new"])
        try f.write("space", "ab\n"); try f.write("empty added", "")
        try f.commit("rename, whitespace and empty files")
        let mixed = try await compare(f, "refs/heads/main")
        try require(mixed.unchangedFileCount == 2 && mixed.netChangedFileCount == 5, "Mixed file counts incorrect")
        try require(Set(mixed.visibleFiles(includingUnchanged: false).map { $0.file.path })
            == Set(["mode", "new", "space", "empty added", "empty deleted"]),
            "Mode-only, rename-only, whitespace-only or empty added/deleted files were hidden")
        for missingEntry in [false, true] {
            let session = BranchComparisonSession(repositoryURL: f.url, current: "refs/heads/feature", selected: "refs/heads/main",
                reader: SystemGitRepositoryReader(commandRunner: TreeFailureRunner(missingEntry: missingEntry)))
            await session.load()
            try require(session.error != nil && session.comparison == nil && !session.isLoading,
                "Failed or missing tree entry silently classified as unchanged")
        }
        print("Unchanged file classification passed: marker, default hiding, expansion, counts, NUL paths, binary restoration and real metadata changes")
    }
}

/// Deliberately returns after cancellation, like a non-cooperative cache or service.
private struct DelayedReader: GitRepositoryReading {
    let slow: Bool
    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot { throw Failure(message: "unused") }
    func history(repositoryURL: URL, limit: Int, skip: Int, revision: String?, author: String?) async throws -> [GitCommitSummary] { [] }
    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { [] }
    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail { throw Failure(message: "unused") }
    func compareBranches(repositoryURL: URL, base: String, compared: String) async throws -> GitBranchComparison {
        try? await Task.sleep(for: .milliseconds(slow ? 80 : 1))
        return GitBranchComparison(baseBranch: base, comparedBranch: compared, commits: [], baseSHA: base, comparedSHA: compared, records: [], files: [])
    }
    func fileDiff(repositoryURL: URL, target: GitDiffTarget, ignoringWhitespace: Bool) async throws -> GitFileDiff {
        let path: String
        switch target {
        case .commit(_, let file), .revisionRange(_, _, let file, _): path = file.path
        case .change(let selection): path = selection.path
        }
        try? await Task.sleep(for: .milliseconds(path == "slow" ? 80 : 1))
        if path == "error" { throw Failure(message: "read failed") }
        return GitFileDiff(path: path, originalPath: nil, oldLabel: "old", newLabel: "new", oldLines: [],
            newLines: [ignoringWhitespace ? "ignored" : path], hunks: [], isBinary: false)
    }
}

private struct HistoryFailureRunner: CommandRunning {
    func run(_ request: CommandRequest) async throws -> CommandResult {
        if request.arguments.first == "rev-parse" {
            return CommandResult(standardOutput: Data((String(repeating: "a", count: 40) + "\n").utf8), standardError: Data(), terminationStatus: 0)
        }
        return CommandResult(standardOutput: Data(), standardError: Data("history read failed".utf8), terminationStatus: 128)
    }
}

private struct TreeFailureRunner: CommandRunning {
    let missingEntry: Bool
    func run(_ request: CommandRequest) async throws -> CommandResult {
        if request.arguments.contains("ls-tree") {
            return CommandResult(standardOutput: Data(), standardError: Data("tree read failed".utf8),
                terminationStatus: missingEntry ? 0 : 128)
        }
        return try await SystemCommandRunner().run(request)
    }
}

private actor ComparisonBlameReader: GitRepositoryReading {
    struct Request {
        let repositoryURL: URL
        let path: String
        let revision: String
        let contentsPath: String?
    }
    private var recorded: [Request] = []
    private var holding = false
    private var failing = false
    private var held: [CheckedContinuation<Void, Never>] = []
    func requests() -> [Request] { recorded }
    func setHolding(_ value: Bool) { holding = value }
    func setFailing(_ value: Bool) { failing = value }
    func heldCount() -> Int { held.count }
    func release() { holding = false; let pending = held; held = []; for continuation in pending { continuation.resume() } }
    func blame(repositoryURL: URL, path: String, revision: String, contentsPath: String?) async throws -> [GitBlameLine] {
        recorded.append(Request(repositoryURL: repositoryURL, path: path, revision: revision, contentsPath: contentsPath))
        if holding { await withCheckedContinuation { held.append($0) } }
        if failing { throw Failure(message: "controlled blame failure") }
        return try await SystemGitRepositoryReader().blame(repositoryURL: repositoryURL, path: path, revision: revision, contentsPath: contentsPath)
    }
    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot { throw Failure(message: "unused") }
    func history(repositoryURL: URL, limit: Int, skip: Int, revision: String?, author: String?) async throws -> [GitCommitSummary] { [] }
    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { [] }
    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        try await SystemGitRepositoryReader().commit(repositoryURL: repositoryURL, hash: hash)
    }
    func fileDiff(repositoryURL: URL, target: GitDiffTarget, ignoringWhitespace: Bool) async throws -> GitFileDiff {
        try await SystemGitRepositoryReader().fileDiff(repositoryURL: repositoryURL, target: target, ignoringWhitespace: ignoringWhitespace)
    }
    func mergeFileDiff(repositoryURL: URL, hash: String, parentHashes: [String], file: GitCommitFile, ignoringWhitespace: Bool) async throws -> GitMergeFileDiff {
        try await SystemGitRepositoryReader().mergeFileDiff(repositoryURL: repositoryURL, hash: hash, parentHashes: parentHashes, file: file, ignoringWhitespace: ignoringWhitespace)
    }
}
