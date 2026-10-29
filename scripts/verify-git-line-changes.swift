import AppKit
import SwiftUI
@testable import RepoDesk

@main
@MainActor
enum VerifyGitLineChanges {
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-LineChanges-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = SystemGitRepositoryReader()
        try await git(["init", "-q"], in: root)
        try await git(["config", "user.name", "Line Change Test"], in: root)
        try await git(["config", "user.email", "line-changes@example.test"], in: root)
        try await git(["config", "commit.gpgsign", "false"], in: root)

        // An unborn HEAD and an untracked file both compare against empty content.
        let unborn = try await reader.lineChanges(repositoryURL: root, path: "new.txt", originalPath: nil, text: "first\nsecond\n")
        try require(unborn == [1: .added, 2: .added], "Unborn HEAD additions: \(unborn)")
        let file = root.appendingPathComponent("sample.txt")
        let original = "header\nold\nkeep\nremove\ntail\n"
        try Data(original.utf8).write(to: file)
        try Data("ignored.txt\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try await git(["add", "--", "sample.txt", ".gitignore"], in: root)
        try await git(["commit", "-qm", "Initial fixture"], in: root)
        let unchanged = try await reader.lineChanges(repositoryURL: root, path: "sample.txt", originalPath: nil, text: original)
        try require(unchanged.isEmpty, "Unchanged file has markers")

        let stagedText = "header\nstaged\nkeep\nremove\ntail\n"
        try Data(stagedText.utf8).write(to: file)
        try await git(["add", "--", "sample.txt"], in: root)
        let stagedIndex = try await gitOutput(["show", ":sample.txt"], in: root)
        let staged = try await reader.lineChanges(repositoryURL: root, path: "sample.txt", originalPath: nil, text: stagedText)
        try require(staged == [2: .modified], "Staged changes missing: \(staged)")

        let workingText = "header\nstaged\ninserted\nkeep\ntail\n"
        try Data(workingText.utf8).write(to: file)
        let mixed = try await reader.lineChanges(repositoryURL: root, path: "sample.txt", originalPath: nil, text: workingText)
        try require(mixed == [2: .modified, 3: .added], "Staged + unstaged changes/deletion: \(mixed)")
        let unsaved = try await reader.lineChanges(repositoryURL: root, path: "sample.txt", originalPath: nil, text: workingText + "unsaved\n")
        try require(unsaved == [2: .modified, 3: .added, 6: .added], "Displayed unsaved content not used: \(unsaved)")
        try require(try Data(contentsOf: file) == Data(workingText.utf8), "Comparison wrote to working file")
        let indexAfter = try await gitOutput(["show", ":sample.txt"], in: root)
        try require(indexAfter == stagedIndex, "Comparison modified index")

        // Restore-to-HEAD content clears markers even while the index differs.
        let reverted = try await reader.lineChanges(repositoryURL: root, path: "sample.txt", originalPath: nil, text: original)
        try require(reverted.isEmpty, "Comparison used index instead of HEAD")
        let deletion = try await reader.lineChanges(repositoryURL: root, path: "sample.txt", originalPath: nil, text: "header\nold\nkeep\ntail\n")
        try require(deletion.isEmpty, "Pure deletion marks an unrelated surviving line")
        let ignored = try await reader.lineChanges(repositoryURL: root, path: "ignored.txt", originalPath: nil, text: "ignored\n")
        try require(ignored.isEmpty, "Ignored file has Git markers")
        let newFile = try await reader.lineChanges(repositoryURL: root, path: "new.txt", originalPath: nil, text: "one\ntwo")
        try require(newFile == [1: .added, 2: .added], "Untracked lines missing")
        let empty = try await reader.lineChanges(repositoryURL: root, path: "new.txt", originalPath: nil, text: "")
        try require(empty.isEmpty, "Empty file has phantom addition")
        let crlf = try await reader.lineChanges(repositoryURL: root, path: "sample.txt", originalPath: nil, text: original.replacingOccurrences(of: "\n", with: "\r\n"))
        try require(crlf.isEmpty, "CRLF normalization changed all lines")

        try await git(["add", "--", "sample.txt"], in: root)
        try await git(["commit", "-qm", "Commit working content"], in: root)
        let committed = try await reader.lineChanges(repositoryURL: root, path: "sample.txt", originalPath: nil, text: workingText)
        try require(committed.isEmpty, "Markers survive commit")
        try await git(["mv", "--", "sample.txt", "renamed file.txt"], in: root)
        let renamed = try await reader.lineChanges(repositoryURL: root, path: "renamed file.txt", originalPath: "sample.txt", text: workingText + "new\n")
        try require(renamed == [6: .added], "Rename baseline or space in path failed: \(renamed)")
        try await git(["commit", "-qm", "Rename fixture"], in: root)
        let renameCommitted = try await reader.lineChanges(repositoryURL: root, path: "renamed file.txt", originalPath: "sample.txt", text: workingText)
        try require(renameCommitted.isEmpty, "Stale rename metadata overrides current HEAD path")

        let utf16 = root.appendingPathComponent("unicode.txt")
        try "中文😀\nsecond\n".data(using: .utf16)!.write(to: utf16)
        try await git(["add", "--", "unicode.txt"], in: root)
        try await git(["commit", "-qm", "UTF16 fixture"], in: root)
        let unicode = try await reader.lineChanges(repositoryURL: root, path: "unicode.txt", originalPath: nil, text: "中文😀\nchanged\n")
        try require(unicode == [2: .modified], "UTF16 baseline decoding failed: \(unicode)")
        // Fast Git exits must not truncate a large UTF-8 blob and mark its Chinese
        // strings/comments as modifications after the decoder falls back to Latin-1.
        let largeText = String(repeating: "return \"抵扣\"; // 批次库存中文注释 😀\n", count: 6000)
        try Data(largeText.utf8).write(to: root.appendingPathComponent("large.txt"))
        try await git(["add", "--", "large.txt"], in: root)
        try await git(["commit", "-qm", "Large UTF8 fixture"], in: root)
        try await withThrowingTaskGroup(of: [Int: GitLineChangeKind].self) { group in
            for _ in 0..<40 {
                group.addTask {
                    try await reader.lineChanges(repositoryURL: root, path: "large.txt", originalPath: nil, text: largeText)
                }
            }
            for try await markers in group {
                try require(markers.isEmpty, "Git-clean UTF8 file falsely has \(markers.count) changed lines")
            }
        }
        try require(GitLineChanges.markers(in: "@@ -3,2 +3,3 @@\n-old\n-old2\n+new\n+new2\n+new3\n") == [3: .modified, 4: .modified, 5: .added], "Replacement pairing failed")
        try verifyRendering()
        print("Git line change verification passed (HEAD/index/worktree/unsaved, commit, rename, encodings, gutter rendering and scrolling)")
    }

