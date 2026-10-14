import Foundation

struct MavenRunHistoryPolicy: Codable, Equatable, Sendable {
    static let defaultMaximumRecordCount = 30
    static let defaultMaximumLogBytes = 512 * 1_024
    static let supportedRecordCount = 1...200
    static let supportedLogByteCount = 0...(10 * 1_024 * 1_024)

    var maximumRecordCount: Int
    var persistsLogs: Bool
    var maximumLogBytes: Int

    init(
        maximumRecordCount: Int = defaultMaximumRecordCount,
        persistsLogs: Bool = false,
        maximumLogBytes: Int = defaultMaximumLogBytes
    ) {
        self.maximumRecordCount = maximumRecordCount
        self.persistsLogs = persistsLogs
        self.maximumLogBytes = maximumLogBytes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maximumRecordCount = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumRecordCount
        ) ?? Self.defaultMaximumRecordCount
        persistsLogs = try container.decodeIfPresent(Bool.self, forKey: .persistsLogs) ?? false
        maximumLogBytes = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumLogBytes
        ) ?? Self.defaultMaximumLogBytes
    }

    var normalized: MavenRunHistoryPolicy {
        MavenRunHistoryPolicy(
            maximumRecordCount: min(
                max(maximumRecordCount, Self.supportedRecordCount.lowerBound),
                Self.supportedRecordCount.upperBound
            ),
            persistsLogs: persistsLogs,
            maximumLogBytes: min(
                max(maximumLogBytes, Self.supportedLogByteCount.lowerBound),
                Self.supportedLogByteCount.upperBound
            )
        )
    }

    static let `default` = MavenRunHistoryPolicy()
}

enum MavenRunActivity: String, Codable, Sendable {
    case queued
    case running
}

struct MavenRunRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let repositoryPath: String
    let modulePath: String
    let moduleName: String
    let goal: MavenLifecycleGoal
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryPath: String
    let terminationStatus: Int32?
    let startedAt: Date
    let finishedAt: Date
    var log: String?
    var activity: MavenRunActivity?
    var queuePosition: Int?

    init(
        id: UUID = UUID(),
        repositoryURL: URL,
        module: MavenModule,
        goal: MavenLifecycleGoal,
        command: MavenCommand,
        terminationStatus: Int32?,
        startedAt: Date,
        finishedAt: Date,
        log: String? = nil,
        activity: MavenRunActivity? = nil,
        queuePosition: Int? = nil
    ) {
        self.id = id
        repositoryPath = repositoryURL.standardizedFileURL.path
        modulePath = module.modulePath
        moduleName = module.displayName
        self.goal = goal
        executablePath = command.executableURL.standardizedFileURL.path
        arguments = command.arguments
        environment = command.environment["JAVA_HOME"].map { ["JAVA_HOME": $0] } ?? [:]
        workingDirectoryPath = command.workingDirectoryURL.standardizedFileURL.path
        self.terminationStatus = terminationStatus
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.log = log
        self.activity = activity
        self.queuePosition = queuePosition
    }

    var duration: TimeInterval {
        max(0, finishedAt.timeIntervalSince(startedAt))
    }

    var command: MavenCommand {
        var replayEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            replayEnvironment[key] = value
        }
        return MavenCommand(
            executableURL: URL(fileURLWithPath: executablePath, isDirectory: false),
            arguments: arguments,
            workingDirectoryURL: URL(fileURLWithPath: workingDirectoryPath, isDirectory: true),
            environment: replayEnvironment
        )
    }

    func makeRunRequest(module: MavenModule) -> MavenRunRequest? {
        guard module.modulePath == modulePath else { return nil }
        return MavenRunRequest(module: module, goal: goal, command: command)
    }

    func preparedForPersistence(policy: MavenRunHistoryPolicy) -> MavenRunRecord {
        var record = self
        let policy = policy.normalized
        guard policy.persistsLogs, policy.maximumLogBytes > 0, let log else {
            record.log = nil
            return record
        }
        record.log = Self.truncatedLog(log, maximumBytes: policy.maximumLogBytes)
        return record
    }

    private static func truncatedLog(_ log: String, maximumBytes: Int) -> String {
        let bytes = Array(log.utf8)
        guard bytes.count > maximumBytes else { return log }

        let marker = Array("[log truncated; showing tail]\n".utf8)
        guard maximumBytes > marker.count else {
            return validUTF8Suffix(of: bytes, maximumBytes: maximumBytes)
        }
        let tail = validUTF8Suffix(of: bytes, maximumBytes: maximumBytes - marker.count)
        return String(decoding: marker, as: UTF8.self) + tail
    }

    private static func validUTF8Suffix(of bytes: [UInt8], maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var suffix = Array(bytes.suffix(maximumBytes))
        while let first = suffix.first, first & 0b1100_0000 == 0b1000_0000 {
            suffix.removeFirst()
        }
        return String(decoding: suffix, as: UTF8.self)
    }
}
