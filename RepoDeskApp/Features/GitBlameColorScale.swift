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
            // Spread small palettes across the same faint-to-bright range.
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
    static let annotationWidth: CGFloat = 204
    // Oldest → newest: a single blue hue with increasingly distinct intensity.
    // Opaque fills keep both text and age colors independent of the code/diff background.
    private static let backgrounds: [NSColor] = [
        adaptive(light: 0xF7F8FA, dark: 0x24262B),
        adaptive(light: 0xF0F3FA, dark: 0x252B36),
        adaptive(light: 0xE5ECF9, dark: 0x273141),
        adaptive(light: 0xD8E4F8, dark: 0x29374C),
        adaptive(light: 0xC9DCF7, dark: 0x2C3D57),
        adaptive(light: 0xB9D0F4, dark: 0x2F4362),
        adaptive(light: 0xABC6F0, dark: 0x32496D),
        adaptive(light: 0x9DBAEB, dark: 0x355078)
    ]

    private static let text = adaptive(light: 0x162B45, dark: 0xF5F8FF)

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return formatter
    }()

    static func detailText(hash: String, author: String, email: String?, date: Date?,
                           message: String?, isUncommitted: Bool) -> String {
        guard !isUncommitted else { return "未提交的改动" }
        let identity = email.flatMap { $0.isEmpty ? nil : "\(author) <\($0)>" } ?? author
        let timestamp = date.map(detailDateFormatter.string(from:)) ?? "未知"
        return "commit \(hash)\nAuthor: \(identity)\nDate: \(timestamp)\n\n\(message ?? "提交说明不可用")"
    }

    static func background(for level: Int?) -> NSColor {
        guard let level, backgrounds.indices.contains(level) else { return .controlBackgroundColor }
        return backgrounds[level]
    }

    static func foreground(for level: Int?) -> NSColor {
        guard let level, backgrounds.indices.contains(level) else { return .labelColor }
        return text
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
    }
}
