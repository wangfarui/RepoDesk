import AppKit
import SwiftUI

enum NativeTextStyle: Equatable {
    case plain
    case diff
    case source(fileExtension: String)
}

struct NativeGitBlameAnnotation: Equatable, Sendable {
    let commitHash: String
    let author: String
    let authoredAt: Date?
    let isUncommitted: Bool
}

@MainActor
private final class NativeCodeTextView: NSTextView {
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
private final class NativeLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineIndex = SourceLineIndex(text: "")
    private var gitBlame: [Int: NativeGitBlameAnnotation]?
    private var blameColorScale = GitBlameColorScale(dates: [])
    private var canToggleGitBlame = false
    private var onToggleGitBlame: (() -> Void)?
    weak var importFolding: NativeJavaImportFolding?
    private var importToggleRect: NSRect?

    private static let gitBlameWidth: CGFloat = 226

    private static let blameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy/MM/dd"
        return formatter
    }()

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

    func refresh(text: String) {
        lineIndex = SourceLineIndex(text: text)
        let digits = max(2, String(lineIndex.lineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: labelFont]).width
        let foldingWidth: CGFloat = importFolding?.region == nil ? 0 : 14
        let lineNumberWidth = max(40, ceil(CGFloat(digits) * digitWidth + 18)) + foldingWidth
        let updatedThickness = lineNumberWidth + (gitBlame == nil ? 0 : Self.gitBlameWidth)
        if ruleThickness != updatedThickness {
            ruleThickness = updatedThickness
            scrollView?.tile()
        }
        needsDisplay = true
    }

    func configureGitBlame(
        _ gitBlame: [Int: NativeGitBlameAnnotation]?,
        canToggle: Bool,
        onToggle: (() -> Void)?
    ) {
        let visibilityChanged = (self.gitBlame == nil) != (gitBlame == nil)
        if self.gitBlame != gitBlame {
            blameColorScale = GitBlameColorScale(dates: (gitBlame ?? [:]).values.lazy
                .filter { !$0.isUncommitted }.compactMap(\.authoredAt))
        }
        self.gitBlame = gitBlame
        canToggleGitBlame = canToggle
        onToggleGitBlame = onToggle
        if visibilityChanged {
            refresh(text: textView?.string ?? "")
        } else if gitBlame != nil {
            needsDisplay = true
        }
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

        layoutManager.ensureLayout(forBoundingRect: textView.visibleRect, in: textContainer)
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
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
                GitBlamePalette.background(for: gitBlame[line]?.isUncommitted == false
                    ? blameColorScale.level(for: gitBlame[line]?.authoredAt) : nil).setFill()
                NSRect(
                    x: 0,
                    y: rulerOrigin.y,
                    width: Self.gitBlameWidth - 1,
                    height: lineRect.height
                ).fill()
                drawGitBlame(
                    gitBlame[line],
                    y: rulerOrigin.y + (lineRect.height - labelFont.pointSize - 2) / 2
                )
            }
            let label = "\(line)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let labelRect = NSRect(
                x: bounds.maxX - labelSize.width - 9 - (importFolding?.region == nil ? 0 : 14),
                y: rulerOrigin.y + (lineRect.height - labelSize.height) / 2,
                width: labelSize.width,
                height: labelSize.height
            )
            label.draw(in: labelRect, withAttributes: attributes)
            if let folding = importFolding, let region = folding.region,
               line == lineIndex.lineNumber(containingUTF16Offset: region.keywordRange.location) {
                let toggleRect = NSRect(x: bounds.maxX - 14, y: labelRect.minY, width: 14, height: labelRect.height)
                importToggleRect = toggleRect
                let symbol = folding.isExpanded ? "chevron.down" : "chevron.right"
                NSImage(systemSymbolName: symbol, accessibilityDescription: "折叠或展开 import")?
                    .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))?
                    .draw(in: toggleRect.insetBy(dx: 3, dy: 3))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let importToggleRect, importToggleRect.contains(convert(event.locationInWindow, from: nil)) {
            importFolding?.toggle()
            needsDisplay = true
            return
        }
        super.mouseDown(with: event)
    }

    private func drawGitBlame(_ blame: NativeGitBlameAnnotation?, y: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let color = blame?.isUncommitted != false
            ? NSColor.secondaryLabelColor
            : NSColor.labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let date = blame?.authoredAt.map(Self.blameDateFormatter.string(from:)) ?? ""
        let author = blame?.author ?? ""
        let hash = blame?.isUncommitted != false
            ? ""
            : String(blame?.commitHash.prefix(8) ?? "")

        (date as NSString).draw(
            in: NSRect(x: 7, y: y, width: 58, height: 14),
            withAttributes: attributes
        )
        (author as NSString).draw(
            in: NSRect(x: 69, y: y, width: 92, height: 14),
            withAttributes: attributes
        )
        (hash as NSString).draw(
            in: NSRect(x: 165, y: y, width: 54, height: 14),
            withAttributes: secondaryAttributes
        )
    }
}

