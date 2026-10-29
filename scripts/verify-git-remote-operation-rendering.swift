import AppKit
import SwiftUI
@testable import RepoDesk

private struct VerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyGitRemoteOperationRendering {
    static func main() throws {
        let context = GitRemoteOperationContext(
            kind: .pull,
            repositoryID: "inventorycore-biz",
            repositoryName: "inventorycore-biz",
            branch: "feature/remote-operation-status",
            startedAt: Date(timeIntervalSinceNow: -8)
        )
        let pushContext = GitRemoteOperationContext(
            kind: .push,
            repositoryID: context.repositoryID,
            repositoryName: context.repositoryName,
            branch: context.branch,
            startedAt: context.startedAt
        )
        let preview = VStack(spacing: 8) {
            GitOperationStatusBand(
                tint: .blue,
                systemImage: "info.circle.fill",
                title: "当前分支已包含该分支的最新代码，无需合并。",
                dismiss: {}
            ) { EmptyView() }
            GitRemoteOperationStatusView(
                state: .running(context),
                retry: {},
                dismiss: {}
            )
            GitRemoteOperationStatusView(
                state: .succeeded(
                    GitRemoteOperationResult(context: context, completedAt: context.startedAt.addingTimeInterval(3.4))
                ),
                retry: {},
                dismiss: {}
            )
            GitRemoteOperationStatusView(
                state: .noChangesToPush(pushContext),
                retry: {},
                dismiss: {}
            )
            GitRemoteOperationStatusView(
                state: .failed(
                    context: context,
                    message: "远程仓库暂时不可用，请检查网络连接、权限或 upstream 配置。"
                ),
                retry: {},
                dismiss: {}
            )
            GitRemoteOperationStatusView(
                state: .requiresConflictResolution(context: context, fileCount: 3),
                retry: {},
                dismiss: {}
            )
        }
        .frame(width: 680)
        .background(Color(nsColor: .windowBackgroundColor))

        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 680, height: 335)
        hostingView.layoutSubtreeIfNeeded()
        guard hostingView.fittingSize.width <= 681,
              hostingView.fittingSize.height <= 336 else {
            throw VerificationError(message: "Git operation status content overflowed its container.")
        }
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw VerificationError(message: "Could not create Git operation status rendering.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 8_000 else {
            throw VerificationError(message: "Git operation status rendering was empty.")
        }
        try png.write(
            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/git-remote-operation-states.png"),
            options: .atomic
        )
        print("Git remote operation rendering verification passed")
    }
}
