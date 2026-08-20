import SwiftUI

@MainActor
struct BranchComparisonSheet: View {
    let comparison: GitBranchComparison
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare Branches").font(.headline)
                    Text("\(comparison.comparedBranch) with \(comparison.baseBranch)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
            }
            .padding()
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Commits").font(.caption.weight(.semibold)).padding(10)
                    Divider()
                    List(comparison.commits) { commit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.subject).lineLimit(2)
                            Text("\(commit.author)  \(commit.hash.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .overlay {
                        if comparison.commits.isEmpty { ContentUnavailableView("没有仅存在于该分支的 Commit", systemImage: "checkmark") }
                    }
                }
                .frame(minWidth: 260)
                VStack(alignment: .leading, spacing: 0) {
                    Text("File Diff").font(.caption.weight(.semibold)).padding(10)
                    Divider()
                    ScrollView([.vertical, .horizontal]) {
                        Text(comparison.diffText.isEmpty ? "没有文件差异" : comparison.diffText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(minWidth: 520)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

@MainActor
struct MergeConflictResolverSheet: View {
    @Bindable var appState: AppState
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resolve Merge Conflicts").font(.headline)
                    Text(appState.mergeSourceBranch.map { "Merge '\($0)' into current branch" } ?? "Merge conflict")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(resolvedCount)/\(appState.conflictFiles.count) resolved")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            HSplitView {
                List(appState.conflictFiles.indices, id: \.self, selection: $selection) { index in
                    Label(appState.conflictFiles[index].path, systemImage: appState.conflictFiles[index].isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .tag(index)
                }
                .frame(minWidth: 220, idealWidth: 260)
                if appState.conflictFiles.indices.contains(selection) {
                    conflictEditor(index: selection)
                }
            }
            Divider()
            HStack {
                Button("Abort Merge", systemImage: "xmark.circle", role: .destructive) {
                    Task { await appState.abortMerge() }
                }
                Spacer()
                Button("Previous", systemImage: "chevron.left") { selection = max(0, selection - 1) }
                    .disabled(selection == 0)
                Button("Next", systemImage: "chevron.right") { selection = min(appState.conflictFiles.count - 1, selection + 1) }
                    .disabled(selection >= appState.conflictFiles.count - 1)
                Button("Continue Merge", systemImage: "checkmark.circle") {
                    Task { await appState.continueMerge() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolvedCount != appState.conflictFiles.count)
            }
            .padding()
        }
        .frame(minWidth: 1100, minHeight: 650)
    }

    private func conflictEditor(index: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("Accept Left", systemImage: "arrow.right") { appState.conflictFiles[index].result = appState.conflictFiles[index].ours }
                Button("Accept Right", systemImage: "arrow.left") { appState.conflictFiles[index].result = appState.conflictFiles[index].theirs }
                Spacer()
                Button(appState.conflictFiles[index].isResolved ? "Resolved" : "Mark Resolved", systemImage: "checkmark") {
                    Task { await appState.resolveConflict(at: index) }
                }
                .disabled(appState.conflictFiles[index].isResolved)
            }
            .padding(8)
            Divider()
            if !GitConflictParser.blocks(in: appState.conflictFiles[index].result).isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(GitConflictParser.blocks(in: appState.conflictFiles[index].result)) { block in
                            HStack(spacing: 4) {
                                Text("Conflict \(block.index + 1)").font(.caption)
                                Button("Left") { appState.acceptConflictBlock(fileIndex: index, blockIndex: block.index, side: .ours) }
                                    .buttonStyle(.bordered)
                                Button("Right") { appState.acceptConflictBlock(fileIndex: index, blockIndex: block.index, side: .theirs) }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.leading, 8)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Divider()
            }
            HSplitView {
                conflictPane(title: "Current Branch", text: appState.conflictFiles[index].ours)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Merge Result").font(.caption.weight(.semibold)).padding(8)
                    Divider()
                    TextEditor(text: $appState.conflictFiles[index].result)
                        .font(.system(.body, design: .monospaced))
                }
                conflictPane(title: appState.mergeSourceBranch ?? "Incoming Branch", text: appState.conflictFiles[index].theirs)
            }
        }
    }

    private func conflictPane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).padding(8)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var resolvedCount: Int { appState.conflictFiles.filter(\.isResolved).count }
}
