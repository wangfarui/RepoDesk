import Foundation
import Testing
@testable import RepoDesk

struct FileSystemPathCopyTests {
    @Test func resolvesFilePathsRelativeToVisibleRoot() throws {
        let rootURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let itemURL = rootURL.appendingPathComponent("src/App.swift")
        let values = try #require(
            FileSystemPathCopyValues(itemURL: itemURL, rootURL: rootURL)
        )

        #expect(values.name == "App.swift")
        #expect(values.relativePath == "src/App.swift")
        #expect(values.absolutePath == "/workspace/src/App.swift")
    }

    @Test func resolvesRepositoryRelativePaths() throws {
        let rootURL = URL(fileURLWithPath: "/workspace/repo", isDirectory: true)
        let values = try #require(
            FileSystemPathCopyValues(
                relativePath: "src/App.swift",
                rootURL: rootURL
            )
        )

        #expect(values.name == "App.swift")
        #expect(values.relativePath == "src/App.swift")
        #expect(values.absolutePath == "/workspace/repo/src/App.swift")
    }

    @Test func resolvesDirectoryName() throws {
        let rootURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        let values = try #require(
            FileSystemPathCopyValues(itemURL: directoryURL, rootURL: rootURL)
        )

        #expect(values.name == "Sources")
    }

    @Test func restoresModulePrefixForCompactDirectoryPaths() {
        #expect(
            FileSystemPathCopyValues.repositoryDirectoryPath(
                path: "src/main/java",
                modulePath: "service"
            ) == "service/src/main/java"
        )
        #expect(
            FileSystemPathCopyValues.repositoryDirectoryPath(
                path: "src/main/java",
                modulePath: "."
            ) == "src/main/java"
        )
    }

    @Test func rejectsPathsOutsideTheVisibleRoot() {
        let rootURL = URL(fileURLWithPath: "/workspace/repo", isDirectory: true)

        #expect(
            FileSystemPathCopyValues(
                itemURL: URL(fileURLWithPath: "/workspace/other/App.swift"),
                rootURL: rootURL
            ) == nil
        )
        #expect(
            FileSystemPathCopyValues(
                relativePath: "../other/App.swift",
                rootURL: rootURL
            ) == nil
        )
    }
}
