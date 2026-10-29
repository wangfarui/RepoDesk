import Foundation

enum XMLSyntaxHighlightStyle: Equatable, Sendable {
    case attributeName
    case attributeValue
    case cdata
    case comment
    case declaration
    case entity
    case markupDelimiter
    case tagName
}

struct XMLSyntaxHighlightSpan: Equatable, Sendable {
    let range: NSRange
    let style: XMLSyntaxHighlightStyle
}

enum XMLSyntaxHighlighter {
    static func highlights(in text: String) -> [XMLSyntaxHighlightSpan] {
        let source = text as NSString
        var spans: [XMLSyntaxHighlightSpan] = []
        var offset = 0

        while offset < source.length {
            if spans.count.isMultiple(of: 128), Task.isCancelled { return [] }
            if source.hasPrefix("<!--", at: offset) {
                let end = scanUntil("-->", from: offset + 4, source: source)
                spans.append(span(.comment, from: offset, to: end))
                offset = end
            } else if source.hasPrefix("<![CDATA[", at: offset) {
                let end = scanUntil("]]>", from: offset + 9, source: source)
                spans.append(span(.cdata, from: offset, to: end))
                offset = end
            } else if source.hasPrefix("<?", at: offset) {
                let end = scanUntil("?>", from: offset + 2, source: source)
                spans.append(span(.declaration, from: offset, to: end))
                offset = end
            } else if source.hasPrefix("<!", at: offset) {
                let end = scanMarkupDeclaration(from: offset, source: source)
                spans.append(span(.declaration, from: offset, to: end))
                offset = end
            } else if source.character(at: offset) == Character.lessThan {
                offset = scanTag(from: offset, source: source, spans: &spans)
            } else if source.character(at: offset) == Character.ampersand,
                      let range = entityRange(from: offset, source: source) {
                spans.append(XMLSyntaxHighlightSpan(range: range, style: .entity))
                offset = NSMaxRange(range)
            } else {
                offset += 1
            }
        }

        return spans
    }

    private static func scanTag(
        from start: Int,
        source: NSString,
        spans: inout [XMLSyntaxHighlightSpan]
    ) -> Int {
        var offset = start + 1
        if offset < source.length, source.character(at: offset) == Character.slash {
            offset += 1
        }
        spans.append(span(.markupDelimiter, from: start, to: offset))
        offset = skipWhitespace(from: offset, source: source)

        let tagNameEnd = scanName(from: offset, source: source)
        if tagNameEnd > offset {
            spans.append(span(.tagName, from: offset, to: tagNameEnd))
            offset = tagNameEnd
        }

        while offset < source.length {
            offset = skipWhitespace(from: offset, source: source)
            guard offset < source.length else { return offset }

            if source.hasPrefix("/>", at: offset) {
                spans.append(span(.markupDelimiter, from: offset, to: offset + 2))
                return offset + 2
            }
            if source.character(at: offset) == Character.greaterThan {
                spans.append(span(.markupDelimiter, from: offset, to: offset + 1))
                return offset + 1
            }

            let attributeNameEnd = scanName(from: offset, source: source)
            if attributeNameEnd == offset {
                offset += 1
                continue
            }
            spans.append(span(.attributeName, from: offset, to: attributeNameEnd))
            offset = skipWhitespace(from: attributeNameEnd, source: source)

            guard offset < source.length,
                  source.character(at: offset) == Character.equals else { continue }
            spans.append(span(.markupDelimiter, from: offset, to: offset + 1))
            offset = skipWhitespace(from: offset + 1, source: source)
            guard offset < source.length else { return offset }

            let valueStart = offset
            let quote = source.character(at: offset)
            let valueEnd: Int
            if quote == Character.doubleQuote || quote == Character.singleQuote {
                valueEnd = scanQuotedValue(from: offset, quote: quote, source: source)
            } else {
                valueEnd = scanUnquotedValue(from: offset, source: source)
            }
            spans.append(span(.attributeValue, from: valueStart, to: valueEnd))
            appendEntities(in: NSRange(location: valueStart, length: valueEnd - valueStart), source: source, spans: &spans)
            offset = valueEnd
        }

        return offset
    }

