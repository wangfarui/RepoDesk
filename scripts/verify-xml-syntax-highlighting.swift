import AppKit
import SwiftUI
@testable import RepoDesk

@main
@MainActor
enum VerifyXMLSyntaxHighlighting {
    static func main() throws {
        _ = NSApplication.shared
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="urn:example">
            <!-- comment -->
            <name enabled='true'>RepoDesk &amp; XML</name>
            <![CDATA[<unparsed>value</unparsed>]]>
        </project>
        """
        let storage = try render(source, fileExtension: "xml")

        try requireColor(XMLSyntaxColorPalette.color(for: .declaration), at: "<?xml", in: source, storage: storage)
        try requireColor(XMLSyntaxColorPalette.color(for: .markupDelimiter), at: "<project", offset: 0, in: source, storage: storage)
        try requireColor(XMLSyntaxColorPalette.color(for: .tagName), at: "project", in: source, storage: storage)
        try requireColor(XMLSyntaxColorPalette.color(for: .attributeName), at: "xmlns", in: source, storage: storage)
        try requireColor(XMLSyntaxColorPalette.color(for: .attributeValue), at: "\"urn:example\"", in: source, storage: storage)
        try requireColor(XMLSyntaxColorPalette.color(for: .comment), at: "<!-- comment -->", in: source, storage: storage)
        try requireColor(XMLSyntaxColorPalette.color(for: .entity), at: "&amp;", in: source, storage: storage)
        try requireColor(XMLSyntaxColorPalette.color(for: .cdata), at: "<![CDATA[", in: source, storage: storage)

        let plainStorage = try render("<project/>", fileExtension: "txt")
        try requireColor(.textColor, at: "project", in: "<project/>", storage: plainStorage)
        print("XML syntax highlighting verification passed")
    }

    private static func render(_ source: String, fileExtension: String) throws -> NSTextStorage {
        let editor = NativeCodeEditor(
            text: .constant(source),
            isEditable: true,
            style: .source(fileExtension: fileExtension)
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 240)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: hostingView), let storage = textView.textStorage else {
            window.close()
            throw VerificationError.failed("XML syntax highlighting fixture did not render")
        }
        let copy = NSTextStorage(attributedString: storage)
        window.close()
        return copy
    }

    private static func requireColor(
        _ expected: NSColor,
        at value: String,
        offset: Int? = nil,
        in source: String,
        storage: NSTextStorage
    ) throws {
        let range = (source as NSString).range(of: value)
        try require(range.location != NSNotFound, "Missing XML color fixture token: \(value)")
        let location = offset.map { range.location + $0 } ?? range.location
        guard let actual = storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor else {
            throw VerificationError.failed("Missing foreground color for \(value)")
        }
        try require(
            actual.usingColorSpace(.deviceRGB) == expected.usingColorSpace(.deviceRGB),
            "Unexpected XML color for \(value): \(actual), expected \(expected)"
        )
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
