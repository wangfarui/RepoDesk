import AppKit
import Foundation
import SwiftUI
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyGitPushPreparation {
    static func main() async throws {
        try await verifyRealRepositoryBehavior()
        try await verifyRendering()
        print("Git Push preparation verification passed")
    }

    private static func verifyRealRepositoryBehavior() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Push-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = root.appendingPathComponent("repository", isDirectory: true)
        let remoteURL = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try git(["init", "--bare", remoteURL.path], in: root)
        try git(["init", "--initial-branch=main"], in: repositoryURL)
        try git(["config", "user.name", "RepoDesk Verification"], in: repositoryURL)
        try git(["config", "user.email", "repodesk@example.test"], in: repositoryURL)
        try Data("base\n".utf8).write(to: repositoryURL.appendingPathComponent("README.md"))
        try git(["add", "--all"], in: repositoryURL)
        try git(["commit", "--message", "Base"], in: repositoryURL)
        try git(["remote", "add", "origin", remoteURL.path], in: repositoryURL)
        try git(["push", "--set-upstream", "origin", "main"], in: repositoryURL)
        try git(["switch", "--create", "feature/push-preview"], in: repositoryURL)

        try Data("first\n".utf8).write(to: repositoryURL.appendingPathComponent("Shared.swift"))
        try git(["add", "--all"], in: repositoryURL)
        try git(["commit", "--message", "Add shared file"], in: repositoryURL)
        try Data("first\nsecond\n".utf8).write(to: repositoryURL.appendingPathComponent("Shared.swift"))
        try Data("second file\n".utf8).write(to: repositoryURL.appendingPathComponent("Second.swift"))
        try git(["add", "--all"], in: repositoryURL)
        try git(["commit", "--message", "Extend shared file"], in: repositoryURL)

        let reader = SystemGitRepositoryReader()
        let preparation = try await reader.pushPreparation(
            repositoryURL: repositoryURL,
            targetRemoteBranch: nil
        )
        try require(preparation.remote == "origin", "Push remote was not fixed to origin.")
        try require(preparation.targetRemoteBranch == "feature/push-preview", "Unexpected default target Branch.")
        try require(preparation.createsRemoteBranch, "New remote Branch was not identified.")
        try require(preparation.commits.count == 2, "Expected two Commit records in Push preview.")

        let range = try await reader.pushCommitRange(
            repositoryURL: repositoryURL,
            commits: preparation.commits
        )
        try require(range.files.map(\.path).sorted() == ["Second.swift", "Shared.swift"], "Selected Commit files were not merged.")
        try require(range.files.filter { $0.path == "Shared.swift" }.count == 1, "Repeated file appeared more than once.")
        guard let sharedFile = range.files.first(where: { $0.path == "Shared.swift" }) else {
            throw VerificationError(message: "Merged Shared.swift change was missing.")
        }
        let sharedDiff = try await reader.fileDiff(
            repositoryURL: repositoryURL,
            target: .revisionRange(
                base: range.baseRevision,
                head: range.headRevision,
                file: sharedFile
            ),
            ignoringWhitespace: false
        )
        try require(sharedDiff.newLines == ["first", "second"], "Cumulative Diff did not use the final selected Commit state.")

        let branchBeforePush = try gitOutput(["branch", "--show-current"], in: repositoryURL)
        let targetBranch = "review/push-preview"
        let outcome = try await SystemGitRepositoryOperator().push(
            repositoryURL: repositoryURL,
            localBranch: preparation.localBranch,
            remote: preparation.remote,
            remoteBranch: targetBranch,
            setUpstream: true
        )
        try require(outcome == .pushed, "Creating the remote Branch was not reported as a Push.")
        let branchAfterPush = try gitOutput(["branch", "--show-current"], in: repositoryURL)
        let upstream = try gitOutput(["rev-parse", "--abbrev-ref", "@{upstream}"], in: repositoryURL)
        let remoteTip = try gitOutput(["rev-parse", "refs/remotes/origin/\(targetBranch)"], in: repositoryURL)
        let localTip = try gitOutput(["rev-parse", "HEAD"], in: repositoryURL)
        try require(branchBeforePush == branchAfterPush, "Push changed the current local Branch.")
        try require(upstream == "origin/\(targetBranch)", "New remote Branch was not configured as upstream.")
        try require(remoteTip == localTip, "Remote Branch does not point to the local Branch tip.")
    }

    private static func verifyRendering() async throws {
        let repository = RegisteredRepository(displayName: "invoice-service", relativePath: "repo", isPinned: false)
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: PushRenderingReader(),
            gitRepositoryOperator: PushRenderingOperator(),
            restoresWorkspaceOnLaunch: false
        )
        state.selectRepositoryContext(repository.id)
        _ = NSApplication.shared
        let hostingView = NSHostingView(rootView: GitPushSheet(appState: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_120, height: 740)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.appearance = NSAppearance(named: .aqua)
        window.alphaValue = 0.01
        window.orderFront(nil)
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        hostingView.layoutSubtreeIfNeeded()
        guard hostingView.fittingSize.width <= 1_121,
              hostingView.fittingSize.height <= 741 else {
            throw VerificationError(message: "Push window content overflowed its container.")
        }
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw VerificationError(message: "Could not create Push window rendering.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 25_000 else {
            throw VerificationError(message: "Push window rendering was empty.")
        }
        try png.write(
            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/git-push-sheet.png"),
            options: .atomic
        )

        let file = GitCommitFile(
            path: "invoice-api/src/main/java/com/internet/invoicemanager/param/invoice/PurchaseUnInvoiceParam.java",
            originalPath: nil,
            status: .modified
        )
        let range = GitPushCommitRange(
            commits: [],
            baseRevision: "11111111",
            headRevision: "22222222",
            files: [file]
        )
        let diffController = GitDiffWindowController(frameAutosaveName: "RepoDesk.GitPushDiff.PreparationVerification")
        let diffTitle = "Push Diff - PurchaseUnInvoiceParam.java"
        diffController.present(title: diffTitle) {
            GitPushFileDiffWindowContent(
                appState: state,
                range: range,
                file: file,
                close: { diffController.close() }
            )
        }
        guard let diffWindow = NSApp.windows.first(where: { $0.title == diffTitle }),
              let diffHostingView = diffWindow.contentView else {
            throw VerificationError(message: "Push Diff window was not presented.")
        }
        guard diffWindow.sheetParent == nil,
              diffWindow.styleMask.contains(.resizable),
              diffWindow.styleMask.contains(.miniaturizable) else {
            throw VerificationError(message: "Push Diff window did not have independent window controls.")
        }
        diffWindow.appearance = NSAppearance(named: .aqua)
        diffWindow.alphaValue = 0.01
        defer { diffController.close() }
        diffHostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        diffHostingView.layoutSubtreeIfNeeded()
        guard diffHostingView.fittingSize.width <= 1_181,
              diffHostingView.fittingSize.height <= 741,
              let diffBitmap = diffHostingView.bitmapImageRepForCachingDisplay(
                in: diffHostingView.bounds
              ) else {
            throw VerificationError(message: "Push Diff window content overflowed its container.")
        }
        diffHostingView.cacheDisplay(in: diffHostingView.bounds, to: diffBitmap)
        guard let diffPNG = diffBitmap.representation(using: .png, properties: [:]),
              diffPNG.count > 25_000 else {
            throw VerificationError(message: "Push Diff window rendering was empty.")
        }
        try diffPNG.write(
            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/git-push-diff-sheet.png"),
            options: .atomic
        )
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        _ = try gitResult(arguments, in: directory)
    }

    private static func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        String(decoding: try gitResult(arguments, in: directory), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gitResult(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VerificationError(
                message: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError(message: message) }
    }
}

