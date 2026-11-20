import AppKit
import SwiftUI

enum NativeTextStyle: Equatable, Sendable {
    case plain
    case diff
    case source(fileExtension: String)
}

struct NativeGitBlameAnnotation: Equatable, Sendable {
    let commitHash: String
    let author: String
    let authoredAt: Date?
    let isUncommitted: Bool
    let authorEmail: String?
    let message: String?

    init(commitHash: String, author: String, authoredAt: Date?, isUncommitted: Bool,
         authorEmail: String? = nil, message: String? = nil) {
        self.commitHash = commitHash
        self.author = author
        self.authoredAt = authoredAt
        self.isUncommitted = isUncommitted
        self.authorEmail = authorEmail
        self.message = message
    }

    @MainActor var detailText: String {
        GitBlamePalette.detailText(hash: commitHash, author: author, email: authorEmail,
                                  date: authoredAt, message: message, isUncommitted: isUncommitted)
    }
}

@MainActor
private extension NSTextView {
    var visibleTextContainerRect: NSRect {
        let origin = textContainerOrigin
        return visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}

@MainActor
private final class NativeCodeTextView: NSTextView {
    private let documentUndoManager = UndoManager()
    private var isSettingMarkedText = false
    private var isCompositionCompletionPending = false
    var isComposingText: Bool { isSettingMarkedText || hasMarkedText() }
    var compositionEndedHandler: (() -> Void)?

    override var undoManager: UndoManager? { documentUndoManager }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        isSettingMarkedText = true
        defer { isSettingMarkedText = false }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasComposing = isComposingText
        super.insertText(insertString, replacementRange: replacementRange)
        if wasComposing { scheduleCompositionCompletion() }
    }

    override func unmarkText() {
        let wasComposing = isComposingText
        super.unmarkText()
        if wasComposing { scheduleCompositionCompletion() }
    }

