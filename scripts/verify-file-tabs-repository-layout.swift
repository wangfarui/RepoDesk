import AppKit
import SwiftUI
@testable import RepoDesk

@main
@MainActor
enum VerifyFileTabsRepositoryLayout {
    static func main() async throws {
        let legacy = CommandLine.arguments.contains("--legacy-scrollers")
        // Process-local override only: never change the user's global scroll settings.
        UserDefaults.standard.setVolatileDomain(
            ["AppleShowScrollBars": legacy ? "Always" : "WhenScrolling"], forName: UserDefaults.argumentDomain
        )
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoDeskTabLayout-\(UUID().uuidString)")
        let suite = "RepoDesk.TabLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let repos = [
            RegisteredRepository(displayName: "searcher", relativePath: "searcher", isPinned: false),
            RegisteredRepository(displayName: "manager", relativePath: "manager", isPinned: false)
        ]
        let names = [
            ["EsGoodsItemGroupManager.java", "ItemExtPropEsDO.java", "EsErpItemManager.java", "InventoryRepo.java", "pom.xml"],
            ["pom.xml", "inventorymanager-api.jar", "purchasemanager-api.jar", "salesmanager-api.jar",
             "PurchaseReceiptNoticeDTO.java", "PurchaseReceiptNoticeManager.java", "PurchaseReceiptNoticeRepo.java",
             "PurchaseReceiptNoticeOrderDtoConverter.java"]
        ]
        for (index, repo) in repos.enumerated() {
            let directory = root.appendingPathComponent(repo.relativePath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in names[index] {
                try "class Fixture {}".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        let state = AppState(
            workspace: WorkspaceSummary(url: root), repositories: repos, selectedSection: .files,
            windowStateStore: UserDefaultsWindowStateStore(defaults: defaults),
            appPreferencesStore: UserDefaultsAppPreferencesStore(defaults: defaults), restoresWorkspaceOnLaunch: false
        )
        state.maximumOpenFileTabs = 20
        let host = NSHostingView(rootView: FilesView(appState: state)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 1600, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.close() }
        for (repoIndex, selectedIndex) in [(0, 4), (1, 5), (0, 4), (1, 7), (0, 0), (1, 0)] {
            state.selectRepositoryContext(repos[repoIndex].id)
            // Seed each session once, then use the real repository session restoration.
            if state.openFileTabs.isEmpty {
                state.openFileTabs = names[repoIndex].map {
                    OpenFileTab(url: root.appendingPathComponent(repos[repoIndex].relativePath).appendingPathComponent($0),
                        loadedDocument: nil, text: "", originalText: "", fingerprint: nil,
                        showsMarkdownPreview: false, isLoading: false, visibleLine: 1)
                }
            }
            try require(state.openFileTabs.indices.contains(selectedIndex), "Repository fixture lost its saved tabs")
            state.selectFileTab(state.openFileTabs[selectedIndex])
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: {
                $0.identifier?.rawValue == "RepoDesk.FileTabs.Scroll" || ($0.frame.height >= 35 && $0.frame.height <= 75)
            }), let document = scroll.documentView else { throw failure("Tab viewport is missing") }
            let viewport = scroll.contentView.bounds
            try require(scroll.frame.height <= 50.5 && document.frame.height <= viewport.height + 0.5,
                        "Overflowing tabs reserve scrollbar height and clip/shift the row")
            try require(abs(viewport.minY) < 0.5, "Repository switch leaves a vertical tab offset")
            if repoIndex == 0 {
                try require(document.frame.width <= viewport.width, "Five-tab fitting case unexpectedly overflows")
            } else {
                try require(document.frame.width > viewport.width, "Eight-tab overflow case is missing")
                if selectedIndex == 7 { try require(viewport.minX > 100, "Restored trailing tab is not revealed") }
            }
            if selectedIndex == 0 { try require(abs(viewport.minX) < 0.5, "First tab inherits the previous repository offset") }
            if legacy && ((repoIndex == 0 && selectedIndex == 4) || (repoIndex == 1 && selectedIndex == 5)) {
                let region = NSRect(x: 0, y: 0, width: host.bounds.width, height: 50)
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: region) {
                    host.cacheDisplay(in: region, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: "build/file-tabs-layout-legacy-\(repoIndex).png"))
                }
            }
        }
        print("File tab repository layout verification passed (\(legacy ? "legacy" : "overlay") scrollers, fitting/overflowing sessions, stable vertical spacing, selection reveal)")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "FileTabRepositoryLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
