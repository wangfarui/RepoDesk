import AppKit
import SwiftUI
@testable import RepoDesk

private struct BlameColorVerificationError: Error {
    let message: String
}

@main
@MainActor
enum VerifyGitBlameColors {
    static func main() throws {
        _ = NSApplication.shared
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let first = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1, hour: 1))!
        let dates = (0..<6_000).map { calendar.date(byAdding: .day, value: $0, to: first)! }
        let scale = GitBlameColorScale(dates: dates, calendar: calendar)
        let levels = dates.compactMap { scale.level(for: $0) }
        try require(Set(levels) == Set(0..<8), "Thousands of dates must use exactly eight available colors")
        try require(levels == levels.sorted(), "Newer dates must never receive an older color")
        try require(scale == GitBlameColorScale(dates: dates.reversed(), calendar: calendar),
                    "Line order must not affect the file-wide scale")

        let sameDay = first.addingTimeInterval(20 * 3_600)
        let shortDates = [first, sameDay, dates[1], dates[2]]
        let shortScale = GitBlameColorScale(dates: shortDates, calendar: calendar)
        try require(shortScale.level(for: first) == shortScale.level(for: sameDay),
                    "Commits on the same local day must share a color")
        try require(Set(shortDates.compactMap { shortScale.level(for: $0) }).count == 3,
                    "Three distinct days must use no more than three colors")
        let singleDayScale = GitBlameColorScale(dates: [first, sameDay], calendar: calendar)
        try require(singleDayScale.level(for: first) == 3, "A single day must use the middle color")
        try require(singleDayScale.level(for: sameDay) == 3, "Single-day timestamps must agree")
        try require(scale.level(for: nil) == nil, "Missing timestamps must stay neutral")
        try require(GitBlameColorScale(dates: []).level(for: first) == nil,
                    "An empty file must stay neutral")

        // Day lengths around daylight saving changes must not shift bucket boundaries.
        let springDates = (7...10).map {
            calendar.date(from: DateComponents(year: 2026, month: 3, day: $0, hour: 12))!
        }
        let springScale = GitBlameColorScale(dates: springDates, calendar: calendar)
        try require(springDates.compactMap { springScale.level(for: $0) } == [0, 2, 5, 7],
                    "Natural-day buckets must survive daylight saving changes")

        let previewDates = (0..<8).map { calendar.date(byAdding: .month, value: $0 * 6, to: first)! }
        let previewScale = GitBlameColorScale(dates: previewDates, calendar: calendar)
        for dark in [false, true] {
            try verifyContrast(dark: dark)
            try renderPreview(dates: previewDates, scale: previewScale, dark: dark)
            try renderNativePreview(dates: previewDates, dark: dark)
        }
        print("Git blame color verification passed (6,000 dates, calendar boundaries, text contrast, blue intensity, hover/click/scroll, light/dark rendering)")
    }

    private static func verifyContrast(dark: Bool) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var previousBackground: Double?
        for level in 0..<GitBlameColorScale.maximumLevelCount {
            let background = luminance(GitBlamePalette.background(for: level), appearance: appearance)
            let text = luminance(GitBlamePalette.foreground(for: level), appearance: appearance)
            try require(contrast(text, background) >= 4.5,
                        "Blame text must reach 4.5:1 contrast (dark: \(dark), level: \(level))")
            if let previousBackground {
                try require(dark ? background > previousBackground : background < previousBackground,
                            "Blue intensity must increase with commit age level (dark: \(dark), level: \(level))")
            }
            previousBackground = background
        }
        try require(GitBlamePalette.background(for: nil) == .controlBackgroundColor,
                    "Uncommitted and unknown dates must retain a neutral background")
    }

    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func luminance(_ color: NSColor, appearance: NSAppearance) -> Double {
        var result = 0.0
        appearance.performAsCurrentDrawingAppearance {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            result = 0.2126 * linear(rgb.redComponent)
                + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        return result
    }

    private static func renderPreview(dates: [Date], scale: GitBlameColorScale, dark: Bool) throws {
        let preview = VStack(alignment: .leading, spacing: 0) {
            ForEach(dates.indices, id: \.self) { index in
                GitBlameAnnotationCell(
                    blame: GitBlameLine(lineNumber: index + 1,
                        commitHash: String(repeating: String(index + 1), count: 40),
                        author: "Author \(index + 1)", authoredAt: dates[index],
                        authorEmail: "author\(index + 1)@example.invalid", message: "Subject\n\nFull body"),
                    height: 24, colorScale: scale
                )
            }
            GitBlameAnnotationCell(
                blame: GitBlameLine(lineNumber: 9, commitHash: String(repeating: "0", count: 40),
                    author: "未提交", authoredAt: dates.last),
                height: 24, colorScale: scale
            )
            GitBlameAnnotationCell(
                blame: GitBlameLine(lineNumber: 10, commitHash: String(repeating: "a", count: 40),
                    author: "Unknown date", authoredAt: nil),
                height: 24, colorScale: scale
            )
            GitBlameAnnotationCell(blame: nil, height: 24, colorScale: scale)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: preview)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(x: 0, y: 0, width: GitBlameAnnotationCell.width, height: 264)
        try saveRendering(view, name: "git-blame-colors-\(dark ? "dark" : "light")")
    }

    private static func renderNativePreview(dates: [Date], dark: Bool) throws {
        var annotations = Dictionary(uniqueKeysWithValues: dates.enumerated().map { index, date in
            (index + 1, NativeGitBlameAnnotation(
                commitHash: String(repeating: String(index + 1), count: 40),
                author: "Author \(index + 1)", authoredAt: date, isUncommitted: false,
                authorEmail: "author\(index + 1)@example.invalid", message: "Subject\n\nFull body 中文"
            ))
        })
        annotations[9] = NativeGitBlameAnnotation(commitHash: String(repeating: "0", count: 40),
            author: "未提交", authoredAt: nil, isUncommitted: true)
        annotations[40] = annotations[8]
        let text = (1...60).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        var selectedHash: String?
        let editor = NativeCodeEditor(text: .constant(text), isEditable: false,
            showsLineNumbers: true, gitBlame: annotations,
            onSelectGitBlameCommit: { selectedHash = $0 }, fontSize: 13)
        let coordinator = editor.makeCoordinator()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scrollView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = scrollView
        defer { window.orderOut(nil) }
        let textView = NSTextView(frame: scrollView.bounds)
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainer?.containerSize = NSSize(width: 520, height: 10_000)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let contentHeight = textView.layoutManager!.usedRect(for: textView.textContainer!).height + 10
        textView.setFrameSize(NSSize(width: 520, height: contentHeight))
        scrollView.documentView = textView
        coordinator.textView = textView
        coordinator.configureLineNumbers(true, in: scrollView)
        scrollView.tile()
        try saveRendering(scrollView, name: "git-blame-native-\(dark ? "dark" : "light")")
        guard let ruler = scrollView.verticalRulerView as? NativeLineNumberRulerView,
              let layout = textView.layoutManager else {
            throw BlameColorVerificationError(message: "Native blame ruler was not installed")
        }
        let index = SourceLineIndex(text: text)
        func point(for line: Int) -> NSPoint {
            let glyph = layout.glyphIndexForCharacter(at: index.lineStartOffsets[line - 1])
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let origin = textView.convert(NSPoint(x: 0, y: rect.midY + textView.textContainerOrigin.y), to: ruler)
            return NSPoint(x: 20, y: origin.y)
        }
        func click(_ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: ruler.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            ruler.mouseDown(with: event)
        }
        let firstPoint = point(for: 1)
        let details = ruler.view(ruler, stringForToolTip: 0, point: firstPoint, userData: nil)
        try require(details.contains(String(repeating: "1", count: 40))
                    && details.contains("author1@example.invalid") && details.contains("Full body 中文"),
                    "Hover must show full hash, email and multiline message")
        click(firstPoint)
        try require(selectedHash == annotations[1]?.commitHash, "Clicking a committed annotation must select its hash")
        selectedHash = nil
        click(point(for: 9))
        try require(selectedHash == nil, "Uncommitted annotations must not trigger History navigation")
        try require(ruler.blameAnnotation(at: NSPoint(x: GitBlamePalette.annotationWidth + 5, y: firstPoint.y)) == nil,
                    "Line numbers and code must not be treated as blame annotations")

        let glyph = layout.glyphIndexForCharacter(at: index.lineStartOffsets[39])
        let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: lineRect.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        ruler.needsDisplay = true
        try saveRendering(scrollView, name: "git-blame-native-scrolled-\(dark ? "dark" : "light")")
        click(point(for: 40))
        try require(selectedHash == annotations[40]?.commitHash,
                    "Blame hit testing must track line positions after scrolling")
        coordinator.gitBlame = nil
        coordinator.configureGitBlame()
        try require(ruler.blameAnnotation(at: point(for: 40)) == nil,
                    "Closing annotations must discard hover and click targets")
    }

    private static func saveRendering(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw BlameColorVerificationError(message: "Could not render \(name)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 1_000 else {
            throw BlameColorVerificationError(message: "Empty rendering: \(name)")
        }
        try png.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/\(name).png"), options: .atomic)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw BlameColorVerificationError(message: message) }
    }
}