    private static func scanUntil(_ terminator: String, from start: Int, source: NSString) -> Int {
        let searchRange = NSRange(location: start, length: source.length - start)
        let range = source.range(of: terminator, options: [], range: searchRange)
        return range.location == NSNotFound ? source.length : NSMaxRange(range)
    }

    private static func scanMarkupDeclaration(from start: Int, source: NSString) -> Int {
        var offset = start + 2
        var quote: unichar?
        var subsetDepth = 0
        while offset < source.length {
            let unit = source.character(at: offset)
            if let activeQuote = quote {
                if unit == activeQuote { quote = nil }
            } else if unit == Character.doubleQuote || unit == Character.singleQuote {
                quote = unit
            } else if unit == Character.leftBracket {
                subsetDepth += 1
            } else if unit == Character.rightBracket {
                subsetDepth = max(0, subsetDepth - 1)
            } else if unit == Character.greaterThan, subsetDepth == 0 {
                return offset + 1
            }
            offset += 1
        }
        return source.length
    }

    private static func scanName(from start: Int, source: NSString) -> Int {
        var offset = start
        while offset < source.length {
            let unit = source.character(at: offset)
            if isWhitespace(unit) || [Character.slash, Character.greaterThan, Character.equals, Character.questionMark].contains(unit) {
                break
            }
            offset += 1
        }
        return offset
    }

    private static func scanQuotedValue(from start: Int, quote: unichar, source: NSString) -> Int {
        var offset = start + 1
        while offset < source.length {
            if source.character(at: offset) == quote { return offset + 1 }
            offset += 1
        }
        return source.length
    }

    private static func scanUnquotedValue(from start: Int, source: NSString) -> Int {
        var offset = start
        while offset < source.length {
            let unit = source.character(at: offset)
            if isWhitespace(unit) || unit == Character.greaterThan || source.hasPrefix("/>", at: offset) {
                break
            }
            offset += 1
        }
        return offset
    }

    private static func appendEntities(
        in range: NSRange,
        source: NSString,
        spans: inout [XMLSyntaxHighlightSpan]
    ) {
        var offset = range.location
        let end = NSMaxRange(range)
        while offset < end {
            if source.character(at: offset) == Character.ampersand,
               let entity = entityRange(from: offset, source: source),
               NSMaxRange(entity) <= end {
                spans.append(XMLSyntaxHighlightSpan(range: entity, style: .entity))
                offset = NSMaxRange(entity)
            } else {
                offset += 1
            }
        }
    }

    private static func entityRange(from start: Int, source: NSString) -> NSRange? {
        var offset = start + 1
        guard offset < source.length else { return nil }
        while offset < source.length {
            let unit = source.character(at: offset)
            if unit == Character.semicolon {
                guard offset > start + 1 else { return nil }
                return NSRange(location: start, length: offset - start + 1)
            }
            if isWhitespace(unit)
                || unit == Character.ampersand
                || unit == Character.lessThan
                || unit == Character.greaterThan
                || unit == Character.doubleQuote
                || unit == Character.singleQuote {
                return nil
            }
            offset += 1
        }
        return nil
    }

    private static func skipWhitespace(from start: Int, source: NSString) -> Int {
        var offset = start
        while offset < source.length, isWhitespace(source.character(at: offset)) {
            offset += 1
        }
        return offset
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 9 || unit == 10 || unit == 13 || unit == 32
    }

    private static func span(_ style: XMLSyntaxHighlightStyle, from start: Int, to end: Int) -> XMLSyntaxHighlightSpan {
        XMLSyntaxHighlightSpan(range: NSRange(location: start, length: end - start), style: style)
    }

    private enum Character {
        static let ampersand: unichar = 38
        static let doubleQuote: unichar = 34
        static let equals: unichar = 61
        static let greaterThan: unichar = 62
        static let leftBracket: unichar = 91
        static let lessThan: unichar = 60
        static let questionMark: unichar = 63
        static let rightBracket: unichar = 93
        static let semicolon: unichar = 59
        static let singleQuote: unichar = 39
        static let slash: unichar = 47
    }
}

private extension NSString {
    func hasPrefix(_ prefix: String, at offset: Int) -> Bool {
        let length = (prefix as NSString).length
        guard offset >= 0, offset + length <= self.length else { return false }
        return substring(with: NSRange(location: offset, length: length)) == prefix
    }
}
