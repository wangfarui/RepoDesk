import Foundation

@MainActor
protocol MavenRunHistoryStoring: AnyObject {
    func recentRuns(for workspaceURL: URL) -> [MavenRunRecord]
    func record(
        _ run: MavenRunRecord,
        for workspaceURL: URL,
        policy: MavenRunHistoryPolicy
    )
    func applyPolicy(_ policy: MavenRunHistoryPolicy, for workspaceURL: URL)
    func remove(runID: MavenRunRecord.ID, for workspaceURL: URL)
    func clearPersistedLogs(for workspaceURL: URL)
    func clearHistory(for workspaceURL: URL)
}

@MainActor
final class UserDefaultsMavenRunHistoryStore: MavenRunHistoryStoring {
    private enum Keys {
        static let runsByWorkspace = "maven.runHistoryByWorkspace.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recentRuns(for workspaceURL: URL) -> [MavenRunRecord] {
        allRuns()[workspaceKey(for: workspaceURL)] ?? []
    }

    func record(
        _ run: MavenRunRecord,
        for workspaceURL: URL,
        policy: MavenRunHistoryPolicy
    ) {
        var runsByWorkspace = allRuns()
        let key = workspaceKey(for: workspaceURL)
        var runs = runsByWorkspace[key] ?? []
        runs.removeAll { $0.id == run.id }
        runs.append(run.preparedForPersistence(policy: policy))
        runsByWorkspace[key] = preparedRuns(runs, policy: policy)
        save(runsByWorkspace)
    }

    func applyPolicy(_ policy: MavenRunHistoryPolicy, for workspaceURL: URL) {
        var runsByWorkspace = allRuns()
        let key = workspaceKey(for: workspaceURL)
        guard let runs = runsByWorkspace[key] else { return }
        runsByWorkspace[key] = preparedRuns(runs, policy: policy)
        save(runsByWorkspace)
    }

    func remove(runID: MavenRunRecord.ID, for workspaceURL: URL) {
        var runsByWorkspace = allRuns()
        let key = workspaceKey(for: workspaceURL)
        guard var runs = runsByWorkspace[key] else { return }
        runs.removeAll { $0.id == runID }
        if runs.isEmpty {
            runsByWorkspace.removeValue(forKey: key)
        } else {
            runsByWorkspace[key] = runs
        }
        save(runsByWorkspace)
    }

    func clearPersistedLogs(for workspaceURL: URL) {
        var runsByWorkspace = allRuns()
        let key = workspaceKey(for: workspaceURL)
        guard var runs = runsByWorkspace[key] else { return }
        for index in runs.indices {
            runs[index].log = nil
        }
        runsByWorkspace[key] = runs
        save(runsByWorkspace)
    }

    func clearHistory(for workspaceURL: URL) {
        var runsByWorkspace = allRuns()
        runsByWorkspace.removeValue(forKey: workspaceKey(for: workspaceURL))
        save(runsByWorkspace)
    }

    private func preparedRuns(
        _ runs: [MavenRunRecord],
        policy: MavenRunHistoryPolicy
    ) -> [MavenRunRecord] {
        let policy = policy.normalized
        return runs
            .map { $0.preparedForPersistence(policy: policy) }
            .sorted {
                if $0.finishedAt != $1.finishedAt {
                    return $0.finishedAt > $1.finishedAt
                }
                return $0.startedAt > $1.startedAt
            }
            .prefix(policy.maximumRecordCount)
            .map { $0 }
    }

    private func allRuns() -> [String: [MavenRunRecord]] {
        guard let data = defaults.data(forKey: Keys.runsByWorkspace),
              let runs = try? JSONDecoder().decode(
                [String: [MavenRunRecord]].self,
                from: data
              ) else {
            return [:]
        }
        return runs
    }

    private func save(_ runsByWorkspace: [String: [MavenRunRecord]]) {
        guard let data = try? JSONEncoder().encode(runsByWorkspace) else { return }
        defaults.set(data, forKey: Keys.runsByWorkspace)
    }

    private func workspaceKey(for workspaceURL: URL) -> String {
        workspaceURL.standardizedFileURL.path
    }
}
