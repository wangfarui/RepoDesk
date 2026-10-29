import Foundation
import SwiftUI

@MainActor
struct GitRemoteOperationStatusView: View {
    let state: GitRemoteOperationState
    let retry: () -> Void
    let dismiss: () -> Void

    @State private var showsErrorDetails = false

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .running(let context):
                TimelineView(.periodic(from: context.startedAt, by: 1)) { timeline in
                    statusBand(
                        tint: .accentColor,
                        showsProgress: true,
                        systemImage: "arrow.triangle.2.circlepath",
                        title: runningTitle(for: context.kind),
                        detail: "\(context.repositoryName) · \(context.branch) · \(elapsedText(from: context.startedAt, to: timeline.date))"
                    ) { EmptyView() }
                }
            case .succeeded(let result):
                statusBand(
                    tint: .green,
                    showsProgress: false,
                    systemImage: "checkmark.circle.fill",
                    title: successTitle(for: result.context.kind),
                    detail: "\(result.context.repositoryName) · \(result.context.branch) · \(durationText(result.duration))",
                    canDismiss: true
                ) { EmptyView() }
            case .noChangesToPush(let context):
                statusBand(
                    tint: .blue,
                    showsProgress: false,
                    systemImage: "info.circle.fill",
                    title: "没有需要 Push 的提交",
                    detail: "\(context.repositoryName) · \(context.branch) 已与远程分支同步",
                    canDismiss: true
                ) { EmptyView() }
            case .failed(let context, let message):
                statusBand(
                    tint: .red,
                    showsProgress: false,
                    systemImage: "exclamationmark.triangle.fill",
                    title: "\(context.kind.rawValue) 未完成",
                    detail: showsErrorDetails
                        ? "\(context.repositoryName) · \(context.branch)\n\(message)"
                        : message,
                    detailLineLimit: showsErrorDetails ? nil : 1,
                    canDismiss: true
                ) {
                    Button("重试", systemImage: "arrow.clockwise", action: retry)
                    Button(
                        showsErrorDetails ? "收起详情" : "查看详情",
                        systemImage: "info.circle"
                    ) {
                        showsErrorDetails.toggle()
                    }
                }
            case .requiresConflictResolution(let context, let fileCount):
                statusBand(
                    tint: .orange,
                    showsProgress: false,
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Pull 已暂停：发现 \(fileCount) 个冲突",
                    detail: "\(context.repositoryName) · \(context.branch) · 请先完成冲突解决"
                ) { EmptyView() }
            }
        }
        .onChange(of: state) { _, _ in
            showsErrorDetails = false
        }
    }

    private func statusBand<Actions: View>(
        tint: Color,
        showsProgress: Bool,
        systemImage: String,
        title: String,
        detail: String,
        detailLineLimit: Int? = 1,
        canDismiss: Bool = false,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        GitOperationStatusBand(
            tint: tint,
            showsProgress: showsProgress,
            systemImage: systemImage,
            title: title,
            detail: detail,
            detailLineLimit: detailLineLimit,
            canDismiss: canDismiss,
            dismiss: dismiss,
            actions: actions
        )
    }

    private func elapsedText(from start: Date, to end: Date) -> String {
        clockText(max(0, Int(end.timeIntervalSince(start))))
    }

    private func runningTitle(for kind: GitRemoteOperationKind) -> String {
        switch kind {
        case .fetch: "正在获取远程更新…"
        case .pull: "正在拉取并合并远程更新…"
        case .push: "正在推送本地提交…"
        case .stash: "正在暂存改动…"
        case .unstash: "正在恢复暂存改动…"
        case .dropStash: "正在删除暂存…"
        case .rollback: "正在回滚改动…"
        }
    }

    private func successTitle(for kind: GitRemoteOperationKind) -> String {
        switch kind {
        case .fetch: "远程更新已获取"
        case .pull: "远程提交已拉取"
        case .push: "本地提交已推送"
        case .stash: "改动已暂存"
        case .unstash: "暂存改动已恢复"
        case .dropStash: "暂存已删除"
        case .rollback: "改动已回滚"
        }
    }

    private func clockText(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        String(format: "%.1f 秒", duration)
    }
}

/// Shared, nonmodal feedback for local and remote Git operations.
@MainActor
struct GitOperationStatusBand<Actions: View>: View {
    let tint: Color
    var showsProgress = false
    let systemImage: String
    let title: String
    var detail: String? = nil
    var detailLineLimit: Int? = 1
    var canDismiss = true
    let dismiss: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Group {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(detailLineLimit)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                actions()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            if canDismiss {
                Button("关闭", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("关闭 Git 操作结果")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(tint.opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.7))
                .frame(width: 3)
        }
    }
}
