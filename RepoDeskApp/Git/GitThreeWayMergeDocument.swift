import Foundation

enum GitMergeSideState: String, Codable, Sendable {
    case pending, accepted, ignored
}

struct GitMergeTextRange: Equatable, Codable, Sendable {
    var start: Int
    var length: Int
    var end: Int { start + length }
    var nsRange: NSRange { NSRange(location: start, length: length) }
}

struct GitMergeChange: Equatable, Codable, Sendable, Identifiable {
    let id: Int
    var baseRange: GitMergeTextRange
    var oursRange: GitMergeTextRange
    var theirsRange: GitMergeTextRange
    var resultRange: GitMergeTextRange
    var isConflict: Bool
    var oursState: GitMergeSideState = .pending
    var theirsState: GitMergeSideState = .pending
    var hasAppliedSide = false
    var isResolved: Bool { oursState != .pending && theirsState != .pending }
}

/// Immutable three-way sources and an independently editable result. Offsets are
/// UTF-16, matching NSTextView. No conflict-marker parsing is used for diffing.
enum GitMergeWhitespacePolicy: String, Codable, CaseIterable, Sendable {
    case none = "Do not ignore"
    case trim = "Trim whitespaces"
    case ignore = "Ignore whitespaces"
    func normalized(_ text: String) -> String {
        switch self {
        case .none: return text
        case .trim: return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        case .ignore: return String(text.filter { !$0.isWhitespace })
        }
    }
}

struct GitThreeWayMergeDocument: Equatable, Codable, Sendable {
    let base: String
    let ours: String
    let theirs: String
    let whitespacePolicy: GitMergeWhitespacePolicy
    private(set) var result: String
    private(set) var changes: [GitMergeChange]

    init(base: String, ours: String, theirs: String, automaticallyApply: Bool = true, whitespacePolicy: GitMergeWhitespacePolicy = .none) {
        self.base = base
        self.ours = ours
        self.theirs = theirs
        self.whitespacePolicy = whitespacePolicy
        result = base
        changes = []
        let b = Self.lines(base), l = Self.lines(ours), r = Self.lines(theirs)
        let left = Self.edits(base: b, side: l, policy: whitespacePolicy), right = Self.edits(base: b, side: r, policy: whitespacePolicy)
        let edits = (left + right).sorted { ($0.base.lowerBound, $0.base.upperBound) < ($1.base.lowerBound, $1.base.upperBound) }
        var groups: [Range<Int>] = []
        for edit in edits {
            if let last = groups.last,
               edit.base.lowerBound < last.upperBound
                || (edit.base.lowerBound == last.upperBound && (edit.base.isEmpty || last.isEmpty)) {
                groups[groups.count - 1] = last.lowerBound..<max(last.upperBound, edit.base.upperBound)
            } else {
                groups.append(edit.base)
            }
        }
        // Multiple edits can share the same insertion boundary.
        for (id, group) in groups.enumerated() {
            let lr = Self.sideRange(group, edits: left), rr = Self.sideRange(group, edits: right)
            let br = Self.textRange(group, lines: b)
            let or = Self.textRange(lr, lines: l), tr = Self.textRange(rr, lines: r)
            let bt = Self.slice(base, br), ot = Self.slice(ours, or), tt = Self.slice(theirs, tr)
            changes.append(GitMergeChange(id: id, baseRange: br, oursRange: or, theirsRange: tr,
                                          resultRange: br, isConflict: whitespacePolicy.normalized(ot) != whitespacePolicy.normalized(bt) && whitespacePolicy.normalized(tt) != whitespacePolicy.normalized(bt) && whitespacePolicy.normalized(ot) != whitespacePolicy.normalized(tt)))
        }
        if automaticallyApply { applyNonConflicting() }
    }

