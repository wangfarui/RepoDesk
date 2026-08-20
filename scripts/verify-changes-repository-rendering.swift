import AppKit
import SwiftUI
@testable import RepoDesk

@main
struct ChangesRepositoryRenderingVerification {
    @MainActor
    static func main() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskChangesRendering", isDirectory: true)
        let member = RegisteredRepository(
            displayName: "online.base.member.service",
            relativePath: "member",
            isPinned: false
        )
        let apiJar = RegisteredRepository(
            displayName: "online.base.apijar.service",
            relativePath: "apijar",
            isPinned: false
        )
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(member.relativePath).appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(apiJar.relativePath).appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [member, apiJar],
            selectedRepositoryID: member.id,
            restoresWorkspaceOnLaunch: false
        )
        state.repositorySnapshots[member.id] = snapshot(path: "member-starter/src/main/java/com/internet/AFa.java")
        state.repositorySnapshots[apiJar.id] = snapshot(path: ".idea/inspectionProfiles/Project_Default.xml")
        state.selectRepositoryContext(member.id)

        _ = NSApplication.shared
        let hostingView = NSHostingView(
            rootView: ChangesView(appState: state).frame(width: 1050, height: 700)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1050, height: 700)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.white.cgColor
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.appearance = NSAppearance(named: .aqua)
        window.alphaValue = 0.01
        window.orderFront(nil)
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let memberRendering = try renderingData(of: hostingView)

        state.selectRepositoryContext(apiJar.id)
        guard state.selectedRepositoryID == apiJar.id,
              state.changesRepositoryScopeID == apiJar.id,
              state.repositorySnapshots[apiJar.id]?.changes.first?.path.hasPrefix(".idea/") == true else {
            throw VerificationError.mismatch("AppState did not switch to apijar")
        }
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

        let repositoryRendering = try saveRendering(
            of: hostingView,
            to: URL(fileURLWithPath: "build/changes-repository-rendering.png")
        )
        guard repositoryRendering != memberRendering else {
            throw VerificationError.mismatch("rendering did not change after selecting apijar")
        }

        state.selectChangesGrouping(.all)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let combinedRendering = try saveRendering(
            of: hostingView,
            to: URL(fileURLWithPath: "build/changes-combined-grouping-rendering.png")
        )
        guard state.changesGrouping == .all,
              state.repositorySnapshots[apiJar.id]?.changes.first?.path
                  == ".idea/inspectionProfiles/Project_Default.xml" else {
            throw VerificationError.mismatch("combined grouping lost the apijar selection")
        }

        state.selectChangesGrouping([])
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let flatRendering = try saveRendering(
            of: hostingView,
            to: URL(fileURLWithPath: "build/changes-flat-grouping-rendering.png")
        )
        guard state.changesGrouping.isEmpty else {
            throw VerificationError.mismatch("flat grouping state was not applied")
        }
        guard Set([repositoryRendering, combinedRendering, flatRendering]).count == 3 else {
            throw VerificationError.mismatch("grouping changes did not produce distinct renderings")
        }
        print("Changes repository rendering verification passed")
    }

    private static func snapshot(path: String) -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: [
                GitFileChange(
                    path: path,
                    originalPath: nil,
                    indexStatus: .untracked,
                    workTreeStatus: .untracked,
                    isUntracked: true,
                    isConflicted: false
                )
            ],
            lastCommit: nil
        )
    }

    @MainActor
    private static func saveRendering(of view: NSView, to url: URL) throws -> Data {
        let data = try renderingData(of: view)
        try data.write(to: url)
        return data
    }

    @MainActor
    private static func renderingData(of view: NSView) throws -> Data {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw VerificationError.mismatch("could not create rendering surface")
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw VerificationError.mismatch("could not encode rendering")
        }
        return data
    }
}

private enum VerificationError: Error, CustomStringConvertible {
    case mismatch(String)

    var description: String {
        switch self {
        case .mismatch(let message): message
        }
    }
}
