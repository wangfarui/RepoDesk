import Foundation
@testable import RepoDesk

private struct VerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
@MainActor
enum VerifyHistoryPresentation {
    static func main() async throws {
        try verifyDates()
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskHistoryPresentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        func git(_ arguments: [String]) async throws -> String {
            let result = try await SystemCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments,
                workingDirectoryURL: repositoryURL, environment: nil
            ))
            guard result.terminationStatus == 0 else {
                throw VerificationFailure(message: String(decoding: result.standardError, as: UTF8.self))
            }
            return String(decoding: result.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.name", "History Verification"])
        _ = try await git(["config", "user.email", "history@example.invalid"])
        try Data("root\n".utf8).write(to: repositoryURL.appendingPathComponent("file.txt"))
        _ = try await git(["add", "file.txt"])
        _ = try await git(["commit", "-m", "Root"])
        let root = try await git(["rev-parse", "HEAD"])
        _ = try await git(["checkout", "-b", "feature"])
        _ = try await git(["commit", "--allow-empty", "-m", "Feature"])
        _ = try await git(["checkout", "main"])
        _ = try await git(["commit", "--allow-empty", "-m", "Merge is only a word here"])
        let ordinary = try await git(["rev-parse", "HEAD"])
        _ = try await git(["merge", "--no-ff", "feature", "-m", "Integrate feature"])
        let merge = try await git(["rev-parse", "HEAD"])
        _ = try await git(["branch", "release"])
        _ = try await git(["update-ref", "refs/remotes/origin/main", merge])
        _ = try await git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        _ = try await git(["tag", "v1"])
        _ = try await git(["branch", "unrelated", root])
        _ = try await git(["commit", "--allow-empty", "-m", "After merge"])

        let reader = SystemGitRepositoryReader()
        let history = try await reader.history(repositoryURL: repositoryURL, limit: 50, skip: 0, revision: nil, author: nil)
        try require(history.first { $0.hash == merge }?.isMerge == true, "A merge with a custom subject must be recognized")
        try require(history.first { $0.hash == ordinary }?.isMerge == false, "A Merge subject must not turn a single-parent commit gray")
        try require(history.first { $0.hash == root }?.parentHashes.isEmpty == true, "Root commit must have no parents")
        let searched = try await reader.searchHistory(repositoryURL: repositoryURL, hashPrefix: merge,
                                                       path: nil, limit: 50, skip: 0, revision: nil, author: nil)
        try require(searched.first?.isMerge == true, "Hash search must retain merge metadata")
        let detail = try await reader.commit(repositoryURL: repositoryURL, hash: merge)
        try require(detail.containingBranches == ["main", "release", "origin/main"],
                    "Containment must include ancestor commits and remote refs, excluding aliases, tags and unrelated branches")
        try require(!detail.summary.refs.contains { $0.contains("main") && !$0.contains("origin/") },
                    "Fixture must exercise an ancestor of main rather than only a branch tip")
        let rootDetail = try await reader.commit(repositoryURL: repositoryURL, hash: root)
        try require(rootDetail.containingBranches == ["feature", "main", "release", "unrelated", "origin/main"],
                    "Shared ancestor must appear in every containing branch")
        let suite = "RepoDeskHistoryPresentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = RegisteredRepository(displayName: "repo", relativePath: ".", isPinned: false)
        let state = AppState(
            workspace: WorkspaceSummary(url: repositoryURL), repositories: [repository],
            selectedRepositoryID: repository.id, selectedSection: .history,
            gitRepositoryReader: reader, windowStateStore: UserDefaultsWindowStateStore(defaults: defaults),
            restoresWorkspaceOnLaunch: false
        )
        state.selectedCommitHash = merge
        state.selectedCommitDetail = detail
        _ = try await git(["branch", "hotfix"])
        await state.loadHistory()
        try require(state.selectedCommitDetail?.summary == detail.summary,
                    "Fixture must keep selected commit metadata unchanged while containment changes")
        try require(state.selectedCommitDetail?.containingBranches == ["hotfix", "main", "release", "origin/main"],
                    "Refreshing unchanged commit metadata must still refresh containing branches")
        _ = try await git(["checkout", "--detach"])
        _ = try await git(["commit", "--allow-empty", "-m", "Detached"])
        let detached = try await reader.commit(repositoryURL: repositoryURL, hash: "HEAD")
        try require(detached.containingBranches.isEmpty, "An unreferenced detached commit must show zero branches")
        print("History presentation verification passed (branch containment, merge metadata, date boundaries)")
    }

    private static func verifyDates() throws {
        let iso = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = iso.date(from: "2026-01-01T00:10:00+08:00")!
        func label(_ date: String) -> String {
            HistoryCommitPresentation.dateLabel(iso.date(from: date)!, now: now, calendar: calendar)
        }
        try require(label("2026-01-01T00:05:00+08:00") == "今天 00:05", "Today must show hours and minutes")
        try require(label("2025-12-31T23:59:00+08:00") == "昨天 23:59", "Yesterday must follow local calendar across year boundaries")
        try require(label("2025-12-30T14:30:59+08:00") == "2025/12/30 14:30", "Older dates must show the full date without seconds")
        try require(label("2026-01-02T14:30:00+08:00") == "2026/01/02 14:30", "Future days must show the full date")
        try require(label("2025-12-31T16:05:00Z") == "今天 00:05", "Date display must use the local time zone")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = iso.date(from: "2026-11-02T00:30:00-08:00")!
        let dstYesterday = iso.date(from: "2026-11-01T00:10:00-07:00")!
        try require(HistoryCommitPresentation.dateLabel(dstYesterday, now: dstNow, calendar: calendar) == "昨天 00:10",
                    "Yesterday must follow the calendar even on a 25-hour daylight-saving day")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationFailure(message: message) }
    }
}
