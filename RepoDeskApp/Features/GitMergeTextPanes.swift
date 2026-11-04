import AppKit
import SwiftUI

@MainActor @Observable
final class GitMergeEditorState {
    var document: GitThreeWayMergeDocument
    let undoManager = UndoManager()
    @ObservationIgnored var commitPendingText: (() -> Void)?
    init(document: GitThreeWayMergeDocument) { self.document = document }
    func change(_ operation: (inout GitThreeWayMergeDocument) -> Void) {
        let previous = document
        var next = previous
        operation(&next)
        guard next != previous else { return }
        replace(next)
    }
    private func replace(_ value: GitThreeWayMergeDocument) {
        let previous = document
        undoManager.registerUndo(withTarget: self) { $0.replace(previous) }
        document = value
    }
}

enum GitMergeHighlight: String, CaseIterable { case words = "Highlight words", characters = "Highlight characters", lines = "Highlight lines", none = "Do not highlight" }
@MainActor @Observable
final class GitMergeViewSettings {
    var highlight = GitMergeHighlight.words
    var showLineNumbers = true
    var showWhitespaces = false
    var showIndentGuides = false
    var softWrap = false
    var syntaxHighlighting = true
    var breadcrumbs = "Don't show"
}

/// The native editor region owns its clipping, gutters and connecting dividers.
/// A gutter action targets its change ID, independently of caret/navigation.
@MainActor
struct GitMergeTextPanes: NSViewRepresentable {
    let state: GitMergeEditorState
    let selectedID: Int?
    let fontSize: CGFloat
    let collapsed: Bool
    let syncScroll: Bool
    let onSelect: (Int) -> Void
    var onExpand: () -> Void = {}
    var settings: GitMergeViewSettings? = nil
    var fileExtension = "txt"
    var onNavigate: (Int) -> Void = { _ in }
    var onCompareClipboard: (String) -> Void = { _ in }
    var onAnnotate: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> MergeCanvasView { context.coordinator.makeView() }
    func updateNSView(_ nsView: MergeCanvasView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.enabled = context.environment.isEnabled
        context.coordinator.update()
    }
    static func dismantleNSView(_ nsView: MergeCanvasView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GitMergeTextPanes
        var enabled = true
        let fallbackSettings = GitMergeViewSettings()
        var settings: GitMergeViewSettings { parent.settings ?? fallbackSettings }
        var canvas: MergeCanvasView!
        var scrolls: [NSScrollView] = []
        var texts: [MergeCodeTextView] = []
        var gutters: [MergeChangeGutter] = []
        var dividers: [MergeChangeDivider] = []
        var offsets: [[Int]] = []
        var updating = false, scrolling = false
        var lastSelectedID: Int?
        var nativeSelectionID: Int?
        var lastStyleKey = ""
        var lastDocument: GitThreeWayMergeDocument?
        init(_ parent: GitMergeTextPanes) { self.parent = parent }

        func makeView() -> MergeCanvasView {
            canvas = MergeCanvasView()
            canvas.coordinator = self
            canvas.setAccessibilityIdentifier("RepoDesk.MergeConflictEditor.Canvas")
            for pane in 0..<3 {
                let scroll = NSScrollView()
                scroll.borderType = .noBorder
                scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
                scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
                scroll.automaticallyAdjustsContentInsets = false
                scroll.wantsLayer = true; scroll.layer?.masksToBounds = true
                scroll.backgroundColor = .textBackgroundColor
                scroll.identifier = NSUserInterfaceItemIdentifier("RepoDesk.MergeConflictEditor.\(["yours", "result", "theirs"][pane]).Document")
                let text = MergeCodeTextView(frame: .zero)
                text.isRichText = false; text.importsGraphics = false
                text.isEditable = pane == 1; text.isSelectable = true
                text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
                text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
                text.isContinuousSpellCheckingEnabled = false; text.allowsUndo = false
                text.mergeUndoManager = parent.state.undoManager
                text.isVerticallyResizable = true; text.isHorizontallyResizable = true
                text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                text.textContainerInset = NSSize(width: 4, height: 6)
                text.textContainer?.widthTracksTextView = false
                text.textContainer?.lineFragmentPadding = 0
                text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                text.delegate = self
                text.wantsLayer = true; text.layer?.masksToBounds = true
                text.setAccessibilityIdentifier("RepoDesk.MergeConflictEditor.\(["yours", "result", "theirs"][pane]).Text")
                scroll.documentView = text
                let gutter = MergeChangeGutter(pane: pane)
                gutter.coordinator = self
                canvas.addSubview(scroll); canvas.addSubview(gutter)
                texts.append(text); scrolls.append(scroll); gutters.append(gutter)
                scroll.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
                text.contextMenu = { [weak self] event in self?.menu(for: pane, event: event) }
                text.navigate = parent.onNavigate
            }
            for side in 0..<2 {
                let divider = MergeChangeDivider(side: side)
                divider.coordinator = self; dividers.append(divider); canvas.addSubview(divider)
            }
            canvas.relayout = { [weak self] in self?.layout() }
            parent.state.commitPendingText = { [weak self] in self?.commitText() }
            texts[1].compositionEnded = { [weak self] in self?.commitText() }
            update()
            return canvas
        }
        func stop() { NotificationCenter.default.removeObserver(self); parent.state.commitPendingText = nil }
        func commitText() {
            guard texts.count == 3 else { return }
            texts[1].unmarkText()
            guard !texts[1].hasMarkedText() else { return }
            parent.state.change { $0.editResult(texts[1].string) }
        }
        func update() {
            guard texts.count == 3 else { return }
            updating = true
            defer { updating = false }
            texts[1].isEditable = enabled
            let document = parent.state.document
            let strings = [document.ours, document.result, document.theirs]
            let key = "\(parent.fontSize)|\(parent.collapsed)|\(settings.highlight)|\(settings.showLineNumbers)|\(settings.showWhitespaces)|\(settings.showIndentGuides)|\(settings.softWrap)|\(settings.syntaxHighlighting)"
            if document != lastDocument || key != lastStyleKey {
                offsets = strings.map(Self.lineOffsets)
                for pane in 0..<3 {
                    let text = texts[pane]
                    if text.string != strings[pane], !text.hasMarkedText() {
                        let selection = text.selectedRange()
                        text.string = strings[pane]
                        text.setSelectedRange(NSRange(location: min(selection.location, (text.string as NSString).length), length: 0))
                    }
                    text.navigate = parent.onNavigate
                    text.expandFold = parent.onExpand
                    text.showIndentGuides = settings.showIndentGuides
                    text.layoutManager?.showsInvisibleCharacters = settings.showWhitespaces
                    style(pane)
                }
                lastDocument = document; lastStyleKey = key
            }
            layout()
            if parent.selectedID != lastSelectedID {
                lastSelectedID = parent.selectedID
                if parent.selectedID == nativeSelectionID { nativeSelectionID = nil }
                else if let change = document.changes.first(where: { $0.id == parent.selectedID }) {
                    for pane in 0..<3 {
                        let r = range(change, pane)
                        let y = documentY(r.start, pane)
                        scrolls[pane].contentView.scroll(to: NSPoint(x: scrolls[pane].contentView.bounds.minX, y: max(0, y - parent.fontSize * 4)))
                        scrolls[pane].reflectScrolledClipView(scrolls[pane].contentView)
                    }
                }
            }
            redrawDecorations()
        }
        func layout() {
            guard canvas != nil, scrolls.count == 3 else { return }
            let previous = updating; updating = true
            defer { updating = previous }
            let width = max(0, (canvas.bounds.width - 64) / 3), height = canvas.bounds.height
            for pane in 0..<3 {
                let origin = CGFloat(pane) * (width + 32)
                let gutterWidth: CGFloat = pane == 1 ? (settings.showLineNumbers ? 42 : 16) : (settings.showLineNumbers ? 72 : 44)
                let gutterX = pane == 0 ? origin + width - gutterWidth : origin
                let codeX = pane == 0 ? origin : origin + gutterWidth
                gutters[pane].frame = NSRect(x: gutterX, y: 0, width: gutterWidth, height: height)
                scrolls[pane].frame = NSRect(x: codeX, y: 0, width: max(0, width - gutterWidth), height: height)
                scrolls[pane].tile()
                texts[pane].fitDocument(wrap: settings.softWrap)
            }
            for side in 0..<2 {
                dividers[side].frame = NSRect(x: CGFloat(side + 1) * width + CGFloat(side) * 32, y: 0, width: 32, height: height)
            }
            redrawDecorations()
        }
        private func style(_ pane: Int) {
            let text = texts[pane]
            guard let storage = text.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let font = GitMergeAppearance.codeFont(parent.fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = ceil(parent.fontSize * 1.5)
            paragraph.maximumLineHeight = ceil(parent.fontSize * 1.5)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph], range: full)
            if settings.syntaxHighlighting { GitMergeSyntax.apply(text.string, fileExtension: parent.fileExtension, font: font, to: storage) }
            text.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
            text.bands = []; text.foldMarkers = []
            var visibleLines = Set<Int>()
            let document = parent.state.document
            for change in document.changes {
                let r = range(change, pane)
                let start = Self.line(r.start, offsets[pane]), end = Self.line(r.end, offsets[pane])
                for line in max(0, start - 3)...min(offsets[pane].count - 1, end + 3) { visibleLines.insert(line) }
                let sideResolved = pane == 1 ? change.isResolved : (pane == 0 ? change.oursState : change.theirsState) != .pending
                guard !sideResolved, settings.highlight != .none else { continue }
                let color = color(change)
                text.bands.append((r, color.withAlphaComponent(0.32)))
                guard r.length > 0 else { continue }
                if settings.highlight == .words || settings.highlight == .characters {
                    let baseText = GitThreeWayMergeDocument.slice(document.base, change.baseRange)
                    let current = GitThreeWayMergeDocument.slice(text.string, r)
                    let comparison: String
                    if pane == 1 {
                        comparison = change.theirsState == .pending ? document.content(.theirs, change: change) : document.content(.ours, change: change)
                    } else { comparison = baseText }
                    for inner in GitMergeSyntax.changedRanges(current, comparedTo: comparison, words: settings.highlight == .words) {
                        storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.8), range: NSRange(location: r.start + inner.location, length: inner.length))
                    }
                }
            }
            if parent.collapsed, !document.changes.isEmpty {
                let hidden = NSMutableParagraphStyle(); hidden.minimumLineHeight = 0.01; hidden.maximumLineHeight = 0.01
                var first: Int?
                for line in offsets[pane].indices {
                    if !visibleLines.contains(line) {
                        if first == nil { first = line }
                        let start = offsets[pane][line], end = line + 1 < offsets[pane].count ? offsets[pane][line + 1] : storage.length
                        if end > start { storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .paragraphStyle: hidden, .foregroundColor: NSColor.clear], range: NSRange(location: start, length: end - start)) }
                    } else if let initial = first {
                        text.foldMarkers.append((offsets[pane][initial], line - initial)); first = nil
                    }
                }
                if let first { text.foldMarkers.append((offsets[pane][first], offsets[pane].count - first)) }
                // Reserve one normal-height row for each folded fragment's marker.
                for (offset, _) in text.foldMarkers where offset < storage.length {
                    let end = NSMaxRange((text.string as NSString).lineRange(for: NSRange(location: offset, length: 0)))
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: offset, length: end - offset))
                }
            }
            storage.endEditing()
            text.needsDisplay = true
        }
        func range(_ change: GitMergeChange, _ pane: Int) -> GitMergeTextRange {
            pane == 0 ? change.oursRange : pane == 1 ? change.resultRange : change.theirsRange
        }
        func color(_ change: GitMergeChange) -> NSColor {
            if change.isConflict { return GitMergeAppearance.conflict }
            if change.baseRange.length == 0 { return GitMergeAppearance.added }
            if change.oursRange.length == 0 || change.theirsRange.length == 0 { return GitMergeAppearance.deleted }
            return GitMergeAppearance.modified
        }
        func documentY(_ offset: Int, _ pane: Int) -> CGFloat {
            let text = texts[pane]
            guard let layout = text.layoutManager, let container = text.textContainer else { return 0 }
            layout.ensureLayout(for: container)
            let clamped = min(offset, (text.string as NSString).length)
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: clamped, length: 0), actualCharacterRange: nil).location
            let y = glyph < layout.numberOfGlyphs ? layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY : layout.usedRect(for: container).maxY
            return y + text.textContainerInset.height
        }
        func rect(_ change: GitMergeChange, _ pane: Int) -> NSRect {
            let r = range(change, pane), scroll = scrolls[pane]
            let top = documentY(r.start, pane) - scroll.contentView.bounds.minY
            let bottom = documentY(r.end, pane) - scroll.contentView.bounds.minY
            return NSRect(x: 0, y: top, width: gutters[pane].bounds.width, height: max(1, bottom - top))
        }
        func redrawDecorations() {
            for gutter in gutters { gutter.updateActions(); gutter.needsDisplay = true }
            for divider in dividers { divider.needsDisplay = true }
        }
        func perform(_ changeID: Int, pane: Int, action: String, flags: NSEvent.ModifierFlags = []) {
            guard enabled else { return }
            nativeSelectionID = changeID == parent.selectedID ? nil : changeID; parent.onSelect(changeID)
            parent.state.commitPendingText?()
            parent.state.change { document in
                let side: GitConflictSide = pane == 0 ? .ours : .theirs
                switch action {
                case "Accept": document.accept(changeID, side: side, resolveBoth: flags.contains(.control))
                case "Ignore": document.ignore(changeID, side: side, resolveBoth: flags.contains(.control))
                case "ResolveLeft": document.accept(changeID, side: .ours, resolveBoth: true)
                case "ResolveRight": document.accept(changeID, side: .theirs, resolveBoth: true)
                case "Resolve": document.resolveSimpleConflict(changeID)
                case "Reset": document.reset(changeID)
                default: document.markResolved(changeID)
                }
            }
            update()
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if parent.collapsed, textView === texts[1] { parent.onExpand() }
            return enabled && textView === texts[1]
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, notification.object as? NSTextView === texts[1], !texts[1].hasMarkedText() else { return }
            parent.state.change { $0.editResult(texts[1].string) }
            update()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView, let pane = texts.firstIndex(where: { $0 === text }) else { return }
            if let change = change(at: text.selectedRange().location, pane: pane) {
                nativeSelectionID = change.id == parent.selectedID ? nil : change.id; parent.onSelect(change.id)
            }
        }
        func change(at offset: Int, pane: Int) -> GitMergeChange? {
            parent.state.document.changes.first { let r = range($0, pane); return offset >= r.start && offset <= r.end }
        }
        @objc private func scrolled(_ notification: Notification) {
            guard !updating, !scrolling, let clip = notification.object as? NSClipView,
                  let source = scrolls.firstIndex(where: { $0.contentView === clip }) else { return }
            scrolling = true
            defer { scrolling = false; redrawDecorations() }
            guard parent.syncScroll, let layout = texts[source].layoutManager, let container = texts[source].textContainer,
                  layout.numberOfGlyphs > 0 else { return }
            let point = NSPoint(x: 0, y: max(0, clip.bounds.minY - texts[source].textContainerInset.height))
            let glyph = min(layout.glyphIndex(for: point, in: container), layout.numberOfGlyphs - 1)
            let character = layout.characterIndexForGlyph(at: glyph)
            let line = Self.line(character, offsets[source])
            let residual = clip.bounds.minY - documentY(offsets[source][line], source)
            for target in 0..<3 where target != source {
                let targetLine = mappedLine(line, from: source, to: target)
                let y = documentY(offsets[target][targetLine], target) + residual
                let scroll = scrolls[target], text = texts[target]
                scroll.contentView.scroll(to: NSPoint(x: min(max(0, clip.bounds.minX), max(0, text.frame.width - scroll.contentView.bounds.width)),
                                                      y: min(max(0, y), max(0, text.frame.height - scroll.contentView.bounds.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        private func mappedLine(_ line: Int, from: Int, to: Int) -> Int {
            var anchors = [(0, 0)]
            for change in parent.state.document.changes {
                let a = range(change, from), b = range(change, to)
                anchors.append((Self.line(a.start, offsets[from]), Self.line(b.start, offsets[to])))
                anchors.append((Self.line(a.end, offsets[from]), Self.line(b.end, offsets[to])))
            }
            anchors.append((offsets[from].count - 1, offsets[to].count - 1))
            for i in 1..<anchors.count where line <= anchors[i].0 {
                let a = anchors[i - 1], b = anchors[i]
                return min(offsets[to].count - 1, max(0, b.0 == a.0 ? b.1 : a.1 + Int(Double(line - a.0) * Double(b.1 - a.1) / Double(b.0 - a.0))))
            }
            return offsets[to].count - 1
        }
        static func lineOffsets(_ text: String) -> [Int] { [0] + text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil } }
        static func line(_ offset: Int, _ values: [Int]) -> Int {
            var low = 0, high = values.count
            while low < high { let mid = (low + high) / 2; if values[mid] <= offset { low = mid + 1 } else { high = mid } }
            return max(0, low - 1)
        }
        func menu(for pane: Int, event: NSEvent) -> NSMenu {
            let text = texts[pane]
            let point = text.convert(event.locationInWindow, from: nil)
            let character = text.characterIndexForInsertion(at: point)
            let selected = text.selectedRange()
            let changes = parent.state.document.changes.filter {
                let r = range($0, pane)
                return selected.length > 0 ? NSIntersectionRange(r.nsRange, selected).length > 0 : (character >= r.start && character <= r.end)
            }
            let menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
                let item = MergeMenuItem(title: title, enabled: enabled && self.enabled, action: action)
                menu.addItem(item)
            }
            let leftPending = changes.contains { !$0.isResolved && $0.oursState == .pending && parent.state.document.isChange($0, side: .ours) }
            let rightPending = changes.contains { !$0.isResolved && $0.theirsState == .pending && parent.state.document.isChange($0, side: .theirs) }
            add("Accept Left Side", enabled: leftPending) { for c in changes { self.perform(c.id, pane: 0, action: "Accept") } }
            add("Accept Right Side", enabled: rightPending) { for c in changes { self.perform(c.id, pane: 2, action: "Accept") } }
            add("Resolve using Left", enabled: leftPending) { for c in changes { self.perform(c.id, pane: pane, action: "ResolveLeft") } }
            add("Resolve using Right", enabled: rightPending) { for c in changes { self.perform(c.id, pane: pane, action: "ResolveRight") } }
            add("Ignore Left Side", enabled: leftPending) { for c in changes { self.perform(c.id, pane: 0, action: "Ignore") } }
            add("Ignore Right Side", enabled: rightPending) { for c in changes { self.perform(c.id, pane: 2, action: "Ignore") } }
            add("Resolve Simple Conflicts", enabled: changes.contains { parent.state.document.simpleResolution(for: $0) != nil }) { for c in changes { self.perform(c.id, pane: pane, action: "Resolve") } }
            add("Ignore", enabled: changes.contains { !$0.isResolved }) { for c in changes { self.perform(c.id, pane: pane, action: "Mark") } }
            add("Reset Change", enabled: changes.contains(where: \.isResolved)) { for c in changes where c.isResolved { self.perform(c.id, pane: pane, action: "Reset") } }
            menu.addItem(.separator())
            add("Undo", enabled: parent.state.undoManager.canUndo) { self.parent.state.undoManager.undo() }
            add("Redo", enabled: parent.state.undoManager.canRedo) { self.parent.state.undoManager.redo() }
            add("Cut", enabled: pane == 1 && selected.length > 0) { text.cut(nil) }
            add("Copy", enabled: selected.length > 0) { text.copy(nil) }
            add("Paste", enabled: pane == 1) { text.paste(nil) }
            add("Select All") { text.selectAll(nil) }
            menu.addItem(.separator())
            add("Compare with Clipboard") { self.parent.onCompareClipboard(text.string) }
            add("Annotate with Git Blame") { self.parent.onAnnotate() }
            return menu
        }
    }
}

@MainActor final class MergeCanvasView: NSView {
    weak var coordinator: GitMergeTextPanes.Coordinator?
    var relayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); relayout?() }
}

