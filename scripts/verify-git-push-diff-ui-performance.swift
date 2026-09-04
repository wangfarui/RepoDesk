import AppKit
import Foundation
import SwiftUI
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationError(message: message) }
}

@main
@MainActor
enum VerifyGitPushDiffUIPerformance {
    static func main() async throws {
        _ = NSApplication.shared
        let repository = RegisteredRepository(displayName: "large-repo", relativePath: "repo", isPinned: false)
        let state = AppState(
            workspace: WorkspaceSummary(name: "workspace", path: "/tmp"),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            gitRepositoryReader: LargeDiffReader(),
            restoresWorkspaceOnLaunch: false
        )
        state.selectRepositoryContext(repository.id)
        let file = GitCommitFile(path: "src/SalesUnInvoiceDao.java", originalPath: nil, status: .modified)
        let range = GitPushCommitRange(
            commits: [],
            baseRevision: "11111111",
            headRevision: "22222222",
            files: [file]
        )
        let controller = GitDiffWindowController(frameAutosaveName: "RepoDesk.GitPushDiff.Verification")
        let title = "Push Diff UI Performance"
        controller.present(title: title) {
            GitPushFileDiffWindowContent(appState: state, range: range, file: file, close: { controller.close() })
        }
        guard let window = NSApp.windows.first(where: { $0.title == title }),
              let hostingView = window.contentView else {
            throw VerificationError(message: "Push Diff window was not presented.")
        }
        try require(window.sheetParent == nil, "Push Diff window must be top-level.")
        window.alphaValue = 0.01
        defer { controller.close() }

        let startedAt = ProcessInfo.processInfo.systemUptime
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let report = String(format: "Large Push Diff UI layout: %.3fs", elapsed)
        FileHandle.standardError.write(Data("\(report)\n".utf8))
        guard elapsed < 2.5 else {
            throw VerificationError(message: "Opening a large Push Diff UI exceeded the 2.5s budget.")
        }
    }
}

private struct LargeDiffReader: GitRepositoryReading {
    func snapshot(repositoryURL: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(branch: "main", isDetachedHEAD: false, aheadCount: 1, behindCount: 0, changes: [], lastCommit: nil)
    }

    func fileDiff(repositoryURL: URL, target: GitDiffTarget, ignoringWhitespace: Bool) async throws -> GitFileDiff {
        let lineCount = 80_000
        let oldLines = (0..<lineCount).map { "    private String field\($0);" }
        let newLines = (0..<lineCount).map { index in
            index == lineCount / 2 ? "    private Long purchaserId;" : "    private String field\(index);"
        }
        let hunk = GitDiffHunk(
            oldStart: 1,
            oldCount: lineCount,
            newStart: 1,
            newCount: lineCount,
            lines: (0..<lineCount).flatMap { index in
                index == lineCount / 2
                    ? [GitPatchLine(kind: .deletion, text: oldLines[index]), GitPatchLine(kind: .addition, text: newLines[index])]
                    : [GitPatchLine(kind: .context, text: oldLines[index])]
            }
        )
        return GitFileDiff(
            path: "src/SalesUnInvoiceDao.java",
            originalPath: nil,
            oldLabel: "11111111",
            newLabel: "22222222",
            oldLines: oldLines,
            newLines: newLines,
            hunks: [hunk],
            isBinary: false
        )
    }

    func history(repositoryURL: URL, limit: Int, skip: Int, revision: String?, author: String?) async throws -> [GitCommitSummary] { [] }
    func branches(repositoryURL: URL) async throws -> [GitBranch] { [] }
    func authors(repositoryURL: URL) async throws -> [String] { [] }
    func commit(repositoryURL: URL, hash: String) async throws -> GitCommitDetail {
        throw GitRepositoryError.pushPreparationUnavailable
    }
}
