import Foundation

@main
struct VerifyGitBlame {
    static func main() throws {
        let data = Data("""
        ^1111111111111111111111111111111111111111 1 1 1
        author Alice
        author-time 1704067200
        filename file.txt
        \tcommitted
        0000000000000000000000000000000000000000 2 2 1
        author Not Committed Yet
        author-time 1704153600
        filename file.txt
        \tuncommitted
        """.utf8)
        let lines = GitBlameParser.parse(data)
        try require(lines.count == 2, "Blame parser returned an unexpected line count")
        try require(lines[0].author == "Alice", "Committed author was not parsed")
        try require(lines[1].isUncommitted, "Working tree line was not marked uncommitted")

        let duplicate = GitBlameLine(
            lineNumber: 2,
            commitHash: "replacement",
            author: "Replacement",
            authoredAt: nil
        )
        let indexed = (lines + [duplicate]).indexedByLineNumber
        try require(indexed.count == 2, "Duplicate blame line created an extra entry")
        try require(indexed[2] == duplicate, "Duplicate blame line did not safely overwrite")
        let crlfData = Data(
            "1111111111111111111111111111111111111111 1 1 1\n"
                .appending("author Alice\n")
                .appending("author-time 1704067200\n")
                .appending("filename file.txt\n")
                .appending("\tfirst\r\n")
                .appending("2222222222222222222222222222222222222222 2 2 1\n")
                .appending("author Bob\n")
                .appending("author-time 1704153600\n")
                .appending("filename file.txt\n")
                .appending("\tsecond\r\n")
                .utf8
        )
        let crlfLines = GitBlameParser.parse(crlfData)
        try require(crlfLines.map(\.lineNumber) == [1, 2], "CRLF blame lost subsequent line headers")
        try verifyRealRepositoryBlame()
        print("Git blame verification passed")
    }

    private static func verifyRealRepositoryBlame() throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskBlameVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        try runGit(["init", "--initial-branch", "main"], at: repositoryURL)
        try runGit(["config", "user.email", "repodesk@example.invalid"], at: repositoryURL)
        try runGit(["config", "user.name", "RepoDesk Author"], at: repositoryURL)
        let fileURL = repositoryURL.appendingPathComponent("file.txt")
        try Data("first\nsecond\n".utf8).write(to: fileURL)
        try runGit(["add", "file.txt"], at: repositoryURL)
        try runGit(["commit", "--message", "Initial"], at: repositoryURL)
        try Data("first\nsecond\nworking\n".utf8).write(to: fileURL)

        let oldData = try gitOutput(
            ["blame", "--line-porcelain", "HEAD", "--", "file.txt"],
            at: repositoryURL
        )
        let newData = try gitOutput(
            ["blame", "--line-porcelain", "--contents", "file.txt", "--", "file.txt"],
            at: repositoryURL
        )
        let oldLines = GitBlameParser.parse(oldData)
        let newLines = GitBlameParser.parse(newData)
        try require(oldLines.count == 2, "HEAD blame did not cover every committed line")
        try require(newLines.count == 3, "Working tree blame did not cover every current line")
        try require(newLines.last?.isUncommitted == true, "Working tree addition was not uncommitted")
    }

    private static func runGit(_ arguments: [String], at repositoryURL: URL) throws {
        _ = try gitOutput(arguments, at: repositoryURL)
    }

    private static func gitOutput(_ arguments: [String], at repositoryURL: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryURL.path] + arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VerificationError(
                message: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError(message: message) }
    }
}

private struct VerificationError: Error {
    let message: String
}