    private func scheduleCompositionCompletion() {
        guard !isCompositionCompletionPending else { return }
        isCompositionCompletionPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isCompositionCompletionPending = false
            guard !isComposingText else { return }
            compositionEndedHandler?()
        }
    }

    var goToLineHandler: (() -> Void)?
    var javaNavigationHandler: ((JavaNavigationAction, JavaSourcePosition, CGPoint?) -> Void)?
    var javaPopupDismissHandler: (() -> Void)?
    var navigationBackHandler: (() -> Void)?
    var navigationForwardHandler: (() -> Void)?
    var isJavaNavigationEnabled = false
    var shortcuts: [AppShortcutID: ShortcutBinding] = ShortcutBinding.defaults()
    private var javaTrackingArea: NSTrackingArea?
    private var hoveredJavaRange: NSRange?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isEditable, !isComposingText,
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == .command {
                breakUndoCoalescing()
                if undoManager?.canUndo == true { undoManager?.undo() }
                return true
            }
            if modifiers == [.command, .shift] {
                breakUndoCoalescing()
                if undoManager?.canRedo == true { undoManager?.redo() }
                return true
            }
        }
        if window?.firstResponder === self,
           matches(.goToLine, event: event) {
            goToLineHandler?()
            return true
        }
        if window?.firstResponder === self {
            if matches(.navigationBack, event: event), let navigationBackHandler {
                navigationBackHandler()
                return true
            }
            if matches(.navigationForward, event: event), let navigationForwardHandler {
                navigationForwardHandler()
                return true
            }
        }
        // SwiftUI's NSViewRepresentable wrapper can leave the text view as an
        // accessibility-focused editor without making it the exact window
        // first responder. Java navigation still has an explicit editor gate,
        // so do not drop the shortcut in that intermediate state.
        if isJavaNavigationEnabled {
            if matches(.implementation, event: event) {
                requestJavaNavigation(.implementation, at: selectedRange().location, anchor: nil)
                return true
            }
            if matches(.declaration, event: event) {
                requestJavaNavigation(.declaration, at: selectedRange().location, anchor: nil)
                return true
            }
            if matches(.superDeclaration, event: event) {
                requestJavaNavigation(.superDeclaration, at: selectedRange().location, anchor: nil)
                return true
            }
            if matches(.implementationAlternate, event: event) {
                requestJavaNavigation(.implementation, at: selectedRange().location, anchor: nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func matches(_ id: AppShortcutID, event: NSEvent) -> Bool {
        guard let binding = shortcuts[id] else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers != binding.modifierFlags { return false }
        if ["left", "right"].contains(binding.key) {
            return (binding.key == "left" && event.keyCode == 123)
                || (binding.key == "right" && event.keyCode == 124)
        }
        if binding.key == "return" { return event.keyCode == 36 }
        return event.charactersIgnoringModifiers?.lowercased() == binding.key
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let javaTrackingArea { removeTrackingArea(javaTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        javaTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard isJavaNavigationEnabled,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              let range = javaNavigationRange(at: event) else {
            clearJavaHover()
            super.mouseMoved(with: event)
            return
        }
        applyJavaHover(range)
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        clearJavaHover()
        super.mouseExited(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) { clearJavaHover() }
        super.flagsChanged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        javaPopupDismissHandler?()
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if isJavaNavigationEnabled,
           modifiers == .command,
           let range = javaNavigationRange(at: event) {
            setSelectedRange(NSRange(location: range.location, length: 0))
            let point = convert(event.locationInWindow, from: nil)
            requestJavaNavigation(
                .contextual,
                at: range.location,
                anchor: popupAnchor(for: point)
            )
            return
        }
        super.mouseDown(with: event)
    }

    private func requestJavaNavigation(
        _ action: JavaNavigationAction,
        at utf16Offset: Int,
        anchor: CGPoint?
    ) {
        let index = SourceLineIndex(text: string)
        let line = index.lineNumber(containingUTF16Offset: utf16Offset) - 1
        guard index.lineStartOffsets.indices.contains(line) else { return }
        javaNavigationHandler?(
            action,
            JavaSourcePosition(
                line: line,
                character: max(0, utf16Offset - index.lineStartOffsets[line])
            ),
            anchor
        )
    }

    private func popupAnchor(for point: CGPoint) -> CGPoint {
        guard let scrollView = enclosingScrollView else { return point }
        let scrollPoint = convert(point, to: scrollView)
        return CGPoint(
            x: scrollPoint.x,
            y: scrollView.isFlipped
                ? scrollPoint.y
                : scrollView.bounds.height - scrollPoint.y
        )
    }

    private func javaNavigationRange(at event: NSEvent) -> NSRange? {
        guard let layoutManager, let textContainer, !string.isEmpty else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyph = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        let offset = layoutManager.characterIndexForGlyph(at: glyph)
        return javaIdentifierRange(atUTF16Offset: offset)
            ?? JavaMethodReferenceSyntax.constructorKeywordRange(in: string, atUTF16Offset: offset)
    }

    private func javaIdentifierRange(atUTF16Offset offset: Int) -> NSRange? {
        let source = string as NSString
        guard source.length > 0 else { return nil }
        var location = min(max(0, offset), source.length - 1)
        if !Self.isJavaIdentifier(source.character(at: location)), location > 0 {
            location -= 1
        }
        guard Self.isJavaIdentifier(source.character(at: location)) else { return nil }
        var start = location
        var end = location + 1
        while start > 0, Self.isJavaIdentifier(source.character(at: start - 1)) { start -= 1 }
        while end < source.length, Self.isJavaIdentifier(source.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isJavaIdentifier(_ character: unichar) -> Bool {
        if character == 95 || character == 36 { return true }
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private func applyJavaHover(_ range: NSRange) {
        guard hoveredJavaRange != range, let layoutManager else { return }
        clearJavaHover()
        hoveredJavaRange = range
        layoutManager.addTemporaryAttributes(
            [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.linkColor
            ],
            forCharacterRange: range
        )
    }

    private func clearJavaHover() {
        guard let range = hoveredJavaRange, let layoutManager else { return }
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        hoveredJavaRange = nil
        NSCursor.arrow.set()
    }
}

@MainActor
final class NativeLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineIndex = SourceLineIndex(text: "")
    private var gitBlame: [Int: NativeGitBlameAnnotation]?
    private var gitLineChanges: [Int: GitLineChangeKind]?
    private var changeMarkerWidth: CGFloat { gitLineChanges == nil ? 0 : 8 }
    private var blameColorScale = GitBlameColorScale(dates: [])
    private var canToggleGitBlame = false
    private var onToggleGitBlame: (() -> Void)?
    private var onSelectGitBlameCommit: ((String) -> Void)?
    private var blameRects: [Int: NSRect] = [:]
    weak var importFolding: NativeJavaImportFolding?
    private var importToggleRect: NSRect?

    private static let gitBlameWidth = GitBlamePalette.annotationWidth

    private var labelFont: NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: max(8, (textView?.font?.pointSize ?? NSFont.systemFontSize) - 3),
            weight: .regular
        )
    }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        refresh(text: textView.string)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(text: String, index: SourceLineIndex? = nil) {
        removeAllToolTips()
        blameRects.removeAll()
        lineIndex = index ?? SourceLineIndex(text: text)
        let digits = max(2, String(lineIndex.lineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: labelFont]).width
        let foldingWidth: CGFloat = importFolding?.region == nil ? 0 : 14
        let lineNumberWidth = max(40, ceil(CGFloat(digits) * digitWidth + 18)) + foldingWidth
        let updatedThickness = lineNumberWidth + changeMarkerWidth + (gitBlame == nil ? 0 : Self.gitBlameWidth)
        if ruleThickness != updatedThickness {
            ruleThickness = updatedThickness
            scrollView?.tile()
        }
        needsDisplay = true
    }

    func configureGitBlame(
        _ gitBlame: [Int: NativeGitBlameAnnotation]?,
        canToggle: Bool,
        onToggle: (() -> Void)?,
        onSelectCommit: ((String) -> Void)?
    ) {
        let visibilityChanged = (self.gitBlame == nil) != (gitBlame == nil)
        if self.gitBlame != gitBlame {
            removeAllToolTips()
            blameRects.removeAll()
            blameColorScale = GitBlameColorScale(dates: (gitBlame ?? [:]).values.lazy
                .filter { !$0.isUncommitted }.compactMap(\.authoredAt))
        }
        self.gitBlame = gitBlame
        canToggleGitBlame = canToggle
        onToggleGitBlame = onToggle
        onSelectGitBlameCommit = onSelectCommit
        if visibilityChanged {
            refresh(text: textView?.string ?? "")
        } else if gitBlame != nil {
            needsDisplay = true
        }
    }

    func configureGitLineChanges(_ markers: [Int: GitLineChangeKind]?) {
        guard gitLineChanges != markers else { return }
        let visibilityChanged = (gitLineChanges == nil) != (markers == nil)
        gitLineChanges = markers
        if visibilityChanged { refresh(text: textView?.string ?? "") }
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard canToggleGitBlame, onToggleGitBlame != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Annotate with Git Blame",
            action: #selector(toggleGitBlame),
            keyEquivalent: ""
        )
        item.target = self
        item.state = gitBlame == nil ? .off : .on
        menu.addItem(item)
        return menu
    }

    @objc private func toggleGitBlame() {
        onToggleGitBlame?()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        removeAllToolTips()
        blameRects.removeAll()
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        if gitBlame != nil {
            NSColor.separatorColor.setFill()
            NSRect(
                x: Self.gitBlameWidth - 1,
                y: bounds.minY,
                width: 1,
                height: bounds.height
            ).fill()
        }

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleTextContainerRect,
            in: textContainer
        )
        let visibleCharacterRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )
        let firstLine = lineIndex.lineNumber(containingUTF16Offset: visibleCharacterRange.location)
        let lastLine = min(
            lineIndex.lineCount,
            lineIndex.lineNumber(containingUTF16Offset: NSMaxRange(visibleCharacterRange)) + 1
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        importToggleRect = nil
        for line in firstLine...max(firstLine, lastLine) {
            let start = lineIndex.lineStartOffsets[line - 1]
            if importFolding?.isHidden(lineStart: start) == true { continue }
            let lineRect: NSRect
            if start < lineIndex.utf16Length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: start)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            } else {
                lineRect = layoutManager.extraLineFragmentRect
            }

            let textOrigin = NSPoint(
                x: 0,
                y: lineRect.minY + textView.textContainerOrigin.y
            )
            let rulerOrigin = textView.convert(textOrigin, to: self)
            if let gitBlame {
                let colorLevel = gitBlame[line]?.isUncommitted == false
                    ? blameColorScale.level(for: gitBlame[line]?.authoredAt) : nil
                GitBlamePalette.background(for: colorLevel).setFill()
                NSRect(
                    x: 0,
                    y: rulerOrigin.y,
                    width: Self.gitBlameWidth - 1,
                    height: lineRect.height
                ).fill()
                let annotationRect = NSRect(x: 0, y: rulerOrigin.y,
                                            width: Self.gitBlameWidth - 1, height: lineRect.height)
                if gitBlame[line] != nil {
                    blameRects[line] = annotationRect
                    _ = addToolTip(annotationRect, owner: self, userData: nil)
                }
                drawGitBlame(
                    gitBlame[line],
                    y: rulerOrigin.y + (lineRect.height - labelFont.pointSize - 2) / 2
                )
            }
            let label = "\(line)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let labelRect = NSRect(
                x: bounds.maxX - changeMarkerWidth - labelSize.width - 9 - (importFolding?.region == nil ? 0 : 14),
                y: rulerOrigin.y + (lineRect.height - labelSize.height) / 2,
                width: labelSize.width,
                height: labelSize.height
            )
            label.draw(in: labelRect, withAttributes: attributes)
            if let change = gitLineChanges?[line] {
                let color = change == .modified
                    ? NSColor(srgbRed: 0.34, green: 0.59, blue: 0.94, alpha: 1)
                    : NSColor(srgbRed: 0.35, green: 0.72, blue: 0.43, alpha: 1)
                color.setFill()
                NSRect(
                    x: bounds.maxX - 7, y: rulerOrigin.y,
                    width: 4, height: lineRect.height
                ).fill()
            }
            if let folding = importFolding, let region = folding.region,
               line == lineIndex.lineNumber(containingUTF16Offset: region.keywordRange.location) {
                let toggleRect = NSRect(x: bounds.maxX - changeMarkerWidth - 14, y: labelRect.minY, width: 14, height: labelRect.height)
                importToggleRect = toggleRect
                let symbol = folding.isExpanded ? "chevron.down" : "chevron.right"
                NSImage(systemSymbolName: symbol, accessibilityDescription: "折叠或展开 import")?
                    .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))?
                    .draw(in: toggleRect.insetBy(dx: 3, dy: 3))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let annotation = blameAnnotation(at: point), !annotation.isUncommitted {
            onSelectGitBlameCommit?(annotation.commitHash)
            return
        }
        if let importToggleRect, importToggleRect.contains(convert(event.locationInWindow, from: nil)) {
            importFolding?.toggle()
            needsDisplay = true
            return
        }
        super.mouseDown(with: event)
    }

    func blameAnnotation(at point: NSPoint) -> NativeGitBlameAnnotation? {
        guard let line = blameRects.first(where: { $0.value.contains(point) })?.key else { return nil }
        return gitBlame?[line]
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        blameAnnotation(at: point)?.detailText ?? ""
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard onSelectGitBlameCommit != nil else { return }
        for (line, rect) in blameRects where gitBlame?[line]?.isUncommitted == false {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    private func drawGitBlame(_ blame: NativeGitBlameAnnotation?, y: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let color = blame?.isUncommitted != false
            ? NSColor.secondaryLabelColor
            : GitBlamePalette.foreground(for: blameColorScale.level(for: blame?.authoredAt))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let date = blame?.authoredAt.map(GitBlamePalette.dateFormatter.string(from:)) ?? ""
        let author = blame?.author ?? ""
        (date as NSString).draw(
            in: NSRect(x: 7, y: y, width: 74, height: 14),
            withAttributes: attributes
        )
        (author as NSString).draw(
            in: NSRect(x: 87, y: y, width: 110, height: 14),
            withAttributes: attributes
        )
    }
}

/// A small AppKit-backed editor surface. The unbounded text container is intentional:
/// code lines scroll horizontally instead of wrapping to the SwiftUI proposal width.
struct NativeCodeEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isSectionActive
    @Binding var text: String
    let isEditable: Bool
    var style: NativeTextStyle = .plain
    var scrollToLine: Int? = nil
    var navigationRequest: NativeTextNavigationRequest? = nil
    var showsLineNumbers = false
    var gitBlame: [Int: NativeGitBlameAnnotation]? = nil
    var gitLineChanges: [Int: GitLineChangeKind]? = nil
    var canToggleGitBlame = false
    var onToggleGitBlame: (() -> Void)? = nil
    var onSelectGitBlameCommit: ((String) -> Void)? = nil
    var onRequestGoToLine: ((_ currentLine: Int, _ lineCount: Int) -> Void)? = nil
    var onVisibleLineChange: ((Int) -> Void)? = nil
    var onNavigationHandled: ((UUID) -> Void)? = nil
    var followsTail: Binding<Bool>? = nil
    var contentIdentity: String? = nil
    var fontSize: CGFloat = NSFont.systemFontSize
    var contentSearch: ContentSearchPresentation? = nil
    var focusRequestID: UUID? = nil
    var semanticTokens: [JavaSemanticToken] = []
    var isJavaNavigationEnabled = false
    var onJavaNavigation: ((JavaNavigationAction, JavaSourcePosition, CGPoint?) -> Void)? = nil
    var onJavaPopupDismiss: (() -> Void)? = nil
    var onNavigationBack: (() -> Void)? = nil
    var onNavigationForward: (() -> Void)? = nil
    var shortcuts: [AppShortcutID: ShortcutBinding] = ShortcutBinding.defaults()
    var foldsJavaImports = false
    var importsExpanded: Binding<Bool>? = nil
    var usesAsyncSourceStyling = false

    @MainActor
    static func focusedSelection(in window: NSWindow, contentIdentity: String) -> NSRange? {
        guard let textView = window.firstResponder as? NativeCodeTextView,
              let coordinator = textView.delegate as? Coordinator,
              coordinator.contentIdentity == contentIdentity else { return nil }
        return textView.selectedRange()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            style: style,
            gitBlame: gitBlame,
            canToggleGitBlame: canToggleGitBlame,
            onToggleGitBlame: onToggleGitBlame,
            onSelectGitBlameCommit: onSelectGitBlameCommit,
            onRequestGoToLine: onRequestGoToLine,
            onVisibleLineChange: onVisibleLineChange,
            onNavigationHandled: onNavigationHandled,
            followsTail: followsTail,
            contentIdentity: contentIdentity,
            fontSize: fontSize,
            contentSearch: contentSearch,
            semanticTokens: semanticTokens,
            gitLineChanges: gitLineChanges,
            usesAsyncSourceStyling: usesAsyncSourceStyling
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.usesPredominantAxisScrolling = false

        let textView = NativeCodeTextView(frame: scrollView.contentView.bounds)
        textView.delegate = context.coordinator
        textView.compositionEndedHandler = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }
        textView.goToLineHandler = { [weak coordinator = context.coordinator] in
            coordinator?.requestGoToLine()
        }
        textView.isJavaNavigationEnabled = isJavaNavigationEnabled
        textView.javaNavigationHandler = onJavaNavigation
        textView.javaPopupDismissHandler = onJavaPopupDismiss
        textView.navigationBackHandler = onNavigationBack
        textView.navigationForwardHandler = onNavigationForward
        textView.shortcuts = shortcuts
        context.coordinator.configureFont(in: textView)
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
        context.coordinator.configureLineNumbers(showsLineNumbers, in: scrollView)
        context.coordinator.startObserving(scrollView)
        let source = text
        context.coordinator.synchronizedText = source
        if context.coordinator.canStyleAsynchronously {
            textView.string = source
            context.coordinator.scheduleSourceStyling(source)
        } else {
            NativeTextStyler.apply(source, style: style, fontSize: fontSize, semanticTokens: semanticTokens, to: textView)
        }
        context.coordinator.lastAppliedSemanticTokens = semanticTokens
        context.coordinator.configureImportFolding(enabled: foldsJavaImports, expanded: importsExpanded, sourceChanged: true)
        context.coordinator.refreshLineNumbers()
        context.coordinator.scrollIfNeeded(to: scrollToLine)
        context.coordinator.navigateIfNeeded(to: navigationRequest)
        context.coordinator.scrollToTailIfFollowing()
        context.coordinator.applyContentSearch(contentSearch)
        context.coordinator.restoreFocusIfNeeded(focusRequestID)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NativeCodeTextView else { return }
        guard isSectionActive else {
            context.coordinator.cancelVisibleLineReport()
            textView.isJavaNavigationEnabled = false
            if scrollView.window?.firstResponder === textView {
                scrollView.window?.makeFirstResponder(nil)
            }
            return
        }
        context.coordinator.text = $text
        context.coordinator.gitBlame = gitBlame
        context.coordinator.gitLineChanges = gitLineChanges
        context.coordinator.canToggleGitBlame = canToggleGitBlame
        context.coordinator.onToggleGitBlame = onToggleGitBlame
        context.coordinator.onSelectGitBlameCommit = onSelectGitBlameCommit
        context.coordinator.onRequestGoToLine = onRequestGoToLine
        context.coordinator.onVisibleLineChange = onVisibleLineChange
        context.coordinator.onNavigationHandled = onNavigationHandled
        context.coordinator.followsTail = followsTail
        context.coordinator.contentSearch = contentSearch
        context.coordinator.semanticTokens = semanticTokens
        textView.isJavaNavigationEnabled = isJavaNavigationEnabled
        textView.javaNavigationHandler = onJavaNavigation
        textView.javaPopupDismissHandler = onJavaPopupDismiss
        textView.navigationBackHandler = onNavigationBack
        textView.navigationForwardHandler = onNavigationForward
        textView.shortcuts = shortcuts
        let styleChanged = context.coordinator.style != style
            || context.coordinator.fontSize != fontSize
            || context.coordinator.lastAppliedSemanticTokens != semanticTokens
            || context.coordinator.usesAsyncSourceStyling != usesAsyncSourceStyling
        let contentIdentityChanged = context.coordinator.contentIdentity != contentIdentity
        if contentIdentityChanged { context.coordinator.cancelVisibleLineReport() }
        context.coordinator.style = style
        context.coordinator.fontSize = fontSize
        context.coordinator.contentIdentity = contentIdentity
        context.coordinator.usesAsyncSourceStyling = usesAsyncSourceStyling
        context.coordinator.configureLineNumbers(showsLineNumbers, in: scrollView)
        // Marked text and its selection belong to the input method until commit.
        // A semantic/font refresh must not end composition or consume its Return.
        if textView.isComposingText && !contentIdentityChanged { return }
        if contentIdentityChanged { textView.unmarkText() }
        context.coordinator.configureFont(in: textView)
        textView.isEditable = isEditable
        let source = text
        let textChanged = context.coordinator.synchronizedText != source
        let sourceChanged = textChanged || contentIdentityChanged
        if contentIdentityChanged || (textChanged && isEditable) {
            textView.breakUndoCoalescing()
            textView.undoManager?.removeAllActions()
        }
        let visibleOrigin = scrollView.contentView.bounds.origin
        let shouldFollowTail = context.coordinator.isFollowingTail
        if textChanged || styleChanged || contentIdentityChanged {
            context.coordinator.beginScrollAdjustment()
            let selection = textView.selectedRange()
            context.coordinator.synchronizedText = source
            if context.coordinator.canStyleAsynchronously {
                if textChanged { textView.string = source }
                context.coordinator.scheduleSourceStyling(source)
            } else {
                context.coordinator.cancelSourceStyling()
                NativeTextStorageUpdater.update(
                    source,
                    style: style,
                    fontSize: fontSize,
                    semanticTokens: semanticTokens,
                    styleChanged: styleChanged,
                    mode: contentIdentityChanged
                        ? .replace
                        : (contentIdentity == nil ? .verifyAppend : .appendOnly),
                    in: textView
                )
            }
            context.coordinator.lastAppliedSemanticTokens = semanticTokens
            context.coordinator.invalidateContentSearch()
            context.coordinator.resetExternalNavigation()
            if sourceChanged {
                context.coordinator.configureImportFolding(enabled: foldsJavaImports, expanded: importsExpanded, sourceChanged: true)
                context.coordinator.refreshLineNumbers()
            }
            textView.setSelectedRange(
                NSRange(
                    location: min(selection.location, textView.textStorage?.length ?? 0),
                    length: sourceChanged ? 0 : selection.length
                )
            )
            if shouldFollowTail {
                context.coordinator.scrollToTail()
            } else {
                context.coordinator.restoreVisibleOrigin(visibleOrigin)
            }
            context.coordinator.endScrollAdjustment()
        }
        context.coordinator.configureImportFolding(enabled: foldsJavaImports, expanded: importsExpanded, sourceChanged: false)
        context.coordinator.scrollIfNeeded(to: scrollToLine)
        context.coordinator.navigateIfNeeded(to: navigationRequest)
        context.coordinator.scrollToTailIfFollowing()
        context.coordinator.applyContentSearch(contentSearch)
        context.coordinator.restoreFocusIfNeeded(focusRequestID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var style: NativeTextStyle
        var gitBlame: [Int: NativeGitBlameAnnotation]?
        var gitLineChanges: [Int: GitLineChangeKind]?
        var usesAsyncSourceStyling: Bool
        // Keep the Swift value shared with the binding to avoid comparing bridged
        // copies of the entire source during unrelated view updates.
        var synchronizedText: String?
        var canToggleGitBlame: Bool
        var onToggleGitBlame: (() -> Void)?
        var onSelectGitBlameCommit: ((String) -> Void)?
        var onRequestGoToLine: ((_ currentLine: Int, _ lineCount: Int) -> Void)?
        var onVisibleLineChange: ((Int) -> Void)?
        var onNavigationHandled: ((UUID) -> Void)?
        var followsTail: Binding<Bool>?
        var contentIdentity: String?
        var fontSize: CGFloat
        var contentSearch: ContentSearchPresentation?
        var semanticTokens: [JavaSemanticToken]
        var lastAppliedSemanticTokens: [JavaSemanticToken] = []
        weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private var lineNumberRuler: NativeLineNumberRulerView?
        private var lineIndex = SourceLineIndex(text: "")
        private var configuredFontSize: CGFloat?
        private(set) var importFolding: NativeJavaImportFolding?
        private var foldsJavaImports = false
        private var importsExpanded: Binding<Bool>?
        private var isApplyingStyle = false
        private var isAdjustingScroll = false
        private var lastScrolledLine: Int?
        private var lastNavigationRequestID: UUID?
        private var lastContentSearchNavigationRequestID: UUID?
        private var lastFocusRequestID: UUID?
        private var pendingCenterRequestID: UUID?
        private var lastAppliedContentSearch: ContentSearchPresentation?
        private var hasAppliedContentSearch = false
        private var lastReportedVisibleLine: Int?
        private var visibleLineTask: Task<Void, Never>?
        private var sourceHighlightTask: Task<NativeSourceHighlightPlan, Never>?
        private var sourceHighlightGeneration = UUID()

        init(
            text: Binding<String>,
            style: NativeTextStyle,
            gitBlame: [Int: NativeGitBlameAnnotation]?,
            canToggleGitBlame: Bool,
            onToggleGitBlame: (() -> Void)?,
            onSelectGitBlameCommit: ((String) -> Void)? = nil,
            onRequestGoToLine: ((_ currentLine: Int, _ lineCount: Int) -> Void)?,
            onVisibleLineChange: ((Int) -> Void)?,
            onNavigationHandled: ((UUID) -> Void)?,
            followsTail: Binding<Bool>?,
            contentIdentity: String?,
            fontSize: CGFloat,
            contentSearch: ContentSearchPresentation?,
            semanticTokens: [JavaSemanticToken],
            gitLineChanges: [Int: GitLineChangeKind]? = nil,
            usesAsyncSourceStyling: Bool = false
        ) {
            self.text = text
            self.style = style
            self.gitBlame = gitBlame
            self.gitLineChanges = gitLineChanges
            self.usesAsyncSourceStyling = usesAsyncSourceStyling
            self.canToggleGitBlame = canToggleGitBlame
            self.onToggleGitBlame = onToggleGitBlame
            self.onSelectGitBlameCommit = onSelectGitBlameCommit
            self.onRequestGoToLine = onRequestGoToLine
            self.onVisibleLineChange = onVisibleLineChange
            self.onNavigationHandled = onNavigationHandled
            self.followsTail = followsTail
            self.contentIdentity = contentIdentity
            self.fontSize = fontSize
            self.contentSearch = contentSearch
            self.semanticTokens = semanticTokens
        }

        deinit {
            visibleLineTask?.cancel()
            sourceHighlightTask?.cancel()
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

        func configureLineNumbers(_ isVisible: Bool, in scrollView: NSScrollView) {
            scrollView.hasVerticalRuler = isVisible
            scrollView.rulersVisible = isVisible
            guard isVisible, let textView else {
                scrollView.verticalRulerView = nil
                lineNumberRuler = nil
                return
            }
            if lineNumberRuler == nil {
                let ruler = NativeLineNumberRulerView(scrollView: scrollView, textView: textView)
                scrollView.verticalRulerView = ruler
                lineNumberRuler = ruler
            }
            configureGitBlame()
            lineNumberRuler?.configureGitLineChanges(gitLineChanges)
        }

        func configureGitBlame() {
            lineNumberRuler?.configureGitBlame(
                gitBlame,
                canToggle: canToggleGitBlame,
                onToggle: onToggleGitBlame,
                onSelectCommit: onSelectGitBlameCommit
            )
        }

        func configureFont(in textView: NSTextView) {
            guard configuredFontSize != fontSize else { return }
            configuredFontSize = fontSize
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            lineNumberRuler?.refresh(text: textView.string, index: lineIndex)
        }

        func refreshLineNumbers() {
            guard let textView else { return }
            lineIndex = SourceLineIndex(text: textView.string)
            lineNumberRuler?.refresh(text: textView.string, index: lineIndex)
        }

        var canStyleAsynchronously: Bool {
            if case .source = style { return usesAsyncSourceStyling }
            return false
        }

        func cancelSourceStyling() {
            sourceHighlightTask?.cancel()
            sourceHighlightTask = nil
            sourceHighlightGeneration = UUID()
        }

        func scheduleSourceStyling(_ source: String, after delay: Duration? = nil) {
            guard case .source(let fileExtension) = style else { return }
            cancelSourceStyling()
            let generation = sourceHighlightGeneration
            let tokens = semanticTokens
            lastAppliedSemanticTokens = tokens
            let task = Task.detached(priority: .userInitiated) {
                if let delay { try? await Task.sleep(for: delay) }
                return NativeSourceHighlightPlan.prepare(source, fileExtension: fileExtension, semanticTokens: tokens)
            }
            sourceHighlightTask = task
            Task { [weak self] in
                let plan = await task.value
                guard let self, sourceHighlightGeneration == generation, !task.isCancelled else { return }
                sourceHighlightTask = nil
                guard canStyleAsynchronously, synchronizedText == source, let textView,
                      (textView as? NativeCodeTextView)?.isComposingText != true,
                      let storage = textView.textStorage, storage.length > 0,
                      storage.length == source.utf16.count else { return }
                isApplyingStyle = true
                defer { isApplyingStyle = false }
                NativeTextStyler.apply(plan, fontSize: fontSize, to: storage)
                importFolding?.updatePlaceholder()
            }
        }

        func configureImportFolding(enabled: Bool, expanded: Binding<Bool>?, sourceChanged: Bool) {
            guard let textView else { return }
            foldsJavaImports = enabled
            importsExpanded = expanded
            if importFolding == nil, enabled {
                importFolding = NativeJavaImportFolding(textView: textView)
                importFolding?.onLayoutChange = { [weak self] in
                    self?.lineNumberRuler?.needsDisplay = true
                }
            }
            importFolding?.onExpansionChange = { value in
                // Navigation can reveal imports during a SwiftUI view update.
                DispatchQueue.main.async { expanded?.wrappedValue = value }
            }
            importFolding?.configure(
                enabled: enabled, expanded: expanded?.wrappedValue ?? importFolding?.isExpanded ?? false,
                sourceChanged: sourceChanged
            )
            lineNumberRuler?.importFolding = importFolding
        }

        func requestGoToLine() {
            guard let textView, let onRequestGoToLine else { return }
            let index = SourceLineIndex(text: textView.string)
            let currentLine = index.lineNumber(containingUTF16Offset: textView.selectedRange().location)
            onRequestGoToLine(currentLine, index.lineCount)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingStyle, !isAdjustingScroll,
                  let textView = notification.object as? NSTextView,
                  textView.selectedRange().length == 0 else { return }
            importFolding?.reveal(textView.selectedRange())
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let wasCollapsed = importFolding?.region != nil && importFolding?.isExpanded == false
            importFolding?.reveal(affectedCharRange)
            // Reveal before a keystroke can remove or replace invisible source.
            return !(wasCollapsed && importFolding?.isExpanded == true)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingStyle,
                  let textView = notification.object as? NSTextView else { return }
            let source = textView.string
            synchronizedText = source
            if text.wrappedValue != source { text.wrappedValue = source }
            // Do not replace attributes, restore selections, or fold source while
            // AppKit is still building an input method's marked-text transaction.
            guard (textView as? NativeCodeTextView)?.isComposingText != true else { return }
            configureFont(in: textView)
            if canStyleAsynchronously {
                scheduleSourceStyling(source, after: .milliseconds(80))
            } else {
                let selection = textView.selectedRange()
                isApplyingStyle = true
                NativeTextStyler.apply(source, style: style, fontSize: fontSize, semanticTokens: semanticTokens, to: textView)
                lastAppliedSemanticTokens = semanticTokens
                textView.setSelectedRange(selection)
                isApplyingStyle = false
            }
            configureImportFolding(enabled: foldsJavaImports, expanded: importsExpanded, sourceChanged: true)
            refreshLineNumbers()
            if contentSearch != nil {
                invalidateContentSearch()
                applyContentSearch(contentSearch)
            }
        }

        func applyContentSearch(_ presentation: ContentSearchPresentation?) {
            guard !hasAppliedContentSearch || lastAppliedContentSearch != presentation else {
                return
            }
            guard let textView,
                  let layoutManager = textView.layoutManager else { return }
            hasAppliedContentSearch = true
            lastAppliedContentSearch = presentation
            let storageLength = textView.textStorage?.length ?? 0
            let fullRange = NSRange(location: 0, length: storageLength)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            guard let presentation else {
                lastContentSearchNavigationRequestID = nil
                return
            }

            let matchColor = NSColor.systemYellow.withAlphaComponent(0.28)
            for range in presentation.ranges where isValid(range, length: storageLength) {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: matchColor,
                    forCharacterRange: range
                )
            }
            guard let activeRange = presentation.activeRange,
                  isValid(activeRange, length: storageLength) else { return }
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.systemOrange.withAlphaComponent(0.48),
                forCharacterRange: activeRange
            )
            guard presentation.navigationRequestID != lastContentSearchNavigationRequestID else {
                return
            }
            lastContentSearchNavigationRequestID = presentation.navigationRequestID
            importFolding?.reveal(activeRange)
            textView.setSelectedRange(activeRange)
            textView.showFindIndicator(for: activeRange)
            center(activeRange, in: textView)
        }

        func restoreFocusIfNeeded(_ requestID: UUID?) {
            guard let requestID, requestID != lastFocusRequestID, let textView else { return }
            lastFocusRequestID = requestID
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }

        func invalidateContentSearch() {
            hasAppliedContentSearch = false
        }

        private func isValid(_ range: NSRange, length: Int) -> Bool {
            range.location != NSNotFound
                && range.location <= length
                && range.length <= length - range.location
        }

        func resetExternalNavigation() {
            lastScrolledLine = nil
        }

        func scrollIfNeeded(to line: Int?) {
            guard let line, line > 0, line != lastScrolledLine, textView != nil else { return }
            navigate(to: line)
            lastScrolledLine = line
        }

        func navigateIfNeeded(to request: NativeTextNavigationRequest?) {
            guard let request, request.id != lastNavigationRequestID else { return }
            cancelVisibleLineReport()
            if let range = request.range {
                navigate(to: range)
            } else {
                navigate(to: request.line)
            }
            lastNavigationRequestID = request.id
            restoreFocusIfNeeded(request.id)
            if let onNavigationHandled {
                DispatchQueue.main.async {
                    onNavigationHandled(request.id)
                }
            }
        }

        private func navigate(to line: Int) {
            guard let textView else { return }
            let index = SourceLineIndex(text: textView.string)
            let line = min(max(1, line), index.lineCount)
            guard let range = index.contentRange(forLine: line, in: textView.string) else { return }
            importFolding?.reveal(range)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            if range.length > 0 {
                textView.showFindIndicator(for: range)
            }
            center(range, in: textView)
            textView.window?.makeFirstResponder(textView)
        }

        private func navigate(to sourceRange: JavaSourceRange) {
            guard let textView else { return }
            let index = SourceLineIndex(text: textView.string)
            guard let range = index.utf16Range(for: sourceRange, in: textView.string) else {
                navigate(to: sourceRange.start.line + 1)
                return
            }
            importFolding?.reveal(range)
            textView.setSelectedRange(range)
            if range.length > 0 {
                textView.showFindIndicator(for: range)
            }
            center(range, in: textView)
            textView.window?.makeFirstResponder(textView)
        }

        private func center(_ range: NSRange, in textView: NSTextView) {
            let requestID = UUID()
            pendingCenterRequestID = requestID
            centerImmediately(range, in: textView)
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self,
                      self.pendingCenterRequestID == requestID,
                      let textView else { return }
                textView.layoutSubtreeIfNeeded()
                self.centerImmediately(range, in: textView)
            }
        }

        private func centerImmediately(_ range: NSRange, in textView: NSTextView) {
            guard let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                textView.scrollRangeToVisible(range)
                return
            }

            let lineRect: NSRect
            if range.location < (textView.string as NSString).length {
                layoutManager.ensureLayout(forCharacterRange: range)
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            } else {
                layoutManager.ensureLayout(for: textContainer)
                lineRect = layoutManager.extraLineFragmentRect
            }

            let visibleHeight = scrollView.contentView.bounds.height
            let desiredY = lineRect.midY + textView.textContainerOrigin.y - visibleHeight / 2
            let maximumY = max(0, textView.bounds.height - visibleHeight)
            let origin = NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: min(max(0, desiredY), maximumY)
            )
            restoreVisibleOrigin(origin)
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
                  let scrollView,
                  let documentView = scrollView.documentView else { return }
            scheduleVisibleLineReport()
            if let followsTail {
                let isAtTail = NativeTextTailFollowPolicy.isAtTail(
                    documentHeight: documentView.bounds.height,
                    visibleMaxY: scrollView.contentView.bounds.maxY
                )
                if followsTail.wrappedValue != isAtTail {
                    followsTail.wrappedValue = isAtTail
                }
            }
        }

        func cancelVisibleLineReport() {
            visibleLineTask?.cancel()
            visibleLineTask = nil
            lastReportedVisibleLine = nil
        }

        private func scheduleVisibleLineReport() {
            guard onVisibleLineChange != nil, visibleLineTask == nil else { return }
            visibleLineTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                if self?.reportVisibleLine() == false {
                    // TextKit may not yet have drawn the new viewport.
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    _ = self?.reportVisibleLine()
                }
                self?.visibleLineTask = nil
            }
        }

        private func reportVisibleLine() -> Bool {
            guard let onVisibleLineChange else { return true }
            guard let line = centerVisibleLine() else { return false }
            if line != lastReportedVisibleLine {
                lastReportedVisibleLine = line
                onVisibleLineChange(line)
            }
            return true
        }

        private func centerVisibleLine() -> Int? {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            if lineIndex.utf16Length == 0 { return 1 }
            let glyphRange = layoutManager.glyphRange(
                forBoundingRectWithoutAdditionalLayout: textView.visibleTextContainerRect,
                in: textContainer
            )
            guard glyphRange.length > 0 else { return nil }
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            let firstLine = lineIndex.lineNumber(containingUTF16Offset: characterRange.location)
            let lastOffset = max(characterRange.location, NSMaxRange(characterRange) - 1)
            let lastLine = lineIndex.lineNumber(containingUTF16Offset: lastOffset)
            let line: Int
            if let folding = importFolding, folding.region != nil, !folding.isExpanded {
                let visibleLines = (firstLine...max(firstLine, lastLine)).filter {
                    !folding.isHidden(lineStart: lineIndex.lineStartOffsets[$0 - 1])
                }
                line = visibleLines.isEmpty ? firstLine : visibleLines[visibleLines.count / 2]
            } else {
                line = firstLine + (lastLine - firstLine) / 2
            }
            return line
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
        fontSize: CGFloat = NSFont.systemFontSize,
        semanticTokens: [JavaSemanticToken] = [],
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
            NativeTextStyler.appendPlain(appendedText, fontSize: fontSize, to: textView)
            return
        }
        NativeTextStyler.apply(
            text,
            style: style,
            fontSize: fontSize,
            semanticTokens: semanticTokens,
            to: textView
        )
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