@MainActor final class MergeChangeGutter: NSView {
    let pane: Int
    weak var coordinator: GitMergeTextPanes.Coordinator?
    private var buttons: [String: MergeGutterButton] = [:]
    override var isFlipped: Bool { true }
    init(pane: Int) { self.pane = pane; super.init(frame: .zero); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { nil }
    func updateActions() {
        guard let c = coordinator, c.texts.count == 3 else { return }
        var required = Set<String>()
        for change in c.parent.state.document.changes {
            let r = c.rect(change, pane)
            guard r.maxY >= 0, r.minY < bounds.height else { continue }
            var operations: [String] = []
            if pane == 1 {
                if c.parent.state.document.simpleResolution(for: change) != nil { operations = ["Resolve"] }
            } else {
                let side: GitConflictSide = pane == 0 ? .ours : .theirs
                let pending = (pane == 0 ? change.oursState : change.theirsState) == .pending
                if pending && c.parent.state.document.isChange(change, side: side) { operations = ["Ignore", "Accept"] }
            }
            for operation in operations {
                let key = "\(change.id).\(operation)"
                required.insert(key)
                let button = buttons[key] ?? MergeGutterButton()
                if buttons[key] == nil { buttons[key] = button; addSubview(button) }
                let x: CGFloat = pane == 0 ? (operation == "Ignore" ? 8 : 27) : (pane == 1 ? 3 : (operation == "Accept" ? 23 : 43))
                button.frame = NSRect(x: x, y: max(-16, r.minY - 1), width: 18, height: 18)
                button.image = GitMergeAppearance.actionIcon(operation, pane: pane, append: change.hasAppliedSide)
                button.isEnabled = c.enabled
                button.toolTip = operation + (change.isConflict && operation != "Resolve" ? " (Ctrl+Click to resolve conflict)" : "")
                button.setAccessibilityLabel("\(operation) \(pane == 0 ? "Left" : pane == 2 ? "Right" : "Simple Conflict") — change \(change.id + 1)")
                button.identifier = NSUserInterfaceItemIdentifier("RepoDesk.MergeConflictEditor.Block.\(change.id).\(pane).\(operation)")
                let actionPane = pane
                button.handler = { [weak c] flags in c?.perform(change.id, pane: actionPane, action: operation, flags: flags) }
            }
        }
        for key in Array(buttons.keys) where !required.contains(key) { buttons.removeValue(forKey: key)?.removeFromSuperview() }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        guard let c = coordinator, !c.offsets.isEmpty else { return }
        for change in c.parent.state.document.changes {
            let r = c.rect(change, pane)
            let resolved = pane == 1 ? change.isResolved : (pane == 0 ? change.oursState : change.theirsState) != .pending
            if !resolved { c.color(change).withAlphaComponent(0.58).setFill(); r.intersection(bounds).fill() }
        }
        guard c.settings.showLineNumbers else { return }
        let text = c.texts[pane], scroll = c.scrolls[pane]
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: NSRect(x: 0, y: max(0, scroll.contentView.bounds.minY - text.textContainerInset.height), width: text.bounds.width, height: bounds.height + 20), in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = GitMergeTextPanes.Coordinator.line(chars.location, c.offsets[pane])
        let last = GitMergeTextPanes.Coordinator.line(NSMaxRange(chars), c.offsets[pane])
        for line in first...last {
            if text.foldMarkers.contains(where: { offset, count in
                let first = GitMergeTextPanes.Coordinator.line(offset, c.offsets[pane])
                return line >= first && line < first + count
            }) { continue }
            let y = c.documentY(c.offsets[pane][line], pane) - scroll.contentView.bounds.minY
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: c.offsets[pane][line], length: 0), actualCharacterRange: nil).location
            if glyph < layout.numberOfGlyphs, layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height < 2 { continue }
            let label = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: GitMergeAppearance.codeFont(max(10, c.parent.fontSize - 1)), .foregroundColor: NSColor.secondaryLabelColor]
            let width = label.size(withAttributes: attributes).width
            let x = pane == 0 ? bounds.width - width - 5 : (pane == 1 ? bounds.width - width - 8 : 18 - width)
            label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        }
    }
}

