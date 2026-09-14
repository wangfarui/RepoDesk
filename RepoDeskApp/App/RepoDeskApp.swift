import AppKit
import SwiftUI

extension Notification.Name {
    static let repoDeskFileSearchRequested = Notification.Name("RepoDesk.FileSearchRequested")
    static let repoDeskJavaTypeSearchRequested = Notification.Name("RepoDesk.JavaTypeSearchRequested")
    static let repoDeskJavaSymbolSearchRequested = Notification.Name("RepoDesk.JavaSymbolSearchRequested")
}

@main
@MainActor
struct RepoDeskApp: App {
    @NSApplicationDelegateAdaptor(RepoDeskApplicationDelegate.self) private var applicationDelegate
    @State private var appState: AppState

    init() {
        _appState = State(
            initialValue: RepoDeskUITestLaunchConfiguration.makeAppState()
                ?? AppState()
        )
    }

    var body: some Scene {
        Window("", id: "main") {
            RootView(appState: appState)
                .frame(minWidth: 1_000, minHeight: 650)
                .background(WindowTitleHider())
                .onAppear {
                    applicationDelegate.appState = appState
                }
        }
        .defaultSize(width: 1_220, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {
                Button("保存") {
                    Task { await appState.saveSelectedDocument() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appState.hasUnsavedDocumentChanges || appState.isSavingDocument)
            }
            CommandMenu("导航") {
                Button("Java 类") {
                    NotificationCenter.default.post(name: .repoDeskJavaTypeSearchRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Java 符号") {
                    NotificationCenter.default.post(name: .repoDeskJavaSymbolSearchRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
            }
        }

        Settings {
            RepoDeskSettingsView(appState: appState)
        }
    }
}

private struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowTitleHidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowTitleHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.titleVisibility = .hidden
    }
}

@MainActor
final class RepoDeskApplicationDelegate: NSObject, NSApplicationDelegate {
    enum FileNavigationMouseAction: Equatable {
        case back
        case forward
    }

    weak var appState: AppState?
    private var shiftMonitor: Any?
    private var contentFindMonitor: Any?
    private var fileNavigationMouseMonitor: Any?
    private var lastShiftPressTimestamp: TimeInterval?

    nonisolated static func fileNavigationAction(
        forMouseButton buttonNumber: Int
    ) -> FileNavigationMouseAction? {
        switch buttonNumber {
        case 3: .back
        case 4: .forward
        default: nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self,
                  (event.keyCode == 56 || event.keyCode == 60),
                  event.modifierFlags.contains(.shift),
                  event.modifierFlags.intersection([.command, .option, .control, .function]).isEmpty else {
                return event
            }
            if let lastShiftPressTimestamp = self.lastShiftPressTimestamp,
               event.timestamp - lastShiftPressTimestamp <= 0.45 {
                NotificationCenter.default.post(name: .repoDeskFileSearchRequested, object: nil)
                self.lastShiftPressTimestamp = nil
            } else {
                self.lastShiftPressTimestamp = event.timestamp
            }
            return event
        }
        contentFindMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let key = event.charactersIgnoringModifiers?.lowercased(),
                  let window = event.window ?? NSApp.keyWindow,
                  ContentFindWindowRegistry.shared.contains(window) else {
                return event
            }
            if modifiers == .command, key == "f" {
                NotificationCenter.default.post(
                    name: .repoDeskContentFindRequested,
                    object: window
                )
                return nil
            }
            if key == "g", modifiers == .command || modifiers == [.command, .shift] {
                NotificationCenter.default.post(
                    name: .repoDeskContentFindNavigationRequested,
                    object: window,
                    userInfo: ["offset": modifiers.contains(.shift) ? -1 : 1]
                )
                return nil
            }
            return event
        }
        fileNavigationMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .otherMouseDown
        ) { [weak self] event in
            guard let self,
                  let appState = self.appState,
                  let action = Self.fileNavigationAction(forMouseButton: event.buttonNumber) else {
                return event
            }
            switch action {
            case .back:
                appState.navigateFileBack()
            case .forward:
                appState.navigateFileForward()
            }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.persistStateBeforeTermination()
        if let shiftMonitor {
            NSEvent.removeMonitor(shiftMonitor)
        }
        if let contentFindMonitor {
            NSEvent.removeMonitor(contentFindMonitor)
        }
        if let fileNavigationMouseMonitor {
            NSEvent.removeMonitor(fileNavigationMouseMonitor)
        }
        shiftMonitor = nil
        contentFindMonitor = nil
        fileNavigationMouseMonitor = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        guard appState.hasUnsavedDocumentChanges else {
            Task { @MainActor in
                await appState.shutdownJavaLanguage()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出 RepoDesk 前保存改动？"
        alert.informativeText = appState.selectedFileURL?.lastPathComponent
            ?? "当前文件还有未保存的改动。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await appState.saveSelectedDocument()
                let didSave = !appState.hasUnsavedDocumentChanges
                if didSave {
                    await appState.shutdownJavaLanguage()
                    sender.reply(toApplicationShouldTerminate: true)
                } else {
                    sender.reply(toApplicationShouldTerminate: false)
                    let failure = NSAlert()
                    failure.alertStyle = .critical
                    failure.messageText = "RepoDesk 无法保存文件"
                    failure.informativeText = appState.hasDocumentConflict
                        ? "磁盘文件已变化，RepoDesk 未覆盖它；请先解决冲突再退出。"
                        : (appState.documentSaveErrorMessage ?? "请先解决保存错误再退出。")
                    failure.runModal()
                }
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            Task { @MainActor in
                await appState.shutdownJavaLanguage()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }
}
