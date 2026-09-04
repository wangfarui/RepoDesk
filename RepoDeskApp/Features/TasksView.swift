import AppKit
import SwiftUI

@MainActor
struct MavenView: View {
    let workspaceURL: URL
    let repositoryURL: URL?
    @Binding var settings: MavenSettings
    let projectRevision: Int
    let validationStore: MavenEnvironmentValidationStore
    let execution: MavenExecutionPresentation
    let recentRuns: [MavenRunRecord]
    let run: (MavenRunRequest) -> Void
    let stop: () -> Void
    let clearLog: () -> Void
    let removeRun: (MavenRunRecord.ID) -> Void
    let clearPersistedLogs: () -> Void
    let clearHistory: () -> Void
    var persistedSelection: MavenWindowSelection? = nil
    var updatePersistedSelection: (MavenWindowSelection?) -> Void = { _ in }

    @State private var project: MavenProject?
    @State private var scanErrorMessage: String?
    @State private var isScanning = false
    @State private var expandedModuleIDs: Set<MavenModule.ID> = []
    @State private var selectedTarget: MavenRunTarget?
    @State private var selectedRunID: MavenRunRecord.ID?
    @State private var activePreviewRequest: MavenRunRequest?
    @State private var pendingConfirmation: MavenRunRequest?
    @State private var isConfirmingHistoryClear = false
    @State private var runValidationMessage: String?
    @State private var profilesDraft = ""
    @State private var additionalArgumentsDraft = ""
    @State private var followsLatestOutput = true
    var body: some View {
        Group {
            if let repositoryURL {
                repositoryContent(repositoryURL: repositoryURL)
            } else {
                settingsContent
            }
        }
        .toolbar {
            if repositoryURL != nil {
                ToolbarItemGroup {
                    Button("重新加载 Maven 项目", systemImage: "arrow.clockwise") {
                        Task { await loadProject() }
                    }
                    .labelStyle(.iconOnly)
                    .help("重新加载 Maven 项目")

                    if execution.runningRequestID != nil {
                        Button("停止", systemImage: "stop.fill", role: .destructive, action: stop)
                            .labelStyle(.iconOnly)
                            .help("停止")
                    } else {
                        Button("运行", systemImage: "play.fill") {
                            runSelectedTarget()
                        }
                        .labelStyle(.iconOnly)
                        .help("运行选中的 Lifecycle")
                        .disabled(selectedTarget?.module.hasPOM != true)
                    }
                }
            }
        }
        .confirmationDialog(
            "执行 deploy？",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("执行 deploy") {
                if let request = pendingConfirmation { run(request) }
                pendingConfirmation = nil
            }
            Button("取消", role: .cancel) { pendingConfirmation = nil }
        } message: {
            if let request = pendingConfirmation {
                Text("deploy 会向远程 Repository 发布构件，请确认最终命令：\n\n\(displayCommand(request.command))")
            }
        }
        .confirmationDialog(
            "清空 Maven 运行记录？",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("清空记录", role: .destructive, action: clearHistory)
            Button("取消", role: .cancel) {}
        } message: {
            Text("运行记录及其中保存的日志将被删除，此操作无法撤销。")
        }
        .task(id: projectScanTaskID) {
            await loadProject()
        }
        .task(id: mavenHomeValidationTaskID) {
            guard repositoryURL == nil else { return }
            await validationStore.validateMavenHome(workspaceURL: workspaceURL, home: settings.mavenHome)
        }
        .task(id: javaHomeValidationTaskID) {
            guard repositoryURL == nil else { return }
            await validationStore.validateJavaHome(workspaceURL: workspaceURL, home: settings.javaHome)
        }
        .onAppear {
            synchronizeParameterDrafts()
            restorePersistedSelectionIfPossible()
        }
        .onChange(of: workspaceURL.standardizedFileURL.path) {
            synchronizeParameterDrafts()
        }
        .onChange(of: repositoryURL?.standardizedFileURL.path) {
            project = nil
            scanErrorMessage = nil
            selectedTarget = nil
            selectedRunID = nil
            activePreviewRequest = nil
            runValidationMessage = nil
            followsLatestOutput = true
            restorePersistedSelectionIfPossible()
        }
        .onChange(of: selectedRunID) {
            if selectedRunID == nil {
                followsLatestOutput = true
            }
        }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Maven 配置")
                        .font(.title2.weight(.semibold))
                    Text(workspaceURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("运行环境")
                    .fontWeight(.semibold)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    mavenHomeConfigurationRows
                    configurationRow(
                        title: "User settings file",
                        value: $settings.userSettingsFile,
                        prompt: "~/.m2/settings.xml",
                        picker: .file,
                        validation: pathValidation(path: settings.userSettingsFile, kind: .userSettingsFile)
                    )
                    configurationRow(
                        title: "Local repository",
                        value: $settings.localRepository,
                        prompt: "~/.m2/repository",
                        picker: .directory,
                        validation: pathValidation(path: settings.localRepository, kind: .localRepository)
                    )
                    javaHomeConfigurationRows
                }
                .frame(maxWidth: 780)

                Divider()
                    .frame(maxWidth: 780)

                Text("运行参数")
                    .fontWeight(.semibold)

                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Profiles")
                            .frame(width: 130, alignment: .trailing)
                        TextField("dev,local", text: $profilesDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280)
                            .onChange(of: profilesDraft) {
                                settings.activeProfiles = parsedProfiles(profilesDraft)
                            }
                        if profilesIncludeFlagPrefix {
                            Label("只填写名称，无需 -P", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Color.clear.frame(width: 1, height: 1)
                        }
                    }

                    GridRow {
                        Text("模块依赖")
                            .frame(width: 130, alignment: .trailing)
                        Toggle("同时构建依赖模块（-am）", isOn: $settings.alsoMake)
                            .toggleStyle(.checkbox)
                        Color.clear.frame(width: 1, height: 1)
                    }

                    GridRow {
                        Text("附加参数")
                            .frame(width: 130, alignment: .trailing)
                            .padding(.top, 5)
                        TextEditor(text: $additionalArgumentsDraft)
                            .font(.body.monospaced())
                            .scrollContentBackground(.hidden)
                            .padding(5)
                            .frame(minWidth: 280, minHeight: 76, maxHeight: 110)
                            .background(.background, in: .rect(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.separator, lineWidth: 1)
                            }
                            .onChange(of: additionalArgumentsDraft) {
                                settings.additionalArguments = parsedAdditionalArguments(additionalArgumentsDraft)
                            }
                        Text("每行一个参数")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: 780)

                Divider()
                    .frame(maxWidth: 780)

                Text("运行记录")
                    .fontWeight(.semibold)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("保存日志")
                            .frame(width: 130, alignment: .trailing)
                        Toggle("保存每次 Maven 运行的输出", isOn: $settings.runHistoryPolicy.persistsLogs)
                            .toggleStyle(.checkbox)
                        Color.clear.frame(width: 1, height: 1)
                    }

