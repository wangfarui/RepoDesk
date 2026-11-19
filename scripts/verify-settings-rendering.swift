import AppKit
import SwiftUI
@testable import RepoDesk

private struct SettingsRenderingError: Error {
    let message: String
}

@main
@MainActor
enum VerifySettingsRendering {
    static func main() throws {
        let suiteName = "RepoDeskSettingsRendering.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SettingsRenderingError(message: "Could not create isolated UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceURL = URL(
            fileURLWithPath: "/Users/you/workspaces/example-workspace",
            isDirectory: true
        ).appendingPathComponent(
            "examples/超长工作区路径/agent-generated-repositories/backend-platform-and-tooling",
            isDirectory: true
        )
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            appPreferencesStore: UserDefaultsAppPreferencesStore(defaults: defaults),
            restoresWorkspaceOnLaunch: false
        )
        state.setShowsHiddenFiles(true)
        state.setOpensMarkdownInPreview(true)
        state.setDiffPresentation(.sideBySide)
        state.setIgnoresWhitespaceInDiff(true)

        try render(tab: .general, state: state, name: "settings-general.png")
        try render(tab: .appearance, state: state, name: "settings-appearance.png")
        try render(tab: .files, state: state, name: "settings-files.png")
        try render(tab: .git, state: state, name: "settings-git.png")
        try render(
            tab: .git,
            state: state,
            name: "settings-git-compact.png",
            size: NSSize(width: 760, height: 600)
        )
        state.setChangesAutoExpansionMode(.always)
        try render(tab: .git, state: state, name: "settings-git-always.png")
        state.setChangesAutoExpansionMode(.never)
        try render(tab: .git, state: state, name: "settings-git-never.png")
        state.resetChangesAutoExpansion()
        try render(tab: .java, state: state, name: "settings-java.png")
        try render(tab: .maven, state: state, name: "settings-maven.png")
        try render(
            tab: .general,
            state: state,
            name: "settings-general-compact.png",
            size: NSSize(width: 760, height: 600)
        )
        try render(
            tab: .general,
            state: state,
            name: "settings-general-wide-dark.png",
            size: NSSize(width: 980, height: 720),
            appearance: .darkAqua,
            colorScheme: .dark
        )
        print("Settings rendering verification passed")
    }

    private static func render(
        tab: RepoDeskSettingsTab,
        state: AppState,
        name: String,
        size: NSSize = NSSize(width: 840, height: 660),
        appearance: NSAppearance.Name = .aqua,
        colorScheme: ColorScheme = .light
    ) throws {
        _ = NSApplication.shared
        let rootView = RepoDeskSettingsView(appState: state, initialTab: tab)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = NSAppearance(named: appearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.appearance = NSAppearance(named: appearance)
        window.alphaValue = 0.01
        window.orderFront(nil)
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        guard hostingView.fittingSize.width <= max(size.width, 980),
              hostingView.fittingSize.height <= max(size.height, 720) else {
            throw SettingsRenderingError(message: "Settings content exceeded its window bounds")
        }
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SettingsRenderingError(message: "Could not create Settings bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SettingsRenderingError(message: "Could not encode Settings PNG")
        }
        let outputURL = workspaceURL.appendingPathComponent("build/\(name)")
        try data.write(to: outputURL, options: .atomic)
    }

    private static var workspaceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}
