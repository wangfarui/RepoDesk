import SwiftUI

enum RepoDeskSettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case files
    case diff
    case maven

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .files: "Files"
        case .diff: "Diff"
        case .maven: "Maven"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "刷新、Workspace 与版本"
        case .files: "文件树与编辑器"
        case .diff: "差异显示偏好"
        case .maven: "运行环境与记录"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .files: "folder"
        case .diff: "rectangle.split.2x1"
        case .maven: "shippingbox"
        }
    }
}

@MainActor
struct RepoDeskSettingsView: View {
    @Bindable var appState: AppState
    @State private var selectedTab: RepoDeskSettingsTab

    init(appState: AppState, initialTab: RepoDeskSettingsTab = .general) {
        self.appState = appState
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 760, idealWidth: 840, minHeight: 600, idealHeight: 660)
        .alert("Maven 配置无法保存", isPresented: mavenSettingsErrorAlertBinding) {
            Button("确定", role: .cancel) { appState.mavenSettingsErrorMessage = nil }
        } message: {
            Text(appState.mavenSettingsErrorMessage ?? "未知错误")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("RepoDesk")
                        .font(.headline)
                    Text("设置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            VStack(spacing: 4) {
                ForEach(RepoDeskSettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.systemImage)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.title)
                                    .fontWeight(.medium)
                                Text(tab.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                        .padding(.horizontal, 10)
                        .frame(height: 50)
                        .background(
                            selectedTab == tab ? Color.accentColor.opacity(0.14) : .clear,
                            in: .rect(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel(tab.title)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            Text("v\(appVersion)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(16)
        }
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTab {
        case .general:
            settingsPage(
                title: "通用",
                description: "控制 RepoDesk 如何跟踪外部变化，并查看当前 Workspace 与版本信息。"
            ) {
                SettingsSection(title: "刷新", systemImage: "arrow.clockwise") {
                    SettingsRow(
                        title: "监听 Workspace 文件变化",
                        description: "文件变化后自动刷新文件树、Git 和 Maven 状态。"
                    ) {
                        Toggle(
                            "监听 Workspace 文件变化",
                            isOn: Binding(
                                get: { appState.automaticallyRefreshesWorkspace },
                                set: appState.setAutomaticallyRefreshesWorkspace
                            )
                        )
                        .labelsHidden()
                    }

                    SettingsRow(
                        title: "切回 RepoDesk 时检查外部变化",
                        description: "从其他应用返回时重新核对工作区状态。"
                    ) {
                        Toggle(
                            "切回 RepoDesk 时检查外部变化",
                            isOn: Binding(
                                get: { appState.refreshesWhenBecomingActive },
                                set: appState.setRefreshesWhenBecomingActive
                            )
                        )
                        .labelsHidden()
                        .help("从其他应用切回 RepoDesk 时，重新检查文件、Git 和 Maven 状态")
                    }

                    SettingsRow(
                        title: "立即刷新",
                        description: "手动执行一次完整的一致性检查。"
                    ) {
                        Button("刷新", systemImage: "arrow.clockwise") {
                            Task { await appState.refreshWorkspaceConsistency() }
                        }
                        .disabled(appState.workspace == nil)
                    }
                }

                SettingsSection(title: "Workspace", systemImage: "folder.badge.gearshape") {
                    SettingsRow(title: "当前 Workspace", description: workspacePath) {
                        Text(appState.workspace?.name ?? "未打开")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    SettingsRow(
                        title: "通用默认值",
                        description: "恢复自动监听与切回检查。"
                    ) {
                        Button("恢复", systemImage: "arrow.counterclockwise") {
                            appState.setAutomaticallyRefreshesWorkspace(true)
                            appState.setRefreshesWhenBecomingActive(true)
                        }
                    }
                }

                SettingsSection(title: "关于", systemImage: "info.circle") {
                    SettingsRow(title: "版本", description: "本地 v0.1 交付版本") {
                        Text(appVersion)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                    SettingsRow(title: "Bundle ID", description: "应用唯一标识") {
                        Text(appBundleIdentifier)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

        case .files:
            settingsPage(
                title: "Files",
                description: "配置 Workspace 和 Repository 文件树，以及 Markdown 的默认打开方式。"
            ) {
                SettingsSection(title: "文件树", systemImage: "folder") {
                    SettingsRow(
                        title: "显示隐藏文件",
                        description: "在文件树与快速打开结果中包含点文件。"
                    ) {
                        Toggle(
                            "显示隐藏文件",
                            isOn: Binding(
                                get: { appState.showsHiddenFiles },
                                set: appState.setShowsHiddenFiles
                            )
                        )
                        .labelsHidden()
                    }
                    SettingsRow(
                        title: "折叠单子目录",
                        description: "将只有一个子目录的连续层级显示为紧凑路径。"
                    ) {
                        Toggle(
                            "折叠单子目录",
                            isOn: Binding(
                                get: { appState.compactsSingleChildDirectories },
                                set: appState.setCompactsSingleChildDirectories
                            )
                        )
                        .labelsHidden()
                    }
                }

                SettingsSection(title: "编辑器", systemImage: "doc.text") {
                    SettingsRow(
                        title: "Markdown 默认打开预览",
                        description: "选择 Markdown 文件时优先显示块级预览。"
                    ) {
                        Toggle(
                            "Markdown 默认打开预览",
                            isOn: Binding(
                                get: { appState.opensMarkdownInPreview },
                                set: appState.setOpensMarkdownInPreview
                            )
                        )
                        .labelsHidden()
                    }
                    SettingsRow(
                        title: "Files 默认值",
                        description: "隐藏点文件、折叠单子目录并默认打开编辑器。"
                    ) {
                        Button("恢复", systemImage: "arrow.counterclockwise") {
                            appState.setShowsHiddenFiles(false)
                            appState.setCompactsSingleChildDirectories(true)
                            appState.setOpensMarkdownInPreview(false)
                        }
                    }
                }
            }

        case .diff:
            settingsPage(
                title: "Diff",
                description: "这些偏好会应用到之后打开或刷新的 Changes Diff。"
            ) {
                SettingsSection(title: "显示", systemImage: "rectangle.split.2x1") {
                    SettingsRow(
                        title: "默认 Diff 模式",
                        description: "Unified 适合快速浏览，Side-by-side 适合逐行比较。"
                    ) {
                        Picker(
                            "默认 Diff 模式",
                            selection: Binding(
                                get: { appState.diffPresentation },
                                set: appState.setDiffPresentation
                            )
                        ) {
                            ForEach(GitDiffPresentation.allCases) { presentation in
                                Text(presentation.rawValue).tag(presentation)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 250)
                    }

                    SettingsRow(
                        title: "忽略空白变化",
                        description: "加载 Diff 时忽略仅由空格和缩进产生的变化。"
                    ) {
                        Toggle(
                            "忽略空白变化",
                            isOn: Binding(
                                get: { appState.ignoresWhitespaceInDiff },
                                set: appState.setIgnoresWhitespaceInDiff
                            )
                        )
                        .labelsHidden()
                    }

                    SettingsRow(
                        title: "Diff 默认值",
                        description: "恢复 Unified 并显示空白变化。"
                    ) {
                        Button("恢复", systemImage: "arrow.counterclockwise") {
                            appState.setDiffPresentation(.unified)
                            appState.setIgnoresWhitespaceInDiff(false)
                        }
                    }
                }
            }

        case .maven:
            if let workspaceURL = appState.currentWorkspaceURL {
                MavenView(
                    workspaceURL: workspaceURL,
                    repositoryURL: nil,
                    settings: Binding(
                        get: { appState.mavenSettings },
                        set: appState.updateMavenSettings
                    ),
                    projectRevision: 0,
                    validationStore: appState.mavenEnvironmentValidationStore,
                    execution: appState.mavenExecution,
                    recentRuns: appState.recentMavenRuns,
                    run: appState.runMaven,
                    stop: appState.stopMaven,
                    clearLog: appState.clearMavenLog,
                    removeRun: appState.removeMavenRun,
                    clearPersistedLogs: appState.clearPersistedMavenLogs,
                    clearHistory: appState.clearMavenRunHistory
                )
            } else {
                ContentUnavailableView(
                    "未打开 Workspace",
                    systemImage: "shippingbox",
                    description: Text("Maven 配置按 Workspace 保存。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func settingsPage<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var workspacePath: String {
        appState.currentWorkspaceURL?.path ?? "当前没有打开 Workspace。"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var appBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.wangfarui.RepoDesk"
    }

    private var mavenSettingsErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.mavenSettingsErrorMessage != nil },
            set: { if !$0 { appState.mavenSettingsErrorMessage = nil } }
        )
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: Control

    init(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 14)
        }
    }
}