                    GridRow {
                        Text("最大记录数")
                            .frame(width: 130, alignment: .trailing)
                        Stepper(
                            value: $settings.runHistoryPolicy.maximumRecordCount,
                            in: MavenRunHistoryPolicy.supportedRecordCount
                        ) {
                            Text("\(settings.runHistoryPolicy.maximumRecordCount) 条")
                                .monospacedDigit()
                        }
                        .frame(width: 180, alignment: .leading)
                        Color.clear.frame(width: 1, height: 1)
                    }

                    GridRow {
                        Text("单条日志上限")
                            .frame(width: 130, alignment: .trailing)
                        Picker("单条日志上限", selection: $settings.runHistoryPolicy.maximumLogBytes) {
                            if !MavenLogCapacity.allCases.contains(where: {
                                $0.bytes == settings.runHistoryPolicy.maximumLogBytes
                            }) {
                                Text(formattedByteCount(settings.runHistoryPolicy.maximumLogBytes))
                                    .tag(settings.runHistoryPolicy.maximumLogBytes)
                            }
                            ForEach(MavenLogCapacity.allCases) { capacity in
                                Text(capacity.title).tag(capacity.bytes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180, alignment: .leading)
                        .disabled(!settings.runHistoryPolicy.persistsLogs)
                        Color.clear.frame(width: 1, height: 1)
                    }

                    GridRow {
                        Color.clear.frame(width: 130, height: 1)
                        HStack(spacing: 8) {
                            Button("清除已保存日志", systemImage: "doc.badge.ellipsis") {
                                clearPersistedLogs()
                            }
                            .disabled(recentRuns.allSatisfy { $0.log == nil })

                            Button("清空运行记录", systemImage: "trash", role: .destructive) {
                                isConfirmingHistoryClear = true
                            }
                            .disabled(recentRuns.isEmpty)
                        }
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
                .frame(maxWidth: 780)

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var mavenHomeConfigurationRows: some View {
        GridRow {
            Text("Maven Home")
                .frame(width: 130, alignment: .trailing)
            TextField("/path/to/apache-maven", text: $settings.mavenHome)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
            Button("选择…") {
                if let path = choosePath(kind: .directory, initialPath: settings.mavenHome) {
                    settings.mavenHome = path
                }
            }
        }
        GridRow {
            Color.clear
                .frame(width: 130, height: 1)
            mavenHomeValidationLabel
            Color.clear
                .frame(width: 1, height: 1)
        }
    }

    @ViewBuilder
    private var javaHomeConfigurationRows: some View {
        GridRow {
            Text("JDK Home")
                .frame(width: 130, alignment: .trailing)
            TextField("/path/to/jdk", text: $settings.javaHome)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
            Button("选择…") {
                if let path = choosePath(kind: .directory, initialPath: settings.javaHome) {
                    settings.javaHome = path
                }
            }
        }
        GridRow {
            Color.clear
                .frame(width: 130, height: 1)
            javaHomeValidationLabel
            Color.clear
                .frame(width: 1, height: 1)
        }
    }

    @ViewBuilder
    private var mavenHomeValidationLabel: some View {
        if isValidatingMavenHome {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在校验 Maven 路径…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch mavenHomeValidation {
            case .unconfigured:
                Label("未配置 Maven Home", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            case .valid(let version):
                Label(version, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .invalid(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var javaHomeValidationLabel: some View {
        if isValidatingJavaHome {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在校验 JDK 路径…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch javaHomeValidation {
            case .unconfigured:
                Label("未配置 JDK Home", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            case .valid(let version):
                Label(version, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .invalid(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func configurationRow(
        title: String,
        value: Binding<String>,
        prompt: String,
        picker: MavenPathPickerKind,
        validation: MavenPathValidationResult
    ) -> some View {
        Group {
            GridRow {
                Text(title)
                    .frame(width: 130, alignment: .trailing)
                TextField(prompt, text: value)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280)
                Button("选择…") {
                    if let path = choosePath(kind: picker, initialPath: value.wrappedValue) {
                        value.wrappedValue = path
                    }
                }
            }
            GridRow {
                Color.clear.frame(width: 130, height: 1)
                pathValidationLabel(validation)
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private func repositoryContent(repositoryURL: URL) -> some View {
        HSplitView {
            VSplitView {
                modulePane(repositoryURL: repositoryURL)
                    .frame(minHeight: 220)
                recentRunsPane(repositoryURL: repositoryURL)
                    .frame(minHeight: 150, idealHeight: 210)
            }
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
            outputPane
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func recentRunsPane(repositoryURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("最近运行")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(repositoryRuns(repositoryURL).count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()

                Button("重新运行", systemImage: "arrow.clockwise") {
                    rerunSelectedRecord(repositoryURL: repositoryURL)
                }
                .labelStyle(.iconOnly)
                .help(recentRerunHelp)
                .disabled(
                    selectedRunRecord == nil
                        || selectedRecordModule == nil
                        || isScanning
                        || execution.runningRequestID != nil
                )

                Button("删除记录", systemImage: "trash", role: .destructive) {
                    removeSelectedRun()
                }
                .labelStyle(.iconOnly)
                .help("删除记录")
                .disabled(selectedRunRecord == nil)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(repositoryRuns(repositoryURL)) { record in
                        recentRunRow(record, repositoryURL: repositoryURL)
                    }
                }
                .padding(5)
            }
            .overlay {
                if repositoryRuns(repositoryURL).isEmpty {
                    Label("暂无运行记录", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func recentRunRow(_ record: MavenRunRecord, repositoryURL: URL) -> some View {
        let module = module(for: record)
        return HStack(spacing: 7) {
            Image(systemName: runStatusSymbol(record))
                .foregroundStyle(runStatusColor(record))
                .frame(width: 14)
                .accessibilityLabel(runStatusTitle(record))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(record.moduleName)
                        .lineLimit(1)
                    Text(record.goal.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 7) {
                    Text(runStatusTitle(record))
                        .foregroundStyle(runStatusColor(record))
                    Text(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("\(record.duration.formatted(.number.precision(.fractionLength(2))))s")
                    if module == nil, !isScanning {
                        Label("模块已不存在", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .background(
            selectedRunID == record.id ? Color.accentColor.opacity(0.15) : .clear,
            in: .rect(cornerRadius: 4)
        )
        .onTapGesture {
            selectRecentRun(record.id)
        }
        .contextMenu {
            Button("重新运行", systemImage: "arrow.clockwise") {
                selectRecentRun(record.id)
                rerunRecord(record, repositoryURL: repositoryURL)
            }
            .disabled(module == nil || isScanning || execution.runningRequestID != nil)

            Button("删除记录", systemImage: "trash", role: .destructive) {
                removeRun(record.id)
                if selectedRunID == record.id {
                    selectedRunID = nil
                    updatePersistedSelection(nil)
                }
            }
        }
    }

    private func modulePane(repositoryURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repositoryURL.lastPathComponent)
                        .fontWeight(.semibold)
                    Text("Maven 项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let scanErrorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(scanErrorMessage)
                }
                if isScanning { ProgressView().controlSize(.small) }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let rootModule = project?.rootModule {
                        moduleRow(rootModule, depth: 0, repositoryURL: repositoryURL)
                    }
                }
                .padding(8)
            }
            .overlay {
                if !isScanning, project == nil {
                    ContentUnavailableView(
                        scanErrorMessage == nil ? "没有 Maven 项目" : "无法加载 Maven 项目",
                        systemImage: "shippingbox",
                        description: Text(scanErrorMessage ?? "当前 Repository 根目录没有 pom.xml。")
                    )
                }
            }
        }
    }

    private func moduleRow(_ module: MavenModule, depth: Int, repositoryURL: URL) -> AnyView {
        AnyView(DisclosureGroup(
            isExpanded: Binding(
                get: { expandedModuleIDs.contains(module.id) },
                set: { isExpanded in
                    if isExpanded { expandedModuleIDs.insert(module.id) }
                    else { expandedModuleIDs.remove(module.id) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(MavenLifecycleGoal.allCases) { goal in
                            lifecycleRow(goal, module: module, repositoryURL: repositoryURL)
                        }
                    }
                    .padding(.leading, 8)
                } label: {
                    Label("Lifecycle", systemImage: "list.bullet.rectangle")
                        .padding(.vertical, 3)
                }
                .padding(.leading, 8)

                ForEach(module.children) { child in
                    moduleRow(child, depth: depth + 1, repositoryURL: repositoryURL)
                        .padding(.leading, 8)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: module.packaging == "pom" ? "shippingbox.fill" : "shippingbox")
                    .foregroundStyle(module.hasPOM ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(module.displayName)
                        .lineLimit(1)
                    if module.modulePath != "." {
                        Text(module.modulePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !module.hasPOM {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("模块目录中没有 pom.xml")
                }
            }
            .padding(.vertical, 3)
        }
        .onAppear {
            if depth == 0 { expandedModuleIDs.insert(module.id) }
        }
        )
    }

    private func lifecycleRow(
        _ goal: MavenLifecycleGoal,
        module: MavenModule,
        repositoryURL: URL
    ) -> some View {
        let target = MavenRunTarget(module: module, goal: goal)
        return HStack(spacing: 7) {
            Image(systemName: execution.runningRequestID == target.id ? "progress.indicator" : "diamond.fill")
                .font(.system(size: 7))
                .foregroundStyle(goal == .deploy ? .orange : .secondary)
                .frame(width: 12)
            Text(goal.rawValue)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .background(
            selectedTarget == target ? Color.accentColor.opacity(0.15) : .clear,
            in: .rect(cornerRadius: 4)
        )
        .onTapGesture(count: 2) {
            selectTarget(target)
            runTarget(target, repositoryURL: repositoryURL)
        }
        .onTapGesture {
            selectTarget(target)
        }
        .contextMenu {
            Button("运行 \(goal.rawValue)", systemImage: "play.fill") {
                selectTarget(target)
                runTarget(target, repositoryURL: repositoryURL)
            }
            .disabled(!module.hasPOM || execution.runningRequestID != nil)
        }
        .opacity(module.hasPOM ? 1 : 0.5)
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            commandPreviewPane

            Divider()

            HStack {
                Text("运行输出")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = displayedTerminationStatus {
                    Text(status == 0 ? "完成" : "失败（退出码 \(status)）")
                        .font(.caption)
                        .foregroundStyle(status == 0 ? .green : .red)
                } else if selectedRunRecord != nil {
                    Text("异常结束")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let finishedAt = displayedFinishedAt {
                    Text(finishedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let duration = displayedDuration {
                    Text("\(duration.formatted(.number.precision(.fractionLength(2))))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button("清除当前输出", systemImage: "trash.slash", action: clearLog)
                    .labelStyle(.iconOnly)
                    .help("清除当前输出")
                    .disabled(selectedRunRecord != nil || execution.log.isEmpty)

                Button("复制", systemImage: "doc.on.doc") { copy(displayedLog) }
                    .labelStyle(.iconOnly)
                    .help("复制输出")
                    .disabled(displayedLog.isEmpty)
            }
            .padding(8)

            Divider()

            StreamingOutputView(
                text: displayedLog,
                emptyMessage: outputEmptyMessage,
                emptyMessageColor: execution.errorMessage == nil || selectedRunRecord != nil
                    ? .secondary
                    : .red,
                enablesTailFollowing: selectedRunRecord == nil,
                contentIdentity: displayedLogIdentity,
                followsTail: $followsLatestOutput
            )
        }
    }

    private var commandPreviewPane: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("最终命令")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let previewTitle {
                    Text(previewTitle)
                        .font(.caption)
                        .lineLimit(1)
                }
                Spacer()
                Button("复制命令", systemImage: "doc.on.doc") {
                    if let command = selectedPreviewCommand {
                        copy(displayCommand(command))
                    }
                }
                .labelStyle(.iconOnly)
                .help("复制最终命令")
                .disabled(selectedPreviewCommand == nil)
            }

            if let command = selectedPreviewCommand {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    commandDetailRow("可执行文件", value: command.executableURL.path)
                    commandDetailRow("参数", value: displayArguments(command.arguments))
                    commandDetailRow("工作目录", value: command.workingDirectoryURL.path)
                    commandDetailRow(
                        "环境",
                        value: command.environment["JAVA_HOME"].map { "JAVA_HOME=\($0)" } ?? "继承系统环境"
                    )
                }

                if let warning = wrapperWarningMessage {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let message = previewValidationMessage {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            } else {
                Text("选择左侧 Lifecycle 后显示命令。")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 138, maxHeight: 178, alignment: .topLeading)
    }

    private func commandDetailRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            ScrollView(.horizontal) {
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func loadProject() async {
        guard let repositoryURL else {
            isScanning = false
            project = nil
            scanErrorMessage = nil
            return
        }
        isScanning = true
        scanErrorMessage = nil
        let previousTarget = selectedTarget
        let standardizedURL = repositoryURL.standardizedFileURL
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                return MavenScanOutcome.success(
                    try MavenProjectScanner().scan(repositoryURL: standardizedURL)
                )
            } catch {
                return MavenScanOutcome.failure(error.localizedDescription)
            }
        }.value
        guard !Task.isCancelled,
              self.repositoryURL?.standardizedFileURL == standardizedURL else { return }
        isScanning = false
        switch outcome {
        case .success(let loadedProject):
            project = loadedProject
            expandedModuleIDs = [loadedProject.rootModule.id]
            if let previousTarget,
               let refreshedModule = module(
                   at: previousTarget.module.modulePath,
                   in: loadedProject.rootModule
               ) {
                selectedTarget = MavenRunTarget(module: refreshedModule, goal: previousTarget.goal)
            } else {
                selectedTarget = nil
            }
            restorePersistedSelectionIfPossible()
        case .failure(let message):
            scanErrorMessage = message
        }
    }

    private var projectScanTaskID: String {
        "\(repositoryURL?.standardizedFileURL.path ?? "workspace")\u{0}\(projectRevision)"
    }

    private var mavenHomeValidationTaskID: String {
        "\(repositoryURL?.standardizedFileURL.path ?? "workspace")\u{0}\(settings.mavenHome)"
    }

    private var javaHomeValidationTaskID: String {
        "\(repositoryURL?.standardizedFileURL.path ?? "workspace")\u{0}\(settings.javaHome)"
    }

    private var mavenHomeValidation: MavenHomeValidationResult {
        validationStore.mavenResult(workspaceURL: workspaceURL, home: settings.mavenHome)
    }

    private var isValidatingMavenHome: Bool {
        validationStore.isValidatingMavenHome(workspaceURL: workspaceURL, home: settings.mavenHome)
    }

    private var javaHomeValidation: JavaHomeValidationResult {
        validationStore.javaResult(workspaceURL: workspaceURL, home: settings.javaHome)
    }

    private var isValidatingJavaHome: Bool {
        validationStore.isValidatingJavaHome(workspaceURL: workspaceURL, home: settings.javaHome)
    }

    private func runSelectedTarget() {
        guard let selectedTarget, let repositoryURL else { return }
        runTarget(selectedTarget, repositoryURL: repositoryURL)
    }

    private func runTarget(_ target: MavenRunTarget, repositoryURL: URL) {
        guard target.module.hasPOM, execution.runningRequestID == nil else { return }
        let request = makeRunRequest(target, repositoryURL: repositoryURL)
        submitRunRequest(request)
    }

    private func submitRunRequest(_ request: MavenRunRequest) {
        runValidationMessage = validationError(for: request)
        activePreviewRequest = request
        guard runValidationMessage == nil else { return }
        selectedRunID = nil
        updatePersistedSelection(.target(modulePath: request.module.modulePath, goal: request.goal))
        followsLatestOutput = true
        if request.requiresConfirmation {
            pendingConfirmation = request
        } else {
            run(request)
        }
    }

    private var selectedRunRequest: MavenRunRequest? {
        guard let selectedTarget, let repositoryURL else { return nil }
        return makeRunRequest(selectedTarget, repositoryURL: repositoryURL)
    }

    private var selectedPreviewCommand: MavenCommand? {
        activePreviewRequest?.command ?? selectedRunRequest?.command ?? selectedRunRecord?.command
    }

    private var previewTitle: String? {
        if let request = activePreviewRequest {
            return "\(request.module.displayName) · \(request.goal.rawValue)"
        }
        if let target = selectedTarget {
            return "\(target.module.displayName) · \(target.goal.rawValue)"
        }
        if let record = selectedRunRecord {
            return "\(record.moduleName) · \(record.goal.rawValue)"
        }
        return nil
    }

    private var selectedRunRecord: MavenRunRecord? {
        guard let selectedRunID, let repositoryURL else { return nil }
        return repositoryRuns(repositoryURL).first { $0.id == selectedRunID }
    }

    private var selectedRecordModule: MavenModule? {
        selectedRunRecord.flatMap(module(for:))
    }

    private var recentRerunHelp: String {
        if isScanning { return "正在同步 Maven 项目" }
        return selectedRecordModule == nil ? "模块已不存在，无法重新运行" : "重新运行"
    }

    private var displayedLog: String {
        selectedRunRecord?.log ?? (selectedRunRecord == nil ? execution.log : "")
    }

    private var displayedLogIdentity: String {
        if let selectedRunRecord {
            return "history:\(selectedRunRecord.id)"
        }
        if let runningRequestID = execution.runningRequestID {
            return "live:\(runningRequestID)"
        }
        return "live:idle"
    }

    private var displayedTerminationStatus: Int32? {
        selectedRunRecord?.terminationStatus ?? (selectedRunRecord == nil ? execution.terminationStatus : nil)
    }

    private var displayedFinishedAt: Date? {
        selectedRunRecord?.finishedAt ?? (selectedRunRecord == nil ? execution.finishedAt : nil)
    }

    private var displayedDuration: TimeInterval? {
        selectedRunRecord?.duration ?? (selectedRunRecord == nil ? execution.duration : nil)
    }

    private var outputEmptyMessage: String {
        if let record = selectedRunRecord {
            return record.log == nil ? "该运行记录未保存日志。" : "该次运行没有输出。"
        }
        return execution.errorMessage ?? "双击 Lifecycle，或选中后点击工具栏运行。"
    }

    private func repositoryRuns(_ repositoryURL: URL) -> [MavenRunRecord] {
        let repositoryPath = repositoryURL.standardizedFileURL.path
        return recentRuns.filter { $0.repositoryPath == repositoryPath }
    }

    private func module(for record: MavenRunRecord) -> MavenModule? {
        guard let rootModule = project?.rootModule else { return nil }
        return module(at: record.modulePath, in: rootModule)
    }

    private func module(at modulePath: String, in module: MavenModule) -> MavenModule? {
        if module.modulePath == modulePath { return module }
        for child in module.children {
            if let match = self.module(at: modulePath, in: child) { return match }
        }
        return nil
    }

    private func rerunSelectedRecord(repositoryURL: URL) {
        guard let record = selectedRunRecord else { return }
        rerunRecord(record, repositoryURL: repositoryURL)
    }

    private func rerunRecord(_ record: MavenRunRecord, repositoryURL: URL) {
        guard execution.runningRequestID == nil, let module = module(for: record) else { return }
        guard let request = record.makeRunRequest(module: module) else { return }
        selectedTarget = nil
        submitRunRequest(request)
    }

    private func removeSelectedRun() {
        guard let id = selectedRunRecord?.id else { return }
        removeRun(id)
        selectedRunID = nil
        updatePersistedSelection(nil)
    }

    private func selectTarget(_ target: MavenRunTarget) {
        selectedTarget = target
        selectedRunID = nil
        activePreviewRequest = nil
        runValidationMessage = nil
        followsLatestOutput = true
        updatePersistedSelection(.target(modulePath: target.module.modulePath, goal: target.goal))
    }

    private func selectRecentRun(_ id: MavenRunRecord.ID) {
        selectedRunID = id
        selectedTarget = nil
        activePreviewRequest = nil
        runValidationMessage = nil
        followsLatestOutput = true
        updatePersistedSelection(.recentRun(id))
    }

    private func restorePersistedSelectionIfPossible() {
        guard let persistedSelection else { return }
        if let runID = persistedSelection.recentRunID,
           let repositoryURL,
           repositoryRuns(repositoryURL).contains(where: { $0.id == runID }) {
            selectedRunID = runID
            selectedTarget = nil
            return
        }
        guard let modulePath = persistedSelection.modulePath,
              let goal = persistedSelection.goal,
              let rootModule = project?.rootModule,
              let module = module(at: modulePath, in: rootModule) else { return }
        selectedTarget = MavenRunTarget(module: module, goal: goal)
        selectedRunID = nil
        expandedModuleIDs.formUnion(expandedModulePaths(to: modulePath))
    }

    private func expandedModulePaths(to modulePath: String) -> Set<MavenModule.ID> {
        guard modulePath != "." else { return ["."] }
        var paths: Set<String> = ["."]
        var components: [Substring] = []
        for component in modulePath.split(separator: "/") {
            components.append(component)
            paths.insert(components.joined(separator: "/"))
        }
        return paths
    }

    private func runStatusSymbol(_ record: MavenRunRecord) -> String {
        switch record.terminationStatus {
        case 0: "checkmark.circle.fill"
        case .some: "xmark.circle.fill"
        case nil: "exclamationmark.circle.fill"
        }
    }

    private func runStatusColor(_ record: MavenRunRecord) -> Color {
        switch record.terminationStatus {
        case 0: .green
        case .some: .red
        case nil: .orange
        }
    }

    private func runStatusTitle(_ record: MavenRunRecord) -> String {
        switch record.terminationStatus {
        case 0: "成功"
        case .some(let status): "失败 \(status)"
        case nil: "异常"
        }
    }

    private var wrapperWarningMessage: String? {
        guard let repositoryURL else { return nil }
        let wrapperURL = repositoryURL.appendingPathComponent("mvnw", isDirectory: false)
        guard FileManager.default.fileExists(atPath: wrapperURL.path),
              !FileManager.default.isExecutableFile(atPath: wrapperURL.path) else { return nil }
        return "检测到 mvnw，但文件不可执行；当前命令将使用其他 Maven executable。"
    }

    private var previewValidationMessage: String? {
        runValidationMessage ?? selectedPreviewCommand.flatMap(validationError(for:))
    }

    private func validationError(for request: MavenRunRequest) -> String? {
        validationError(for: request.command)
    }

    private func validationError(for command: MavenCommand) -> String? {
        let fileManager = FileManager.default

        let mavenHome = expandedPath(settings.mavenHome)
        if !mavenHome.isEmpty {
            let executable = URL(fileURLWithPath: mavenHome, isDirectory: true)
                .appendingPathComponent("bin/mvn", isDirectory: false)
            if !fileManager.isExecutableFile(atPath: executable.path) {
                return "Maven Home 无效：未找到可执行文件 bin/mvn。"
            }
        }

        let configuredJavaHome = expandedPath(settings.javaHome)
        if !configuredJavaHome.isEmpty,
           !fileManager.isExecutableFile(
               atPath: URL(fileURLWithPath: configuredJavaHome, isDirectory: true)
                   .appendingPathComponent("bin/java", isDirectory: false).path
           ) {
            return "JDK Home 无效：未找到可执行文件 bin/java。"
        }

        if case .invalid(let message) = pathValidation(
            path: settings.userSettingsFile,
            kind: .userSettingsFile
        ) {
            return "User settings file 无效：\(message)"
        }
        if case .invalid(let message) = pathValidation(
            path: settings.localRepository,
            kind: .localRepository
        ) {
            return "Local repository 无效：\(message)"
        }

        if let commandJavaHome = command.environment["JAVA_HOME"],
           !commandJavaHome.isEmpty,
           !fileManager.isExecutableFile(
               atPath: URL(fileURLWithPath: commandJavaHome, isDirectory: true)
                   .appendingPathComponent("bin/java", isDirectory: false).path
           ) {
            return "最终命令的 JAVA_HOME 无效：未找到可执行文件 bin/java。"
        }
        guard fileManager.isExecutableFile(atPath: command.executableURL.path) else {
            return "最终 Maven executable 不可执行：\(command.executableURL.path)"
        }
        if command.executableURL.path == "/usr/bin/env",
           command.arguments.first == "mvn",
           !executableExistsInPath("mvn", environment: command.environment) {
            return "未在 PATH 中找到 Maven executable；请配置 Maven Home 或可执行的 mvnw。"
        }
        guard fileManager.fileExists(atPath: command.workingDirectoryURL.path) else {
            return "工作目录不存在：\(command.workingDirectoryURL.path)"
        }
        return nil
    }

    private func expandedPath(_ path: String) -> String {
        NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
    }

    private func executableExistsInPath(_ name: String, environment: [String: String]) -> Bool {
        let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false).path
            )
        }
    }

    private func formattedByteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }

    private func makeRunRequest(_ target: MavenRunTarget, repositoryURL: URL) -> MavenRunRequest {
        MavenRunRequest(
            module: target.module,
            goal: target.goal,
            command: MavenCommandBuilder.makeCommand(
                repositoryURL: repositoryURL,
                module: target.module,
                goal: target.goal,
                settings: settings
            )
        )
    }

    private func pathValidation(path: String, kind: MavenPathKind) -> MavenPathValidationResult {
        MavenPathValidator().validate(path: path, kind: kind)
    }

    @ViewBuilder
    private func pathValidationLabel(_ validation: MavenPathValidationResult) -> some View {
        switch validation {
        case .unconfigured:
            Label("未配置", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .valid:
            Label("路径有效", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func synchronizeParameterDrafts() {
        profilesDraft = settings.activeProfiles.joined(separator: ",")
        additionalArgumentsDraft = settings.additionalArguments.joined(separator: "\n")
    }

    private func parsedProfiles(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map {
                let profile = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return profile.hasPrefix("-P") ? String(profile.dropFirst(2)) : profile
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var profilesIncludeFlagPrefix: Bool {
        profilesDraft
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-P") }
    }

    private func parsedAdditionalArguments(_ value: String) -> [String] {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func displayCommand(_ command: MavenCommand) -> String {
        command.displayComponents.map(shellQuoted).joined(separator: " ")
    }

    private func displayArguments(_ arguments: [String]) -> String {
        "[" + arguments.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ") + "]"
    }

    private func shellQuoted(_ component: String) -> String {
        guard !component.isEmpty else { return "''" }
        let safeCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_@%+=:,./-"))
        guard !component.unicodeScalars.allSatisfy(safeCharacters.contains) else {
            return component
        }
        return "'\(component.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func choosePath(kind: MavenPathPickerKind, initialPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .directory
        panel.canChooseFiles = kind == .file
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = kind == .directory
        let expandedPath = NSString(string: initialPath).expandingTildeInPath
        if !expandedPath.isEmpty {
            let initialURL = URL(fileURLWithPath: expandedPath, isDirectory: kind == .directory)
            panel.directoryURL = kind == .directory ? initialURL : initialURL.deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private enum MavenPathPickerKind {
    case file
    case directory
}

private enum MavenLogCapacity: Int, CaseIterable, Identifiable {
    case kilobytes64 = 65_536
    case kilobytes256 = 262_144
    case kilobytes512 = 524_288
    case megabyte1 = 1_048_576
    case megabytes2 = 2_097_152
    case megabytes5 = 5_242_880
    case megabytes10 = 10_485_760

    var id: Int { rawValue }
    var bytes: Int { rawValue }

    var title: String {
        switch self {
        case .kilobytes64: "64 KB"
        case .kilobytes256: "256 KB"
        case .kilobytes512: "512 KB"
        case .megabyte1: "1 MB"
        case .megabytes2: "2 MB"
        case .megabytes5: "5 MB"
        case .megabytes10: "10 MB"
        }
    }
}

private struct MavenRunTarget: Equatable {
    let module: MavenModule
    let goal: MavenLifecycleGoal

    var id: String { "\(module.id):\(goal.id)" }
}

private enum MavenScanOutcome: Sendable {
    case success(MavenProject)
    case failure(String)
}

// Kept temporarily so the existing root can compile while navigation switches from Tasks to Maven.
@MainActor
struct TasksView: View {
    @Bindable var appState: AppState

    var body: some View {
        if let workspace = appState.workspace {
            MavenView(
                workspaceURL: URL(fileURLWithPath: workspace.path, isDirectory: true),
                repositoryURL: selectedRepositoryURL,
                settings: Binding(
                    get: { appState.mavenSettings },
                    set: appState.updateMavenSettings
                ),
                projectRevision: appState.mavenProjectRevision(for: selectedRepositoryURL),
                validationStore: appState.mavenEnvironmentValidationStore,
                execution: appState.mavenExecution,
                recentRuns: appState.recentMavenRuns,
                run: appState.runMaven,
                stop: appState.stopMaven,
                clearLog: appState.clearMavenLog,
                removeRun: appState.removeMavenRun,
                clearPersistedLogs: appState.clearPersistedMavenLogs,
                clearHistory: appState.clearMavenRunHistory,
                persistedSelection: selectedRepositoryID.flatMap {
                    appState.mavenSelection(for: $0)
                },
                updatePersistedSelection: { selection in
                    guard let repositoryID = selectedRepositoryID else { return }
                    appState.updateMavenSelection(selection, for: repositoryID)
                }
            )
        } else {
            ContentUnavailableView("没有工作区", systemImage: "folder")
        }
    }

    private var selectedRepositoryURL: URL? {
        guard appState.isRepositoryContext,
              let workspace = appState.workspace,
              let repository = appState.selectedRepository else { return nil }
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        return repository.relativePath == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
    }

    private var selectedRepositoryID: RegisteredRepository.ID? {
        appState.isRepositoryContext ? appState.selectedRepositoryID : nil
    }
}
