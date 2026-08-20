import AppKit

@MainActor
protocol WorkspacePicking {
    func chooseWorkspace() -> URL?
}

@MainActor
struct SystemWorkspacePicker: WorkspacePicking {
    func chooseWorkspace() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Workspace"
        panel.message = "Choose the directory RepoDesk should manage."
        panel.prompt = "Open Workspace"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
