import Foundation
import Testing
@testable import RepoDesk

struct RepositoryRegistrationTests {
    @Test func acceptsGitDirectoryAndGitFile() throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let directoryRepository = try fixture.createRepository(at: "directory-repo", gitMarkerIsFile: false)
        let fileRepository = try fixture.createRepository(at: "file-repo", gitMarkerIsFile: true)

        let first = try RepositoryRegistration.make(
            directoryURL: directoryRepository,
            workspaceURL: fixture.workspaceURL
        )
        let second = try RepositoryRegistration.make(
            directoryURL: fileRepository,
            workspaceURL: fixture.workspaceURL
        )

        #expect(first.relativePath == "directory-repo")
        #expect(second.relativePath == "file-repo")
    }

    @Test func rejectsDirectoryOutsideWorkspace() throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let outside = fixture.rootURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        #expect(throws: RepositoryRegistrationError.outsideWorkspace(outside.path)) {
            try RepositoryRegistration.make(
                directoryURL: outside,
                workspaceURL: fixture.workspaceURL
            )
        }
    }

    @Test func discoverySkipsBuildAndDependencyDirectories() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        _ = try fixture.createRepository(at: "service", gitMarkerIsFile: false)
        _ = try fixture.createRepository(at: "target/generated-repo", gitMarkerIsFile: false)
        _ = try fixture.createRepository(at: "node_modules/dependency", gitMarkerIsFile: false)

        let repositories = await FileSystemRepositoryDiscoverer()
            .discoverRepositories(in: fixture.workspaceURL)

        #expect(repositories.map(\.relativePath) == ["service"])
    }
}

private struct RepositoryFixture {
    let rootURL: URL
    let workspaceURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskTests-\(UUID().uuidString)", isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }

    func createRepository(at relativePath: String, gitMarkerIsFile: Bool) throws -> URL {
        let repositoryURL = workspaceURL.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let markerURL = repositoryURL.appendingPathComponent(".git", isDirectory: !gitMarkerIsFile)
        if gitMarkerIsFile {
            try Data("gitdir: ../metadata".utf8).write(to: markerURL)
        } else {
            try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)
        }
        return repositoryURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
