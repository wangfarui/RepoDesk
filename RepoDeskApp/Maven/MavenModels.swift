import Foundation

struct MavenSettings: Codable, Equatable, Sendable {
    var mavenHome: String
    var javaHome: String
    var userSettingsFile: String
    var localRepository: String
    var activeProfiles: [String]
    var alsoMake: Bool
    var additionalArguments: [String]
    var runHistoryPolicy: MavenRunHistoryPolicy

    init(
        mavenHome: String = "",
        javaHome: String = "",
        userSettingsFile: String = "",
        localRepository: String = "",
        activeProfiles: [String] = [],
        alsoMake: Bool = false,
        additionalArguments: [String] = [],
        runHistoryPolicy: MavenRunHistoryPolicy = .default
    ) {
        self.mavenHome = mavenHome
        self.javaHome = javaHome
        self.userSettingsFile = userSettingsFile
        self.localRepository = localRepository
        self.activeProfiles = activeProfiles
        self.alsoMake = alsoMake
        self.additionalArguments = additionalArguments
        self.runHistoryPolicy = runHistoryPolicy
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mavenHome = try container.decodeIfPresent(String.self, forKey: .mavenHome) ?? ""
        javaHome = try container.decodeIfPresent(String.self, forKey: .javaHome) ?? ""
        userSettingsFile = try container.decodeIfPresent(String.self, forKey: .userSettingsFile) ?? ""
        localRepository = try container.decodeIfPresent(String.self, forKey: .localRepository) ?? ""
        activeProfiles = try container.decodeIfPresent([String].self, forKey: .activeProfiles) ?? []
        alsoMake = try container.decodeIfPresent(Bool.self, forKey: .alsoMake) ?? false
        additionalArguments = try container.decodeIfPresent([String].self, forKey: .additionalArguments) ?? []
        runHistoryPolicy = try container.decodeIfPresent(
            MavenRunHistoryPolicy.self,
            forKey: .runHistoryPolicy
        ) ?? .default
    }

    static let empty = MavenSettings()
}

enum MavenLifecycleGoal: String, CaseIterable, Codable, Identifiable, Sendable {
    case clean
    case compile
    case package
    case install
    case deploy

    var id: String { rawValue }
    var requiresConfirmation: Bool { self == .deploy }
}

struct MavenWindowSelection: Codable, Equatable, Sendable {
    var modulePath: String?
    var goal: MavenLifecycleGoal?
    var recentRunID: UUID?

    static func target(modulePath: String, goal: MavenLifecycleGoal) -> MavenWindowSelection {
        MavenWindowSelection(modulePath: modulePath, goal: goal, recentRunID: nil)
    }

    static func recentRun(_ id: UUID) -> MavenWindowSelection {
        MavenWindowSelection(modulePath: nil, goal: nil, recentRunID: id)
    }
}

struct MavenModule: Equatable, Identifiable, Sendable {
    let modulePath: String
    let pomURL: URL
    let displayName: String
    let groupID: String?
    let artifactID: String
    let version: String?
    let packaging: String
    let hasPOM: Bool
    let children: [MavenModule]

    var id: String { modulePath }
}

struct MavenProject: Equatable, Sendable {
    let repositoryURL: URL
    let rootModule: MavenModule
}

struct MavenCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let environment: [String: String]

    init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
    }

    var displayComponents: [String] {
        [executableURL.path] + arguments
    }
}

struct MavenRunRequest: Equatable, Identifiable, Sendable {
    let module: MavenModule
    let goal: MavenLifecycleGoal
    let command: MavenCommand

    var id: String { "\(module.id):\(goal.id)" }
    var requiresConfirmation: Bool { goal.requiresConfirmation }
}

struct MavenExecutionPresentation: Equatable, Sendable {
    var runningRequestID: MavenRunRequest.ID?
    var log: String
    var terminationStatus: Int32?
    var duration: TimeInterval?
    var finishedAt: Date?
    var errorMessage: String?

    static let idle = MavenExecutionPresentation(
        runningRequestID: nil,
        log: "",
        terminationStatus: nil,
        duration: nil,
        finishedAt: nil,
        errorMessage: nil
    )
}
