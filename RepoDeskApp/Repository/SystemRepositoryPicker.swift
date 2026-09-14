import AppKit

@MainActor
protocol RepositoryPicking {
    func chooseRepository(in workspaceURL: URL, purpose: RepositoryPickerPurpose) -> URL?
}

enum RepositoryPickerPurpose {
    case register
    case relocate(String)
    case ignoreForDiscovery
}

@MainActor
struct SystemRepositoryPicker: RepositoryPicking {
    func chooseRepository(in workspaceURL: URL, purpose: RepositoryPickerPurpose) -> URL? {
        let panel = NSOpenPanel()
        switch purpose {
        case .register:
            panel.title = "Register Repository"
            panel.message = "Choose a Git repository inside the current workspace."
            panel.prompt = "Register"
        case .relocate(let name):
            panel.title = "Relocate \(name)"
            panel.message = "Choose the repository's new location inside the current workspace."
            panel.prompt = "Relocate"
        case .ignoreForDiscovery:
            panel.title = "Ignore Directory"
            panel.message = "Choose a directory to skip when discovering Git repositories."
            panel.prompt = "Ignore"
        }
        panel.directoryURL = workspaceURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
