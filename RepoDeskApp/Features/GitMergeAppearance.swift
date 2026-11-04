import AppKit
import CoreText

@MainActor
enum GitMergeAppearance {
    static let conflict = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.48, green: 0.24, blue: 0.24, alpha: 1) : NSColor(red: 1, green: 0.83, blue: 0.81, alpha: 1) }
    static let added = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.22, green: 0.40, blue: 0.25, alpha: 1) : NSColor(red: 0.63, green: 0.84, blue: 0.64, alpha: 1) }
    static let modified = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.24, green: 0.34, blue: 0.48, alpha: 1) : NSColor(red: 0.65, green: 0.78, blue: 0.94, alpha: 1) }
    static let deleted = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.darkGray : NSColor.lightGray }
    private static let registerBundled: Void = {
        if let directory = Bundle.main.resourceURL?.appendingPathComponent("MergeFonts") { registerFonts(in: directory) }
    }()
    static func registerFonts(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) }
    }
    static func codeFont(_ size: CGFloat) -> NSFont {
        _ = registerBundled
        return NSFont(name: "JetBrainsMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    static func actionIcon(_ operation: String, pane: Int, append: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1
            if operation == "Ignore" {
                path.move(to: NSPoint(x: 3, y: 3)); path.line(to: NSPoint(x: 13, y: 13))
                path.move(to: NSPoint(x: 3, y: 13)); path.line(to: NSPoint(x: 13, y: 3))
            } else if operation == "Resolve" {
                path.move(to: NSPoint(x: 3, y: 3)); path.line(to: NSPoint(x: 13, y: 13))
                path.move(to: NSPoint(x: 4, y: 10)); path.line(to: NSPoint(x: 1, y: 12)); path.move(to: NSPoint(x: 10, y: 15)); path.line(to: NSPoint(x: 10, y: 12))
            } else {
                let direction: CGFloat = pane == 0 ? 1 : -1
                let origin: CGFloat = pane == 0 ? 4 : 12
                if append {
                    path.move(to: NSPoint(x: origin, y: 14)); path.line(to: NSPoint(x: origin, y: 5)); path.line(to: NSPoint(x: origin + direction * 8, y: 5))
                    path.move(to: NSPoint(x: origin + direction * 4, y: 9)); path.line(to: NSPoint(x: origin + direction * 8, y: 5)); path.line(to: NSPoint(x: origin + direction * 4, y: 1))
                } else {
                    for shift: CGFloat in [0, 5] {
                        let x = origin - direction * 2 + direction * shift
                        path.move(to: NSPoint(x: x, y: 13)); path.line(to: NSPoint(x: x + direction * 5, y: 8)); path.line(to: NSPoint(x: x, y: 3))
                    }
                }
            }
            path.stroke(); return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
enum GitMergeSyntax {
    static func apply(_ text: String, fileExtension: String, font: NSFont, to storage: NSTextStorage) {
        if fileExtension == "java" {
            for span in JavaSyntaxHighlighter.highlights(in: text) {
                let color: NSColor
                switch span.style {
                case .keyword, .number: color = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemOrange : NSColor(red: 0, green: 0, blue: 0.5, alpha: 1) }
                case .string: color = NSColor(red: 0, green: 0.45, blue: 0.12, alpha: 1)
                case .comment: color = .secondaryLabelColor
                case .annotation: color = .systemBrown
                case .fieldDeclaration, .fieldReference, .constant: color = .systemPurple
                case .methodDeclaration, .methodCall: color = .textColor
                }
                storage.addAttribute(.foregroundColor, value: color, range: span.range)
            }
        } else if fileExtension == "xml" {
            for span in XMLSyntaxHighlighter.highlights(in: text) { storage.addAttribute(.foregroundColor, value: XMLSyntaxColorPalette.color(for: span.style), range: span.range) }
        }
    }
    static func changedRanges(_ text: String, comparedTo other: String, words: Bool) -> [NSRange] {
        func tokens(_ text: String) -> [(String, NSRange)] {
            let source = text as NSString
            if words, let regex = try? NSRegularExpression(pattern: #"\w+|\s+|[^\w\s]"#) {
                return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { (source.substring(with: $0.range), $0.range) }
            }
            var offset = 0
            return text.map { character in
                let token = String(character); let length = (token as NSString).length
                defer { offset += length }
                return (token, NSRange(location: offset, length: length))
            }
        }
        let target = tokens(text), baseline = tokens(other)
        guard target.count + baseline.count < 16_000 else { return [] }
        return target.map(\.0).difference(from: baseline.map(\.0)).compactMap { change in
            if case .insert(let index, _, _) = change, !target[index].0.allSatisfy(\.isWhitespace) { return target[index].1 }
            return nil
        }
    }
}
