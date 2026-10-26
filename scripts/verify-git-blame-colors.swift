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
            try renderPreview(dates: previewDates, scale: previewScale, dark: dark)
            try renderNativePreview(dates: previewDates, dark: dark)
        }
        print("Git blame color verification passed (6,000 dates, calendar boundaries, light/dark rendering)")
    }

    private static func renderPreview(dates: [Date], scale: GitBlameColorScale, dark: Bool) throws {
        let preview = VStack(alignment: .leading, spacing: 0) {
            ForEach(dates.indices, id: \.self) { index in
                GitBlameAnnotationCell(
                    blame: GitBlameLine(lineNumber: index + 1,
                        commitHash: String(repeating: String(index + 1), count: 40),
                        author: "Author \(index + 1)", authoredAt: dates[index]),
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
        let annotations = Dictionary(uniqueKeysWithValues: dates.enumerated().map { index, date in
            (index + 1, NativeGitBlameAnnotation(
                commitHash: String(repeating: String(index + 1), count: 40),
                author: "Author \(index + 1)", authoredAt: date, isUncommitted: false
            ))
        })
        let text = dates.indices.map { "let value\($0 + 1) = \($0 + 1)" }.joined(separator: "\n")
        let editor = NativeCodeEditor(text: .constant(text), isEditable: false,
            showsLineNumbers: true, gitBlame: annotations, fontSize: 13)
        let coordinator = editor.makeCoordinator()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scrollView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let textView = NSTextView(frame: scrollView.bounds)
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        coordinator.textView = textView
        coordinator.configureLineNumbers(true, in: scrollView)
        scrollView.tile()
        try saveRendering(scrollView, name: "git-blame-native-\(dark ? "dark" : "light")")
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
