import AppKit
import SwiftUI

enum FileFontSizeAction: Equatable, Sendable {
    case increase
    case decrease
    case reset

    static func matching(key: String?, modifiers: NSEvent.ModifierFlags) -> Self? {
        // Numeric-pad flags do not change the meaning of +, - or 0.
        let modifiers = modifiers.intersection([.command, .option, .control, .shift, .function])
        return switch (key, modifiers) {
        case ("=", .command), ("+", .command),
             ("=", [.command, .shift]), ("+", [.command, .shift]): .increase
        case ("-", .command): .decrease
        case ("0", .command): .reset
        default: nil
        }
    }
}

@MainActor
struct FileFontSizeCommandListener: NSViewRepresentable {
    let isEnabled: Bool
    let perform: (FileFontSizeAction) -> Bool

    func makeNSView(context: Context) -> FileFontSizeCommandView {
        FileFontSizeCommandView()
    }

    func updateNSView(_ view: FileFontSizeCommandView, context: Context) {
        view.isEnabled = isEnabled
        view.perform = perform
    }

    static func dismantleNSView(_ view: FileFontSizeCommandView, coordinator: ()) {
        view.stopMonitoring()
    }
}

@MainActor
final class FileFontSizeCommandView: NSView {
    var isEnabled = false
    var perform: (FileFontSizeAction) -> Bool = { _ in false }
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard isEnabled, let window, event.window === window,
              window.attachedSheet == nil,
              (window.firstResponder as? NSTextView)?.isFieldEditor != true,
              let action = FileFontSizeAction.matching(
                key: event.charactersIgnoringModifiers, modifiers: event.modifierFlags
              ), perform(action) else { return event }
        return nil
    }
}
