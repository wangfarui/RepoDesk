import AppKit
import Foundation
@testable import RepoDesk

private struct VerificationFailure: Error { let message: String }

@main
@MainActor
enum VerifyThreeWayMerge {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationFailure(message: message) }
    }
    static func main() async throws {
        try modelScenarios()
        try await repositoryScenarios()
        print("Three-way merge verification passed (sources, independent decisions, edits, undo, persistence, index, deletion, binary, revert, abort, continue)")
    }
    static func modelScenarios() throws {
        var d = GitThreeWayMergeDocument(base: "before\nbase\nafter\n", ours: "before\nleft\nafter\n", theirs: "before\nright\nafter\n")
        try require(d.result == d.base && d.changes.count == 1, "Conflict result must start from Base")
        d.accept(0, side: .ours)
        try require(d.unresolvedIDs == [0] && d.result.contains("left"), "Accepting left must leave right pending")
        d.accept(0, side: .theirs)
        try require(d.result == "before\nleft\nright\nafter\n" && d.unresolvedIDs.isEmpty, "Second accepted side must append")
        d.reset(0); d.accept(0, side: .theirs); d.ignore(0, side: .ours)
        try require(d.result == "before\nright\nafter\n" && d.unresolvedIDs.isEmpty, "Ignore must preserve result")
        d.reset(0); d.accept(0, side: .ours, resolveBoth: true)
        try require(d.unresolvedIDs.isEmpty && !d.result.contains("right"), "Quick resolution must finish both sides")
        let independent = GitThreeWayMergeDocument(base: "a\nb\nc\n", ours: "left\nb\nc\n", theirs: "a\nb\nright\n")
        try require(independent.result == "left\nb\nright\n" && independent.unresolvedIDs.isEmpty, "Non-conflicting edits did not combine")
        var shared = GitThreeWayMergeDocument(base: "base\n", ours: "shared\n", theirs: "shared\n", automaticallyApply: false)
        shared.applyNonConflicting(side: .theirs)
        try require(shared.result == "shared\n" && shared.unresolvedIDs.isEmpty, "Right-only batch omitted identical two-sided edits")
        var manual = GitThreeWayMergeDocument(base: "one\nbase\nmiddle\nbase2\nend", ours: "one\nleft\nmiddle\nleft2\nend", theirs: "one\nright\nmiddle\nright2\nend")
        manual.editResult("😀\none\nbase\nmiddle\nbase2\nend")
        manual.accept(1, side: .ours, resolveBoth: true)
        try require(manual.result == "😀\none\nbase\nmiddle\nleft2\nend", "UTF-16 insertion broke downstream ranges")
        manual.editResult("😀\none\ncombined\nend")
        try require(manual.changes.count == 1 && manual.unresolvedIDs == [0], "Cross-block edit must coalesce obsolete overlapping decisions")
        manual.accept(0, side: .theirs, resolveBoth: true)
        try require(manual.result == "😀\none\nright\nmiddle\nright2\nend", "Coalesced range lost surrounding text")
        let state = GitMergeEditorState(document: d)
        state.undoManager.beginUndoGrouping()
        state.change { $0.reset(0) }
        state.undoManager.endUndoGrouping()
        state.undoManager.undo()
        try require(state.document == d, "Undo must restore full decision state and text")
        state.undoManager.redo()
        try require(state.document.result == state.document.base && state.document.unresolvedIDs == [0], "Redo must restore reset state")
        var simple = GitThreeWayMergeDocument(base: "first = 1; last = 2;\n", ours: "first = 3; last = 2;\n", theirs: "first = 1; last = 4;\n", automaticallyApply: false)
        try require(simple.changes.contains { simple.simpleResolution(for: $0) != nil }, "Disjoint word edits should be resolvable")
        simple.resolveSimpleConflicts()
        try require(simple.result == "first = 3; last = 4;\n" && simple.unresolvedIDs.isEmpty, "Explicit simple-conflict resolution produced wrong text")
        var manualNonConflict = GitThreeWayMergeDocument(base: "a\nb\n", ours: "left\nb\n", theirs: "a\nb\n", automaticallyApply: false)
        manualNonConflict.editResult("manual\nb\n")
        try require(!manualNonConflict.canApplyNonConflicting(), "Batch application must not overwrite manual result edits")
        manualNonConflict.applyNonConflicting()
        try require(manualNonConflict.result == "manual\nb\n", "Batch application overwrote a modified result range")
        var ignoredSimple = GitThreeWayMergeDocument(base: "first = 1; last = 2;\n", ours: "first = 3; last = 2;\n", theirs: "first = 1; last = 4;\n", automaticallyApply: false)
        ignoredSimple.ignore(0, side: .ours)
        try require(ignoredSimple.simpleResolution(for: ignoredSimple.changes[0]) == nil, "Simple resolution resurrected an ignored alternative")
        let whitespace = GitThreeWayMergeDocument(base: "a = 1;\n", ours: "  a = 1;  \n", theirs: "a = 1;\n", automaticallyApply: false, whitespacePolicy: .trim)
        try require(whitespace.changes.isEmpty && whitespace.result == whitespace.base, "Trim comparison created a whitespace-only change")
        let oldJSON = "{\"base\":\"\",\"ours\":\"\",\"theirs\":\"\",\"result\":\"\",\"changes\":[]}"
        let oldDraft = try JSONDecoder().decode(GitThreeWayMergeDocument.self, from: Data(oldJSON.utf8))
        try require(oldDraft.whitespacePolicy == .none, "Old drafts lost decoder compatibility")
        let roundTrip = try JSONDecoder().decode(GitThreeWayMergeDocument.self, from: JSONEncoder().encode(manual))
        try require(roundTrip == manual, "Draft serialization lost decisions")
        let added = GitThreeWayMergeDocument(base: "", ours: "left", theirs: "right")
        try require(added.changes.count == 1 && added.unresolvedConflictCount == 1, "Add/add must retain conflict")
        var noFinalNewline = added
        noFinalNewline.accept(0, side: .ours); noFinalNewline.accept(0, side: .theirs)
        try require(noFinalNewline.result == "left\nright", "Accepting both line versions must not fuse missing terminal newlines")
        var crlf = GitThreeWayMergeDocument(base: "a\r\nb", ours: "left\r\nb", theirs: "right\r\nb")
        crlf.accept(0, side: .theirs, resolveBoth: true)
        try require(crlf.result == "right\r\nb", "Line endings or missing terminal newline changed")
        // Every single-sided change must reproduce that side byte-for-byte,
        // including repeated lines, insertions, deletions and empty documents.
        let cases = ["", "a", "a\n", "a\na\n", "b\na\nc\n", "😀\r\na\n", "x\ny\nz"]
        for base in cases { for source in cases {
            let left = GitThreeWayMergeDocument(base: base, ours: source, theirs: base)
            let right = GitThreeWayMergeDocument(base: base, ours: base, theirs: source)
            try require(left.result == source && right.result == source, "Single-sided diff invariant failed")
        } }
        for base in cases { for ours in cases { for theirs in cases {
            var document = GitThreeWayMergeDocument(base: base, ours: ours, theirs: theirs)
            try require(document.isValid, "Initial range invariant failed")
            for id in document.changes.map(\.id) {
                document.accept(id, side: .ours); document.accept(id, side: .theirs)
                try require(document.isValid, "Accepted ranges overlap")
                document.reset(id)
            }
            document.editResult(document.result + "😀\n")
            try require(document.isValid, "Insertion at empty-change boundary corrupted ranges")
        } } }
    }

    static func repositoryScenarios() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RepoDesk-three-way-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = SystemCommandRunner()
        func git(_ arguments: [String], allowFailure: Bool = false) async throws -> String {
            let result = try await runner.run(CommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments,
                workingDirectoryURL: url, environment: nil))
            if !allowFailure { try require(result.terminationStatus == 0, "Git failed: \(arguments) \(String(decoding: result.standardError, as: UTF8.self))") }
            return String(decoding: result.standardOutput, as: UTF8.self)
        }
        func write(_ name: String, _ data: Data) throws { try data.write(to: url.appendingPathComponent(name)) }
        _ = try await git(["init", "--initial-branch=main"])
        _ = try await git(["config", "user.name", "RepoDesk Verification"])
        _ = try await git(["config", "user.email", "verification@example.invalid"])
        _ = try await git(["config", "commit.gpgsign", "false"])
        _ = try await git(["config", "core.hooksPath", "/dev/null"])
        try write("text.txt", Data("top\nbase\nbottom\n".utf8))
        try write("deleted.txt", Data("base\n".utf8)); try write("binary.dat", Data([0,1,2]))
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "base"])
        _ = try await git(["branch", "incoming"])
        try write("text.txt", Data("top\nours\nbottom\n".utf8))
        _ = try await git(["rm", "deleted.txt"]); try write("binary.dat", Data([0,3,4]))
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "ours"])
        let originalHead = try await git(["rev-parse", "HEAD"])
        _ = try await git(["switch", "incoming"])
        try write("text.txt", Data("top\ntheirs\nbottom\n".utf8))
        let theirsBinary = Data([0,5,6]) + Data("\n<<<<<<< HEAD\nleft\n=======\nright\n>>>>>>> incoming\n".utf8)
        try write("deleted.txt", Data("theirs\n".utf8)); try write("binary.dat", theirsBinary)
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "theirs"])
        _ = try await git(["switch", "main"])
        let op = SystemGitRepositoryOperator()
        _ = try await git(["merge", "incoming"], allowFailure: true)
        var files = try await op.conflictFiles(repositoryURL: url)
        try require(files.count == 3, "Expected text, binary and modify/delete conflicts")
        do { try await op.continueMerge(repositoryURL: url); throw VerificationFailure(message: "Continue accepted unresolved index") }
        catch is GitRepositoryOperationError { }
        var file = files.first { $0.path == "text.txt" }!
        var doc = GitThreeWayMergeDocument(base: file.base!, ours: file.ours, theirs: file.theirs)
        doc.accept(0, side: .ours)
        file.result = doc.result; file.mergeDocument = doc
        try await op.saveConflictProgress(repositoryURL: url, file: file)
        let reopened = try await SystemGitRepositoryOperator().mergeSession(repositoryURL: url)!
        try require(reopened.files.first { $0.path == file.path }?.mergeDocument == doc, "Restart lost half-resolved draft")
        let unmergedCount = try await awaitUnmerged(git)
        try require(unmergedCount == 3, "Saving draft changed unresolved index")
        file = reopened.files.first { $0.path == "text.txt" }!
        try write("text.txt", Data("external edit\n".utf8))
        do { try await op.resolveConflict(repositoryURL: url, file: file); throw VerificationFailure(message: "External edit was overwritten") }
        catch is GitRepositoryOperationError { }
        let externalBytes = try Data(contentsOf: url.appendingPathComponent("text.txt"))
        try require(externalBytes == Data("external edit\n".utf8), "External data changed")
        try write("text.txt", Data(doc.result.utf8))
        _ = try await git(["add", "text.txt"])
        do { try await op.resolveConflict(repositoryURL: url, file: file); throw VerificationFailure(message: "External index change was overwritten") }
        catch is GitRepositoryOperationError { }
        _ = try await git(["checkout", "--conflict=merge", "--", "text.txt"])
        try write("text.txt", Data(doc.result.utf8))
        doc.accept(0, side: .theirs); file.result = doc.result; file.mergeDocument = doc
        try await op.saveConflictProgress(repositoryURL: url, file: file)
        let fullyChosenDraft = try await op.mergeSession(repositoryURL: url)!
        file = fullyChosenDraft.files.first { $0.path == "text.txt" }!
        try require(!file.isResolved && file.mergeDocument?.unresolvedIDs.isEmpty == true, "Fully chosen draft was staged or lost")
        try await op.resolveConflict(repositoryURL: url, file: file)
        let session = try await op.mergeSession(repositoryURL: url)!
        let resolved = session.files.first { $0.path == "text.txt" }!
        try require(resolved.isResolved, "Applied file not retained for reopening")
        try await op.restoreConflictProgress(repositoryURL: url, file: resolved)
        files = try await op.conflictFiles(repositoryURL: url)
        try require(files.first { $0.path == "text.txt" }?.result.contains("<<<<<<<") == true, "Revert did not reload actual conflict")
        for var pending in files {
            if pending.path == "deleted.txt" {
                try require(!pending.hasOurs && pending.hasTheirs, "Deletion metadata lost")
                pending.deletesResult = true; pending.result = ""; pending.resultData = nil
            } else if pending.isBinary {
                pending.resultData = pending.theirsData
            } else { pending.result = "top\nmerged\nbottom\n" }
            try await op.resolveConflict(repositoryURL: url, file: pending)
        }
        try require(!FileManager.default.fileExists(atPath: url.appendingPathComponent("deleted.txt").path), "Delete side created an empty file")
        let binaryBytes = try Data(contentsOf: url.appendingPathComponent("binary.dat"))
        try require(binaryBytes == theirsBinary, "Binary bytes changed")
        let repository = RegisteredRepository(displayName: "merge", relativePath: ".", isPinned: false)
        let app = AppState(workspace: WorkspaceSummary(name: "merge", path: url.path), repositories: [repository],
                           selectedRepositoryID: repository.id, gitRepositoryOperator: op, restoresWorkspaceOnLaunch: false)
        app.navigationContext = .repository(repository.id)
        await app.reloadMergeSession()
        try require(app.conflictFiles.isEmpty && app.resolvedConflictFiles.count == 3 && app.mergeSourceBranch == nil,
                    "App state did not recover the resolved merge session")
        app.mergeSourceBranch = "incoming"
        await app.closeMergeConflictResolution()
        try require(app.mergeSourceBranch == nil && app.conflictFiles.isEmpty, "Close did not abort an all-resolved merge")
        let afterAbort = try await git(["rev-parse", "HEAD"])
        try require(afterAbort == originalHead, "Abort moved HEAD")
        let abortedSession = try await op.mergeSession(repositoryURL: url)
        try require(abortedSession == nil, "Abort left a merge session")
        _ = try await git(["merge", "incoming"], allowFailure: true)
        files = try await op.conflictFiles(repositoryURL: url)
        await app.reloadMergeSession()
        for pending in files {
            let accepted = await app.acceptConflictFile(path: pending.path, side: .theirs)
            try require(accepted, "App rejected an entire source version: \(app.branchOperationErrorMessage ?? pending.path)")
        }
        let finishedSession = try await op.mergeSession(repositoryURL: url)
        try require(finishedSession == nil && app.mergeSourceBranch == nil, "Resolving the last file did not finish the merge")
        await app.continueMerge()
        try require(app.branchOperationErrorMessage == nil, "App could not continue merge")
        let parents = try await git(["rev-list", "--parents", "-n", "1", "HEAD"])
        try require(parents.split(whereSeparator: \.isWhitespace).count == 3, "Continue did not create merge commit")
        let completedSession = try await op.mergeSession(repositoryURL: url)
        try require(completedSession == nil, "Continue left stale session")
    }
    static func awaitUnmerged(_ git: ([String], Bool) async throws -> String) async throws -> Int {
        try await git(["diff", "--name-only", "--diff-filter=U"], false).split(whereSeparator: \.isNewline).count
    }
}
