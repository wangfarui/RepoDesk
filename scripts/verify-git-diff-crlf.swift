import Foundation

private struct GitDiffCRLFVerificationError: Error {
    let message: String
}

@main
enum GitDiffCRLFVerification {
    static func main() throws {
        let fileLines = GitDiffParser.lines(from: Data("first\r\nsecond\r\n".utf8))
        try require(fileLines == ["first", "second"], "CRLF file lines retained carriage returns.")

        let patch = """
        @@ -1 +1,2 @@
         first\r
        +inserted\r
        """
        let hunks = GitDiffParser.parseHunks(patch)
        try require(hunks.count == 1, "CRLF patch did not produce one hunk.")
        try require(
            hunks[0].lines.map(\.text) == ["first", "inserted"],
            "CRLF hunk lines retained carriage returns."
        )
        try require(
            hunks[0].lines.map(\.kind) == [.context, .addition],
            "CRLF hunk line kinds were parsed incorrectly."
        )
        print("Git diff CRLF verification passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GitDiffCRLFVerificationError(message: message) }
    }
}
