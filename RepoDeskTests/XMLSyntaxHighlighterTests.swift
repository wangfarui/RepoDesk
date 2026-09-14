import Foundation
import Testing
@testable import RepoDesk

struct XMLSyntaxHighlighterTests {
    @Test func highlightsXMLStructureAndOpaqueRegions() {
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="urn:example" enabled='true'>
            <!-- <ignored attribute="value"> -->
            <name>RepoDesk &amp; XML</name>
            <![CDATA[<raw attribute="value">]]>
        </project>
        """
        let spans = XMLSyntaxHighlighter.highlights(in: source)

        #expect(style(at: "<?xml", in: source, spans: spans) == .declaration)
        #expect(style(at: "project", occurrence: 1, in: source, spans: spans) == .tagName)
        #expect(style(at: "xmlns", in: source, spans: spans) == .attributeName)
        #expect(style(at: "\"urn:example\"", in: source, spans: spans) == .attributeValue)
        #expect(style(at: "<!--", in: source, spans: spans) == .comment)
        #expect(style(at: "&amp;", in: source, spans: spans) == .entity)
        #expect(style(at: "<![CDATA[", in: source, spans: spans) == .cdata)
        #expect(style(at: "ignored", in: source, spans: spans) == .comment)
        #expect(style(at: "raw", in: source, spans: spans) == .cdata)
        #expect(style(at: "</", in: source, spans: spans) == .markupDelimiter)
    }

    @Test func toleratesUnclosedConstructs() {
        let source = "<project value=\"unfinished &amp; value"
        let spans = XMLSyntaxHighlighter.highlights(in: source)

        #expect(style(at: "project", in: source, spans: spans) == .tagName)
        #expect(style(at: "value", occurrence: 1, in: source, spans: spans) == .attributeName)
        #expect(style(at: "\"unfinished", in: source, spans: spans) == .attributeValue)
        #expect(style(at: "&amp;", in: source, spans: spans) == .entity)
    }

    private func style(
        at value: String,
        occurrence: Int = 1,
        in source: String,
        spans: [XMLSyntaxHighlightSpan]
    ) -> XMLSyntaxHighlightStyle? {
        let location = occurrenceRange(of: value, occurrence: occurrence, in: source).location
        guard location != NSNotFound else { return nil }
        return spans.last { NSLocationInRange(location, $0.range) }?.style
    }

    private func occurrenceRange(of value: String, occurrence: Int, in source: String) -> NSRange {
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
}
