import Foundation

enum HistoryJarChange: String, Hashable, Sendable {
    case added, deleted, modified, unchanged
}

struct HistoryJarEntry: Identifiable, Hashable, Sendable {
    let path: String
    let oldSize: Int?
    let newSize: Int?
    let change: HistoryJarChange
    var id: String { path }
}

struct HistoryJarContent: Sendable {
    let diff: GitFileDiff?
    let message: String?
}

/// Owns historical snapshots and their cached previews for the lifetime of one selection.
final class HistoryJarComparison: Sendable {
    let entries: [HistoryJarEntry]
    let oldLabel: String
    let newLabel: String
    let oldArchive: HistoryJarArchive?
    let newArchive: HistoryJarArchive?
    let directory: URL
    let cache = HistoryJarPreviewCache()

    init(entries: [HistoryJarEntry], oldLabel: String, newLabel: String,
         oldArchive: HistoryJarArchive?, newArchive: HistoryJarArchive?, directory: URL) {
        self.entries = entries
        self.oldLabel = oldLabel
        self.newLabel = newLabel
        self.oldArchive = oldArchive
        self.newArchive = newArchive
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

actor HistoryJarPreviewCache {
    private var values: [String: HistoryJarContent] = [:]

    func value(for key: String) -> HistoryJarContent? { values[key] }
    func store(_ value: HistoryJarContent, for key: String) {
        if values.count >= 8 { values.removeAll() }
        values[key] = value
    }
}

struct HistoryJarComparisonService: Sendable {
    private let runner: any CommandRunning

    init(runner: any CommandRunning = SystemCommandRunner(timeout: .seconds(60))) {
        self.runner = runner
    }

    func compare(repositoryURL: URL, hash: String, file: GitCommitFile,
                 parentHash: String?) async throws -> HistoryJarComparison {
        let revision = try await git(["rev-parse", "--verify", "\(hash)^{commit}"], in: repositoryURL)
        let commit = String(decoding: revision, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parents = try await git(["rev-list", "--parents", "-n", "1", commit], in: repositoryURL)
        let commitAndParents = String(decoding: parents, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        let parent = parentHash ?? commitAndParents.dropFirst().first
        if let parent, !commitAndParents.dropFirst().contains(parent) {
            throw HistoryJarError.command("比较基准不是该提交的父提交。")
        }
        async let old = snapshot(repositoryURL: repositoryURL, revision: parent, path: file.originalPath ?? file.path)
        async let new = snapshot(repositoryURL: repositoryURL, revision: commit, path: file.path)
        let (oldArchive, newArchive) = try await (old, new)
        guard oldArchive != nil || newArchive != nil else {
            throw HistoryJarError.command("所选历史版本中没有该 JAR。")
        }
        let names = Set(oldArchive?.entries.keys.map { $0 } ?? [])
            .union(newArchive?.entries.keys.map { $0 } ?? []).sorted()
        var entries: [HistoryJarEntry] = []
        var comparisonBudget = 512 * 1_048_576
        for name in names {
            try Task.checkCancellation()
            let before = oldArchive?.entries[name]
            let after = newArchive?.entries[name]
            let change: HistoryJarChange
            if before == nil { change = .added }
            else if after == nil { change = .deleted }
            else if let before, let after, let oldArchive, let newArchive {
                if before.size != after.size || before.crc != after.crc {
                    change = .modified
                } else if before.size <= HistoryJarArchive.maximumEntrySize,
                          before.size <= comparisonBudget,
                          before.flags & 1 == 0, after.flags & 1 == 0,
                          [0, 8].contains(before.method), [0, 8].contains(after.method) {
                    // CRC is a fast rejection, but equal CRCs still require an exact content comparison.
                    comparisonBudget -= before.size
                    change = try oldArchive.contents(of: before) == newArchive.contents(of: after) ? .unchanged : .modified
                } else {
                    guard before.method == after.method,
                          try oldArchive.compressedBytes(for: before) == newArchive.compressedBytes(for: after) else {
                        throw HistoryJarError.limit("存在无法精确比较的大文件或特殊压缩文件：\(name)")
                    }
                    change = .unchanged
                }
            } else { continue }
            entries.append(HistoryJarEntry(path: name, oldSize: before?.size, newSize: after?.size, change: change))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Jar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try oldArchive?.data.write(to: directory.appendingPathComponent("old.jar"))
            try newArchive?.data.write(to: directory.appendingPathComponent("new.jar"))
            return HistoryJarComparison(
                entries: entries, oldLabel: parent.map { String($0.prefix(8)) } ?? "空版本",
                newLabel: String(commit.prefix(8)), oldArchive: oldArchive, newArchive: newArchive,
                directory: directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func content(comparison: HistoryJarComparison, entry: HistoryJarEntry,
                 ignoringWhitespace: Bool) async throws -> HistoryJarContent {
        let key = "\(ignoringWhitespace):\(entry.path)"
        if let cached = await comparison.cache.value(for: key) { return cached }
        try Task.checkCancellation()
        let oldData = try comparison.oldArchive.flatMap { archive in
            try archive.entries[entry.path].map { try archive.contents(of: $0) }
        }
        let newData = try comparison.newArchive.flatMap { archive in
            try archive.entries[entry.path].map { try archive.contents(of: $0) }
        }
        let isClass = (entry.path as NSString).pathExtension.lowercased() == "class"
        async let before = text(data: oldData, isClass: isClass, archiveURL: comparison.directory.appendingPathComponent("old.jar"))
        async let after = text(data: newData, isClass: isClass, archiveURL: comparison.directory.appendingPathComponent("new.jar"))
        guard let (oldText, newText) = try await optionalPair(before, after) else {
            return HistoryJarContent(diff: nil, message: "该包内文件是二进制内容或文本编码不受支持，无法显示文本 Diff。")
        }
        let work = comparison.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let oldURL = work.appendingPathComponent("old.txt")
        let newURL = work.appendingPathComponent("new.txt")
        try Data(oldText.utf8).write(to: oldURL)
        try Data(newText.utf8).write(to: newURL)
        var arguments = ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--text", "--unified=3"]
        if ignoringWhitespace { arguments.append("--ignore-all-space") }
        arguments += ["--", oldURL.path, newURL.path]
        let result = try await run(URL(fileURLWithPath: "/usr/bin/git"), arguments, in: work)
        guard [0, 1].contains(result.terminationStatus) else {
            throw HistoryJarError.command("生成包内文件 Diff 失败：\(errorText(result))")
        }
        let oldLines = GitDiffParser.lines(from: Data(oldText.utf8))
        let newLines = GitDiffParser.lines(from: Data(newText.utf8))
        var hunks = GitDiffParser.parseHunks(String(decoding: result.standardOutput, as: UTF8.self))
        if hunks.isEmpty, oldLines == newLines, !oldLines.isEmpty {
            // Keep identical source readable when only bytecode metadata changed.
            hunks = [GitDiffHunk(oldStart: oldLines.isEmpty ? 0 : 1, oldCount: oldLines.count,
                                 newStart: newLines.isEmpty ? 0 : 1, newCount: newLines.count,
                                 lines: oldLines.map { GitPatchLine(kind: .context, text: $0) })]
        }
        let message: String?
        if isClass, entry.change == .modified, oldText == newText {
            message = "字节码发生变化，但反编译后的 Java 代码一致。"
        } else if result.terminationStatus == 0, oldText != newText {
            message = "忽略空白后没有代码差异。"
        } else if isClass {
            message = "Java 反编译视图 · 不包含原始源码注释与排版。"
        } else { message = nil }
        let content = HistoryJarContent(
            diff: GitFileDiff(
                path: isClass ? String(entry.path.dropLast(6)) + ".java" : entry.path,
                originalPath: nil, oldLabel: comparison.oldLabel, newLabel: comparison.newLabel,
                oldLines: oldLines, newLines: newLines, hunks: hunks, isBinary: false
            ), message: message
        )
        try Task.checkCancellation()
        await comparison.cache.store(content, for: key)
        return content
    }

    private func optionalPair(_ old: String?, _ new: String?) -> (String, String)? {
        guard let old, let new else { return nil }
        return (old, new)
    }

    private func text(data: Data?, isClass: Bool, archiveURL: URL) async throws -> String? {
        guard let data else { return "" }
        if isClass {
            let runtime = try JarDecompilerRuntime.resolve()
            let directory = archiveURL.deletingLastPathComponent()
                .appendingPathComponent("class-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let classURL = directory.appendingPathComponent("Preview.class")
            try data.write(to: classURL)
            let result = try await run(runtime.javaURL, [
                // Git uses LC_ALL=C; keep Java's output UTF-8 instead of replacing Unicode with '?'.
                "-Xmx256m", "-Dstdout.encoding=UTF-8", "-Dstderr.encoding=UTF-8",
                "-jar", runtime.decompilerURL.path, classURL.path,
                "--extraclasspath", archiveURL.path, "--silent", "true", "--comments", "false",
                "--hideutf", "false"
            ], in: directory)
            let output = String(decoding: result.standardOutput, as: UTF8.self)
            guard result.terminationStatus == 0, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !output.contains("Can't load the class specified:") else {
                throw HistoryJarError.command("Class 反编译失败：\(errorText(result))")
            }
            return output
        }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            return String(data: data, encoding: .utf16)
        }
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func snapshot(repositoryURL: URL, revision: String?, path: String) async throws -> HistoryJarArchive? {
        guard let revision else { return nil }
        let record = try await git(["--literal-pathspecs", "ls-tree", "-z", revision, "--", path], in: repositoryURL)
        guard !record.isEmpty else { return nil }
        let header = String(decoding: record.prefix(while: { $0 != 9 }), as: UTF8.self).split(separator: " ")
        guard header.count == 3, header[1] == "blob" else {
            throw HistoryJarError.command("历史路径不是 JAR 文件。")
        }
        let object = String(header[2])
        let sizeData = try await git(["cat-file", "-s", object], in: repositoryURL)
        guard let size = Int(String(decoding: sizeData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              size <= HistoryJarArchive.maximumArchiveSize else {
            throw HistoryJarError.limit("单个 JAR 最大支持 256 MB。")
        }
        return try HistoryJarArchive(data: await git(["cat-file", "blob", object], in: repositoryURL))
    }

    private func git(_ arguments: [String], in directory: URL) async throws -> Data {
        let result = try await run(URL(fileURLWithPath: "/usr/bin/git"), arguments, in: directory)
        guard result.terminationStatus == 0 else {
            throw HistoryJarError.command("读取 Git 历史失败：\(errorText(result))")
        }
        return result.standardOutput
    }

    private func run(_ executable: URL, _ arguments: [String], in directory: URL) async throws -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        return try await runner.run(CommandRequest(executableURL: executable, arguments: arguments,
                                                 workingDirectoryURL: directory, environment: environment))
    }

    private func errorText(_ result: CommandResult) -> String {
        String(decoding: result.standardError.isEmpty ? result.standardOutput : result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000).description
    }
}
