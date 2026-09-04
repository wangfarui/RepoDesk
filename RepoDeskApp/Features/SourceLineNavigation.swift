import Foundation

struct SourceLineIndex: Equatable {
    let lineStartOffsets: [Int]
    let utf16Length: Int

    init(text: String) {
        let source = text as NSString
        var offsets = [0]
        var cursor = 0

        while cursor < source.length {
            var lineEnd = 0
            var contentEnd = 0
            source.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentEnd,
                for: NSRange(location: cursor, length: 0)
            )
            guard lineEnd > cursor else { break }
            if lineEnd < source.length || contentEnd < lineEnd {
                offsets.append(lineEnd)
            }
            cursor = lineEnd
        }

        lineStartOffsets = offsets
        utf16Length = source.length
    }

    var lineCount: Int {
        lineStartOffsets.count
    }

    func lineNumber(containingUTF16Offset offset: Int) -> Int {
        let target = min(max(0, offset), utf16Length)
        var lowerBound = 0
        var upperBound = lineStartOffsets.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lineStartOffsets[middle] <= target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return max(1, lowerBound)
    }

    func contentRange(forLine line: Int, in text: String) -> NSRange? {
        guard line > 0, line <= lineCount else { return nil }
        let source = text as NSString
        let start = lineStartOffsets[line - 1]
        guard start < source.length else {
            return NSRange(location: source.length, length: 0)
        }

        var contentEnd = 0
        source.getLineStart(
            nil,
            end: nil,
            contentsEnd: &contentEnd,
            for: NSRange(location: start, length: 0)
        )
        return NSRange(location: start, length: max(0, contentEnd - start))
    }
}

enum GoToLineValidationError: Error, Equatable {
    case empty
    case notPositiveInteger
    case outOfRange(maximum: Int)

    var message: String {
        switch self {
        case .empty:
            return "请输入行号。"
        case .notPositiveInteger:
            return "请输入大于 0 的整数。"
        case .outOfRange(let maximum):
            return "行号范围为 1 至 \(maximum)。"
        }
    }
}

enum GoToLineValidator {
    static func validate(_ input: String, maximumLine: Int) throws -> Int {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw GoToLineValidationError.empty }
        guard value.allSatisfy(\.isNumber), let line = Int(value), line > 0 else {
            throw GoToLineValidationError.notPositiveInteger
        }
        guard line <= maximumLine else {
            throw GoToLineValidationError.outOfRange(maximum: maximumLine)
        }
        return line
    }
}

struct NativeTextNavigationRequest: Equatable {
    let id: UUID
    let line: Int

    init(line: Int, id: UUID = UUID()) {
        self.id = id
        self.line = line
    }
}
