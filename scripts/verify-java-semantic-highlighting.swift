import AppKit
import SwiftUI
@testable import RepoDesk

@main
@MainActor
enum VerifyJavaSemanticHighlighting {
    static func main() throws {
        _ = NSApplication.shared
        let source = "@ApiAutowired(CommonParameter.applicationId) ProcessingNotifyPageResult searchProcessingNotifyPage(int appId) { return \"ok\"; }"
        let values: [(String, JavaSemanticTokenStyle)] = [
            ("ApiAutowired", .annotation),
            ("CommonParameter", .class),
            ("applicationId", .property),
            ("ProcessingNotifyPageResult", .class),
            ("searchProcessingNotifyPage", .method),
            ("int", .keyword),
            ("appId", .parameter),
            ("return", .keyword),
            ("\"ok\"", .string)
        ]
        let tokens = try values.map { value, style in
            let range = (source as NSString).range(of: value)
            try require(range.location != NSNotFound, "Missing semantic fixture token: \(value)")
            return JavaSemanticToken(
                range: JavaSourceRange(
                    start: JavaSourcePosition(line: 0, character: range.location),
                    end: JavaSourcePosition(line: 0, character: range.location + range.length)
                ),
                style: style
            )
        }
        let editor = NativeCodeEditor(
            text: .constant(source),
            isEditable: true,
            style: .source(fileExtension: "java"),
            semanticTokens: tokens
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 160)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: hostingView), let storage = textView.textStorage else {
            throw VerificationError.failed("Java semantic highlighting fixture did not render")
        }

        try requireColor(JavaSemanticColorPalette.color(for: .annotation), at: "ApiAutowired", in: source, storage: storage)
        try requireColor(JavaSemanticColorPalette.color(for: .annotation), at: "@", in: source, storage: storage)
        try requireColor(.labelColor, at: "CommonParameter", in: source, storage: storage)
        try requireColor(JavaSemanticColorPalette.color(for: .property), at: "applicationId", in: source, storage: storage)
        try requireColor(.labelColor, at: "ProcessingNotifyPageResult", in: source, storage: storage)
        try requireColor(JavaSemanticColorPalette.color(for: .method), at: "searchProcessingNotifyPage", in: source, storage: storage)
        try requireColor(JavaSemanticColorPalette.color(for: .keyword), at: "int", in: source, storage: storage)
        try requireColor(.labelColor, at: "appId", in: source, storage: storage)
        try requireColor(JavaSemanticColorPalette.color(for: .keyword), at: "return", in: source, storage: storage)
        try requireColor(JavaSemanticColorPalette.color(for: .string), at: "\"ok\"", in: source, storage: storage)
        try writeScreenshot(of: hostingView, filename: "java-semantic-highlighting.png")
        try verifyJavaSyntaxFallback()
        print("Java semantic highlighting verification passed")
    }

    private static func verifyJavaSyntaxFallback() throws {
        let source = """
        @Component
        public class WhcenterOrderManager {
            @Autowired
            private ContractTemplateManager contractTemplateManager;

            public ProcessingResult previewProcessingNotifyOrderDetail(int domainId) {
                log.info("preview {}", JSON.toJSONString(domainId), contractTemplateManager.getDefaultTemplate(PROCESSING_NOTIFY_ORDER_CONTRACT_TYPE, 42));
                return null; // no matching result
            }
        }
        """
        let editor = NativeCodeEditor(
            text: .constant(source),
            isEditable: true,
            style: .source(fileExtension: "java"),
            semanticTokens: []
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 260)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: hostingView), let storage = textView.textStorage else {
            throw VerificationError.failed("Java syntax fallback fixture did not render")
        }

        try requireColor(.systemBrown, at: "@Component", in: source, storage: storage)
        try requireColor(.systemBrown, at: "@Autowired", in: source, storage: storage)
        try requireColor(.systemTeal, at: "previewProcessingNotifyOrderDetail", in: source, storage: storage)
        try requireColor(.secondaryLabelColor, at: "contractTemplateManager", occurrence: 1, in: source, storage: storage)
        try requireColor(.systemPurple, at: "contractTemplateManager", occurrence: 2, in: source, storage: storage)
        try requireColor(.systemGreen, at: "\"preview {}\"", in: source, storage: storage)
        try requireColor(.textColor, at: "JSON", in: source, storage: storage)
        try requireColor(.systemPurple, at: "PROCESSING_NOTIFY_ORDER_CONTRACT_TYPE", in: source, storage: storage)
        try requireColor(.systemBlue, at: "42", in: source, storage: storage)
        try requireColor(.systemBlue, at: "null", in: source, storage: storage)
        try requireColor(.secondaryLabelColor, at: "// no matching result", in: source, storage: storage)
        try requireItalic(at: "info", in: source, storage: storage)
        try requireItalic(at: "toJSONString", in: source, storage: storage)
        try requireItalic(at: "getDefaultTemplate", in: source, storage: storage)
        try requireItalic(at: "PROCESSING_NOTIFY_ORDER_CONTRACT_TYPE", in: source, storage: storage)
        try writeScreenshot(of: hostingView, filename: "java-syntax-fallback-highlighting.png")
    }

    private static func writeScreenshot(of view: NSView, filename: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw VerificationError.failed("Could not create Java semantic highlighting bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw VerificationError.failed("Could not encode Java semantic highlighting PNG")
        }
        try data.write(
            to: URL(fileURLWithPath: "build/\(filename)"),
            options: .atomic
        )
    }

    private static func requireColor(
        _ expected: NSColor,
        at value: String,
        occurrence: Int = 1,
        in source: String,
        storage: NSTextStorage
    ) throws {
        let range = occurrenceRange(of: value, occurrence: occurrence, in: source)
        try require(range.location != NSNotFound, "Missing color fixture token: \(value)")
        guard let actual = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor else {
            throw VerificationError.failed("Missing foreground color for \(value)")
        }
        try require(
            actual.usingColorSpace(.deviceRGB) == expected.usingColorSpace(.deviceRGB),
            "Unexpected Java color for \(value): \(actual), expected \(expected)"
        )
    }

    private static func requireItalic(
        at value: String,
        in source: String,
        storage: NSTextStorage
    ) throws {
        let range = occurrenceRange(of: value, occurrence: 1, in: source)
        try require(range.location != NSNotFound, "Missing italic fixture token: \(value)")
        guard let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else {
            throw VerificationError.failed("Missing font for \(value)")
        }
        try require(
            font.fontDescriptor.symbolicTraits.contains(.italic),
            "Expected italic Java syntax for \(value): \(font)"
        )
    }

    private static func occurrenceRange(of value: String, occurrence: Int, in source: String) -> NSRange {
        let source = source as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var result = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            result = source.range(of: value, options: [], range: searchRange)
            guard result.location != NSNotFound else { return result }
            let nextLocation = NSMaxRange(result)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return result
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }

    private enum VerificationError: Error {
        case failed(String)
    }
}
