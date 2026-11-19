import Foundation
import Testing
@testable import RepoDesk

struct WorkspaceFileSearchTests {
    @Test func searchesAllFileTypesWithFuzzyFileNameRanking() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-desk-file-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let files = [
            "UserService.java",
            "UserServiceTest.java",
            "UserRepository.swift",
            "OrderService.java",
            "user-config.yaml",
            "README.md",
            ".env",
            ".git/HiddenService.java"
        ]
        for path in files {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        let results = await FileSystemWorkspaceSearch().search(in: rootURL, query: "UsrSrv", limit: 100)

        #expect(results.map(\.name) == ["UserService.java", "UserServiceTest.java"])

        let nonJavaResults = await FileSystemWorkspaceSearch().search(in: rootURL, query: "UsrCfg", limit: 100)
        #expect(nonJavaResults.map(\.name) == ["user-config.yaml"])
    }

    @Test func supportsFilenameSuffixAndHonorsLimit() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-desk-file-search-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for name in ["Alpha.java", "Alpine.java", "Algebra.java"] {
            try Data().write(to: rootURL.appendingPathComponent(name))
        }

        let results = await FileSystemWorkspaceSearch().search(in: rootURL, query: "Al.java", limit: 2)

        #expect(results.count == 2)
        #expect(results.map(\.name) == ["Alpha.java", "Alpine.java"])
    }

    @Test func skipsHiddenFilesAndIgnoredDirectories() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-desk-file-search-hidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for path in ["visible.txt", ".hidden.txt", ".git/visible.txt", "target/visible.txt"] {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        let results = await FileSystemWorkspaceSearch().search(in: rootURL, query: "visible", limit: 100)

        #expect(results.map(\.name) == ["visible.txt"])
    }
}
