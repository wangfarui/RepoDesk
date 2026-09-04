import Foundation
import Testing
@testable import RepoDesk

struct WorkspaceTextSearchTests {
    @Test func searchesTextWithinTheVisibleRootAndReturnsLineNumbers() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-desk-text-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("src/main/App.java")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "class App {\n  String value = \"needle\";\n}\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "needle outside".write(
            to: rootURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let results = await FileSystemWorkspaceTextSearch().search(in: rootURL, query: "NEEDLE", limit: 20)

        #expect(results.count == 2)
        #expect(results.contains { $0.fileURL.lastPathComponent == "App.java" && $0.line == 2 })
        #expect(results.map(\.lineText).contains("needle outside"))
    }
}