/// A small AppKit-backed editor surface. The unbounded text container is intentional:
/// code lines scroll horizontally instead of wrapping to the SwiftUI proposal width.
struct NativeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    var style: NativeTextStyle = .plain
    var scrollToLine: Int? = nil
    var navigationRequest: NativeTextNavigationRequest? = nil
    var showsLineNumbers = false
    var gitBlame: [Int: NativeGitBlameAnnotation]? = nil
    var canToggleGitBlame = false
    var onToggleGitBlame: (() -> Void)? = nil
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

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            style: style,
            gitBlame: gitBlame,
            canToggleGitBlame: canToggleGitBlame,
            onToggleGitBlame: onToggleGitBlame,
            onRequestGoToLine: onRequestGoToLine,
            onVisibleLineChange: onVisibleLineChange,
            onNavigationHandled: onNavigationHandled,
            followsTail: followsTail,
            contentIdentity: contentIdentity,
            fontSize: fontSize,
            contentSearch: contentSearch,
            semanticTokens: semanticTokens
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
        NativeTextStyler.apply(
            text,
            style: style,
            fontSize: fontSize,
            semanticTokens: semanticTokens,
            to: textView
        )
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
        context.coordinator.text = $text
        context.coordinator.gitBlame = gitBlame
        context.coordinator.canToggleGitBlame = canToggleGitBlame
        context.coordinator.onToggleGitBlame = onToggleGitBlame
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
        let contentIdentityChanged = context.coordinator.contentIdentity != contentIdentity
        context.coordinator.style = style
        context.coordinator.fontSize = fontSize
        context.coordinator.contentIdentity = contentIdentity
        context.coordinator.configureLineNumbers(showsLineNumbers, in: scrollView)
        context.coordinator.configureFont(in: textView)
        textView.isEditable = isEditable
        let textChanged = textView.string != text
        let visibleOrigin = scrollView.contentView.bounds.origin
        let shouldFollowTail = context.coordinator.isFollowingTail
        if textChanged || styleChanged || contentIdentityChanged {
            context.coordinator.beginScrollAdjustment()
            let selection = textView.selectedRange()
            NativeTextStorageUpdater.update(
                text,
                style: style,
                fontSize: fontSize,
                semanticTokens: semanticTokens,
                styleChanged: styleChanged,
                mode: contentIdentityChanged
                    ? .replace
                    : (contentIdentity == nil ? .verifyAppend : .appendOnly),
                in: textView
            )
            context.coordinator.lastAppliedSemanticTokens = semanticTokens
            context.coordinator.invalidateContentSearch()
            context.coordinator.resetExternalNavigation()
            context.coordinator.configureImportFolding(enabled: foldsJavaImports, expanded: importsExpanded, sourceChanged: true)
            context.coordinator.refreshLineNumbers()
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
        var canToggleGitBlame: Bool
        var onToggleGitBlame: (() -> Void)?
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

        init(
            text: Binding<String>,
            style: NativeTextStyle,
            gitBlame: [Int: NativeGitBlameAnnotation]?,
            canToggleGitBlame: Bool,
            onToggleGitBlame: (() -> Void)?,
            onRequestGoToLine: ((_ currentLine: Int, _ lineCount: Int) -> Void)?,
            onVisibleLineChange: ((Int) -> Void)?,
            onNavigationHandled: ((UUID) -> Void)?,
            followsTail: Binding<Bool>?,
            contentIdentity: String?,
            fontSize: CGFloat,
            contentSearch: ContentSearchPresentation?,
            semanticTokens: [JavaSemanticToken]
        ) {
            self.text = text
            self.style = style
            self.gitBlame = gitBlame
            self.canToggleGitBlame = canToggleGitBlame
            self.onToggleGitBlame = onToggleGitBlame
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
        }

        func configureGitBlame() {
            lineNumberRuler?.configureGitBlame(
                gitBlame,
                canToggle: canToggleGitBlame,
                onToggle: onToggleGitBlame
            )
        }

        func configureFont(in textView: NSTextView) {
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            guard textView.font?.fontName != font.fontName
                    || textView.font?.pointSize != font.pointSize else { return }
            textView.font = font
        }

        func refreshLineNumbers() {
            guard let textView else { return }
            lineIndex = SourceLineIndex(text: textView.string)
            lineNumberRuler?.refresh(text: textView.string)
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
            lineNumberRuler?.needsDisplay = true
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
            text.wrappedValue = textView.string
            let selection = textView.selectedRange()
            isApplyingStyle = true
            NativeTextStyler.apply(
                textView.string,
                style: style,
                fontSize: fontSize,
                semanticTokens: semanticTokens,
                to: textView
            )
            lastAppliedSemanticTokens = semanticTokens
            textView.setSelectedRange(selection)
            isApplyingStyle = false
            configureImportFolding(enabled: foldsJavaImports, expanded: importsExpanded, sourceChanged: true)
            refreshLineNumbers()
            invalidateContentSearch()
            applyContentSearch(contentSearch)
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
            if let line = centerVisibleLine(in: scrollView) {
                onVisibleLineChange?(line)
            }
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

        private func centerVisibleLine(in scrollView: NSScrollView) -> Int? {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            layoutManager.ensureLayout(forBoundingRect: textView.visibleRect, in: textContainer)
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: textView.visibleRect,
                in: textContainer
            )
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
            guard line != lastReportedVisibleLine else { return nil }
            lastReportedVisibleLine = line
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

@MainActor
private enum NativeTextStyler {
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
