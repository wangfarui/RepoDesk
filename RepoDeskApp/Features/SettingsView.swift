import SwiftUI

enum RepoDeskSettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case appearance
    case files
    case shortcuts
    case git
    case java
    case maven

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .appearance: "外观"
        case .files: "Files"
        case .shortcuts: "快捷键"
        case .git: "Git"
        case .java: "Java"
        case .maven: "Maven"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "刷新、Workspace 与版本"
        case .appearance: "分区域字体大小"
        case .files: "文件树与编辑器"
        case .shortcuts: "查看与修改应用快捷键"
        case .git: "Changes 列表与 Diff 显示"
        case .java: "索引资源与缓存"
        case .maven: "运行环境与记录"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "textformat.size"
        case .files: "folder"
        case .shortcuts: "command"
        case .git: "point.3.connected.trianglepath.dotted"
        case .java: "cup.and.heat.waves"
        case .maven: "shippingbox"
        }
    }
}

@MainActor
struct RepoDeskSettingsView: View {
    @Bindable var appState: AppState
    @State private var selectedTab: RepoDeskSettingsTab
    @State private var javaIndexSettingsDraft: JavaIndexSettings
    @State private var showsRepositoryDiscoveryIgnoredDirectories = false

    init(appState: AppState, initialTab: RepoDeskSettingsTab = .general) {
        self.appState = appState
        _selectedTab = State(initialValue: initialTab)
        _javaIndexSettingsDraft = State(initialValue: appState.javaIndexSettings)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 760, idealWidth: 840, minHeight: 600, idealHeight: 660)
        .sheet(isPresented: $showsRepositoryDiscoveryIgnoredDirectories) {
            RepositoryDiscoveryIgnoredDirectoriesSheet(appState: appState)
        }
        .alert("Maven 配置无法保存", isPresented: mavenSettingsErrorAlertBinding) {
            Button("确定", role: .cancel) { appState.mavenSettingsErrorMessage = nil }
        } message: {
            Text(appState.mavenSettingsErrorMessage ?? "未知错误")
        }
        .alert("无法更新扫描忽略目录", isPresented: repositoryDiscoverySettingsErrorAlertBinding) {
            Button("确定", role: .cancel) {
                appState.repositoryDiscoverySettingsErrorMessage = nil
            }
        } message: {
            Text(appState.repositoryDiscoverySettingsErrorMessage ?? "未知错误")
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
                                set: { appState.setAutomaticallyRefreshesWorkspace($0) }
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
                                set: { appState.setRefreshesWhenBecomingActive($0) }
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

                SettingsSection(title: "Git 仓库发现", systemImage: "magnifyingglass") {
                    SettingsRow(
                        title: "自定义忽略目录",
                        description: "扫描时跳过所选目录及其子目录；不影响已经注册的 Repository。"
                    ) {
                        HStack {
                            Button("查看忽略目录", systemImage: "list.bullet") {
                                showsRepositoryDiscoveryIgnoredDirectories = true
                            }
                            .accessibilityIdentifier(
                                "RepoDesk.RepositoryDiscovery.ViewIgnoredDirectories"
                            )

                            Button("添加目录…", systemImage: "folder.badge.plus") {
                                appState.chooseRepositoryDiscoveryIgnoredDirectory()
                            }
                        }
                        .disabled(appState.workspace?.isAvailable != true)
                    }

                    SettingsRow(
                        title: "内置忽略规则",
                        description: ".git、.gradle、.idea、build、node_modules、target、隐藏目录和 macOS 文件包。"
                    ) {
                        Text("始终启用")
                            .foregroundStyle(.secondary)
                    }

                    SettingsRow(
                        title: "扫描操作",
                        description: "配置会立即保存，并从下一次发现 Repository 开始生效。"
                    ) {
                        HStack {
                            Button("清空自定义规则", systemImage: "arrow.counterclockwise") {
                                appState.resetRepositoryDiscoveryIgnoredDirectories()
                            }
                            .disabled(
                                appState.repositoryDiscoverySettings.ignoredDirectoryPaths.isEmpty
                            )

                            Button("重新扫描", systemImage: "magnifyingglass") {
                                appState.discoverRepositories()
                            }
                            .disabled(
                                appState.workspace?.isAvailable != true
                                    || appState.isDiscoveringRepositories
                            )
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

        case .appearance:
            settingsPage(
                title: "外观",
                description: "分别调整主窗口左侧栏、右侧功能区和文件内容的字体大小。"
            ) {
                SettingsSection(title: "字体大小", systemImage: "textformat.size") {
                    SettingsRow(
                        title: "左侧栏",
                        description: "Git 仓库、工作区及其列表项。"
                    ) {
                        FontSizeStepper(
                            value: Binding(
                                get: { appState.sidebarFontSize },
                                set: { appState.setSidebarFontSize($0) }
                            )
                        )
                    }

                    SettingsRow(
                        title: "右侧功能区",
                        description: "按钮、页签、文件名、分组标题和其他功能项名称。"
                    ) {
                        FontSizeStepper(
                            value: Binding(
                                get: { appState.interfaceFontSize },
                                set: { appState.setInterfaceFontSize($0) }
                            )
                        )
                    }

                    SettingsRow(
                        title: "文件内容",
                        description: "源码编辑器、Markdown 预览和 Git Diff 内容。"
                    ) {
                        FontSizeStepper(
                            value: Binding(
                                get: { appState.fileContentFontSize },
                                set: { appState.setFileContentFontSize($0) }
                            )
                        )
                    }

                    SettingsRow(
                        title: "字体默认值",
                        description: "将三个区域恢复为 13 pt。"
                    ) {
                        Button("恢复", systemImage: "arrow.counterclockwise") {
                            appState.resetFontSizes()
                        }
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
                        description: "在文件树中包含点文件；文件名搜索仍会排除点文件。"
                    ) {
                        Toggle(
                            "显示隐藏文件",
                            isOn: Binding(
                                get: { appState.showsHiddenFiles },
                                set: { appState.setShowsHiddenFiles($0) }
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
                                set: { appState.setCompactsSingleChildDirectories($0) }
                            )
                        )
                        .labelsHidden()
                    }
                }

                SettingsSection(title: "编辑器", systemImage: "doc.text") {
                    SettingsRow(
                        title: "最多打开文件 Tab",
                        description: "超过数量时自动关闭最早打开的文件。"
                    ) {
                        Stepper(
                            value: Binding(
                                get: { appState.maximumOpenFileTabs },
                                set: { appState.setMaximumOpenFileTabs($0) }
                            ),
                            in: 1...50
                        ) {
                            Text("\(appState.maximumOpenFileTabs)")
                                .monospacedDigit()
                                .frame(minWidth: 24, alignment: .trailing)
                        }
                    }
                    SettingsRow(
                        title: "Markdown 默认打开预览",
                        description: "选择 Markdown 文件时优先显示块级预览。"
                    ) {
                        Toggle(
                            "Markdown 默认打开预览",
                            isOn: Binding(
                                get: { appState.opensMarkdownInPreview },
                                set: { appState.setOpensMarkdownInPreview($0) }
                            )
                        )
                        .labelsHidden()
                    }
                    SettingsRow(
                        title: "Files 默认值",
                        description: "隐藏点文件、折叠单子目录、默认打开编辑器并保留 5 个 Tab。"
                    ) {
                        Button("恢复", systemImage: "arrow.counterclockwise") {
                            appState.setShowsHiddenFiles(false)
                            appState.setCompactsSingleChildDirectories(true)
                            appState.setOpensMarkdownInPreview(false)
                            appState.setMaximumOpenFileTabs(5)
                        }
                    }
                }
            }

        case .shortcuts:
            shortcutSettingsPage

        case .git:
            settingsPage(
                title: "Git",
                description: "配置 Repository 和 Workspace 的 Changes 列表，以及 Diff 显示偏好。"
            ) {
                SettingsSection(title: "Changes 列表", systemImage: "list.bullet.indent") {
                    SettingsRow(
                        title: "自动展开改动列表",
                        description: "重新进入 Changes、切换仓库或更换分组时应用；手动展开、折叠后，刷新会保留当前状态。"
                    ) {
                        Picker(
                            "自动展开改动列表",
                            selection: Binding(
                                get: { appState.changesAutoExpansion.mode },
                                set: { appState.setChangesAutoExpansionMode($0) }
                            )
                        ) {
                            ForEach(ChangesAutoExpansionSettings.Mode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .accessibilityIdentifier("RepoDesk.Settings.ChangesAutoExpansionMode")
                    }

                    if appState.changesAutoExpansion.mode == .byCount {
                        SettingsRow(
                            title: "自动展开阈值",
                            description: "当前 Changes 范围内的改动数量不超过此值时，自动展开所有分组，显示文件列表。"
                        ) {
                            HStack(spacing: 6) {
                                TextField(
                                    "自动展开阈值",
                                    value: changesAutoExpansionMaximumFileCountBinding,
                                    format: .number.grouping(.never)
                                )
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                                .accessibilityIdentifier("RepoDesk.Settings.ChangesAutoExpansionThreshold")
                                Text("个")
                                Stepper(
                                    "自动展开阈值",
                                    value: changesAutoExpansionMaximumFileCountBinding,
                                    in: ChangesAutoExpansionSettings.fileCountRange
                                )
                                .labelsHidden()
                                .fixedSize()
                            }
                            .help("可输入 1–10,000；默认 10")
                        }
                    }

                    SettingsRow(
                        title: "Changes 默认值",
                        description: "恢复按改动数量自动展开，阈值为 10。"
                    ) {
                        Button("恢复", systemImage: "arrow.counterclockwise") {
                            appState.resetChangesAutoExpansion()
                        }
                    }
                }

                SettingsSection(title: "Diff 显示", systemImage: "rectangle.split.2x1") {
                    SettingsRow(
                        title: "默认 Diff 模式",
                        description: "Unified 适合快速浏览，Side-by-side 适合逐行比较。"
                    ) {
                        Picker(
                            "默认 Diff 模式",
                            selection: Binding(
                                get: { appState.diffPresentation },
                                set: { appState.setDiffPresentation($0) }
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
                                set: { appState.setIgnoresWhitespaceInDiff($0) }
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

        case .java:
            settingsPage(
                title: "Java",
                description: "控制 Eclipse JDT Language Server 的并发、CPU、内存和持久化索引缓存。修改只在显式应用后生效。"
            ) {
                SettingsSection(title: "运行资源", systemImage: "cpu") {
                    SettingsRow(
                        title: "最大 JVM 数量",
                        description: "多个 Java Repository 可并行索引；前台 Repository 会优先占用名额。"
                    ) {
                        Stepper(value: maximumJVMCountBinding, in: 1...4) {
                            Text("\(javaIndexSettingsDraft.maximumJVMCount)")
                                .monospacedDigit()
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                    SettingsRow(
                        title: "每个 JVM 的 CPU",
                        description: "通过 ActiveProcessorCount 限制每个 Java 进程可使用的处理器数量。"
                    ) {
                        Stepper(
                            value: processorCountBinding,
                            in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount)
                        ) {
                            Text("\(javaIndexSettingsDraft.processorCountPerJVM) 核")
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    SettingsRow(
                        title: "每个 JVM 最大堆内存",
                        description: "大型 Spring 多模块项目可能需要更高上限；默认 2 GB。"
                    ) {
                        Stepper(value: maximumHeapBinding, in: 1_024...8_192, step: 1_024) {
                            Text("\(javaIndexSettingsDraft.maximumHeapMegabytes / 1_024) GB")
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    SettingsRow(
                        title: "最大合计堆内存",
                        description: "所有允许同时运行的 Java language server 的理论上限。"
                    ) {
                        Text(combinedHeapText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsSection(title: "缓存", systemImage: "externaldrive") {
                    SettingsRow(
                        title: "磁盘缓存总量",
                        description: "按 Repository 保存并使用 LRU 清理；正在使用的缓存不会被删除。"
                    ) {
                        Stepper(value: cacheLimitBinding, in: 1...100) {
                            Text("\(javaIndexSettingsDraft.cacheLimitGigabytes) GB")
                                .monospacedDigit()
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                    SettingsRow(
                        title: "当前使用量",
                        description: "所有已识别 Java Repository 的索引缓存合计。"
                    ) {
                        Text(javaCacheUsageText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow(
                        title: "清理未使用缓存",
                        description: "删除当前未由 Java language server 使用的 Repository 缓存。"
                    ) {
                        Button("清理", systemImage: "trash") {
                            appState.clearUnusedJavaCaches()
                        }
                    }
                }

                SettingsSection(title: "索引控制", systemImage: "arrow.triangle.2.circlepath") {
                    SettingsRow(
                        title: "运行状态",
                        description: "非 Java Repository 不启动 JVM；前台操作始终优先于后台预索引。"
                    ) {
                        Text(javaRuntimeStatusText)
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow(
                        title: "后台索引",
                        description: "暂停只影响后台任务，当前查看的 Java Repository 仍可按需加载。"
                    ) {
                        Toggle(
                            "后台索引",
                            isOn: Binding(
                                get: { !appState.javaIndexSnapshot.isBackgroundIndexingPaused },
                                set: { appState.setJavaBackgroundIndexingPaused(!$0) }
                            )
                        )
                        .labelsHidden()
                    }
                    SettingsRow(
                        title: "资源默认值",
                        description: "恢复为 1 个 JVM、每个 2 核、2 GB 堆内存和 10 GB 缓存。"
                    ) {
                        Button("恢复", systemImage: "arrow.counterclockwise") {
                            javaIndexSettingsDraft = .default
                        }
                    }
                    SettingsRow(
                        title: "应用配置",
                        description: "保存设置并重启当前 Java 索引进程；未保存的文件内容不会丢失。"
                    ) {
                        Button("应用并重启 Java 索引", systemImage: "checkmark.circle") {
                            appState.setJavaIndexSettings(javaIndexSettingsDraft)
                        }
                        .disabled(javaIndexSettingsDraft == appState.javaIndexSettings)
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
                        set: { appState.updateMavenSettings($0) }
                    ),
                    projectRevision: 0,
                    validationStore: appState.mavenEnvironmentValidationStore,
                    execution: appState.mavenExecution,
                    recentRuns: appState.recentMavenRuns,
                    run: { appState.runMaven($0) },
                    stop: { appState.stopMaven() },
                    clearLog: { appState.clearMavenLog() },
                    removeRun: { appState.removeMavenRun($0) },
                    clearPersistedLogs: { appState.clearPersistedMavenLogs() },
                    clearHistory: { appState.clearMavenRunHistory() },
                    queueMessage: appState.mavenQueueMessage,
                    duplicateMessage: { appState.mavenQueue.duplicateMessage(for: $0, repositoryURL: $1) }
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

    private var changesAutoExpansionMaximumFileCountBinding: Binding<Int> {
        Binding(
            get: { appState.changesAutoExpansion.maximumFileCount },
            set: { appState.setChangesAutoExpansionMaximumFileCount($0) }
        )
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

    private var shortcutSettingsPage: some View {
        settingsPage(
            title: "快捷键",
            description: "配置 RepoDesk 自己定义的应用快捷键。macOS 和文本编辑器自带的复制、粘贴等快捷键不在此处配置。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("点击右侧录制框后输入新的组合键。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复全部默认值", systemImage: "arrow.counterclockwise") {
                        appState.resetAllShortcuts()
                    }
                }
                ForEach(Array(AppShortcutID.allCases.enumerated()), id: \.element) { index, id in
                    if index == 0 || AppShortcutID.allCases[index - 1].group != id.group {
                        Text(id.group)
                            .font(.headline)
                            .padding(.top, index == 0 ? 4 : 14)
                    }
                    ShortcutSettingsRow(id: id, appState: appState)
                }
            }
        }
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

    private var maximumJVMCountBinding: Binding<Int> {
        Binding(
            get: { javaIndexSettingsDraft.maximumJVMCount },
            set: {
                javaIndexSettingsDraft = JavaIndexSettings(
                    maximumJVMCount: $0,
                    processorCountPerJVM: javaIndexSettingsDraft.processorCountPerJVM,
                    maximumHeapMegabytes: javaIndexSettingsDraft.maximumHeapMegabytes,
                    cacheLimitGigabytes: javaIndexSettingsDraft.cacheLimitGigabytes
                )
            }
        )
    }

    private var processorCountBinding: Binding<Int> {
        Binding(
            get: { javaIndexSettingsDraft.processorCountPerJVM },
            set: {
                javaIndexSettingsDraft = JavaIndexSettings(
                    maximumJVMCount: javaIndexSettingsDraft.maximumJVMCount,
                    processorCountPerJVM: $0,
                    maximumHeapMegabytes: javaIndexSettingsDraft.maximumHeapMegabytes,
                    cacheLimitGigabytes: javaIndexSettingsDraft.cacheLimitGigabytes
                )
            }
        )
    }

    private var maximumHeapBinding: Binding<Int> {
        Binding(
            get: { javaIndexSettingsDraft.maximumHeapMegabytes },
            set: {
                javaIndexSettingsDraft = JavaIndexSettings(
                    maximumJVMCount: javaIndexSettingsDraft.maximumJVMCount,
                    processorCountPerJVM: javaIndexSettingsDraft.processorCountPerJVM,
                    maximumHeapMegabytes: $0,
                    cacheLimitGigabytes: javaIndexSettingsDraft.cacheLimitGigabytes
                )
            }
        )
    }

    private var cacheLimitBinding: Binding<Int> {
        Binding(
            get: { javaIndexSettingsDraft.cacheLimitGigabytes },
            set: {
                javaIndexSettingsDraft = JavaIndexSettings(
                    maximumJVMCount: javaIndexSettingsDraft.maximumJVMCount,
                    processorCountPerJVM: javaIndexSettingsDraft.processorCountPerJVM,
                    maximumHeapMegabytes: javaIndexSettingsDraft.maximumHeapMegabytes,
                    cacheLimitGigabytes: $0
                )
            }
        )
    }

    private var combinedHeapText: String {
        let value = javaIndexSettingsDraft.maximumCombinedHeapGigabytes
        return value.rounded() == value ? "\(Int(value)) GB" : String(format: "%.1f GB", value)
    }

    private var javaCacheUsageText: String {
        ByteCountFormatter.string(
            fromByteCount: appState.javaIndexSnapshot.cacheBytes,
            countStyle: .file
        )
    }

    private var javaRuntimeStatusText: String {
        let snapshot = appState.javaIndexSnapshot
        return "\(snapshot.runningJVMCount) JVM · \(snapshot.readyRepositoryCount)/\(snapshot.javaRepositoryCount) Repository 就绪"
    }

    private var mavenSettingsErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.mavenSettingsErrorMessage != nil },
            set: { if !$0 { appState.mavenSettingsErrorMessage = nil } }
        )
    }

    private var repositoryDiscoverySettingsErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.repositoryDiscoverySettingsErrorMessage != nil },
            set: {
                if !$0 {
                    appState.repositoryDiscoverySettingsErrorMessage = nil
                }
            }
        )
    }
}

private struct RepositoryDiscoveryIgnoredDirectoriesSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.minus")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("忽略目录")
                        .font(.title2.weight(.semibold))
                    Text("管理当前 Workspace 在发现 Git 仓库时跳过的目录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace 根路径")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(workspaceRootPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            Group {
                if ignoredDirectoryPaths.isEmpty {
                    ContentUnavailableView(
                        "没有自定义忽略目录",
                        systemImage: "folder",
                        description: Text("可返回设置页，通过“添加目录…”创建扫描忽略规则。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(ignoredDirectoryPaths, id: \.self) { relativePath in
                                ignoredDirectoryRow(relativePath)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text("共 \(ignoredDirectoryPaths.count) 个目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 460)
        .accessibilityIdentifier("RepoDesk.RepositoryDiscovery.IgnoredDirectoriesSheet")
    }

    private var ignoredDirectoryPaths: [String] {
        appState.repositoryDiscoverySettings.ignoredDirectoryPaths
    }

    private var workspaceRootPath: String {
        appState.currentWorkspaceURL?.path ?? "当前没有打开 Workspace。"
    }

    private func ignoredDirectoryRow(_ relativePath: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(relativePath)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Text("相对于 Workspace 根路径")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                appState.removeRepositoryDiscoveryIgnoredDirectory(relativePath)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }
}

private struct FontSizeStepper: View {
    @Binding var value: Double

    var body: some View {
        Stepper(
            value: $value,
            in: RepoDeskFontSize.minimum...RepoDeskFontSize.maximum,
            step: 1
        ) {
            Text("\(Int(value)) pt")
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
        .accessibilityValue("\(Int(value)) pt")
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

private struct ShortcutSettingsRow: View {
    let id: AppShortcutID
    @Bindable var appState: AppState
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id.title)
                Text("默认：\(id.defaultBinding.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let conflict = appState.shortcutConflict(for: id) {
                    Text("与“\(conflict.title)”冲突")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            ShortcutRecorder(
                binding: Binding(
                    get: { appState.shortcut(for: id) },
                    set: { appState.setShortcut($0, for: id) }
                ),
                isRecording: $isRecording
            )
            .frame(width: 130, height: 28)
            Button("恢复") {
                appState.resetShortcut(id)
            }
            .disabled(appState.shortcut(for: id) == id.defaultBinding)
        }
        .padding(.vertical, 4)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var binding: ShortcutBinding
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.binding = binding
        view.isRecording = isRecording
        view.onBindingChanged = { newBinding in
            binding = newBinding
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.binding = binding
        nsView.isRecording = isRecording
        nsView.onBindingChanged = { newBinding in
            binding = newBinding
            isRecording = false
        }
    }
}

private final class ShortcutRecorderView: NSView {
    var binding = ShortcutBinding(key: "") { didSet { needsDisplay = true } }
    var isRecording = false { didSet { needsDisplay = true } }
    var onBindingChanged: ((ShortcutBinding) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        switch event.keyCode {
        case 36: key = "return"
        case 51: key = "delete"
        case 123: key = "left"
        case 124: key = "right"
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(),
                  let first = characters.first else { return }
            key = String(first)
        }
        let shortcutModifiers: Set<ShortcutModifier> = Set(
            ShortcutModifier.allCases.filter { modifiers.contains($0.eventFlag) }
        )
        onBindingChanged?(ShortcutBinding(key: key, modifiers: shortcutModifiers))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).stroke()
        let text = isRecording ? "输入快捷键…" : binding.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}
