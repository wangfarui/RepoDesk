import AppKit
import SwiftUI

@MainActor
struct WorkspaceSidebar: View {
    @Bindable var appState: AppState
    @State private var repositoryToRename: RegisteredRepository?
    @AppStorage("sidebar.workspaceSectionHeight") private var storedWorkspaceHeight = 180.0
    @State private var dragStartHeight: CGFloat?
    @State private var draggedWorkspaceHeight: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let height = constrainedWorkspaceHeight(
                draggedWorkspaceHeight ?? storedWorkspaceHeight,
                availableHeight: geometry.size.height
            )

            VStack(spacing: 0) {
                repositorySection
                    .frame(maxHeight: .infinity)

                workspaceDivider(height: height, availableHeight: geometry.size.height)

                workspaceSection
                    .frame(height: height)
            }
            .coordinateSpace(name: "workspaceSidebarResize")
        }
        .sheet(item: $repositoryToRename) { repository in
            RenameRepositorySheet(repository: repository) { name in
                appState.renameRepository(repository.id, displayName: name)
            }
        }
    }

    private var repositorySection: some View {
        VStack(spacing: 0) {
            SidebarSectionTitle("Git仓库", fontSize: appState.sidebarFontSize)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    repositoryRows
                    discoveryProgress
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

        }
    }

    private var workspaceSection: some View {
        VStack(spacing: 0) {
            HStack {
                SidebarSectionTitle("工作区", fontSize: appState.sidebarFontSize)
                Spacer()
                Button("新增工作区", systemImage: "plus") {
                    appState.chooseWorkspace()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .disabled(appState.isGitWriteOperationRunning)
                .help("新增工作区")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    workspaceRows
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    // Include the header, both text lines, row padding and the list's bottom padding.
    // Deriving this from the sidebar font keeps a full row visible at every supported size.
    private var minimumWorkspaceHeight: CGFloat {
        let fontSize = appState.sidebarFontSize
        let titleHeight = lineHeight(fontSize: max(9, fontSize - 2))
        let headerHeight = max(20, titleHeight) + 12
        let rowHeight = lineHeight(fontSize: fontSize)
            + lineHeight(fontSize: max(8, fontSize - 3)) + 1 + 12
        return headerHeight + rowHeight + 8
    }

    private func lineHeight(fontSize: Double) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize)))
    }

    private func constrainedWorkspaceHeight(_ proposed: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let minimum = minimumWorkspaceHeight
        // Keep the Git heading and at least one repository row usable above the divider.
        let maximum = max(minimum, availableHeight - 100 - 8)
        return min(max(proposed.isFinite ? proposed : 180, minimum), maximum)
    }

    private func workspaceDivider(height: CGFloat, availableHeight: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Divider()
        }
        .frame(height: 8)
        .contentShape(.rect)
        .background(WorkspaceSidebarResizeCursor())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("workspaceSidebarResize"))
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = height
                    }
                    draggedWorkspaceHeight = constrainedWorkspaceHeight(
                        (dragStartHeight ?? height) - value.translation.height,
                        availableHeight: availableHeight
                    )
                }
                .onEnded { value in
                    storedWorkspaceHeight = constrainedWorkspaceHeight(
                        (dragStartHeight ?? height) - value.translation.height,
                        availableHeight: availableHeight
                    )
                    dragStartHeight = nil
                    draggedWorkspaceHeight = nil
                }
        )
        .help("上下拖动以调整工作区区域高度")
        .accessibilityLabel("工作区区域高度")
        .accessibilityValue("\(Int(height)) 点")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 24 : -24
            storedWorkspaceHeight = constrainedWorkspaceHeight(
                height + delta,
                availableHeight: availableHeight
            )
        }
    }

    @ViewBuilder
    private var repositoryRows: some View {
        if appState.repositories.isEmpty {
            Text(appState.workspace == nil ? "请先打开工作区" : "尚未发现 Git 仓库")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            ForEach(appState.repositories) { repository in
                Button {
                    appState.selectRepositoryContext(repository.id)
                } label: {
                    RepositoryRow(
                        repository: repository,
                        snapshot: appState.repositorySnapshots[repository.id],
                        unavailableMessage: appState.repositoryUnavailableMessage(for: repository),
                        isRefreshing: appState.refreshingRepositoryIDs.contains(repository.id),
                        fontSize: appState.sidebarFontSize
                    )
                    .contentShape(.rect)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .background(
                    !appState.isWorkspaceContext && appState.selectedRepositoryID == repository.id
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear,
                    in: .rect(cornerRadius: 6)
                )
                .accessibilityValue(
                    !appState.isWorkspaceContext && appState.selectedRepositoryID == repository.id ? "已选择" : ""
                )
                .contextMenu {
                    Button("重命名", systemImage: "pencil") {
                        repositoryToRename = repository
                    }
                    Button("重新定位…", systemImage: "folder.badge.questionmark") {
                        appState.relocateRepository(repository.id)
                    }
                    Button(
                        repository.isPinned ? "取消置顶" : "置顶",
                        systemImage: repository.isPinned ? "pin.slash" : "pin"
                    ) {
                        appState.toggleRepositoryPin(repository.id)
                    }
                    Button("上移", systemImage: "arrow.up") {
                        appState.moveRepository(repository.id, by: -1)
                    }
                    .disabled(!appState.canMoveRepository(repository.id, by: -1))
                    Button("下移", systemImage: "arrow.down") {
                        appState.moveRepository(repository.id, by: 1)
                    }
                    .disabled(!appState.canMoveRepository(repository.id, by: 1))
                    Divider()
                    Button("移除注册", systemImage: "minus.circle", role: .destructive) {
                        appState.removeRepository(repository.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var discoveryProgress: some View {
        if appState.isDiscoveringRepositories {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在发现 Repository…")
                    .font(.system(size: max(9, appState.sidebarFontSize - 2)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var workspaceRows: some View {
        ForEach(sidebarWorkspaces) { workspace in
            Button {
                if appState.workspace?.path == workspace.path {
                    appState.selectWorkspaceContext()
                } else {
                    appState.openRecentWorkspace(workspace)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: workspaceIcon(for: workspace))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.name)
                            .lineLimit(1)
                        Text(workspace.path)
                            .font(.system(size: max(8, appState.sidebarFontSize - 3)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(
                appState.workspace?.path != workspace.path
                    && appState.isGitWriteOperationRunning
            )
            .background(
                isSelectedWorkspace(workspace) ? Color.accentColor.opacity(0.14) : Color.clear,
                in: .rect(cornerRadius: 6)
            )
            .help(workspace.path)
            .accessibilityValue(isSelectedWorkspace(workspace) ? "已选择" : "")
            .contextMenu {
                if appState.recentWorkspaces.contains(where: { $0.path == workspace.path }) {
                    Button("移除记录", systemImage: "minus.circle") {
                        appState.removeRecentWorkspace(workspace)
                    }
                }
            }
        }

        if sidebarWorkspaces.isEmpty {
            Text("尚未添加工作区")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }

    private func isSelectedWorkspace(_ workspace: RecentWorkspace) -> Bool {
        appState.isWorkspaceContext && appState.workspace?.path == workspace.path
    }

    private var sidebarWorkspaces: [RecentWorkspace] {
        guard let current = appState.workspace,
              !appState.recentWorkspaces.contains(where: { $0.path == current.path }) else {
            return appState.recentWorkspaces
        }
        return [
            RecentWorkspace(path: current.path, bookmark: nil, lastOpenedAt: .now)
        ] + appState.recentWorkspaces
    }

    private func workspaceIcon(for workspace: RecentWorkspace) -> String {
        guard appState.workspace?.path == workspace.path else { return "folder" }
        return appState.workspace?.isAvailable == true ? "folder.fill" : "folder.badge.questionmark"
    }
}

private struct WorkspaceSidebarResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeCursorView {
        ResizeCursorView()
    }

    func updateNSView(_ nsView: ResizeCursorView, context: Context) {}

    final class ResizeCursorView: NSView {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct RenameRepositorySheet: View {
    let repository: RegisteredRepository
    let rename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(repository: RegisteredRepository, rename: @escaping (String) -> Void) {
        self.repository = repository
        self.rename = rename
        _name = State(initialValue: repository.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名 Repository").font(.title2.weight(.semibold))
            TextField("显示名称", text: $name)
            Text(repository.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("重命名") {
                    rename(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct SidebarSectionTitle: View {
    let title: String
    let fontSize: Double

    init(_ title: String, fontSize: Double) {
        self.title = title
        self.fontSize = fontSize
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: max(9, fontSize - 2), weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }
}

private struct RepositoryRow: View {
    let repository: RegisteredRepository
    let snapshot: GitRepositorySnapshot?
    let unavailableMessage: String?
    let isRefreshing: Bool
    let fontSize: Double

    var body: some View {
        HStack {
            Image(
                systemName: unavailableMessage == nil
                    ? "point.3.connected.trianglepath.dotted"
                    : "externaldrive.badge.exclamationmark"
            )
                .foregroundStyle(unavailableMessage == nil ? Color.accentColor : Color.red)
            VStack(alignment: .leading) {
                Text(repository.name)
                Text(unavailableMessage == nil ? (snapshot?.branch ?? repository.relativePath) : "不可用")
                    .font(.system(size: max(9, fontSize - 2)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else if let snapshot, !snapshot.changes.isEmpty {
                Text("\(snapshot.changes.count)")
                    .font(.system(size: max(9, fontSize - 2), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if repository.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
