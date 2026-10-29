import Foundation

enum JavaSyntaxHighlightStyle: Equatable, Sendable {
    case annotation
    case comment
    case constant
    case fieldDeclaration
    case fieldReference
    case keyword
    case methodCall
    case methodDeclaration
    case number
    case string
}

struct JavaSyntaxHighlightSpan: Equatable, Sendable {
    let range: NSRange
    let style: JavaSyntaxHighlightStyle
}

enum JavaSyntaxHighlighter {
    private enum TokenKind: Equatable {
        case comment
        case identifier
        case keyword
        case number
        case string
        case symbol
    }

    private enum BraceContext {
        case block
        case type
    }

    private struct Token: Equatable {
        let kind: TokenKind
        let range: NSRange
        let text: String
    }

    private static let keywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
        "class", "const", "continue", "default", "do", "double", "else", "enum",
        "extends", "false", "final", "finally", "float", "for", "goto", "if",
        "implements", "import", "instanceof", "int", "interface", "long", "native",
        "new", "null", "package", "private", "protected", "public", "record", "return",
        "sealed", "short", "static", "strictfp", "super", "switch", "synchronized",
        "this", "throw", "throws", "transient", "true", "try", "var", "void",
        "volatile", "while", "yield", "permits"
    ]

    private static let primitiveTypes: Set<String> = [
        "boolean", "byte", "char", "double", "float", "int", "long", "short", "void", "var"
    ]

    private static let typeDeclarationKeywords: Set<String> = [
        "class", "enum", "interface", "record"
    ]

    static func highlights(in text: String) -> [JavaSyntaxHighlightSpan] {
        guard !Task.isCancelled else { return [] }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [] }

        var spans = lexicalSpans(tokens)
        let annotationTokenIndices = annotationIndices(tokens)
        spans.append(contentsOf: annotationSpans(tokens, indices: annotationTokenIndices))

        let typeContext = typeContextByToken(tokens)
        let methodDeclarations = methodDeclarationIndices(tokens, typeContext: typeContext)
        let fields = fieldDeclarationIndices(
            tokens,
            typeContext: typeContext,
            methodDeclarations: methodDeclarations
        )
        let fieldNames = Set(fields.map { tokens[$0].text })

        for index in methodDeclarations {
            spans.append(JavaSyntaxHighlightSpan(range: tokens[index].range, style: .methodDeclaration))
        }
        for (index, token) in tokens.enumerated() where token.kind == .identifier {
            if index.isMultiple(of: 128), Task.isCancelled { return [] }
            if fields.contains(index) {
                spans.append(JavaSyntaxHighlightSpan(range: token.range, style: .fieldDeclaration))
            } else if fieldNames.contains(token.text) {
                spans.append(JavaSyntaxHighlightSpan(range: token.range, style: .fieldReference))
            }
            if isConstant(at: index, tokens: tokens), !annotationTokenIndices.contains(index) {
                spans.append(JavaSyntaxHighlightSpan(range: token.range, style: .constant))
            }
            if isMethodCall(at: index, tokens: tokens, methodDeclarations: methodDeclarations) {
                spans.append(JavaSyntaxHighlightSpan(range: token.range, style: .methodCall))
            }
        }
        return spans
    }

    private static func lexicalSpans(_ tokens: [Token]) -> [JavaSyntaxHighlightSpan] {
        tokens.compactMap { token in
            let style: JavaSyntaxHighlightStyle
            switch token.kind {
            case .comment:
                style = .comment
            case .keyword:
                style = .keyword
            case .number:
                style = .number
            case .string:
                style = .string
            case .identifier, .symbol:
                return nil
            }
            return JavaSyntaxHighlightSpan(range: token.range, style: style)
        }
    }

    private static func annotationIndices(_ tokens: [Token]) -> Set<Int> {
        var result: Set<Int> = []
        for index in tokens.indices where tokens[index].text == "@" {
            var cursor = index + 1
            guard tokens.indices.contains(cursor), tokens[cursor].kind == .identifier else { continue }
            result.insert(cursor)
            while tokens.indices.contains(cursor + 2),
                  tokens[cursor + 1].text == ".",
                  tokens[cursor + 2].kind == .identifier {
                cursor += 2
                result.insert(cursor)
            }
        }
        return result
    }

    private static func annotationSpans(_ tokens: [Token], indices: Set<Int>) -> [JavaSyntaxHighlightSpan] {
        var spans: [JavaSyntaxHighlightSpan] = []
        for index in tokens.indices where tokens[index].text == "@" {
            var cursor = index + 1
            guard indices.contains(cursor) else { continue }
            var end = NSMaxRange(tokens[cursor].range)
            while tokens.indices.contains(cursor + 2),
                  tokens[cursor + 1].text == ".",
                  indices.contains(cursor + 2) {
                cursor += 2
                end = NSMaxRange(tokens[cursor].range)
            }
            spans.append(
                JavaSyntaxHighlightSpan(
                    range: NSRange(location: tokens[index].range.location, length: end - tokens[index].range.location),
                    style: .annotation
                )
            )
        }
        return spans
    }

    private static func typeContextByToken(_ tokens: [Token]) -> [Bool] {
        var result = Array(repeating: false, count: tokens.count)
        var stack: [BraceContext] = []
        var boundary = 0
        for index in tokens.indices {
            result[index] = stack.last == .type
            switch tokens[index].text {
            case "{":
                let opensType = tokens[boundary..<index].contains {
                    $0.kind == .keyword && typeDeclarationKeywords.contains($0.text)
                }
                stack.append(opensType ? .type : .block)
                boundary = index + 1
            case "}":
                if !stack.isEmpty { stack.removeLast() }
                boundary = index + 1
            case ";":
                boundary = index + 1
            default:
                break
            }
        }
        return result
    }

    private static func methodDeclarationIndices(
        _ tokens: [Token],
        typeContext: [Bool]
    ) -> Set<Int> {
        var result: Set<Int> = []
        for index in tokens.indices where tokens[index].kind == .identifier && typeContext[index] {
            guard tokens.indices.contains(index + 1), tokens[index + 1].text == "(",
                  let close = matchingCloseParen(from: index + 1, tokens: tokens),
                  hasDeclarationTerminator(after: close, tokens: tokens),
                  isPlausibleDeclarationName(at: index, tokens: tokens) else {
                continue
            }
            let boundary = previousStatementBoundary(before: index, tokens: tokens)
            guard !tokens[boundary..<index].contains(where: { $0.text == "=" }) else { continue }
            result.insert(index)
        }
        return result
    }

    private static func fieldDeclarationIndices(
        _ tokens: [Token],
        typeContext: [Bool],
        methodDeclarations: Set<Int>
    ) -> Set<Int> {
        var result: Set<Int> = []
        for end in tokens.indices where tokens[end].text == ";" && typeContext[end] {
            let start = previousStatementBoundary(before: end, tokens: tokens)
            let segment = start..<end
            guard !segment.contains(where: { methodDeclarations.contains($0) }),
                  !tokens[segment].contains(where: {
                      $0.kind == .keyword && ["import", "package"].contains($0.text)
                  }) else {
                continue
            }
            let declarationEnd = segment.first(where: { tokens[$0].text == "=" }) ?? end
            guard let candidate = tokens[start..<declarationEnd].indices.reversed().first(where: {
                tokens[$0].kind == .identifier
            }) else {
                continue
            }
            let hasType = tokens[start..<candidate].contains {
                $0.kind == .identifier || ($0.kind == .keyword && primitiveTypes.contains($0.text))
            }
            guard hasType else { continue }
            result.insert(candidate)
        }
        return result
    }

    private static func isMethodCall(
        at index: Int,
        tokens: [Token],
        methodDeclarations: Set<Int>
    ) -> Bool {
        guard !methodDeclarations.contains(index),
              tokens.indices.contains(index + 1), tokens[index + 1].text == "(" else {
            return false
        }
        let previous = index > 0 ? tokens[index - 1].text : nil
        return previous != "@" && previous != "new"
    }

    private static func isPlausibleDeclarationName(at index: Int, tokens: [Token]) -> Bool {
        guard index > 0 else { return false }
        let previous = tokens[index - 1]
        if previous.text == "." || previous.text == "@" || previous.text == "new" {
            return false
        }
        if previous.kind == .identifier || primitiveTypes.contains(previous.text) {
            return true
        }
        return previous.text == ">" || previous.text == "]"
    }

    private static func hasDeclarationTerminator(after close: Int, tokens: [Token]) -> Bool {
        var cursor = close + 1
        if tokens.indices.contains(cursor), tokens[cursor].text == "throws" {
            cursor += 1
            while tokens.indices.contains(cursor), tokens[cursor].text != "{", tokens[cursor].text != ";" {
                cursor += 1
            }
        }
        return tokens.indices.contains(cursor) && (tokens[cursor].text == "{" || tokens[cursor].text == ";")
    }

    private static func matchingCloseParen(from open: Int, tokens: [Token]) -> Int? {
        var depth = 0
        for index in open..<tokens.count {
            if tokens[index].text == "(" {
                depth += 1
            } else if tokens[index].text == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func previousStatementBoundary(before index: Int, tokens: [Token]) -> Int {
        guard index > 0 else { return 0 }
        for cursor in stride(from: index - 1, through: 0, by: -1) {
            if [";", "{", "}"].contains(tokens[cursor].text) {
                return cursor + 1
            }
        }
        return 0
    }

    private static func isConstant(at index: Int, tokens: [Token]) -> Bool {
        let value = tokens[index].text
        guard value.count > 1, value.contains(where: { $0.isLetter }) else { return false }
        guard value.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else { return false }
        let previous = index > 0 ? tokens[index - 1].text : nil
        return value.contains("_") || previous == "."
    }

    private static func tokenize(_ text: String) -> [Token] {
        let source = text as NSString
        var tokens: [Token] = []
        var offset = 0
        while offset < source.length {
            if tokens.count.isMultiple(of: 128), Task.isCancelled { return [] }
            let unit = source.character(at: offset)
            if isWhitespace(unit) {
                offset += 1
                continue
            }
            if unit == 47, offset + 1 < source.length {
                let next = source.character(at: offset + 1)
                if next == 47 {
                    let end = scanLineComment(from: offset, source: source)
                    tokens.append(token(.comment, from: offset, to: end, source: source))
                    offset = end
                    continue
                }
                if next == 42 {
                    let end = scanBlockComment(from: offset, source: source)
                    tokens.append(token(.comment, from: offset, to: end, source: source))
                    offset = end
                    continue
                }
            }
            if unit == 34 || unit == 39 {
                let end = scanQuotedLiteral(from: offset, quote: unit, source: source)
                tokens.append(token(.string, from: offset, to: end, source: source))
                offset = end
                continue
            }
            if isIdentifierStart(unit) {
                let end = scanIdentifier(from: offset, source: source)
                let value = source.substring(with: NSRange(location: offset, length: end - offset))
                let kind: TokenKind = keywords.contains(value) ? .keyword : .identifier
                tokens.append(Token(kind: kind, range: NSRange(location: offset, length: end - offset), text: value))
                offset = end
                continue
            }
            if isDigit(unit) {
                let end = scanNumber(from: offset, source: source)
                tokens.append(token(.number, from: offset, to: end, source: source))
                offset = end
                continue
            }
            tokens.append(token(.symbol, from: offset, to: offset + 1, source: source))
            offset += 1
        }
        return tokens
    }

    private static func token(_ kind: TokenKind, from start: Int, to end: Int, source: NSString) -> Token {
        let range = NSRange(location: start, length: end - start)
        return Token(kind: kind, range: range, text: source.substring(with: range))
    }

    private static func scanLineComment(from start: Int, source: NSString) -> Int {
        var offset = start + 2
        while offset < source.length, ![10, 13].contains(source.character(at: offset)) {
            offset += 1
        }
        return offset
    }

    private static func scanBlockComment(from start: Int, source: NSString) -> Int {
        var offset = start + 2
        while offset + 1 < source.length {
            if source.character(at: offset) == 42, source.character(at: offset + 1) == 47 {
                return offset + 2
            }
            offset += 1
        }
        return source.length
    }

    private static func scanQuotedLiteral(from start: Int, quote: unichar, source: NSString) -> Int {
        let isTextBlock = quote == 34
            && start + 2 < source.length
            && source.character(at: start + 1) == 34
            && source.character(at: start + 2) == 34
        var offset = start + (isTextBlock ? 3 : 1)
        while offset < source.length {
            if source.character(at: offset) == 92 {
                offset = min(offset + 2, source.length)
                continue
            }
            if isTextBlock,
               offset + 2 < source.length,
               source.character(at: offset) == 34,
               source.character(at: offset + 1) == 34,
               source.character(at: offset + 2) == 34 {
                return offset + 3
            }
            if !isTextBlock, source.character(at: offset) == quote {
                return offset + 1
            }
            offset += 1
        }
        return source.length
    }

    private static func scanIdentifier(from start: Int, source: NSString) -> Int {
        var offset = start + 1
        while offset < source.length, isIdentifierPart(source.character(at: offset)) {
            offset += 1
        }
        return offset
    }

    private static func scanNumber(from start: Int, source: NSString) -> Int {
        var offset = start + 1
        while offset < source.length {
            let unit = source.character(at: offset)
            guard isIdentifierPart(unit) || unit == 46 else { break }
            offset += 1
        }
        return offset
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 9 || unit == 10 || unit == 13 || unit == 32
    }

    private static func isDigit(_ unit: unichar) -> Bool {
        unit >= 48 && unit <= 57
    }

    private static func isIdentifierStart(_ unit: unichar) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36 || unit >= 128
    }

    private static func isIdentifierPart(_ unit: unichar) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }
}
