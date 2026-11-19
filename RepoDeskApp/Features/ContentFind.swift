import AppKit
import SwiftUI

extension Notification.Name {
    static let repoDeskContentFindRequested = Notification.Name("RepoDesk.ContentFindRequested")
    static let repoDeskContentFindNavigationRequested = Notification.Name(
        "RepoDesk.ContentFindNavigationRequested"
    )
}

private let contentFindNavigationOffsetKey = "offset"

@MainActor
final class ContentFindWindowRegistry {
    static let shared = ContentFindWindowRegistry()
    private final class Entry {
        weak var window: NSWindow?
        var listenerCount: Int

        init(window: NSWindow) {
            self.window = window
            listenerCount = 1
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ window: NSWindow) {
        removeReleasedWindows()
        let identifier = ObjectIdentifier(window)
        if let entry = entries[identifier] {
            entry.listenerCount += 1
        } else {
            entries[identifier] = Entry(window: window)
        }
    }

    func unregister(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard let entry = entries[identifier] else { return }
        entry.listenerCount -= 1
        if entry.listenerCount <= 0 {
            entries.removeValue(forKey: identifier)
        }
    }

    func contains(_ window: NSWindow) -> Bool {
        removeReleasedWindows()
        return entries[ObjectIdentifier(window)] != nil
    }

    private func removeReleasedWindows() {
        entries = entries.filter { $0.value.window != nil }
    }
}

struct ContentSearchOptions: Equatable, Sendable {
    var matchesCase = false
    var matchesWholeWords = false
}

struct ContentSearchMatch: Equatable, Sendable {
    let lineIndex: Int
    let range: NSRange
    let rangeInLine: NSRange
}

enum ContentSearchMatcher {
    static func matches(
        in text: String,
        query: String,
        options: ContentSearchOptions
    ) -> [ContentSearchMatch] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var matches: [ContentSearchMatch] = []
        var lineIndex = 0
        var lineStart = 0

        while lineStart <= source.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getLineStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: lineStart, length: 0)
            )
            appendMatches(
                in: source.substring(with: NSRange(location: start, length: contentsEnd - start)),
                query: query,
                options: options,
                lineIndex: lineIndex,
                documentOffset: start,
                to: &matches
            )
            guard end < source.length else { break }
            lineStart = end
            lineIndex += 1
        }
        return matches
    }

    static func matches(
        in lines: [String],
        query: String,
        options: ContentSearchOptions
    ) -> [ContentSearchMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [ContentSearchMatch] = []
        var documentOffset = 0
        for (lineIndex, line) in lines.enumerated() {
            appendMatches(
                in: line,
                query: query,
                options: options,
                lineIndex: lineIndex,
                documentOffset: documentOffset,
                to: &matches
            )
            documentOffset += (line as NSString).length
            if lineIndex < lines.count - 1 { documentOffset += 1 }
        }
        return matches
    }

    private static func appendMatches(
        in line: String,
        query: String,
        options: ContentSearchOptions,
        lineIndex: Int,
        documentOffset: Int,
        to matches: inout [ContentSearchMatch]
    ) {
        for range in ranges(in: line, query: query, options: options) {
            matches.append(ContentSearchMatch(
                lineIndex: lineIndex,
                range: NSRange(location: documentOffset + range.location, length: range.length),
                rangeInLine: range
            ))
        }
    }

    static func ranges(
        in text: String,
        query: String,
        options: ContentSearchOptions,
        startingAt start: Int = 0
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        let searchOptions: NSString.CompareOptions = options.matchesCase
            ? []
            : [.caseInsensitive]
        var matches: [NSRange] = []
        var searchLocation = start

        while searchLocation <= source.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            let range = source.range(of: query, options: searchOptions, range: searchRange)
            guard range.location != NSNotFound else { break }
            if !options.matchesWholeWords || isWholeWord(range, in: text) {
                matches.append(range)
            }
            searchLocation = range.location + max(1, range.length)
        }
        return matches
    }

    static func isWholeWord(_ range: NSRange, in source: String) -> Bool {
        guard let matchRange = Range(range, in: source) else { return false }
        let startsAtBoundary = matchRange.lowerBound == source.startIndex
            || !isWordCharacter(source[source.index(before: matchRange.lowerBound)])
        let endsAtBoundary = matchRange.upperBound == source.endIndex
            || !isWordCharacter(source[matchRange.upperBound])
        return startsAtBoundary && endsAtBoundary
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }
}

struct ContentFindState: Equatable {
    var isPresented = false
    var query = "" {
        didSet { if query != oldValue { resetSelection() } }
    }
    var matchesCase = false {
        didSet { if matchesCase != oldValue { resetSelection() } }
    }
    var matchesWholeWords = false {
        didSet { if matchesWholeWords != oldValue { resetSelection() } }
    }
    var currentMatchIndex = 0
    var navigationRequestID = UUID()
    var focusRequestID = UUID()
    var contentFocusRequestID: UUID?
    private var selectedSearchRange: NSRange?

    var options: ContentSearchOptions {
        ContentSearchOptions(
            matchesCase: matchesCase,
            matchesWholeWords: matchesWholeWords
        )
    }

    mutating func present() {
        isPresented = true
        focusRequestID = UUID()
        navigationRequestID = UUID()
    }

