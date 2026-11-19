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
            displayName: "example.services.member.service",
            relativePath: "member",
            isPinned: false
        )
        let apiJar = RegisteredRepository(
            displayName: "example.services.apijar.service",
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
        try verifyFileNameSearch(state: state, hosting: hostingView, member: member, apiJar: apiJar)
        print("Changes repository rendering verification passed")
    }

    @MainActor
    private static func verifyFileNameSearch(
        state: AppState,
        hosting: NSView,
        member: RegisteredRepository,
        apiJar: RegisteredRepository
    ) throws {
        state.repositorySnapshots[member.id] = snapshot(paths: [
            "src/OrderService.java", "config/order.xml", "order/Customer.java"
        ])
        state.repositorySnapshots[apiJar.id] = snapshot(paths: ["src/OrderApi.java", "src/Other.java"])
        state.changesAutoExpansion = ChangesAutoExpansionSettings(mode: .never)
        state.selectWorkspaceContext()
        state.selectChangesRepositoryScope(nil)
        state.selectChangesGrouping(.directory)
        updateLayout(hosting)

        let excluded = GitChangeSelection(path: "config/order.xml", kind: .unversioned)
        state.setCommitInclusion([excluded], repositoryID: member.id, included: false)
        let before = state.includedCommitChanges(repositoryID: member.id)
        let collapsedRendering = try renderingData(of: hosting)
        try setSearch("oRdEr", in: hosting)
        let searchRendering = try saveRendering(
            of: hosting, to: URL(fileURLWithPath: "build/changes-file-search-rendering.png")
        )
        guard searchRendering != collapsedRendering else {
            throw VerificationError.mismatch("Typing in Changes search did not update the list")
        }
        guard state.includedCommitChanges(repositoryID: member.id) == before else {
            throw VerificationError.mismatch("Searching changed commit inclusion")
        }

        for grouping: GitChangesGrouping in [[], .module, .all] {
            state.selectChangesGrouping(grouping)
            updateLayout(hosting)
            _ = try saveRendering(
                of: hosting,
                to: URL(fileURLWithPath: "build/changes-search-grouping-\(grouping.rawValue).png")
            )
        }
        state.selectChangesRepositoryScope(member.id)
        updateLayout(hosting)
        let scopedRendering = try saveRendering(
            of: hosting, to: URL(fileURLWithPath: "build/changes-search-single-repository.png")
        )
        try setSearch("not-a-file", in: hosting)
        let emptyRendering = try saveRendering(
            of: hosting, to: URL(fileURLWithPath: "build/changes-search-empty.png")
        )
        guard emptyRendering != scopedRendering else {
            throw VerificationError.mismatch("An unmatched search did not update the list")
        }

        // Re-enter a directory scope with automatic expansion disabled. Ending a
        // search should render the same collapsed groups as before the search.
        state.selectChangesGrouping(.directory)
        updateLayout(hosting)
        try setSearch("", in: hosting)
        let beforeSearch = try renderingData(of: hosting)
        try setSearch("order", in: hosting)
        let duringSearch = try renderingData(of: hosting)
        try setSearch("", in: hosting)
        let afterSearch = try renderingData(of: hosting)
        guard beforeSearch == afterSearch, duringSearch != afterSearch else {
            throw VerificationError.mismatch("Clearing search did not restore the original rendering")
        }
        guard state.includedCommitChanges(repositoryID: member.id) == before else {
            throw VerificationError.mismatch("Clearing search changed commit inclusion")
        }
        print("Changes file search interaction verification passed")
    }

    @MainActor
    private static func updateLayout(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    }

    @MainActor
    private static func setSearch(_ query: String, in view: NSView) throws {
        guard let field = descendants(view).compactMap({ $0 as? NSTextField }).first(where: {
            $0.placeholderString == "搜索改动文件名"
        }) else { throw VerificationError.mismatch("Changes file name search field is missing") }
        field.stringValue = query
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        updateLayout(view)
    }

    @MainActor
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private static func snapshot(path: String) -> GitRepositorySnapshot {
        snapshot(paths: [path])
    }

    private static func snapshot(paths: [String]) -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            branch: "main",
            isDetachedHEAD: false,
            aheadCount: 0,
            behindCount: 0,
            changes: paths.map { path in
                GitFileChange(
                    path: path,
                    originalPath: nil,
                    indexStatus: .untracked,
                    workTreeStatus: .untracked,
                    isUntracked: true,
                    isConflicted: false
                )
            },
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
