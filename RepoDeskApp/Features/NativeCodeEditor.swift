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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self,
           modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            goToLineHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class NativeLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineIndex = SourceLineIndex(text: "")
    private var gitBlame: [Int: NativeGitBlameAnnotation]?
    private var canToggleGitBlame = false
    private var onToggleGitBlame: (() -> Void)?

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
        let lineNumberWidth = max(40, ceil(CGFloat(digits) * digitWidth + 18))
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
        guard canToggleGitBlame, onToggleGitBlame != nil else {
            return super.menu(for: event)
        }
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

        for line in firstLine...max(firstLine, lastLine) {
            let start = lineIndex.lineStartOffsets[line - 1]
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
                drawGitBlame(
                    gitBlame[line],
                    y: rulerOrigin.y + (lineRect.height - labelFont.pointSize - 2) / 2
                )
            }
            let label = "\(line)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let labelRect = NSRect(
                x: bounds.maxX - labelSize.width - 9,
                y: rulerOrigin.y + (lineRect.height - labelSize.height) / 2,
                width: labelSize.width,
                height: labelSize.height
            )
            label.draw(in: labelRect, withAttributes: attributes)
        }
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
            .foregroundColor: NSColor.tertiaryLabelColor
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
            contentSearch: contentSearch
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
        NativeTextStyler.apply(text, style: style, fontSize: fontSize, to: textView)
        context.coordinator.refreshLineNumbers()
        context.coordinator.scrollIfNeeded(to: scrollToLine)
        context.coordinator.navigateIfNeeded(to: navigationRequest)
        context.coordinator.scrollToTailIfFollowing()
        context.coordinator.applyContentSearch(contentSearch)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.gitBlame = gitBlame
        context.coordinator.canToggleGitBlame = canToggleGitBlame
        context.coordinator.onToggleGitBlame = onToggleGitBlame
        context.coordinator.onRequestGoToLine = onRequestGoToLine
        context.coordinator.onVisibleLineChange = onVisibleLineChange
        context.coordinator.onNavigationHandled = onNavigationHandled
        context.coordinator.followsTail = followsTail
        context.coordinator.contentSearch = contentSearch
        let styleChanged = context.coordinator.style != style
            || context.coordinator.fontSize != fontSize
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
                styleChanged: styleChanged,
                mode: contentIdentityChanged
                    ? .replace
                    : (contentIdentity == nil ? .verifyAppend : .appendOnly),
                in: textView
            )
            context.coordinator.invalidateContentSearch()
            context.coordinator.resetExternalNavigation()
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
        context.coordinator.scrollIfNeeded(to: scrollToLine)
        context.coordinator.navigateIfNeeded(to: navigationRequest)
        context.coordinator.scrollToTailIfFollowing()
        context.coordinator.applyContentSearch(contentSearch)
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
        weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private var lineNumberRuler: NativeLineNumberRulerView?
        private var lineIndex = SourceLineIndex(text: "")
        private var isApplyingStyle = false
        private var isAdjustingScroll = false
        private var lastScrolledLine: Int?
        private var lastNavigationRequestID: UUID?
        private var lastContentSearchNavigationRequestID: UUID?
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
            contentSearch: ContentSearchPresentation?
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

        func requestGoToLine() {
            guard let textView, let onRequestGoToLine else { return }
            let index = SourceLineIndex(text: textView.string)
            let currentLine = index.lineNumber(containingUTF16Offset: textView.selectedRange().location)
            onRequestGoToLine(currentLine, index.lineCount)
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
                to: textView
            )
            textView.setSelectedRange(selection)
            isApplyingStyle = false
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
            textView.showFindIndicator(for: activeRange)
            center(activeRange, in: textView)
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
            navigate(to: request.line)
            lastNavigationRequestID = request.id
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
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            if range.length > 0 {
                textView.showFindIndicator(for: range)
            }
            center(range, in: textView)
            textView.window?.makeFirstResponder(textView)
        }

        private func center(_ range: NSRange, in textView: NSTextView) {
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
            let line = firstLine + (lastLine - firstLine) / 2
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
        NativeTextStyler.apply(text, style: style, fontSize: fontSize, to: textView)
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
