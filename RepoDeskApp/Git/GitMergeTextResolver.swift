import Foundation

/// Conservative character merge for the viewer's explicit "Resolve Simple
/// Conflicts" action. Overlapping alternatives stay pending.
enum GitMergeTextResolver {
    private struct Edit: Equatable {
        let range: Range<Int>
        let replacement: [Character]
    }
    static func resolve(base: String, ours: String, theirs: String) -> String? {
        if ours == theirs { return ours }
        if ours == base { return theirs }
        if theirs == base { return ours }
        let b = Array(base), l = Array(ours), r = Array(theirs)
        guard b.count + l.count + r.count <= 12_000 else { return nil }
        let left = edits(b, l), right = edits(b, r)
        for a in left { for c in right where a != c {
            let overlaps = a.range.overlaps(c.range)
                || (a.range.isEmpty && c.range.lowerBound...c.range.upperBound ~= a.range.lowerBound)
                || (c.range.isEmpty && a.range.lowerBound...a.range.upperBound ~= c.range.lowerBound)
            if overlaps { return nil }
        } }
        let combined = left + right.filter { !left.contains($0) }
        var result = b
        for edit in combined.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return String(result)
    }
    private static func edits(_ base: [Character], _ side: [Character]) -> [Edit] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in side.difference(from: base) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let anchors = Array(zip(base.indices.filter { !removed.contains($0) }, side.indices.filter { !inserted.contains($0) }))
        var result: [Edit] = [], b = 0, s = 0
        for (bi, si) in anchors + [(base.count, side.count)] {
            if b != bi || s != si { result.append(Edit(range: b..<bi, replacement: Array(side[s..<si]))) }
            b = bi + 1; s = si + 1
        }
        return result
    }
}
