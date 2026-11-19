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
enum VerifyGitPushDiffReal {
    static func main() async throws {
        _ = NSApplication.shared

        let environment = ProcessInfo.processInfo.environment
        guard let workspacePath = environment["REPODESK_VERIFY_WORKSPACE"],
              let repositoryPath = environment["REPODESK_VERIFY_REPOSITORY"],
              let branch = environment["REPODESK_VERIFY_BRANCH"],
              let path = environment["REPODESK_VERIFY_DIFF_PATH"] else {
            throw VerificationError(message: "Set REPODESK_VERIFY_WORKSPACE, REPODESK_VERIFY_REPOSITORY, REPODESK_VERIFY_BRANCH and REPODESK_VERIFY_DIFF_PATH to opt into a real-repository check.")
        }
        let workspaceURL = URL(fileURLWithPath: workspacePath)
        let repository = RegisteredRepository(
            displayName: URL(fileURLWithPath: repositoryPath).lastPathComponent,
            relativePath: repositoryPath,
            isPinned: false
        )
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            restoresWorkspaceOnLaunch: false
        )
        state.selectRepositoryContext(repository.id)

        let preparation = try await state.pushPreparation(targetRemoteBranch: branch)
        guard let firstCommit = preparation.commits.first else {
            throw VerificationError(message: "真实仓库没有可用于 Push Diff 验证的 Commit。")
        }
        let range = try await state.pushCommitRange([firstCommit])
        guard let file = range.files.first(where: { $0.path == path }) else {
            throw VerificationError(message: "Push 文件列表中没有目标 Java 文件。")
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let diff = try await state.pushFileDiff(range: range, file: file)
        let diffElapsed = ProcessInfo.processInfo.systemUptime - startedAt
        guard !diff.isBinary, !diff.hunks.isEmpty else {
            throw VerificationError(message: "真实仓库目标文件未生成文本 Diff。")
        }

        let controller = GitDiffWindowController(frameAutosaveName: "RepoDesk.GitPushDiff.RealVerification")
        let title = "Real Push Diff"
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

        let layoutStartedAt = ProcessInfo.processInfo.systemUptime
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let layoutElapsed = ProcessInfo.processInfo.systemUptime - layoutStartedAt

        print(String(format: "Real Push Diff: git=%.3fs ui=%.3fs hunks=%d files=%d", diffElapsed, layoutElapsed, diff.hunks.count, range.files.count))
        guard diffElapsed < 3, layoutElapsed < 3 else {
            throw VerificationError(message: "真实 Push Diff 超过 3 秒响应预算。")
        }
    }
}
