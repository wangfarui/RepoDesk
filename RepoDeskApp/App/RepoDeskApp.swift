import AppKit
import SwiftUI

@main
@MainActor
struct RepoDeskApp: App {
    @NSApplicationDelegateAdaptor(RepoDeskApplicationDelegate.self) private var applicationDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("RepoDesk", id: "main") {
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
    weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState, appState.hasUnsavedDocumentChanges else { return .terminateNow }

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
                sender.reply(toApplicationShouldTerminate: didSave)
                if !didSave {
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
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
