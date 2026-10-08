import Foundation
import Testing
@testable import RepoDesk

struct WorkspaceFileTransferTests {
    @Test func copiesCompleteDirectoryTree() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let sourceDirectory = fixture.sourceRoot.appendingPathComponent("Feature", isDirectory: true)
        let nestedDirectory = sourceDirectory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("content".utf8).write(
            to: nestedDirectory.appendingPathComponent("File.txt")
        )
        let transfer = FileSystemWorkspaceFileTransfer()

        let plan = try await transfer.preparePaste(
            sourceURLs: [sourceDirectory],
            destinationDirectoryURL: fixture.destinationRoot
        )
        let result = try await transfer.executePaste(plan, resolution: .replace)

        #expect(plan.conflictingDestinationURLs.isEmpty)
        #expect(result.items.map(\.destinationURL.lastPathComponent) == ["Feature"])
        let copiedText = try String(
            contentsOf: fixture.destinationRoot
                .appendingPathComponent("Feature/Nested/File.txt"),
            encoding: .utf8
        )
        #expect(copiedText == "content")
    }

    @Test func conflictCanKeepBothOrReplaceExistingItem() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let sourceFile = fixture.sourceRoot.appendingPathComponent("notes.txt")
        let destinationFile = fixture.destinationRoot.appendingPathComponent("notes.txt")
        try Data("new".utf8).write(to: sourceFile)
        try Data("old".utf8).write(to: destinationFile)
        let transfer = FileSystemWorkspaceFileTransfer()

        let keepBothPlan = try await transfer.preparePaste(
            sourceURLs: [sourceFile],
            destinationDirectoryURL: fixture.destinationRoot
        )
        let keepBothResult = try await transfer.executePaste(
            keepBothPlan,
            resolution: .keepBoth
        )

        #expect(keepBothPlan.conflictingDestinationURLs == [destinationFile])
        #expect(keepBothResult.items.first?.destinationURL.lastPathComponent == "notes copy.txt")
        #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "old")

        try Data("newer".utf8).write(to: sourceFile)
        let replacePlan = try await transfer.preparePaste(
            sourceURLs: [sourceFile],
            destinationDirectoryURL: fixture.destinationRoot
        )
        _ = try await transfer.executePaste(replacePlan, resolution: .replace)

        #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "newer")
    }

    @Test func rejectsCopyingDirectoryIntoItsDescendant() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let sourceDirectory = fixture.sourceRoot.appendingPathComponent("Feature", isDirectory: true)
        let nestedDirectory = sourceDirectory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let transfer = FileSystemWorkspaceFileTransfer()

        await #expect(throws: WorkspaceFileTransferError.destinationInsideSource("Feature")) {
            try await transfer.preparePaste(
                sourceURLs: [sourceDirectory],
                destinationDirectoryURL: nestedDirectory
            )
        }
    }

    @Test func deletesFileAndDirectoryContents() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let fileURL = fixture.destinationRoot.appendingPathComponent("notes.txt")
        let directoryURL = fixture.destinationRoot.appendingPathComponent("Feature", isDirectory: true)
        try Data("notes".utf8).write(to: fileURL)
        try FileManager.default.createDirectory(
            at: directoryURL.appendingPathComponent("Nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("content".utf8).write(
            to: directoryURL.appendingPathComponent("Nested/File.txt")
        )
        let deleter = FileSystemWorkspaceFileDeleter()

        try await deleter.delete(
            WorkspaceFileDeletionRequest(itemURL: fileURL, workspaceRootURL: fixture.destinationRoot)
        )
        try await deleter.delete(
            WorkspaceFileDeletionRequest(itemURL: directoryURL, workspaceRootURL: fixture.destinationRoot)
        )

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
    }

    @Test func deletedItemCanBeRestoredToItsOriginalPath() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let fileURL = fixture.destinationRoot.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: fileURL)
        let backupURL = fixture.destinationRoot.appendingPathComponent(".backup", isDirectory: true)
        let deleter = FileSystemWorkspaceFileDeleter()

        let deletedItem = try await deleter.delete(
            WorkspaceFileDeletionRequest(
                itemURL: fileURL,
                workspaceRootURL: fixture.destinationRoot,
                backupDirectoryURL: backupURL
            )
        )
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        try await deleter.restore(
            WorkspaceFileDeletionSession(
                items: [deletedItem],
                backupDirectoryURL: backupURL,
                workspaceRootURL: fixture.destinationRoot
            )
        )

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "notes")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test func refusesToDeleteWorkspaceRoot() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let deleter = FileSystemWorkspaceFileDeleter()

        await #expect(throws: WorkspaceFileDeletionError.invalidTarget) {
            try await deleter.delete(
                WorkspaceFileDeletionRequest(
                    itemURL: fixture.destinationRoot,
                    workspaceRootURL: fixture.destinationRoot
                )
            )
        }
    }

    @Test func renamesFileAndDirectoryItems() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let fileURL = fixture.destinationRoot.appendingPathComponent("notes.txt")
        let directoryURL = fixture.destinationRoot.appendingPathComponent("Feature", isDirectory: true)
        try Data("notes".utf8).write(to: fileURL)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let renamer = FileSystemWorkspaceFileRenamer()

        let renamedFileURL = try await renamer.rename(
            WorkspaceFileRenameRequest(
                itemURL: fileURL,
                newName: "README.md",
                workspaceRootURL: fixture.destinationRoot
            )
        )
        let renamedDirectoryURL = try await renamer.rename(
            WorkspaceFileRenameRequest(
                itemURL: directoryURL,
                newName: "Sources",
                workspaceRootURL: fixture.destinationRoot
            )
        )

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try String(contentsOf: renamedFileURL, encoding: .utf8) == "notes")
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
        #expect(FileManager.default.fileExists(atPath: renamedDirectoryURL.path))
    }

    @Test func renameSupportsCaseOnlyNameChange() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let fileURL = fixture.destinationRoot.appendingPathComponent("Readme.md")
        try Data("notes".utf8).write(to: fileURL)
        let renamer = FileSystemWorkspaceFileRenamer()

        let renamedURL = try await renamer.rename(
            WorkspaceFileRenameRequest(
                itemURL: fileURL,
                newName: "README.md",
                workspaceRootURL: fixture.destinationRoot
            )
        )

        #expect(renamedURL.lastPathComponent == "README.md")
        #expect(FileManager.default.fileExists(atPath: renamedURL.path))
        #expect(try String(contentsOf: renamedURL, encoding: .utf8) == "notes")
    }

    @Test func renameRejectsInvalidTargetsAndConflicts() async throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let fileURL = fixture.destinationRoot.appendingPathComponent("notes.txt")
        let existingURL = fixture.destinationRoot.appendingPathComponent("README.md")
        try Data("notes".utf8).write(to: fileURL)
        try Data("readme".utf8).write(to: existingURL)
        let renamer = FileSystemWorkspaceFileRenamer()

        await #expect(throws: WorkspaceFileRenameError.invalidTarget) {
            try await renamer.rename(
                WorkspaceFileRenameRequest(
                    itemURL: fixture.destinationRoot,
                    newName: "workspace-renamed",
                    workspaceRootURL: fixture.destinationRoot
                )
            )
        }
        await #expect(throws: WorkspaceFileRenameError.invalidName) {
            try await renamer.rename(
                WorkspaceFileRenameRequest(
                    itemURL: fileURL,
                    newName: "nested/notes.txt",
                    workspaceRootURL: fixture.destinationRoot
                )
            )
        }
        await #expect(throws: WorkspaceFileRenameError.itemAlreadyExists("README.md")) {
            try await renamer.rename(
                WorkspaceFileRenameRequest(
                    itemURL: fileURL,
                    newName: "README.md",
                    workspaceRootURL: fixture.destinationRoot
                )
            )
        }
    }

    @MainActor
    @Test func clipboardFilterAcceptsFileSystemItemsAndIgnoresOtherContent() throws {
        let fixture = try FileTransferFixture()
        defer { fixture.remove() }
        let sourceDirectory = fixture.sourceRoot.appendingPathComponent("Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let nonexistentFile = fixture.sourceRoot.appendingPathComponent("missing.txt")
        let webURL = try #require(URL(string: "https://example.com/image.png"))

        #expect(FileSystemClipboard.supportedFileURLs([sourceDirectory]) == [sourceDirectory])
        #expect(FileSystemClipboard.supportedFileURLs([]).isEmpty)
        #expect(
            FileSystemClipboard.supportedFileURLs([nonexistentFile, webURL]).isEmpty
        )
    }
}

private struct FileTransferFixture {
    let root: URL
    let sourceRoot: URL
    let destinationRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RepoDeskFileTransferTests-\(UUID().uuidString)",
            isDirectory: true
        )
        sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