private struct NativeSourceHighlightPlan: Sendable {
    enum Style: Sendable {
        case java(JavaSyntaxHighlightStyle)
        case xml(XMLSyntaxHighlightStyle)
        case semantic(JavaSemanticTokenStyle)
        case comment, markup, property, keyword
    }
    struct Span: Sendable {
        let range: NSRange
        let style: Style
    }
    let spans: [Span]

    static func prepare(_ text: String, fileExtension: String, semanticTokens: [JavaSemanticToken]) -> Self {
        guard !Task.isCancelled else { return Self(spans: []) }
        var spans: [Span]
        switch fileExtension {
        case "java":
            spans = JavaSyntaxHighlighter.highlights(in: text).map { Span(range: $0.range, style: .java($0.style)) }
        case "xml":
            spans = XMLSyntaxHighlighter.highlights(in: text).map { Span(range: $0.range, style: .xml($0.style)) }
        default:
            spans = genericSpans(in: text, fileExtension: fileExtension)
        }
        guard !Task.isCancelled else { return Self(spans: []) }
        if fileExtension == "java", !semanticTokens.isEmpty {
            let index = SourceLineIndex(text: text)
            let source = text as NSString
            for token in semanticTokens {
                guard var range = index.utf16Range(for: token.range, in: text), range.length > 0 else { continue }
                if token.style == .annotation, range.location > 0, source.character(at: range.location - 1) == 64 {
                    range = NSRange(location: range.location - 1, length: range.length + 1)
                }
                spans.append(Span(range: range, style: .semantic(token.style)))
            }
        }
        return Self(spans: spans)
    }

