import Foundation

enum FileSystemPathCopyVerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

@main
enum FileSystemPathCopyVerification {
    static func main() throws {
        let workspaceRoot = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let fileValues = try require(
            FileSystemPathCopyValues(
                itemURL: workspaceRoot.appendingPathComponent("src/App.swift"),
                rootURL: workspaceRoot
            ),
            "A file under the visible root should have copyable paths."
        )
        try expect(fileValues.name == "App.swift", "The file name is incorrect.")
        try expect(fileValues.relativePath == "src/App.swift", "The relative file path is incorrect.")
        try expect(fileValues.absolutePath == "/workspace/src/App.swift", "The absolute file path is incorrect.")

        let directoryValues = try require(
            FileSystemPathCopyValues(
                itemURL: workspaceRoot.appendingPathComponent("Sources", isDirectory: true),
                rootURL: workspaceRoot
            ),
            "A directory under the visible root should have a copyable name."
        )
        try expect(directoryValues.name == "Sources", "The directory name is incorrect.")

        let repositoryRoot = URL(fileURLWithPath: "/workspace/repo", isDirectory: true)
        let repositoryValues = try require(
            FileSystemPathCopyValues(
                relativePath: "src/App.swift",
                rootURL: repositoryRoot
            ),
            "A repository-relative path should be copyable."
        )
        try expect(repositoryValues.name == "App.swift", "The repository file name is incorrect.")
        try expect(repositoryValues.relativePath == "src/App.swift", "The repository-relative path changed.")
        try expect(
            repositoryValues.absolutePath == "/workspace/repo/src/App.swift",
            "The repository absolute path is incorrect."
        )

        try expect(
            FileSystemPathCopyValues.repositoryDirectoryPath(
                path: "src/main/java",
                modulePath: "service"
            ) == "service/src/main/java",
            "A grouped directory should restore its module prefix."
        )
        try expect(
            FileSystemPathCopyValues.repositoryDirectoryPath(
                path: "src/main/java",
                modulePath: "."
            ) == "src/main/java",
            "The repository-root module should not add a prefix."
        )

        try expect(
            FileSystemPathCopyValues(
                itemURL: URL(fileURLWithPath: "/workspace/other/App.swift"),
                rootURL: repositoryRoot
            ) == nil,
            "An item outside the root must not expose a copy menu."
        )
        try expect(
            FileSystemPathCopyValues(
                relativePath: "../other/App.swift",
                rootURL: repositoryRoot
            ) == nil,
            "A repository-relative path must not escape its root."
        )

        print("File-system path copy verification passed")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FileSystemPathCopyVerificationError.failed(message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FileSystemPathCopyVerificationError.failed(message) }
    }
}
