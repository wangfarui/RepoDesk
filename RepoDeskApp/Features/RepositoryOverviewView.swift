import SwiftUI

struct RepositoryOverviewView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                spacing: 12
            ) {
                ForEach(appState.repositories) { repository in
                    RepositoryOverviewCard(
                        repository: repository,
                        snapshot: appState.repositorySnapshots[repository.id],
                        errorMessage: appState.repositorySnapshotErrors[repository.id],
                        unavailableMessage: appState.repositoryUnavailableMessage(for: repository),
                        isRefreshing: appState.refreshingRepositoryIDs.contains(repository.id),
                        isSelected: repository.id == appState.selectedRepositoryID,
                        select: { appState.selectRepositoryContext(repository.id) },
                        relocate: { appState.relocateRepository(repository.id) }
                    )
                }
            }
            .padding(20)
        }
        .overlay {
            if appState.repositories.isEmpty {
                ContentUnavailableView {
                    Label("尚未发现 Git 仓库", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("扫描工作区后，会在这里展示其中的 Git 仓库。")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("发现 Repository", systemImage: "magnifyingglass") {
                    appState.discoverRepositories()
                }
                .disabled(appState.isDiscoveringRepositories || appState.workspace?.isAvailable != true)
                .help("扫描当前工作区中的 Git 仓库")
            }
        }
    }
}

private struct RepositoryOverviewCard: View {
    let repository: RegisteredRepository
    let snapshot: GitRepositorySnapshot?
    let errorMessage: String?
    let unavailableMessage: String?
    let isRefreshing: Bool
    let isSelected: Bool
    let select: () -> Void
    let relocate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repository.name)
                            .fontWeight(.semibold)
                        Text(repository.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else if repository.isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.secondary)
                    }
                }

                if let snapshot {
                    HStack(spacing: 12) {
                        Label(
                            snapshot.isDetachedHEAD ? "Detached HEAD" : snapshot.branch,
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                        if snapshot.aheadCount > 0 {
                            Label("\(snapshot.aheadCount)", systemImage: "arrow.up")
                        }
                        if snapshot.behindCount > 0 {
                            Label("\(snapshot.behindCount)", systemImage: "arrow.down")
                        }
                    }

                    HStack(spacing: 14) {
                        ChangeMetric(value: snapshot.trackedChangeCount, label: "Changes")
                        ChangeMetric(value: snapshot.unversionedFileCount, label: "Unversioned Files")
                    }

                    if let commit = snapshot.lastCommit {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.subject)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(commit.author)
                                if let date = commit.authoredAt {
                                    Text(date, format: .relative(presentation: .named))
                                }
                                Text(String(commit.hash.prefix(8)))
                                    .monospaced()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else if let unavailableMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(unavailableMessage, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                        Button("重新定位 Repository…", systemImage: "folder.badge.questionmark") {
                            relocate()
                        }
                        .buttonStyle(.bordered)
                    }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                } else {
                    Text("正在等待 Git 状态…")
                        .foregroundStyle(.secondary)
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 185, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
    }
}

private struct ChangeMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
