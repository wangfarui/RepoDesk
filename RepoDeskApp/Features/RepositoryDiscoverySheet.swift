import SwiftUI

struct RepositoryDiscoverySheet: View {
    let repositories: [RegisteredRepository]
    let register: ([RegisteredRepository]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<RegisteredRepository.ID>

    init(
        repositories: [RegisteredRepository],
        register: @escaping ([RegisteredRepository]) -> Void
    ) {
        self.repositories = repositories
        self.register = register
        _selectedIDs = State(initialValue: Set(repositories.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发现的 Repository")
                    .font(.title2.weight(.semibold))
                Text(description)
                    .foregroundStyle(.secondary)
            }

            if repositories.isEmpty {
                ContentUnavailableView(
                    "没有新的 Repository",
                    systemImage: "checkmark.circle",
                    description: Text("发现的 Repository 均已注册，或扫描未找到 Repository。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(repositories) { repository in
                            Toggle(isOn: selectionBinding(for: repository.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repository.name)
                                    Text(repository.relativePath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("注册所选项") {
                    register(repositories.filter { selectedIDs.contains($0.id) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private var description: String {
        repositories.isEmpty
            ? "扫描完成，没有可添加的 Repository。"
            : "选择要注册到当前 Workspace 的 Repository。"
    }

    private func selectionBinding(for id: RegisteredRepository.ID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
        )
    }
}
