import AppKit

/// Source offsets stay unchanged: the import body has zero layout advancement.
struct JavaImportRegion: Equatable {
    let keywordRange: NSRange
    let hiddenRange: NSRange

    static func find(in text: String) -> JavaImportRegion? {
        let source = text as NSString
        let trivia = try! NSRegularExpression(pattern: #"(?:\s+|\uFEFF|//[^\r\n]*(?:\r\n|\r|\n|$)|/\*[\s\S]*?\*/)*"#)
        let declaration = try! NSRegularExpression(
            pattern: #"(package|import)\s+(?:static\s+)?[\p{L}_$][\p{L}\p{N}_$]*(?:\s*\.\s*(?:[\p{L}_$][\p{L}\p{N}_$]*|\*))*\s*;"#
        )
        var cursor = 0
        var firstImport: NSRange?
        var lastImport: NSRange?
        var sawPackage = false
        while cursor < source.length {
            let remaining = NSRange(location: cursor, length: source.length - cursor)
            if let match = trivia.firstMatch(in: text, options: .anchored, range: remaining) {
                cursor = NSMaxRange(match.range)
            }
            guard cursor < source.length,
                  let match = declaration.firstMatch(
                    in: text, options: .anchored,
                    range: NSRange(location: cursor, length: source.length - cursor)
                  ) else { break }
            let keyword = source.substring(with: match.range(at: 1))
            if keyword == "package" {
                guard firstImport == nil, !sawPackage else { break }
                sawPackage = true
            } else {
                if firstImport == nil { firstImport = match.range }
                lastImport = match.range
            }
            cursor = NSMaxRange(match.range)
        }
        guard let firstImport, let lastImport else { return nil }
        let keywordRange = NSRange(location: firstImport.location, length: 6)
        return JavaImportRegion(
            keywordRange: keywordRange,
            hiddenRange: NSRange(
                location: NSMaxRange(keywordRange),
                length: NSMaxRange(lastImport) - NSMaxRange(keywordRange)
            )
        )
    }
}

@MainActor
final class NativeJavaImportFolding: NSObject, @preconcurrency NSLayoutManagerDelegate {
    private weak var textView: NSTextView?
    private(set) var region: JavaImportRegion?
    private(set) var isExpanded = false
    var onExpansionChange: ((Bool) -> Void)?
    var onLayoutChange: (() -> Void)?
    private let placeholder = NSButton(title: "...", target: nil, action: nil)
    private var hasConfiguredSource = false

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        textView.layoutManager?.delegate = self
        placeholder.target = self
        placeholder.action = #selector(toggle)
        placeholder.bezelStyle = .inline
        placeholder.attributedTitle = NSAttributedString(
            string: "...", attributes: [.foregroundColor: NSColor.systemRed]
        )
        placeholder.isBordered = false
        placeholder.wantsLayer = true
        placeholder.layer?.cornerRadius = 2
        placeholder.toolTip = "展开 import"
        placeholder.setAccessibilityIdentifier("RepoDesk.JavaImports.Expand")
        placeholder.setAccessibilityLabel("展开 import")
        placeholder.isHidden = true
        textView.addSubview(placeholder)
    }

    func configure(enabled: Bool, expanded: Bool, sourceChanged: Bool) {
        guard let textView else { return }
        let oldRegion = region
        let oldExpanded = isExpanded
        if sourceChanged || !hasConfiguredSource || !enabled {
            region = enabled ? JavaImportRegion.find(in: textView.string) : nil
            hasConfiguredSource = true
        }
        isExpanded = expanded
        if oldRegion != region || oldExpanded != expanded {
            invalidateLayout()
        }
        updatePlaceholder()
    }

    @objc func toggle() {
        setExpanded(!isExpanded)
    }

    func reveal(_ range: NSRange) {
        guard let region, !isExpanded else { return }
        let hidden = region.hiddenRange
        if NSIntersectionRange(hidden, range).length > 0
            || (range.length == 0 && NSLocationInRange(range.location, hidden)) {
            setExpanded(true)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard region != nil, isExpanded != expanded else { return }
        isExpanded = expanded
        if !expanded, let textView, let region,
           NSLocationInRange(textView.selectedRange().location, region.hiddenRange) {
            textView.setSelectedRange(NSRange(location: region.keywordRange.location, length: 0))
        }
        invalidateLayout()
        updatePlaceholder()
        onLayoutChange?()
        onExpansionChange?(expanded)
    }

    private func invalidateLayout() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        layoutManager.invalidateGlyphs(
            forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length),
            changeInLength: 0, actualCharacterRange: nil
        )
        textView.needsDisplay = true
        textView.invalidateIntrinsicContentSize()
    }

    func updatePlaceholder() {
        guard let textView, let region, !isExpanded,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            placeholder.isHidden = true
            return
        }
        layoutManager.ensureLayout(forCharacterRange: region.keywordRange)
        let glyphs = layoutManager.glyphRange(forCharacterRange: region.keywordRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        placeholder.font = textView.font
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            placeholder.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.1).cgColor
        }
        placeholder.frame = NSRect(
            x: rect.maxX + textView.textContainerOrigin.x + 4,
            y: rect.minY + textView.textContainerOrigin.y,
            width: max(28, (textView.font?.pointSize ?? 13) * 2.2), height: rect.height
        )
        placeholder.isHidden = false
    }

    func isHidden(lineStart: Int) -> Bool {
        guard let region, !isExpanded else { return false }
        return NSLocationInRange(lineStart, region.hiddenRange)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard let region, !isExpanded,
              NSLocationInRange(charIndex, region.hiddenRange) else { return action }
        return .zeroAdvancement
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let region, !isExpanded else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for index in properties.indices where NSLocationInRange(charIndexes[index], region.hiddenRange) {
            // Large runs of .null glyphs corrupt NSATSTypesetter's paragraph ranges,
            // merging visible lines after the fold. Control glyphs retain the source
            // mapping while the delegate above suppresses their width and line breaks.
            properties[index] = .controlCharacter
            changed = true
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(
            glyphs, properties: properties, characterIndexes: charIndexes,
            font: font, forGlyphRange: glyphRange
        )
        return glyphRange.length
    }
}
