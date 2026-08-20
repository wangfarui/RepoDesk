import AppKit
import SwiftUI

enum NativeTextStyle: Equatable {
    case plain
    case diff
    case source(fileExtension: String)
}

/// A small AppKit-backed editor surface. The unbounded text container is intentional:
/// code lines scroll horizontally instead of wrapping to the SwiftUI proposal width.
struct NativeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    var style: NativeTextStyle = .plain
    var scrollToLine: Int? = nil
    var followsTail: Binding<Bool>? = nil
    var contentIdentity: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            style: style,
            followsTail: followsTail,
            contentIdentity: contentIdentity
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.usesPredominantAxisScrolling = false

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityIdentifier("RepoDesk.SourceEditor")

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.startObserving(scrollView)
        NativeTextStyler.apply(text, style: style, to: textView)
        context.coordinator.scrollIfNeeded(to: scrollToLine)
        context.coordinator.scrollToTailIfFollowing()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.followsTail = followsTail
        let styleChanged = context.coordinator.style != style
        let contentIdentityChanged = context.coordinator.contentIdentity != contentIdentity
        context.coordinator.style = style
        context.coordinator.contentIdentity = contentIdentity
        textView.isEditable = isEditable
        let textChanged = textView.string != text
        let visibleOrigin = scrollView.contentView.bounds.origin
        let shouldFollowTail = context.coordinator.isFollowingTail
        if textChanged || styleChanged {
            context.coordinator.beginScrollAdjustment()
            let selection = textView.selectedRange()
            NativeTextStorageUpdater.update(
                text,
                style: style,
                styleChanged: styleChanged,
                mode: contentIdentityChanged
                    ? .replace
                    : (contentIdentity == nil ? .verifyAppend : .appendOnly),
                in: textView
            )
            textView.setSelectedRange(
                NSRange(
                    location: min(selection.location, textView.textStorage?.length ?? 0),
                    length: 0
                )
            )
            if shouldFollowTail {
                context.coordinator.scrollToTail()
            } else {
                context.coordinator.restoreVisibleOrigin(visibleOrigin)
            }
            context.coordinator.endScrollAdjustment()
        }
        context.coordinator.scrollIfNeeded(to: scrollToLine)
        context.coordinator.scrollToTailIfFollowing()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var style: NativeTextStyle
        var followsTail: Binding<Bool>?
        var contentIdentity: String?
        weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private var isApplyingStyle = false
        private var isAdjustingScroll = false
        private var lastScrolledLine: Int?

        init(
            text: Binding<String>,
            style: NativeTextStyle,
            followsTail: Binding<Bool>?,
            contentIdentity: String?
        ) {
            self.text = text
            self.style = style
            self.followsTail = followsTail
            self.contentIdentity = contentIdentity
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        var isFollowingTail: Bool {
            followsTail?.wrappedValue == true
        }

        func startObserving(_ scrollView: NSScrollView) {
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingStyle,
                  let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            let selection = textView.selectedRange()
            isApplyingStyle = true
            NativeTextStyler.apply(textView.string, style: style, to: textView)
            textView.setSelectedRange(selection)
            isApplyingStyle = false
        }

        func scrollIfNeeded(to line: Int?) {
            guard let line, line > 0, line != lastScrolledLine, let textView else { return }
            let text = textView.string as NSString
            var currentLine = 1
            var location = 0
            while currentLine < line, location < text.length {
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                currentLine += 1
            }
            let range = NSRange(location: min(location, text.length), length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            lastScrolledLine = line
        }

        func scrollToTailIfFollowing() {
            guard isFollowingTail else { return }
            scrollToTail()
        }

        func beginScrollAdjustment() {
            isAdjustingScroll = true
        }

        func endScrollAdjustment() {
            isAdjustingScroll = false
        }

        func scrollToTail() {
            guard let textView, let scrollView else { return }
            let horizontalOffset = scrollView.contentView.bounds.origin.x
            let endRange = NSRange(location: textView.textStorage?.length ?? 0, length: 0)
            let wasAdjustingScroll = isAdjustingScroll
            isAdjustingScroll = true
            textView.scrollRangeToVisible(endRange)
            let verticalOffset = scrollView.contentView.bounds.origin.y
            scrollView.contentView.scroll(
                to: NSPoint(x: horizontalOffset, y: verticalOffset)
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
            followsTail?.wrappedValue = true
            isAdjustingScroll = wasAdjustingScroll
        }

        func restoreVisibleOrigin(_ origin: NSPoint) {
            guard let scrollView else { return }
            let wasAdjustingScroll = isAdjustingScroll
            isAdjustingScroll = true
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isAdjustingScroll = wasAdjustingScroll
        }

        @objc private func visibleBoundsDidChange(_ notification: Notification) {
            guard !isAdjustingScroll,
                  let followsTail,
                  let scrollView,
                  let documentView = scrollView.documentView else { return }
            let isAtTail = NativeTextTailFollowPolicy.isAtTail(
                documentHeight: documentView.bounds.height,
                visibleMaxY: scrollView.contentView.bounds.maxY
            )
            if followsTail.wrappedValue != isAtTail {
                followsTail.wrappedValue = isAtTail
            }
        }
    }
}

enum NativeTextTailFollowPolicy {
    static let tolerance: CGFloat = 18

    static func isAtTail(
        documentHeight: CGFloat,
        visibleMaxY: CGFloat,
        tolerance: CGFloat = NativeTextTailFollowPolicy.tolerance
    ) -> Bool {
        documentHeight - visibleMaxY <= tolerance
    }
}

@MainActor
enum NativeTextStorageUpdater {
    enum Mode {
        case replace
        case verifyAppend
        case appendOnly
    }

    static func update(
        _ text: String,
        style: NativeTextStyle,
        styleChanged: Bool,
        mode: Mode = .verifyAppend,
        in textView: NSTextView
    ) {
        if !styleChanged,
           style == .plain,
           mode != .replace,
           let appendedText = appendedSuffix(
               of: text,
               after: textView.string,
               verifiesPrefix: mode == .verifyAppend
           ) {
            NativeTextStyler.appendPlain(appendedText, to: textView)
            return
        }
        NativeTextStyler.apply(text, style: style, to: textView)
    }

    private static func appendedSuffix(
        of text: String,
        after existingText: String,
        verifiesPrefix: Bool
    ) -> String? {
        let updated = text as NSString
        let existing = existingText as NSString
        guard updated.length >= existing.length else {
            return nil
        }
        if verifiesPrefix,
           updated.substring(with: NSRange(location: 0, length: existing.length)) != existingText {
            return nil
        }
        return updated.substring(
            with: NSRange(
                location: existing.length,
                length: updated.length - existing.length
            )
        )
    }
}

@MainActor
private enum NativeTextStyler {
    private static var plainAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.textColor
        ]
    }

    static func apply(_ text: String, style: NativeTextStyle, to textView: NSTextView) {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: plainAttributes
        )
        switch style {
        case .plain:
            break
        case .diff:
            applyDiffStyle(to: attributed, text: text)
        case .source(let fileExtension):
            applySourceStyle(to: attributed, text: text, fileExtension: fileExtension)
        }
        textView.textStorage?.setAttributedString(attributed)
    }

    static func appendPlain(_ text: String, to textView: NSTextView) {
        guard !text.isEmpty else { return }
        textView.textStorage?.append(
            NSAttributedString(string: text, attributes: plainAttributes)
        )
    }

    private static func applyDiffStyle(to attributed: NSMutableAttributedString, text: String) {
        enumerateLines(in: text) { line, range in
            let attributes: [NSAttributedString.Key: Any]
            if line.hasPrefix("@@") {
                attributes = [.foregroundColor: NSColor.systemPurple]
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                attributes = [
                    .foregroundColor: NSColor.systemGreen,
                    .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.09)
                ]
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                attributes = [
                    .foregroundColor: NSColor.systemRed,
                    .backgroundColor: NSColor.systemRed.withAlphaComponent(0.09)
                ]
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") {
                attributes = [.foregroundColor: NSColor.secondaryLabelColor]
            } else {
                attributes = [:]
            }
            attributed.addAttributes(attributes, range: range)
        }
    }

    private static func applySourceStyle(
        to attributed: NSMutableAttributedString,
        text: String,
        fileExtension: String
    ) {
        enumerateLines(in: text) { line, range in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("<!--") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: range)
            } else if ["xml", "html"].contains(fileExtension), trimmed.hasPrefix("<") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range)
            } else if ["json", "yaml", "yml", "properties"].contains(fileExtension),
                      trimmed.contains(":") || trimmed.contains("=") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
            }
        }

        let keywords: [String]
        switch fileExtension {
        case "swift":
            keywords = ["import", "struct", "class", "actor", "enum", "func", "let", "var", "if", "else", "guard", "return", "async", "await", "throws"]
        case "java", "kt":
            keywords = ["package", "import", "public", "private", "class", "interface", "fun", "void", "return", "new", "if", "else", "try", "catch"]
        case "sh", "bash", "zsh":
            keywords = ["if", "then", "else", "fi", "for", "do", "done", "function", "case", "esac"]
        default:
            keywords = []
        }
        guard !keywords.isEmpty else { return }
        let escaped = keywords.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard let expression = try? NSRegularExpression(pattern: "\\b(?:\(escaped))\\b") else { return }
        let range = NSRange(location: 0, length: (text as NSString).length)
        expression.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
        }
    }

    private static func enumerateLines(
        in text: String,
        body: (_ line: String, _ range: NSRange) -> Void
    ) {
        let fullText = text as NSString
        var lineStart = 0
        while lineStart < fullText.length {
            let range = fullText.lineRange(for: NSRange(location: lineStart, length: 0))
            body(fullText.substring(with: range), range)
            lineStart = NSMaxRange(range)
        }
    }
}