@MainActor final class MergeChangeDivider: NSView {
    let side: Int
    weak var coordinator: GitMergeTextPanes.Coordinator?
    override var isFlipped: Bool { true }
    init(side: Int) { self.side = side; super.init(frame: .zero); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        guard let c = coordinator else { return }
        for change in c.parent.state.document.changes {
            let sourcePane = side == 0 ? 0 : 1, targetPane = side == 0 ? 1 : 2
            let source = c.rect(change, sourcePane), target = c.rect(change, targetPane)
            guard min(source.minY, target.minY) < bounds.height, max(source.maxY, target.maxY) > 0 else { continue }
            let resolved = side == 0 ? change.oursState != .pending : change.theirsState != .pending
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: source.minY))
            path.curve(to: NSPoint(x: bounds.width, y: target.minY), controlPoint1: NSPoint(x: bounds.width * 0.4, y: source.minY), controlPoint2: NSPoint(x: bounds.width * 0.6, y: target.minY))
            path.line(to: NSPoint(x: bounds.width, y: target.maxY))
            path.curve(to: NSPoint(x: 0, y: source.maxY), controlPoint1: NSPoint(x: bounds.width * 0.6, y: target.maxY), controlPoint2: NSPoint(x: bounds.width * 0.4, y: source.maxY))
            path.close()
            c.color(change).withAlphaComponent(resolved ? 0.12 : 0.6).setFill(); path.fill()
        }
    }
}

