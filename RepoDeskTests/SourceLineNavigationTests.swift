import Foundation
import Testing
@testable import RepoDesk

struct SourceLineNavigationTests {
    @Test func lineIndexCountsEmptyTrailingAndCRLFLines() {
        #expect(SourceLineIndex(text: "").lineCount == 1)
        #expect(SourceLineIndex(text: "first\nsecond").lineCount == 2)
        #expect(SourceLineIndex(text: "first\n").lineCount == 2)
        #expect(SourceLineIndex(text: "first\r\nsecond\r\n").lineCount == 3)
    }

    @Test func lineIndexMapsOffsetsAndReturnsContentWithoutLineEndings() {
        let text = "first\r\nsecond\nthird"
        let index = SourceLineIndex(text: text)

        #expect(index.lineNumber(containingUTF16Offset: 0) == 1)
        #expect(index.lineNumber(containingUTF16Offset: 7) == 2)
        #expect(index.lineNumber(containingUTF16Offset: (text as NSString).length) == 3)
        #expect(index.contentRange(forLine: 2, in: text) == NSRange(location: 7, length: 6))
        #expect(index.contentRange(forLine: 4, in: text) == nil)
    }

    @Test func goToLineValidationAcceptsWhitespaceAndRejectsInvalidRanges() throws {
        #expect(try GoToLineValidator.validate(" 12 ", maximumLine: 20) == 12)

        #expect(throws: GoToLineValidationError.empty) {
            try GoToLineValidator.validate("  ", maximumLine: 20)
        }
        #expect(throws: GoToLineValidationError.notPositiveInteger) {
            try GoToLineValidator.validate("1.5", maximumLine: 20)
        }
        #expect(throws: GoToLineValidationError.notPositiveInteger) {
            try GoToLineValidator.validate("0", maximumLine: 20)
        }
        #expect(throws: GoToLineValidationError.outOfRange(maximum: 20)) {
            try GoToLineValidator.validate("21", maximumLine: 20)
        }
    }
}
