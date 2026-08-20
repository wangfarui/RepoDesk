import Foundation

@MainActor
protocol RepoTaskStoring: AnyObject {
    func catalog(workspaceURL: URL, repositoryURL: URL?) -> TaskCatalog
    func save(
        _ task: RepoTaskDefinition,
        scope: RepoTaskScope,
        workspaceURL: URL,
        repositoryURL: URL?
    )
    func remove(
        taskID: String,
        scope: RepoTaskScope,
        workspaceURL: URL,
        repositoryURL: URL?
    )
    func recentRuns() -> [TaskRunRecord]
    func record(_ run: TaskRunRecord)
}

@MainActor
final class ApplicationSupportRepoTaskStore: RepoTaskStoring {
    private struct PersistedData: Codable {
        var tasks: [String: [RepoTaskDefinition]] = [:]
        var recentRuns: [TaskRunRecord] = []
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let baseURL = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RepoDesk", isDirectory: true)
        fileURL = baseURL.appendingPathComponent("tasks-v1.json")
    }

    func catalog(workspaceURL: URL, repositoryURL: URL?) -> TaskCatalog {
        let tasks = load().tasks
        return TaskCatalog(
            global: tasks["global"] ?? [],
            workspace: tasks["workspace:\(workspaceURL.standardizedFileURL.path)"] ?? [],
            repository: repositoryURL.flatMap {
                tasks["repository:\($0.standardizedFileURL.path)"]
            } ?? []
        )
    }

    func save(
        _ task: RepoTaskDefinition,
        scope: RepoTaskScope,
        workspaceURL: URL,
        repositoryURL: URL?
    ) {
        guard let key = key(for: scope, workspaceURL: workspaceURL, repositoryURL: repositoryURL) else { return }
        var data = load()
        var definitions = data.tasks[key] ?? []
        if let index = definitions.firstIndex(where: { $0.id == task.id }) {
            definitions[index] = task
        } else {
            definitions.append(task)
        }
        data.tasks[key] = definitions
        persist(data)
    }

    func remove(
        taskID: String,
        scope: RepoTaskScope,
        workspaceURL: URL,
        repositoryURL: URL?
    ) {
        guard let key = key(for: scope, workspaceURL: workspaceURL, repositoryURL: repositoryURL) else { return }
        var data = load()
        data.tasks[key] = (data.tasks[key] ?? []).filter { $0.id != taskID }
        persist(data)
    }

    func recentRuns() -> [TaskRunRecord] {
        load().recentRuns
    }

    func record(_ run: TaskRunRecord) {
        var data = load()
        data.recentRuns.insert(run, at: 0)
        data.recentRuns = Array(data.recentRuns.prefix(30))
        persist(data)
    }

    private func load() -> PersistedData {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(PersistedData.self, from: data) else {
            return PersistedData()
        }
        return persisted
    }

    private func persist(_ data: PersistedData) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(data).write(to: fileURL, options: .atomic)
        } catch {
            // The UI reports resolution and execution errors; persistence failures leave the prior file intact.
        }
    }

    private func key(
        for scope: RepoTaskScope,
        workspaceURL: URL,
        repositoryURL: URL?
    ) -> String? {
        switch scope {
        case .global: "global"
        case .workspace: "workspace:\(workspaceURL.standardizedFileURL.path)"
        case .repository: repositoryURL.map { "repository:\($0.standardizedFileURL.path)" }
        }
    }
}

@MainActor
final class UserDefaultsRepoTaskStore: RepoTaskStoring {
    private enum Keys {
        static let tasks = "tasks.catalog.v1"
        static let recentRuns = "tasks.recent-runs.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func catalog(workspaceURL: URL, repositoryURL: URL?) -> TaskCatalog {
        let all = allTasks()
        return TaskCatalog(
            global: all["global"] ?? [],
            workspace: all["workspace:\(workspaceURL.standardizedFileURL.path)"] ?? [],
            repository: repositoryURL.flatMap {
                all["repository:\($0.standardizedFileURL.path)"]
            } ?? []
        )
    }

    func save(
        _ task: RepoTaskDefinition,
        scope: RepoTaskScope,
        workspaceURL: URL,
        repositoryURL: URL?
    ) {
        guard let key = key(for: scope, workspaceURL: workspaceURL, repositoryURL: repositoryURL) else { return }
        var all = allTasks()
        var tasks = all[key] ?? []
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        all[key] = tasks
        persist(all)
    }

    func remove(
        taskID: String,
        scope: RepoTaskScope,
        workspaceURL: URL,
        repositoryURL: URL?
    ) {
        guard let key = key(for: scope, workspaceURL: workspaceURL, repositoryURL: repositoryURL) else { return }
        var all = allTasks()
        all[key] = (all[key] ?? []).filter { $0.id != taskID }
        persist(all)
    }

    func recentRuns() -> [TaskRunRecord] {
        guard let data = defaults.data(forKey: Keys.recentRuns),
              let records = try? JSONDecoder().decode([TaskRunRecord].self, from: data) else {
            return []
        }
        return records
    }

    func record(_ run: TaskRunRecord) {
        var records = recentRuns()
        records.insert(run, at: 0)
        records = Array(records.prefix(30))
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Keys.recentRuns)
        }
    }

    private func key(
        for scope: RepoTaskScope,
        workspaceURL: URL,
        repositoryURL: URL?
    ) -> String? {
        switch scope {
        case .global: "global"
        case .workspace: "workspace:\(workspaceURL.standardizedFileURL.path)"
        case .repository: repositoryURL.map { "repository:\($0.standardizedFileURL.path)" }
        }
    }

    private func allTasks() -> [String: [RepoTaskDefinition]] {
        guard let data = defaults.data(forKey: Keys.tasks),
              let tasks = try? JSONDecoder().decode([String: [RepoTaskDefinition]].self, from: data) else {
            return [:]
        }
        return tasks
    }

    private func persist(_ tasks: [String: [RepoTaskDefinition]]) {
        if let data = try? JSONEncoder().encode(tasks) {
            defaults.set(data, forKey: Keys.tasks)
        }
    }
}
