import Foundation

enum RepoTaskScope: String, Codable, CaseIterable, Sendable {
    case global = "Global"
    case workspace = "Workspace"
    case repository = "Repository"
}

enum RepoTaskConfirmation: String, Codable, CaseIterable, Sendable {
    case none
    case required
}

struct RepoTaskDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var executable: String
    var arguments: [String]
    var workingDirectory: String
    var environment: [String: String]
    var confirmation: RepoTaskConfirmation
}

struct TaskResolutionContext: Sendable {
    let workspaceURL: URL
    let repositoryURL: URL?
    let selectedFileURL: URL?
    let userHomeURL: URL
    let processEnvironment: [String: String]
}

struct ResolvedRepoTask: Equatable, Sendable {
    let definitionID: String
    let name: String
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let environment: [String: String]
    let confirmation: RepoTaskConfirmation
}

enum TaskOutputChannel: Sendable {
    case standardOutput
    case standardError
}

struct TaskOutputChunk: Sendable {
    let channel: TaskOutputChannel
    let text: String
}

struct TaskRunResult: Equatable, Sendable {
    let terminationStatus: Int32
    let startedAt: Date
    let finishedAt: Date

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

struct TaskRunRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: String
    let taskName: String
    let terminationStatus: Int32
    let startedAt: Date
    let finishedAt: Date
}

struct TaskCatalog: Codable, Equatable, Sendable {
    var global: [RepoTaskDefinition]
    var workspace: [RepoTaskDefinition]
    var repository: [RepoTaskDefinition]

    var effectiveTasks: [RepoTaskDefinition] {
        var definitions: [String: RepoTaskDefinition] = [:]
        for task in global { definitions[task.id] = task }
        for task in workspace { definitions[task.id] = task }
        for task in repository { definitions[task.id] = task }
        return definitions.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