@MainActor final class MergeGutterButton: NSButton {
    var handler: ((NSEvent.ModifierFlags) -> Void)?
    init() {
        super.init(frame: .zero); isBordered = false; imagePosition = .imageOnly
        setButtonType(.momentaryChange); bezelStyle = .regularSquare
        target = self; action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler?(NSApp.currentEvent?.modifierFlags ?? []) }
    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { handler?(event.modifierFlags) } else { super.rightMouseDown(with: event) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor final class MergeMenuItem: NSMenuItem {
    let handler: @MainActor () -> Void
    init(title: String, enabled: Bool, action: @escaping @MainActor () -> Void) {
        handler = action; super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

@MainActor final class MergeCodeTextView: NSTextView {
    var mergeUndoManager: UndoManager?
    var compositionEnded: (() -> Void)?
    var contextMenu: ((NSEvent) -> NSMenu?)?
    var navigate: (Int) -> Void = { _ in }
    var bands: [(GitMergeTextRange, NSColor)] = []
    var foldMarkers: [(Int, Int)] = []
    var expandFold: () -> Void = {}
    var showIndentGuides = false
    override var undoManager: UndoManager? { mergeUndoManager }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(event) ?? super.menu(for: event) }
    override func unmarkText() {
        let composing = hasMarkedText(); super.unmarkText()
        if composing { DispatchQueue.main.async { [weak self] in self?.compositionEnded?() } }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let composing = hasMarkedText(); super.insertText(insertString, replacementRange: replacementRange)
        if composing { DispatchQueue.main.async { [weak self] in self?.compositionEnded?() } }
    }
    func fitDocument(wrap: Bool) {
        guard let layout = layoutManager, let container = textContainer else { return }
        let viewport = enclosingScrollView?.contentView.bounds.size ?? .zero
        let width = max(1, viewport.width - textContainerInset.width * 2)
        container.containerSize = NSSize(width: wrap ? width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isHorizontallyResizable = !wrap
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = NSSize(width: wrap ? viewport.width : max(viewport.width, ceil(used.maxX) + textContainerInset.width * 2 + 4),
                          height: max(viewport.height, ceil(used.maxY) + textContainerInset.height * 2 + 2))
        if frame.origin != .zero || frame.size != size { frame = NSRect(origin: .zero, size: size) }
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer else { return }
        for (range, color) in bands where range.start <= (string as NSString).length {
            let glyph = layout.glyphRange(forCharacterRange: range.nsRange, actualCharacterRange: nil)
            let area: NSRect
            if range.length == 0 {
                area = glyph.location < layout.numberOfGlyphs ? layout.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil) : layout.usedRect(for: container)
            } else { area = layout.boundingRect(forGlyphRange: glyph, in: container) }
            let y = area.minY + textContainerInset.height
            let height = range.length == 0 ? 1 : max(area.height, font?.pointSize ?? 13)
            color.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: height).intersection(rect).fill()
        }
        if showIndentGuides, let font {
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            let advance = (" " as NSString).size(withAttributes: [.font: font]).width
            let source = string as NSString
            let visibleGlyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
            let chars = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
            var offset = source.lineRange(for: NSRange(location: min(chars.location, source.length), length: 0)).location
            while offset < min(source.length, NSMaxRange(chars)) {
                let line = source.lineRange(for: NSRange(location: offset, length: 0))
                let content = source.substring(with: line)
                let spaces = content.prefix { $0 == " " }.count
                let glyph = layout.glyphRange(forCharacterRange: NSRange(location: offset, length: 0), actualCharacterRange: nil).location
                if glyph < layout.numberOfGlyphs {
                    let row = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    if spaces >= 4 { for indent in stride(from: 4, through: spaces, by: 4) {
                        let x = textContainerInset.width + CGFloat(indent) * advance
                        let path = NSBezierPath(); path.lineWidth = 0.5; path.move(to: NSPoint(x: x, y: row.minY + textContainerInset.height)); path.line(to: NSPoint(x: x, y: row.maxY + textContainerInset.height)); path.stroke()
                    } }
                }
                guard NSMaxRange(line) > offset else { break }; offset = NSMaxRange(line)
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout = layoutManager else { return }
        for (offset, count) in foldMarkers {
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: offset, length: 0), actualCharacterRange: nil).location
            guard glyph < layout.numberOfGlyphs else { continue }
            let y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerInset.height
            ("⋯ \(count) lines" as NSString).draw(at: NSPoint(x: textContainerInset.width, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
    override func mouseDown(with event: NSEvent) {
        if let layout = layoutManager {
            let point = convert(event.locationInWindow, from: nil)
            for (offset, _) in foldMarkers {
                let glyph = layout.glyphRange(forCharacterRange: NSRange(location: offset, length: 0), actualCharacterRange: nil).location
                if glyph < layout.numberOfGlyphs {
                    let row = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    if point.y >= row.minY + textContainerInset.height && point.y < row.minY + textContainerInset.height + 20 {
                        expandFold(); return
                    }
                }
            }
        }
        super.mouseDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if !hasMarkedText(), event.keyCode == 98, flags.isEmpty || flags == .shift { navigate(flags.contains(.shift) ? -1 : 1); return true }
        if isEditable, !hasMarkedText(), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if flags == .command { mergeUndoManager?.undo(); return true }
            if flags == [.command, .shift] { mergeUndoManager?.redo(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