    private static func genericSpans(in text: String, fileExtension: String) -> [Span] {
        let source = text as NSString
        var result: [Span] = []
        var start = 0
        while start < source.length {
            if Task.isCancelled { return [] }
            let range = source.lineRange(for: NSRange(location: start, length: 0))
            let line = source.substring(with: range).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("#") || line.hasPrefix("<!--") {
                result.append(Span(range: range, style: .comment))
            } else if fileExtension == "html", line.hasPrefix("<") {
                result.append(Span(range: range, style: .markup))
            } else if ["json", "yaml", "yml", "properties"].contains(fileExtension), line.contains(":") || line.contains("=") {
                result.append(Span(range: range, style: .property))
            }
            start = NSMaxRange(range)
        }
        let keywords: [String]
        switch fileExtension {
        case "swift": keywords = ["import", "struct", "class", "actor", "enum", "func", "let", "var", "if", "else", "guard", "return", "async", "await", "throws"]
        case "kt": keywords = ["package", "import", "public", "private", "class", "interface", "fun", "return", "if", "else", "try", "catch"]
        case "sh", "bash", "zsh": keywords = ["if", "then", "else", "fi", "for", "do", "done", "function", "case", "esac"]
        default: keywords = []
        }
        if !keywords.isEmpty,
           let regex = try? NSRegularExpression(pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b") {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                result.append(Span(range: match.range, style: .keyword))
            }
        }
        return result
    }
}

