import Foundation
import Testing
@testable import RepoDesk

struct FilesModuleTests {
    @Test func fileBlameTargetUsesDeepestContainingRepository() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let repositories = [
            RegisteredRepository(displayName: "root", relativePath: ".", isPinned: true),
            RegisteredRepository(displayName: "nested", relativePath: "services/nested", isPinned: true)
        ]
        let fileURL = workspaceURL.appendingPathComponent("services/nested/Sources/App.swift")

        let target = GitFileBlameTarget.resolve(
            fileURL: fileURL,
            workspaceURL: workspaceURL,
            repositories: repositories
        )

        #expect(target?.repositoryID == "services/nested")
        #expect(
            target?.repositoryURL
                == workspaceURL.appendingPathComponent("services/nested", isDirectory: true)
        )
        #expect(target?.path == "Sources/App.swift")
    }

    @Test func fileBlameTargetRejectsFilesOutsideRegisteredRepositories() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let target = GitFileBlameTarget.resolve(
            fileURL: workspaceURL.appendingPathComponent("unregistered/file.txt"),
            workspaceURL: workspaceURL,
            repositories: [
                RegisteredRepository(displayName: "service", relativePath: "service", isPinned: true)
            ]
        )

        #expect(target == nil)
    }

    @Test func browserSortsDirectoriesBeforeFiles() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("text".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))

        let entries = try await FileSystemWorkspaceBrowser().children(of: fixture.root)

        #expect(entries.map(\.name) == ["folder", "file.txt"])
    }

    @Test func loaderDistinguishesTextAndBinary() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let textURL = fixture.root.appendingPathComponent("source.swift")
        let binaryURL = fixture.root.appendingPathComponent("binary.dat")
        let utf16URL = fixture.root.appendingPathComponent("utf16.txt")
        try Data("let value = 1".utf8).write(to: textURL)
        try Data([0, 1, 2, 3]).write(to: binaryURL)
        try "hello".data(using: .utf16)!.write(to: utf16URL)
        let loader = FileSystemDocumentLoader()
        let text = await loader.load(textURL)
        let binary = await loader.load(binaryURL)
        let utf16 = await loader.load(utf16URL)

        guard case .text(let textDocument) = text else {
            Issue.record("Expected a text document")
            return
        }
        #expect(textDocument.text == "let value = 1")
        #expect(textDocument.encoding == .utf8)
        #expect(textDocument.isLarge == false)
        #expect(binary == .binary(size: 4))
        guard case .text(let utf16Document) = utf16 else {
            Issue.record("Expected a UTF-16 text document")
            return
        }
        #expect(utf16Document.text == "hello")
        #expect([.utf16LittleEndian, .utf16BigEndian].contains(utf16Document.encoding))
    }

    @Test func saverPreservesEncodingAndRejectsExternalChanges() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let fileURL = fixture.root.appendingPathComponent("notes.txt")
        let originalData = Data([0xEF, 0xBB, 0xBF]) + Data("first".utf8)
        try originalData.write(to: fileURL)
        let store = FileSystemDocumentStore()
        let loaded = await store.load(fileURL)
        guard case .text(let document) = loaded else {
            Issue.record("Expected a text document")
            return
        }

        let savedRevision = try await store.save(
            DocumentSaveRequest(
                fileURL: fileURL,
                text: "second",
                encoding: document.encoding,
                expectedRevision: document.revision,
                allowsOverwrite: false
            )
        )
        let savedData = try Data(contentsOf: fileURL)
        #expect(savedData.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(savedRevision == FileSystemDocumentStore.revision(for: savedData))

        try Data("external".utf8).write(to: fileURL)
        do {
            _ = try await store.save(
                DocumentSaveRequest(
                    fileURL: fileURL,
                    text: "third",
                    encoding: document.encoding,
                    expectedRevision: savedRevision,
                    allowsOverwrite: false
                )
            )
            Issue.record("Expected the external modification to be rejected")
        } catch let error as DocumentSaveError {
            #expect(error == .changedOnDisk)
        }
    }

    @Test func saverPreservesExecutablePermissionAndSymbolicLink() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let targetURL = fixture.root.appendingPathComponent("script.sh")
        let linkURL = fixture.root.appendingPathComponent("script-link.sh")
        try Data("echo first\n".utf8).write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetURL.path)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let store = FileSystemDocumentStore()
        let loaded = await store.load(linkURL)
        guard case .text(let document) = loaded else {
            Issue.record("Expected a text document through the symbolic link")
            return
        }

        _ = try await store.save(
            DocumentSaveRequest(
                fileURL: linkURL,
                text: "echo second\n",
                encoding: document.encoding,
                expectedRevision: document.revision,
                allowsOverwrite: false
            )
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        let linkValues = try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(linkValues.isSymbolicLink == true)
        let savedText = try String(contentsOf: targetURL, encoding: .utf8)
        #expect(savedText == "echo second\n")
    }

    @Test func refreshPlannerUpdatesOnlyAffectedLoadedDirectories() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let sourceURL = workspaceURL.appendingPathComponent("Sources", isDirectory: true)
        let nestedURL = sourceURL.appendingPathComponent("Feature", isDirectory: true)
        let docsURL = workspaceURL.appendingPathComponent("Docs", isDirectory: true)
        let changedFileURL = nestedURL.appendingPathComponent("Screen.swift")
        let batch = WorkspaceChangeBatch(
            changedURLs: [changedFileURL],
            requiresFullRescan: false,
            monitoringError: nil
        )

        let directories = WorkspaceTreeRefreshPlanner.directoriesToRefresh(
            for: batch,
            workspaceURL: workspaceURL,
            loadedDirectoryURLs: [workspaceURL, sourceURL, nestedURL, docsURL]
        )

        #expect(directories == [nestedURL])
    }

    @Test func refreshPlannerRefreshesLoadedSubtreeForDirectoryEvent() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let sourceURL = workspaceURL.appendingPathComponent("Sources", isDirectory: true)
        let nestedURL = sourceURL.appendingPathComponent("Feature", isDirectory: true)
        let docsURL = workspaceURL.appendingPathComponent("Docs", isDirectory: true)
        let batch = WorkspaceChangeBatch(
            changedURLs: [sourceURL],
            requiresFullRescan: false,
            monitoringError: nil
        )

        let directories = WorkspaceTreeRefreshPlanner.directoriesToRefresh(
            for: batch,
            workspaceURL: workspaceURL,
            loadedDirectoryURLs: [workspaceURL, sourceURL, nestedURL, docsURL]
        )

        #expect(directories == [workspaceURL, sourceURL, nestedURL])
    }

    @Test func workspaceRootFileDoesNotAffectNestedRepository() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("nested-repository", isDirectory: true)
        let batch = WorkspaceChangeBatch(
            changedURLs: [workspaceURL.appendingPathComponent("AGENTS.md")],
            requiresFullRescan: false,
            monitoringError: nil
        )

        #expect(!WorkspaceTreeRefreshPlanner.batch(batch, affectsRepositoryAt: repositoryURL))
    }

    @Test func repositoryFileAffectsItsRepository() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("nested-repository", isDirectory: true)
        let batch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL.appendingPathComponent("Sources/App.swift")],
            requiresFullRescan: false,
            monitoringError: nil
        )

        #expect(WorkspaceTreeRefreshPlanner.batch(batch, affectsRepositoryAt: repositoryURL))
    }

    @Test func repositoryDirectoryEventAffectsRepository() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("nested-repository", isDirectory: true)
        let batch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL],
            requiresFullRescan: false,
            monitoringError: nil
        )

        #expect(WorkspaceTreeRefreshPlanner.batch(batch, affectsRepositoryAt: repositoryURL))
    }

    @Test func markdownPreviewParserCreatesBlockLevelStructure() {
        let source = """
        # Heading

        Paragraph text.

        - First item

        ```swift
        let value = 1
        ```

        | Name | Value |
        | --- | --- |
        | one | 1 |
        """

        let blocks = MarkdownPreviewParser.parse(source)

        #expect(blocks.contains(.heading(level: 1, text: "Heading")))
        #expect(blocks.contains(.listItem(MarkdownPreviewListItem(marker: .unordered, depth: 0, text: "First item"))))
        #expect(blocks.contains(.codeBlock(language: "swift", code: "let value = 1")))
        #expect(blocks.contains(.table(headers: ["Name", "Value"], rows: [["one", "1"]])))
    }
}

private struct FileFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
