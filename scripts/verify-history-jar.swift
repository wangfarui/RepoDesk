import Foundation
@testable import RepoDesk

private struct HistoryJarVerificationError: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw HistoryJarVerificationError(description: message) }
}

/// Real Git objects, compiler output, and ZIP compression keep this test independent of the archive parser.
private struct HistoryJarFixture {
    let root: URL
    let repository: URL
    let source: URL
    let contents: URL
    let java: URL
    let compiler: URL
    let jarPath = "libraries/fixture.jar"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoDesk-HistoryJar-\(UUID().uuidString)")
        repository = root.appendingPathComponent("repository")
        source = root.appendingPathComponent("source")
        contents = root.appendingPathComponent("contents")
        for directory in [repository, source, contents, repository.appendingPathComponent("libraries")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        do {
            let runtime = try JavaLanguageRuntime.resolve()
            java = runtime.javaExecutableURL
            let plugins = runtime.jdtRootURL.appendingPathComponent("plugins")
            guard let compilerURL = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix("org.eclipse.jdt.core.compiler.batch_")
                    && $0.pathExtension == "jar" }) else {
                throw HistoryJarVerificationError(description: "Bundled Eclipse Java compiler is missing.")
            }
            compiler = compilerURL
            try git(["init", "--initial-branch=main"])
            try git(["config", "user.name", "RepoDesk Verification"])
            try git(["config", "user.email", "repodesk@example.test"])
            try git(["config", "commit.gpgsign", "false"])
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func prepare(version: Int, debugMetadata: Bool) throws {
        let description = version == 1 ? "old-note 费用量取值（1一口价）" : "new-note 费用量取值（1一口价 7按预提）"
        let field = version == 1 ? "int count = 1" : "long count = 2L"
        let inner = version == 1 ? "inner-before" : "inner-after"
        let demo = """
        package sample;
        import java.lang.annotation.Retention;
        import java.lang.annotation.RetentionPolicy;
        @Retention(RetentionPolicy.RUNTIME)
        @interface Description { String value(); }
        public class Demo {
            @Description("\(description)") public \(field);
            public String 中文字段 = "真实内容😀";
            public String literalEscapes() { return "\\\\u4e2d\\\\n\\\\t"; }
            public String controls() { return "他说：\\\"你好\\\"\\n下一行\\t尾行"; }
            public int calculate(int input) { return input + \(version); }
            public static class Nested {
                public String value() { return "\(inner)"; }
            }
        }
        """
        let metadata = """
        package sample;
        public class MetadataOnly {
            public int stable() { return 17; }
        }
        """
        try write(demo, to: source.appendingPathComponent("Demo.java"))
        try write(metadata, to: source.appendingPathComponent("MetadataOnly.java"))
        _ = try Self.run(java.path, ["-jar", compiler.path, "-encoding", "UTF-8", "-source", "1.8", "-target", "1.8", "-g:none",
                                    "-d", contents.path, source.appendingPathComponent("Demo.java").path], in: root)
        _ = try Self.run(java.path, ["-jar", compiler.path, "-encoding", "UTF-8", "-17", debugMetadata ? "-g:lines,source" : "-g:none",
                                    "-d", contents.path, source.appendingPathComponent("MetadataOnly.java").path], in: root)
        try write("version=\(version)\n", to: contents.appendingPathComponent("config.properties"))
        try write("unchanged\n", to: contents.appendingPathComponent("unchanged.txt"))
        try Data([0xff, 0x81, 0xfe]).write(to: contents.appendingPathComponent("legacy-encoding.txt"))
        try Data([0, 1, 2, 3]).write(to: contents.appendingPathComponent("binary.bin"))
        try Data([0xca, 0xfe, 0xba, 0xbe, 0]).write(to: contents.appendingPathComponent("broken.class"))
        if version == 1 {
            try write("removed entry\n", to: contents.appendingPathComponent("deleted.txt"))
        } else {
            try FileManager.default.removeItem(at: contents.appendingPathComponent("deleted.txt"))
            try write("new entry\n", to: contents.appendingPathComponent("added.txt"))
        }
        try archive(compression: "-9")
    }

    func archive(compression: String) throws {
        let destination = repository.appendingPathComponent(jarPath)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        _ = try Self.run("/usr/bin/zip", ["-q", compression, "-r", destination.path, "."], in: contents)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        try Self.run("/usr/bin/git", arguments, in: repository)
    }

    func commit(_ message: String) throws -> String {
        try git(["add", "--all"])
        try git(["commit", "-m", message])
        return try git(["rev-parse", "HEAD"])
    }

    func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(process.terminationStatus == 0, "\(executable) failed: \(text)")
        return text
    }
}