@MainActor
private enum NativeTextStyler {
    static func apply(_ plan: NativeSourceHighlightPlan, fontSize: CGFloat, to storage: NSTextStorage) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor],
                              range: NSRange(location: 0, length: storage.length))
        for span in plan.spans {
            let attributes: [NSAttributedString.Key: Any]
            switch span.style {
            case .java(let style): attributes = javaAttributes(for: style, italic: italic)
            case .xml(let style): attributes = [.foregroundColor: XMLSyntaxColorPalette.color(for: style)]
            case .semantic(let style): attributes = [.foregroundColor: JavaSemanticColorPalette.color(for: style)]
            case .comment: attributes = [.foregroundColor: NSColor.systemGreen]
            case .markup, .keyword: attributes = [.foregroundColor: NSColor.systemPurple]
            case .property: attributes = [.foregroundColor: NSColor.systemBlue]
            }
            storage.addAttributes(attributes, range: span.range)
        }
        storage.endEditing()
    }

    private static func javaAttributes(for style: JavaSyntaxHighlightStyle, italic: NSFont) -> [NSAttributedString.Key: Any] {
        switch style {
        case .annotation: return [.foregroundColor: NSColor.systemBrown]
        case .comment, .fieldDeclaration: return [.foregroundColor: NSColor.secondaryLabelColor]
        case .constant, .methodCall:
            return style == .constant
                ? [.foregroundColor: NSColor.systemPurple, .font: italic] : [.font: italic]
        case .fieldReference: return [.foregroundColor: NSColor.systemPurple]
        case .keyword, .number: return [.foregroundColor: NSColor.systemBlue]
        case .methodDeclaration: return [.foregroundColor: NSColor.systemTeal]
        case .string: return [.foregroundColor: NSColor.systemGreen]
        }
    }
    private static func plainAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(
                ofSize: fontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.textColor
        ]
    }

    static func apply(
        _ text: String,
        style: NativeTextStyle,
        fontSize: CGFloat,
        semanticTokens: [JavaSemanticToken] = [],
        to textView: NSTextView
    ) {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: plainAttributes(fontSize: fontSize)
        )
        switch style {
        case .plain:
            break
        case .diff:
            applyDiffStyle(to: attributed, text: text)
        case .source(let fileExtension):
            applySourceStyle(to: attributed, text: text, fileExtension: fileExtension)
            if fileExtension == "java" {
                applyJavaSyntaxHighlights(to: attributed, text: text, fontSize: fontSize)
                applyJavaSemanticTokens(semanticTokens, to: attributed, text: text)
            } else if fileExtension == "xml" {
                applyXMLSyntaxHighlights(to: attributed, text: text)
            }
        }
        textView.textStorage?.setAttributedString(attributed)
    }

    static func appendPlain(_ text: String, fontSize: CGFloat, to textView: NSTextView) {
        guard !text.isEmpty else { return }
        textView.textStorage?.append(
            NSAttributedString(string: text, attributes: plainAttributes(fontSize: fontSize))
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
        guard fileExtension != "java", fileExtension != "xml" else { return }
        enumerateLines(in: text) { line, range in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("<!--") {
                let color: NSColor = fileExtension == "java" ? .secondaryLabelColor : .systemGreen
                attributed.addAttribute(.foregroundColor, value: color, range: range)
            } else if fileExtension == "html", trimmed.hasPrefix("<") {
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
        case "kt":
            keywords = ["package", "import", "public", "private", "class", "interface", "fun", "return", "if", "else", "try", "catch"]
        case "sh", "bash", "zsh":
            keywords = ["if", "then", "else", "fi", "for", "do", "done", "function", "case", "esac"]
        default:
            keywords = []
        }
        guard !keywords.isEmpty else { return }
        let escaped = keywords.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard let expression = try? NSRegularExpression(pattern: "\\b(?:\(escaped))\\b") else { return }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let keywordColor: NSColor = .systemPurple
        expression.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: keywordColor, range: match.range)
        }
    }

    private static func applyJavaSyntaxHighlights(
        to attributed: NSMutableAttributedString,
        text: String,
        fontSize: CGFloat
    ) {
        let regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let italicFont = NSFontManager.shared.convert(regularFont, toHaveTrait: .italicFontMask)
        for span in JavaSyntaxHighlighter.highlights(in: text) {
            switch span.style {
            case .annotation:
                attributed.addAttribute(.foregroundColor, value: NSColor.systemBrown, range: span.range)
            case .comment, .fieldDeclaration:
                attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            case .constant:
                attributed.addAttributes(
                    [.foregroundColor: NSColor.systemPurple, .font: italicFont],
                    range: span.range
                )
            case .fieldReference:
                attributed.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: span.range)
            case .keyword, .number:
                attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: span.range)
            case .methodCall:
                attributed.addAttribute(.font, value: italicFont, range: span.range)
            case .methodDeclaration:
                attributed.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: span.range)
            case .string:
                attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: span.range)
            }
        }
    }

    private static func applyXMLSyntaxHighlights(
        to attributed: NSMutableAttributedString,
        text: String
    ) {
        for span in XMLSyntaxHighlighter.highlights(in: text) {
            attributed.addAttribute(
                .foregroundColor,
                value: XMLSyntaxColorPalette.color(for: span.style),
                range: span.range
            )
        }
    }

    private static func applyJavaSemanticTokens(
        _ tokens: [JavaSemanticToken],
        to attributed: NSMutableAttributedString,
        text: String
    ) {
        let index = SourceLineIndex(text: text)
        let source = text as NSString
        for token in tokens {
            guard var range = index.utf16Range(for: token.range, in: text), range.length > 0 else {
                continue
            }
            if token.style == .annotation,
               range.location > 0,
               source.substring(with: NSRange(location: range.location - 1, length: 1)) == "@" {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            attributed.addAttribute(.foregroundColor, value: color(for: token.style), range: range)
        }
    }

    private static func color(for style: JavaSemanticTokenStyle) -> NSColor {
        JavaSemanticColorPalette.color(for: style)
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

enum XMLSyntaxColorPalette {
    static func color(for style: XMLSyntaxHighlightStyle) -> NSColor {
        switch style {
        case .tagName:
            muted(.systemBlue)
        case .markupDelimiter:
            .secondaryLabelColor
        case .attributeName:
            muted(.systemPurple)
        case .attributeValue:
            muted(.systemGreen)
        case .declaration:
            muted(.systemIndigo)
        case .comment:
            .secondaryLabelColor
        case .cdata:
            muted(.systemOrange)
        case .entity:
            muted(.systemCyan)
        }
    }

    private static func muted(_ color: NSColor) -> NSColor {
        let blended = color.blended(withFraction: 0.22, of: .textColor) ?? color
        return blended.withAlphaComponent(0.86)
    }
}

enum JavaSemanticColorPalette {
    static func color(for style: JavaSemanticTokenStyle) -> NSColor {
        switch style {
        case .class, .interface, .enum, .struct, .type, .typeParameter,
             .parameter, .variable, .namespace:
            .labelColor
        case .annotation:
            muted(.systemBrown)
        case .method, .function:
            muted(.systemTeal)
        case .property, .enumMember:
            muted(.systemPurple)
        case .keyword, .modifier:
            muted(.systemBlue)
        case .comment:
            .secondaryLabelColor
        case .string, .regexp:
            muted(.systemGreen)
        case .number:
            muted(.systemBlue)
        case .operator, .event, .macro:
            .secondaryLabelColor
        }
    }

    private static func muted(_ color: NSColor) -> NSColor {
        let blended = color.blended(withFraction: 0.22, of: .textColor) ?? color
        return blended.withAlphaComponent(0.86)
    }
}