    private enum CodingKeys: String, CodingKey { case base, ours, theirs, result, changes, whitespacePolicy }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        base = try values.decode(String.self, forKey: .base)
        ours = try values.decode(String.self, forKey: .ours)
        theirs = try values.decode(String.self, forKey: .theirs)
        result = try values.decode(String.self, forKey: .result)
        changes = try values.decode([GitMergeChange].self, forKey: .changes)
        whitespacePolicy = try values.decodeIfPresent(GitMergeWhitespacePolicy.self, forKey: .whitespacePolicy) ?? .none
    }

    func isChange(_ change: GitMergeChange, side: GitConflictSide) -> Bool {
        whitespacePolicy.normalized(content(side, change: change)) != whitespacePolicy.normalized(Self.slice(base, change.baseRange))
    }
    func canApplyNonConflicting(side: GitConflictSide? = nil) -> Bool {
        changes.contains { change in
            guard !change.isConflict, !change.isResolved, Self.slice(result, change.resultRange) == Self.slice(base, change.baseRange) else { return false }
            guard let side else { return true }
            return isChange(change, side: side)
        }
    }
    func simpleResolution(for change: GitMergeChange) -> String? {
        guard change.isConflict, change.oursState == .pending, change.theirsState == .pending, !change.hasAppliedSide,
              Self.slice(result, change.resultRange) == Self.slice(base, change.baseRange) else { return nil }
        return GitMergeTextResolver.resolve(base: Self.slice(base, change.baseRange),
                                            ours: content(.ours, change: change), theirs: content(.theirs, change: change))
    }
    mutating func resolveSimpleConflicts() {
        applyNonConflicting()
        for change in changes { resolveSimpleConflict(change.id) }
    }
    mutating func resolveSimpleConflict(_ id: Int) {
        guard let index = changes.firstIndex(where: { $0.id == id }), let text = simpleResolution(for: changes[index]) else { return }
        replaceResult(change: index, with: text)
        markResolved(id)
    }

    var isValid: Bool {
        guard Set(changes.map(\.id)).count == changes.count else { return false }
        let limits = [(base as NSString).length, (ours as NSString).length,
                      (theirs as NSString).length, (result as NSString).length]
        var previousEnds = [0, 0, 0, 0]
        for change in changes {
            let ranges = [change.baseRange, change.oursRange, change.theirsRange, change.resultRange]
            for i in ranges.indices {
                guard ranges[i].start >= previousEnds[i], ranges[i].length >= 0,
                      ranges[i].start <= limits[i], ranges[i].length <= limits[i] - ranges[i].start else { return false }
                previousEnds[i] = ranges[i].end
            }
        }
        return true
    }

    var unresolvedIDs: [Int] { changes.filter { !$0.isResolved }.map(\.id) }
    var unresolvedConflictCount: Int { changes.filter { !$0.isResolved && $0.isConflict }.count }
    var unresolvedChangeCount: Int { changes.filter { !$0.isResolved && !$0.isConflict }.count }

    func content(_ side: GitConflictSide, change: GitMergeChange) -> String {
        side == .ours ? Self.slice(ours, change.oursRange) : Self.slice(theirs, change.theirsRange)
    }

    mutating func accept(_ id: Int, side: GitConflictSide, resolveBoth: Bool = false) {
        guard let i = changes.firstIndex(where: { $0.id == id }) else { return }
        let change = changes[i]
        guard (side == .ours ? change.oursState : change.theirsState) == .pending else { return }
        let text = content(side, change: change)
        let opposite = content(side == .ours ? .theirs : .ours, change: change)
        let replacement: String
        if change.isConflict && change.hasAppliedSide {
            let current = Self.slice(result, change.resultRange)
            let separator = current.contains("\r\n") ? "\r\n" : "\n"
            replacement = current + (current.isEmpty || current.hasSuffix("\n") || text.isEmpty ? "" : separator) + text
        } else { replacement = text }
        replaceResult(change: i, with: replacement)
        if side == .ours { changes[i].oursState = .accepted }
        else { changes[i].theirsState = .accepted }
        if resolveBoth || !change.isConflict || opposite.isEmpty {
            if side == .ours { changes[i].theirsState = .ignored }
            else { changes[i].oursState = .ignored }
        }
        changes[i].hasAppliedSide = true
    }

    mutating func ignore(_ id: Int, side: GitConflictSide, resolveBoth: Bool = false) {
        guard let i = changes.firstIndex(where: { $0.id == id }) else { return }
        if side == .ours { changes[i].oursState = .ignored }
        else { changes[i].theirsState = .ignored }
        if resolveBoth || !changes[i].isConflict {
            changes[i].oursState = .ignored
            changes[i].theirsState = .ignored
        }
    }

    mutating func markResolved(_ id: Int) {
        guard let i = changes.firstIndex(where: { $0.id == id }) else { return }
        if changes[i].oursState == .pending { changes[i].oursState = .ignored }
        if changes[i].theirsState == .pending { changes[i].theirsState = .ignored }
    }

    mutating func reset(_ id: Int) {
        guard let i = changes.firstIndex(where: { $0.id == id }) else { return }
        replaceResult(change: i, with: Self.slice(base, changes[i].baseRange))
        changes[i].oursState = .pending
        changes[i].theirsState = .pending
        changes[i].hasAppliedSide = false
    }

    mutating func applyNonConflicting(side: GitConflictSide? = nil) {
        for id in changes.filter({ !$0.isConflict && !$0.isResolved }).map(\.id) {
            guard let change = changes.first(where: { $0.id == id }) else { continue }
            guard Self.slice(result, change.resultRange) == Self.slice(base, change.baseRange) else { continue }
            let ancestor = Self.slice(base, change.baseRange)
            let leftChanged = whitespacePolicy.normalized(content(.ours, change: change)) != whitespacePolicy.normalized(ancestor)
            let rightChanged = whitespacePolicy.normalized(content(.theirs, change: change)) != whitespacePolicy.normalized(ancestor)
            if let side {
                if side == .ours ? leftChanged : rightChanged { accept(change.id, side: side, resolveBoth: true) }
            } else {
                accept(change.id, side: leftChanged ? .ours : .theirs, resolveBoth: true)
            }
        }
    }

    /// Updates tracking ranges for arbitrary, continuous edits. When an edit
    /// crosses multiple changes, combine them into one pending decision so a
    /// later arrow never applies to overlapping/obsolete ranges.
    mutating func editResult(_ text: String) {
        guard text != result else { return }
        let old = Array(result.utf16), new = Array(text.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        // Avoid splitting a surrogate pair in a replacement range.
        if prefix > 0, prefix < old.count, (0xDC00...0xDFFF).contains(old[prefix]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        if suffix > 0, suffix < old.count - prefix,
           (0xDC00...0xDFFF).contains(old[old.count - suffix]) { suffix -= 1 }
        let end = old.count - suffix, newEnd = new.count - suffix
        let touched = changes.indices.filter {
            let r = changes[$0].resultRange
            return (r.start < end && r.end > prefix) || (r.length == 0 && r.start >= prefix && r.start <= end)
        }
        if let first = touched.first, let last = touched.last, first != last {
            var combined = changes[first]
            combined.baseRange.length = changes[last].baseRange.end - combined.baseRange.start
            combined.oursRange.length = changes[last].oursRange.end - combined.oursRange.start
            combined.theirsRange.length = changes[last].theirsRange.end - combined.theirsRange.start
            combined.resultRange.length = changes[last].resultRange.end - combined.resultRange.start
            combined.isConflict = true
            combined.oursState = .pending
            combined.theirsState = .pending
            combined.hasAppliedSide = false
            changes.replaceSubrange(first...last, with: [combined])
        }
        for i in changes.indices {
            let range = changes[i].resultRange
            if range.end <= prefix && (range.length > 0 || range.start < prefix) { continue }
            if range.start >= end && !(end == prefix && range.start == prefix && range.length == 0) {
                changes[i].resultRange.start += newEnd - end
            } else {
                let start = min(range.start, prefix)
                let mappedEnd = range.end >= end ? range.end + newEnd - end : newEnd
                changes[i].resultRange = GitMergeTextRange(start: start, length: max(0, mappedEnd - start))
            }
        }
        result = text
    }

    private mutating func replaceResult(change index: Int, with text: String) {
        let range = changes[index].resultRange
        result = (result as NSString).replacingCharacters(in: range.nsRange, with: text)
        let length = (text as NSString).length, delta = length - range.length
        changes[index].resultRange.length = length
        for i in changes.indices where i != index && changes[i].resultRange.start >= range.end {
            // Zero-length changes at a shared boundary remain in source order.
            if changes[i].resultRange.start > range.start || i > index { changes[i].resultRange.start += delta }
        }
    }

    static func slice(_ text: String, _ range: GitMergeTextRange) -> String {
        let string = text as NSString
        guard range.start >= 0, range.end <= string.length else { return "" }
        return string.substring(with: range.nsRange)
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices where i < lines.count - 1 { lines[i] += "\n" }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private struct Edit {
        let base: Range<Int>
        let side: Range<Int>
        var delta: Int { side.count - base.count }
    }

    private static func edits(base: [String], side: [String], policy: GitMergeWhitespacePolicy) -> [Edit] {
        let diff = side.map(policy.normalized).difference(from: base.map(policy.normalized))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let anchors = zip(base.indices.filter { !removed.contains($0) }, side.indices.filter { !inserted.contains($0) })
        var result: [Edit] = [], b = 0, s = 0
        for (bi, si) in Array(anchors) + [(base.count, side.count)] {
            if b != bi || s != si { result.append(Edit(base: b..<bi, side: s..<si)) }
            b = bi + 1; s = si + 1
        }
        return result
    }

    private static func sideRange(_ range: Range<Int>, edits: [Edit]) -> Range<Int> {
        let included = edits.filter {
            $0.base.lowerBound >= range.lowerBound && $0.base.upperBound <= range.upperBound
        }
        let shift = edits.filter { edit in
            edit.base.upperBound <= range.lowerBound && !included.contains(where: { $0.base == edit.base && $0.side == edit.side })
        }.reduce(0) { $0 + $1.delta }
        let start = range.lowerBound + shift
        return start..<(start + range.count + included.reduce(0) { $0 + $1.delta })
    }

    private static func textRange(_ range: Range<Int>, lines: [String]) -> GitMergeTextRange {
        GitMergeTextRange(start: lines.prefix(range.lowerBound).reduce(0) { $0 + ($1 as NSString).length },
                          length: lines[range].reduce(0) { $0 + ($1 as NSString).length })
    }
}
