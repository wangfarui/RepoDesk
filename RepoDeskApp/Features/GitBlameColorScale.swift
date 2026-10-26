import AppKit
import Foundation

/// A file-wide scale, independent of the visible rows and the number of commits.
struct GitBlameColorScale: Equatable, Sendable {
    static let maximumLevelCount = 8
    private let levelsByDate: [Date: Int]

    init(dates: some Sequence<Date>, calendar: Calendar = .current) {
        let daysByDate = Dictionary(uniqueKeysWithValues: Set(dates).map {
            ($0, calendar.startOfDay(for: $0))
        })
        let days = Set(daysByDate.values)
        guard let first = days.min(), let last = days.max() else {
            levelsByDate = [:]
            return
        }
        guard first != last else {
            levelsByDate = daysByDate.mapValues { _ in (Self.maximumLevelCount - 1) / 2 }
            return
        }

        let levelCount = min(Self.maximumLevelCount, days.count)
        let span = max(1, calendar.dateComponents([.day], from: first, to: last).day ?? 1)
        levelsByDate = daysByDate.mapValues { day in
            let offset = calendar.dateComponents([.day], from: first, to: day).day ?? 0
            let bucket = min(levelCount - 1, offset * levelCount / span)
            // Spread small palettes across the same light-to-strong range.
            return Int((Double(bucket) * Double(Self.maximumLevelCount - 1)
                / Double(levelCount - 1)).rounded())
        }
    }

    func level(for date: Date?) -> Int? {
        date.flatMap { levelsByDate[$0] }
    }
}

@MainActor
enum GitBlamePalette {
    private static let backgrounds: [NSColor] = (0..<GitBlameColorScale.maximumLevelCount).map { level in
        NSColor(name: nil) { appearance in
            let strength = CGFloat(level) / CGFloat(GitBlameColorScale.maximumLevelCount - 1)
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(
                srgbRed: dark ? 0.16 + strength * 0.06 : 0.96 - strength * 0.30,
                green: dark ? 0.18 + strength * 0.18 : 0.97 - strength * 0.17,
                blue: dark ? 0.21 + strength * 0.31 : 0.99 - strength * 0.04,
                alpha: 1
            )
        }
    }

    static func background(for level: Int?) -> NSColor {
        guard let level, backgrounds.indices.contains(level) else { return .controlBackgroundColor }
        return backgrounds[level]
    }
}