@main
enum VerifyHistoryJar {
    static func main() async throws {
        let fixture = try HistoryJarFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = HistoryJarComparisonService()
        let addedFile = GitCommitFile(path: fixture.jarPath, originalPath: nil, status: .added)
        let modifiedFile = GitCommitFile(path: fixture.jarPath, originalPath: nil, status: .modified)

        try fixture.prepare(version: 1, debugMetadata: false)
        let first = try fixture.commit("initial JAR")
        let initial = try await service.compare(repositoryURL: fixture.repository, hash: first,
                                                file: addedFile, parentHash: nil)
        try require(initial.entries.count >= 8 && initial.entries.allSatisfy { $0.change == .added },
                    "Root commit must compare every JAR entry against an empty version.")
        let initialClass = try await preview("sample/Demo.class", in: initial, using: service)
        try require(initialClass.diff?.oldLines.isEmpty == true && initialClass.diff?.newLines.isEmpty == false,
                    "An added class must display Java only on the new side.")

        try fixture.prepare(version: 2, debugMetadata: true)
        let second = try fixture.commit("class, resource, and entry changes")
        let historicalJar = try Data(contentsOf: fixture.repository.appendingPathComponent(fixture.jarPath))
        // A corrupt current file proves previews are obtained from Git blobs, not the checkout.
        try fixture.write("working tree is deliberately not a ZIP", to: fixture.repository.appendingPathComponent(fixture.jarPath))
        let changed = try await service.compare(repositoryURL: fixture.repository, hash: second,
                                                file: modifiedFile, parentHash: first)
        try require(try entry("sample/Demo.class", in: changed).change == .modified, "Class change was not listed.")
        try require(try entry("deleted.txt", in: changed).change == .deleted, "Removed entry was not listed.")
        try require(try entry("added.txt", in: changed).change == .added, "Added entry was not listed.")
        try require(try entry("unchanged.txt", in: changed).change == .unchanged, "Unchanged entry was reported as modified.")

        let java = try await preview("sample/Demo.class", in: changed, using: service)
        let oldJava = java.diff?.oldLines.joined(separator: "\n") ?? ""
        let newJava = java.diff?.newLines.joined(separator: "\n") ?? ""
        try require(oldJava.contains("费用量取值（1一口价）") && newJava.contains("费用量取值（1一口价 7按预提）"),
                    "Decompiled annotation text must show readable Chinese instead of Unicode escape sequences.")
        try require(oldJava.contains("中文字段") && oldJava.contains("真实内容😀")
                    && newJava.contains("中文字段") && newJava.contains("真实内容😀"),
                    "Decompiled identifiers, strings, and supplementary Unicode characters must remain readable under LC_ALL=C.")
        try require(oldJava.contains(#"\\u4e2d\\n\\t"#) && newJava.contains(#"\\u4e2d\\n\\t"#)
                    && oldJava.contains(#"他说：\"你好\"\n下一行\t尾行"#),
                    "Readable Unicode must preserve literal backslash sequences, escaped quotes, newlines, and tabs.")
        try require(java.diff?.path == "sample/Demo.java", "Class preview must use a Java path for syntax highlighting.")
        try require(oldJava.contains("old-note") && newJava.contains("new-note")
                    && oldJava.contains("int count") && newJava.contains("long count")
                    && oldJava.contains("+ 1") && newJava.contains("+ 2"),
                    "Decompiled Java lost annotation, field, or method-body changes.")
        try require(java.diff?.hunks.contains { $0.lines.contains { $0.kind == .addition } } == true,
                    "A changed class must produce code difference hunks.")
        let nested = try await preview("sample/Demo$Nested.class", in: changed, using: service)
        try require(nested.diff?.oldLines.joined().contains("inner-before") == true
                    && nested.diff?.newLines.joined().contains("inner-after") == true,
                    "Nested-class method changes were not decompiled.")
        let resource = try await preview("config.properties", in: changed, using: service)
        try require(resource.diff?.oldLines == ["version=1"] && resource.diff?.newLines == ["version=2"],
                    "Text resources must use their original text.")
        let removed = try await preview("deleted.txt", in: changed, using: service)
        let inserted = try await preview("added.txt", in: changed, using: service)
        try require(removed.diff?.newLines.isEmpty == true && inserted.diff?.oldLines.isEmpty == true,
                    "Removed and added entries must have an empty opposite side.")
        for path in ["binary.bin", "legacy-encoding.txt"] {
            let content = try await preview(path, in: changed, using: service)
            try require(content.diff == nil && content.message?.isEmpty == false,
                        "Binary or unsupported encoding must show an explicit explanation: \(path)")
        }
        do {
            _ = try await preview("broken.class", in: changed, using: service)
            throw HistoryJarVerificationError(description: "A damaged class must report decompilation failure.")
        } catch let error as HistoryJarError {
            try require(error.localizedDescription.contains("反编译"), "Damaged-class error must identify decompilation failure.")
        }
        let metadata = try await preview("sample/MetadataOnly.class", in: changed, using: service)
        try require(try entry("sample/MetadataOnly.class", in: changed).change == .modified
                    && metadata.diff?.oldLines == metadata.diff?.newLines
                    && metadata.message?.contains("一致") == true,
                    "Changed class debug metadata must stay readable and explain identical Java output.")
        try require(try Data(contentsOf: fixture.repository.appendingPathComponent(fixture.jarPath))
                    == Data("working tree is deliberately not a ZIP".utf8), "Preview must not modify the working tree.")
        try historicalJar.write(to: fixture.repository.appendingPathComponent(fixture.jarPath))

        try fixture.archive(compression: "-0")
        try require(try Data(contentsOf: fixture.repository.appendingPathComponent(fixture.jarPath)) != historicalJar,
                    "Fixture must actually change ZIP compression or metadata.")
        let metadataCommit = try fixture.commit("ZIP metadata and compression only")
        let repacked = try await service.compare(repositoryURL: fixture.repository, hash: metadataCommit,
                                                 file: modifiedFile, parentHash: nil)
        try require(repacked.entries.allSatisfy { $0.change == .unchanged },
                    "ZIP compression and metadata changes must not report package-content changes.")

        let mergeCommit = try fixture.git(["commit-tree", "\(second)^{tree}", "-p", first,
                                           "-p", metadataCommit, "-m", "two-parent comparison fixture"])
        let againstFirst = try await service.compare(repositoryURL: fixture.repository, hash: mergeCommit,
                                                     file: modifiedFile, parentHash: first)
        let againstSecond = try await service.compare(repositoryURL: fixture.repository, hash: mergeCommit,
                                                      file: modifiedFile, parentHash: metadataCommit)
        try require(try entry("sample/Demo.class", in: againstFirst).change == .modified
                    && againstSecond.entries.allSatisfy { $0.change == .unchanged },
                    "Merge comparison must honor the selected parent instead of always using its first parent.")
        try require(try fixture.git(["rev-parse", "HEAD"]) == metadataCommit,
                    "Reading a merge object must not check it out or alter HEAD.")

        let renamedPath = "libraries/renamed fixture.jar"
        try fixture.git(["mv", "--", fixture.jarPath, renamedPath])
        let renameCommit = try fixture.commit("rename JAR")
        let renameFile = GitCommitFile(path: renamedPath, originalPath: fixture.jarPath, status: .renamed)
        let renamed = try await service.compare(repositoryURL: fixture.repository, hash: renameCommit,
                                                file: renameFile, parentHash: nil)
        try require(renamed.entries.count == repacked.entries.count
                    && renamed.entries.allSatisfy { $0.change == .unchanged },
                    "Whole-JAR rename must resolve the old Git path, including spaces.")
        try fixture.git(["rm", "--", renamedPath])
        let deleteCommit = try fixture.commit("delete JAR")
        let deletedFile = GitCommitFile(path: renamedPath, originalPath: nil, status: .deleted)
        let deleted = try await service.compare(repositoryURL: fixture.repository, hash: deleteCommit,
                                                file: deletedFile, parentHash: nil)
        try require(deleted.entries.count == renamed.entries.count
                    && deleted.entries.allSatisfy { $0.change == .deleted }, "Deleted JAR must preserve its previous entries.")
        let deletedClass = try await preview("sample/Demo.class", in: deleted, using: service)
        try require(deletedClass.diff?.oldLines.isEmpty == false && deletedClass.diff?.newLines.isEmpty == true,
                    "A deleted JAR class must display Java only on the old side.")

        let cancelled = Task {
            try await service.compare(repositoryURL: fixture.repository, hash: second,
                                      file: modifiedFile, parentHash: nil)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw HistoryJarVerificationError(description: "Cancelled JAR selection must not produce a preview.")
        } catch is CancellationError {}

        try FileManager.default.createDirectory(at: fixture.repository.appendingPathComponent("libraries"),
                                                withIntermediateDirectories: true)
        try fixture.write("invalid ZIP", to: fixture.repository.appendingPathComponent(fixture.jarPath))
        let invalidCommit = try fixture.commit("invalid JAR fixture")
        do {
            _ = try await service.compare(repositoryURL: fixture.repository, hash: invalidCommit,
                                          file: addedFile, parentHash: nil)
            throw HistoryJarVerificationError(description: "Invalid JAR must fail with a readable error.")
        } catch let error as HistoryJarError {
            try require(error.localizedDescription.contains("JAR"), "Invalid archive error must name the failed JAR.")
        }
        try require(try fixture.git(["rev-parse", "HEAD"]) == invalidCommit,
                    "History comparison must not change the repository revision.")
        print("History JAR verification passed: historical Git snapshots, Java 8/17 classes, nested classes, resources, metadata, merge parents, rename/delete, encoding, cancellation, invalid ZIP/class")
    }

    private static func entry(_ path: String, in comparison: HistoryJarComparison) throws -> HistoryJarEntry {
        guard let entry = comparison.entries.first(where: { $0.path == path }) else {
            throw HistoryJarVerificationError(description: "Missing fixture entry: \(path)")
        }
        return entry
    }

    private static func preview(_ path: String, in comparison: HistoryJarComparison,
                                using service: HistoryJarComparisonService) async throws -> HistoryJarContent {
        try await service.content(comparison: comparison, entry: entry(path, in: comparison), ignoringWhitespace: false)
    }
}