private struct PushRenderingReader: GitRepositoryReading {
    private let commits: [GitCommitSummary]
    private let files: [GitCommitFile]

    init(commits: [GitCommitSummary] = [
        GitCommitSummary(hash: "2222222222222222", subject: "feat(invoice): 支持进项链路单采购负责人", author: "Wang", authoredAt: .now),
        GitCommitSummary(hash: "1111111111111111", subject: "fix(invoice): 修复有链路项目快照项目取值", author: "Wang", authoredAt: Date(timeIntervalSinceNow: -3_600))
    ], files: [GitCommitFile] = [
        GitCommitFile(path: "invoice-api/src/main/java/com/internet/invoicemanager/param/invoice/PurchaseUnInvoiceParam.java", originalPath: nil, status: .modified),
        GitCommitFile(path: "invoice-biz/src/main/java/com/internet/invoice/converter/invoice/v2/PurchaseUnInvoiceCoreConvert.java", originalPath: nil, status: .added),
        GitCommitFile(path: "invoice-biz/src/main/java/com/internet/invoice/dao/invoice/PurchaseInvoiceDAO.java", originalPath: nil, status: .modified)
    ]) {
        self.commits = commits
        self.files = files
    }

    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(branch: "dev_260826_ytd", isDetachedHEAD: false, aheadCount: 2, behindCount: 0, changes: [], lastCommit: commits.first)
    }

    func fileDiff(repositoryURL: URL, target: GitDiffTarget, ignoringWhitespace: Bool) async throws -> GitFileDiff {
        GitFileDiff(
            path: files[0].path,
            originalPath: nil,
            oldLabel: "11111111",
            newLabel: "22222222",
            oldLines: ["class PurchaseUnInvoiceParam {", "    private Long projectId;", "}"],
            newLines: ["class PurchaseUnInvoiceParam {", "    private Long projectId;", "    private Long purchaserId;", "}"],
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 3,
                    newStart: 1,
                    newCount: 4,
                    lines: [
                        GitPatchLine(kind: .context, text: " class PurchaseUnInvoiceParam {"),
                        GitPatchLine(kind: .context, text: "     private Long projectId;"),
                        GitPatchLine(kind: .addition, text: "+    private Long purchaserId;"),
                        GitPatchLine(kind: .context, text: " }")
                    ]
                )
            ],
            isBinary: false
        )
    }

    func history(repositoryURL: URL, limit: Int, skip: Int, revision: String?, author: String?) async throws -> [GitCommitSummary] { commits }
    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { ["Wang"] }
    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail { GitCommitDetail(summary: commits[0], files: files) }

    func pushPreparation(repositoryURL: URL, targetRemoteBranch: String?) async throws -> GitPushPreparation {
        GitPushPreparation(
            localBranch: "dev_260826_ytd",
            remote: "origin",
            targetRemoteBranch: targetRemoteBranch ?? "dev_260826_ytd",
            remoteBranches: ["dev_260826_ytd", "main", "release/2026.08"],
            targetExists: targetRemoteBranch != "feature/new-remote",
            commits: commits,
            blockingMessage: nil
        )
    }

    func pushCommitRange(repositoryURL: URL, commits: [GitCommitSummary]) async throws -> GitPushCommitRange {
        GitPushCommitRange(
            commits: commits,
            baseRevision: "00000000",
            headRevision: commits.first?.hash ?? "22222222",
            files: commits.count == 1 ? Array(files.prefix(2)) : files
        )
    }
}

private actor PushRenderingOperator: GitRepositoryOperating {
    func createCommit(repositoryURL: URL, message: String) async throws -> GitCreatedCommit { GitCreatedCommit(hash: "created") }
    func pushCurrentBranch(repositoryURL: URL) async throws {}
    func switchBranch(repositoryURL: URL, branch: GitBranch) async throws {}
}
