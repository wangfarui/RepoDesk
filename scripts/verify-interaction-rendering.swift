import AppKit
import SwiftUI
@testable import RepoDesk

private struct InteractionRenderingError: Error {
    let message: String
}

@main
@MainActor
enum VerifyInteractionRendering {
    static func main() throws {
        let workspace = WorkspaceSummary(
            name: "RepoDesk 长名称 Workspace",
            path: "/tmp"
        )
        let state = AppState(
            workspace: workspace,
            restoresWorkspaceOnLaunch: false
        )
        state.setAutomaticallyRefreshesWorkspace(false)
        state.recentWorkspaces = [
            RecentWorkspace(
                path: "/tmp/very-long-workspace-path/包含中文名称/enterprise-platform-workspace",
                bookmark: nil,
                lastOpenedAt: .now
            )
        ]

        try render(
            state: state,
            width: 1_000,
            height: 650,
            colorScheme: .light,
            appearance: .aqua,
            outputName: "interaction-compact-light.png"
        )
        try render(
            state: state,
            width: 1_400,
            height: 900,
            colorScheme: .dark,
            appearance: .darkAqua,
            outputName: "interaction-wide-dark.png"
        )
        state.setSidebarFontSize(16)
        state.setInterfaceFontSize(16)
        state.setFileContentFontSize(16)
        try render(
            state: state,
            width: 1_000,
            height: 650,
            colorScheme: .light,
            appearance: .aqua,
            outputName: "interaction-compact-large-fonts.png"
        )
        let sourceURL = URL(fileURLWithPath: "/tmp/FontSizePreview.swift")
        let source = """
        struct FontSizePreview {
            let sidebar = 16
            let interface = 16
            let fileContent = 16
        }
        """
        state.selectedSection = .files
        state.selectedFileURL = sourceURL
        state.documentText = source
        state.documentOriginalText = source
        state.loadedDocument = .text(
            LoadedTextDocument(
                text: source,
                isLarge: false,
                encoding: .utf8,
                revision: DocumentRevision(byteCount: source.utf8.count, contentDigest: 1)
            )
        )
        try render(
            state: state,
            width: 1_000,
            height: 650,
            colorScheme: .light,
            appearance: .aqua,
            outputName: "interaction-files-large-fonts.png"
        )
        print("Interaction rendering verification passed")
    }

    private static func render(
        state: AppState,
        width: CGFloat,
        height: CGFloat,
        colorScheme: ColorScheme,
        appearance: NSAppearance.Name,
        outputName: String
    ) throws {
        _ = NSApplication.shared
        let rootView = RootView(appState: state)
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.appearance = NSAppearance(named: appearance)
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        guard hostingView.fittingSize.width <= width + 1,
              hostingView.fittingSize.height <= height + 1 else {
            throw InteractionRenderingError(message: "Root content exceeded \(width)x\(height)")
        }
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw InteractionRenderingError(message: "Could not create root rendering")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count > 20_000 else {
            throw InteractionRenderingError(message: "Root rendering was empty")
        }
        try data.write(
            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/\(outputName)"),
            options: .atomic
        )
    }
}
