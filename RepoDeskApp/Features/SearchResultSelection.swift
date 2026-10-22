import AppKit
import SwiftUI

struct SearchResultSelection: Equatable, Sendable {
    var index = 0

    mutating func reset() {
        index = 0
    }

    mutating func clamp(toCount count: Int) {
        guard count > 0 else {
            index = 0
            return
        }
        index = min(max(index, 0), count - 1)
    }

    func moved(by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let current = min(max(index, 0), count - 1)
        return min(max(current + offset, 0), count - 1)
    }
}

extension View {
    func searchResultArrowKeys(
        isEnabled: Bool,
        count: Int,
        selection: Binding<SearchResultSelection>
    ) -> some View {
        modifier(
            SearchResultArrowKeysModifier(
                isEnabled: isEnabled,
                count: count,
                selection: selection
            )
        )
    }
}

@MainActor
private final class SearchResultArrowKeyMonitor {
    var isEnabled = false
    var move: (Int) -> Void = { _ in }
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isEnabled, event.window?.isKeyWindow == true, !Self.menuIsVisible else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, let offset = Self.offset(for: event) else { return event }
        move(offset)
        return nil
    }

    private static func offset(for event: NSEvent) -> Int? {
        switch event.keyCode {
        case 126: -1
        case 125: 1
        default: nil
        }
    }

    private static var menuIsVisible: Bool {
        NSApp.windows.contains { candidate in
            candidate.isVisible
                && NSStringFromClass(type(of: candidate)).localizedCaseInsensitiveContains("Menu")
        }
    }
}

private struct SearchResultArrowKeysModifier: ViewModifier {
    var isEnabled: Bool
    var count: Int
    @Binding var selection: SearchResultSelection
    @State private var monitor = SearchResultArrowKeyMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor.start()
                install()
            }
            .onDisappear {
                monitor.stop()
            }
            .onChange(of: isEnabled) { install() }
            .onChange(of: count) { install() }
    }

    private func install() {
        monitor.isEnabled = isEnabled && count > 0
        let count = count
        let selection = $selection
        monitor.move = { offset in
            guard let next = selection.wrappedValue.moved(by: offset, count: count),
                  next != selection.wrappedValue.index else { return }
            var updated = selection.wrappedValue
            updated.index = next
            selection.wrappedValue = updated
        }
    }
}
