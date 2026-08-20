import AppKit
import SwiftUI
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyCommitExecutionRendering {
    static func main() throws {
        let context = GitCommitExecutionContext(
            repositoryID: ".",
            repositoryName: "online.base.member.service",
            branch: "master",
            fileCount: 3,
            shouldPush: true,
            pushTarget: "origin/master"
        )
        let result = GitCommitExecutionResult(
            context: context,
            commitHash: "a83f1c2d4567890",
            wasPushed: true
        )
        let preview = VStack(alignment: .leading, spacing: 16) {
            previewSection("Commit 阶段", state: .committing(context))
            previewSection(
                "Push 阶段",
                state: .pushing(context: context, commitHash: result.commitHash)
            )
            previewSection("成功", state: .succeeded(result))
            previewSection(
                "部分成功",
                state: .pushFailed(
                    result: GitCommitExecutionResult(
                        context: context,
                        commitHash: result.commitHash,
                        wasPushed: false
                    ),
                    message: "远程仓库拒绝了本次推送，请检查权限或远程分支状态。"
                )
            )
        }
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))

        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 470)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw VerificationError(message: "Could not create commit status rendering.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw VerificationError(message: "Could not encode commit status rendering.")
        }
        try png.write(
            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/commit-execution-states.png"),
            options: .atomic
        )
        print("Commit execution rendering verification passed")
    }

    private static func previewSection(
        _ title: String,
        state: GitCommitExecutionState
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            CommitExecutionStatusView(
                state: state,
                retryCommit: { _ in },
                retryPush: {},
                showInHistory: { _ in },
                dismiss: {}
            )
        }
    }
}
