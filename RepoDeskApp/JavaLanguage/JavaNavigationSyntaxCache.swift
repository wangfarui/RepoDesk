import Foundation

/// A small content-keyed cache: unsaved buffers and disk changes cannot reuse
/// spans from an older document. All mutable state is protected by the lock.
final class JavaNavigationSyntaxCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [JavaSyntaxHighlightSpan]] = [:]
    private var order: [String] = []

    func highlights(in text: String) -> [JavaSyntaxHighlightSpan] {
        if let cached = lock.withLock({ entries[text] }) { return cached }
        let spans = JavaSyntaxHighlighter.highlights(in: text)
        // The highlighter supports cancellation and may have returned partial
        // work. Never let a cancelled request poison a subsequent navigation.
        guard !Task.isCancelled, text.utf8.count <= 1_000_000 else { return spans }
        lock.withLock {
            guard entries[text] == nil else { return }
            if order.count == 16 { entries.removeValue(forKey: order.removeFirst()) }
            entries[text] = spans
            order.append(text)
        }
        return spans
    }
}