    mutating func present(selection: NSRange?, in text: String) {
        if let selection, selection.length > 0, let range = Range(selection, in: text) {
            query = String(text[range])
            if matchesWholeWords && !ContentSearchMatcher.isWholeWord(selection, in: text) {
                matchesWholeWords = false
            }
            selectedSearchRange = selection
            currentMatchIndex = documentMatchRanges(in: text).firstIndex(of: selection) ?? 0
        }
        present()
    }

    func documentMatchRanges(in text: String) -> [NSRange] {
        let matches = ContentSearchMatcher.ranges(in: text, query: query, options: options)
        guard let selection = selectedSearchRange, !matches.contains(selection),
              let range = Range(selection, in: text), text[range] == query else {
            return matches
        }
        // Prefer the user's selection if the forward scan found an overlapping
        // occurrence first. Keep the result list ordered and nonoverlapping.
        let before = matches.prefix { NSMaxRange($0) <= selection.location }
        let after = ContentSearchMatcher.ranges(
            in: text, query: query, options: options, startingAt: NSMaxRange(selection)
        )
        return Array(before) + [selection] + after
    }

    mutating func dismiss() {
        let shouldRestoreContentFocus = isPresented
        isPresented = false
        navigationRequestID = UUID()
        if shouldRestoreContentFocus {
            contentFocusRequestID = UUID()
        }
    }

    mutating func resetSelection() {
        currentMatchIndex = 0
        selectedSearchRange = nil
        navigationRequestID = UUID()
    }

    mutating func navigate(by offset: Int, matchCount: Int) {
        guard matchCount > 0 else {
            currentMatchIndex = 0
            navigationRequestID = UUID()
            return
        }
        let current = activeMatchIndex(matchCount: matchCount) ?? 0
        currentMatchIndex = (current + offset + matchCount) % matchCount
        navigationRequestID = UUID()
    }

    func activeMatchIndex(matchCount: Int) -> Int? {
        guard matchCount > 0 else { return nil }
        return min(max(0, currentMatchIndex), matchCount - 1)
    }
}

struct ContentSearchPresentation: Equatable {
    let ranges: [NSRange]
    let activeRange: NSRange?
    let navigationRequestID: UUID
}

@MainActor
struct ContentFindBar: View {
    @Binding var state: ContentFindState
    let matchCount: Int
    var dismiss: () -> Void
    @FocusState private var queryIsFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, idealWidth: 260, maxWidth: 360)
                .focused($queryIsFocused)
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    state.navigate(
                        by: keyPress.modifiers.contains(.shift) ? -1 : 1,
                        matchCount: matchCount
                    )
                    return .handled
                }
            Text(matchSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(matchCount == 0 && !state.query.isEmpty ? .red : .secondary)
                .frame(minWidth: 52, alignment: .trailing)
            Button("Previous Match", systemImage: "chevron.up") {
                state.navigate(by: -1, matchCount: matchCount)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .help("Previous Match (Command+Shift+G or Shift+Enter)")
            Button("Next Match", systemImage: "chevron.down") {
                state.navigate(by: 1, matchCount: matchCount)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .help("Next Match (Command+G or Enter)")
            Toggle("Match Case", isOn: $state.matchesCase)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Match Case")
            Toggle("Words", isOn: $state.matchesWholeWords)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Match Whole Words")
            Button("Close Find", systemImage: "xmark") {
                dismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close (Escape)")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .onAppear { queryIsFocused = true }
        .onChange(of: state.focusRequestID) { _, _ in queryIsFocused = true }
        .onExitCommand(perform: dismiss)
        .accessibilityIdentifier("RepoDesk.ContentFind")
    }

    private var matchSummary: String {
        guard !state.query.isEmpty else { return "" }
        guard let index = state.activeMatchIndex(matchCount: matchCount) else { return "0 / 0" }
        return "\(index + 1) / \(matchCount)"
    }
}

@MainActor
struct ContentFindCommandListener: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let requestFind: (NSWindow) -> Void
    var navigateMatch: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> ContentFindCommandListenerView {
        let view = ContentFindCommandListenerView()
        view.isListening = isEnabled
        view.requestFind = requestFind
        view.navigateMatch = navigateMatch
        return view
    }

    func updateNSView(_ view: ContentFindCommandListenerView, context: Context) {
        view.isListening = isEnabled
        view.requestFind = requestFind
        view.navigateMatch = navigateMatch
    }
}

@MainActor
final class ContentFindCommandListenerView: NSView {
    var requestFind: ((NSWindow) -> Void)?
    var navigateMatch: ((Int) -> Void)?
    private weak var registeredWindow: NSWindow?
    var isListening = true {
        didSet { if oldValue != isListening { updateRegistration() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(findRequested(_:)),
            name: .repoDeskContentFindRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(findNavigationRequested(_:)),
            name: .repoDeskContentFindNavigationRequested,
            object: nil
        )
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRegistration()
    }

    private func updateRegistration() {
        if let registeredWindow {
            ContentFindWindowRegistry.shared.unregister(registeredWindow)
        }
        registeredWindow = isListening ? window : nil
        if let window = registeredWindow {
            ContentFindWindowRegistry.shared.register(window)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func findRequested(_ notification: Notification) {
        guard isListening, let requestedWindow = notification.object as? NSWindow,
              requestedWindow === window else { return }
        requestFind?(requestedWindow)
    }

    @objc private func findNavigationRequested(_ notification: Notification) {
        guard isListening, let requestedWindow = notification.object as? NSWindow,
              requestedWindow === window,
              let offset = notification.userInfo?[contentFindNavigationOffsetKey] as? Int else {
            return
        }
        navigateMatch?(offset)
    }
}