    static func verifyRendering() throws {
        let source = """
        package example;

        import java.util.List;
        import java.util.Map;

        public class Example {
            String changed = "蓝色修改";
            // 绿色新增
            // 连续新增
        }
        """
        let editor = NativeCodeEditor(
            text: .constant(source), isEditable: true, style: .source(fileExtension: "java"),
            showsLineNumbers: true, gitLineChanges: [7: .modified, 8: .added, 9: .added],
            fontSize: 16, foldsJavaImports: true
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 850, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let textView = try unwrap(findTextView(host), "Missing editor")
        let scroll = try unwrap(textView.enclosingScrollView, "Missing scroll view")
        let ruler = try unwrap(scroll.verticalRulerView as? NativeLineNumberRulerView, "Missing gutter")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            host.appearance = NSAppearance(named: appearance)
            let bitmap = try render(ruler)
            let counts = markerPixels(bitmap)
            try require(counts.blue > 10 && counts.green > counts.blue, "Missing blue/green markers in \(name): \(counts)")
            try save(host, name: "git-line-changes-\(name)")
        }
        let coordinator = try unwrap(textView.delegate as? NativeCodeEditor.Coordinator, "Missing coordinator")
        coordinator.importFolding?.toggle()
        try require(markerPixels(render(ruler)).blue > 10, "Expanding imports lost markers")
        ruler.configureGitBlame([7: NativeGitBlameAnnotation(
            commitHash: "1234567", author: "Tester", authoredAt: Date(), isUncommitted: false
        )], canToggle: false, onToggle: nil, onSelectCommit: nil)
        try require(markerPixels(render(ruler)).blue > 10, "Blame hides line change markers")
        ruler.configureGitLineChanges([:])
        let cleared = try markerPixels(render(ruler))
        try require(cleared.blue == 0 && cleared.green == 0, "Clearing changes leaves stale markers")

        // A marker far down the file follows its source line after vertical/horizontal scrolling.
        let longText = (1...250).map { "line \($0) " + String(repeating: "x", count: 120) }.joined(separator: "\n")
        textView.string = longText
        coordinator.importFolding?.configure(enabled: false, expanded: false, sourceChanged: true)
        ruler.configureGitBlame(nil, canToggle: false, onToggle: nil, onSelectCommit: nil)
        ruler.configureGitLineChanges([180: .modified, 181: .added])
        ruler.refresh(text: longText)
        let index = SourceLineIndex(text: longText)
        textView.scrollRangeToVisible(NSRange(location: index.lineStartOffsets[179], length: 0))
        scroll.contentView.scroll(to: NSPoint(x: 250, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrolled = try markerPixels(render(ruler))
        try require(scrolled.blue > 10 && scrolled.green > 10, "Scrolled markers disappear")
        try save(host, name: "git-line-changes-scrolled")
    }

    static func markerPixels(_ bitmap: NSBitmapImageRep) -> (blue: Int, green: Int) {
        var blue = 0
        var green = 0
        // Inspect only the dedicated marker strip, excluding blame/line-number colors.
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let x = max(0, min(bitmap.pixelsWide - 1, Int((bitmap.size.width - 5) * scale)))
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.blueComponent > 0.8 && color.redComponent < 0.5 && color.greenComponent < 0.7 { blue += 1 }
            if color.greenComponent > 0.6 && color.redComponent < 0.5 && color.blueComponent < 0.6 { green += 1 }
        }
        return (blue, green)
    }

    static func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        view.displayIfNeeded()
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "Missing bitmap")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    static func save(_ view: NSView, name: String) throws {
        let png = try unwrap(render(view).representation(using: .png, properties: [:]), "Missing PNG")
        try png.write(to: URL(fileURLWithPath: "build/\(name).png"))
    }

    static func findTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }

    static func git(_ arguments: [String], in root: URL) async throws {
        _ = try await gitOutput(arguments, in: root)
    }

    static func gitOutput(_ arguments: [String], in root: URL) async throws -> Data {
        let result = try await SystemCommandRunner().run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
            workingDirectoryURL: root, environment: nil
        ))
        try require(result.terminationStatus == 0, "Git fixture failed: \(String(decoding: result.standardError, as: UTF8.self))")
        return result.standardOutput
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "GitLineChanges", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: "GitLineChanges", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
}
