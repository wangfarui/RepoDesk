import Foundation

struct JavaIndexSettings: Codable, Equatable, Sendable {
    static let defaultMaximumJVMCount = 1
    static let defaultProcessorCount = 2
    static let defaultMaximumHeapMegabytes = 2_048
    static let defaultCacheLimitGigabytes = 10

    var maximumJVMCount: Int
    var processorCountPerJVM: Int
    var maximumHeapMegabytes: Int
    var cacheLimitGigabytes: Int

    init(
        maximumJVMCount: Int = defaultMaximumJVMCount,
        processorCountPerJVM: Int = defaultProcessorCount,
        maximumHeapMegabytes: Int = defaultMaximumHeapMegabytes,
        cacheLimitGigabytes: Int = defaultCacheLimitGigabytes
    ) {
        self.maximumJVMCount = Self.normalizeJVMCount(maximumJVMCount)
        self.processorCountPerJVM = Self.normalizeProcessorCount(processorCountPerJVM)
        self.maximumHeapMegabytes = Self.normalizeHeapMegabytes(maximumHeapMegabytes)
        self.cacheLimitGigabytes = Self.normalizeCacheGigabytes(cacheLimitGigabytes)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maximumJVMCount: try container.decodeIfPresent(Int.self, forKey: .maximumJVMCount)
                ?? Self.defaultMaximumJVMCount,
            processorCountPerJVM: try container.decodeIfPresent(Int.self, forKey: .processorCountPerJVM)
                ?? Self.defaultProcessorCount,
            maximumHeapMegabytes: try container.decodeIfPresent(Int.self, forKey: .maximumHeapMegabytes)
                ?? Self.defaultMaximumHeapMegabytes,
            cacheLimitGigabytes: try container.decodeIfPresent(Int.self, forKey: .cacheLimitGigabytes)
                ?? Self.defaultCacheLimitGigabytes
        )
    }

    static let `default` = JavaIndexSettings()

    static func normalizeJVMCount(_ value: Int) -> Int {
        min(max(value, 1), 4)
    }

    static func normalizeProcessorCount(_ value: Int) -> Int {
        min(max(value, 1), max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    static func normalizeHeapMegabytes(_ value: Int) -> Int {
        min(max(value, 1_024), 8_192)
    }

    static func normalizeCacheGigabytes(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }

    var maximumHeapGigabytes: Double {
        Double(maximumHeapMegabytes) / 1_024
    }

    var maximumCombinedHeapGigabytes: Double {
        maximumHeapGigabytes * Double(maximumJVMCount)
    }
}

struct JavaRepositoryDescriptor: Equatable, Identifiable, Sendable {
    let repositoryID: RegisteredRepository.ID
    let displayName: String
    let repositoryURL: URL
    let isJavaProject: Bool
    let nestedRepositoryURLs: [URL]

    var id: RegisteredRepository.ID { repositoryID }

    var cacheScopeIdentifier: String {
        let repositoryPath = repositoryURL.standardizedFileURL.path
        let nestedPaths = nestedRepositoryURLs.map { nestedURL in
            let path = nestedURL.standardizedFileURL.path
            guard path.hasPrefix(repositoryPath + "/") else { return path }
            return String(path.dropFirst(repositoryPath.count + 1))
        }
        return (["repository-boundaries-v1"] + nestedPaths).joined(separator: "\n")
    }

    func containsOwnedFile(_ fileURL: URL) -> Bool {
        let fileURL = fileURL.standardizedFileURL
        guard Self.isSameOrDescendant(fileURL, of: repositoryURL) else { return false }
        return !nestedRepositoryURLs.contains {
            Self.isSameOrDescendant(fileURL, of: $0.standardizedFileURL)
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        if candidate == root { return true }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }
}

enum JavaRepositoryIndexPhase: String, Codable, Equatable, Sendable {
    case notRequired
    case queued
    case starting
    case indexing
    case ready
    case stale
    case paused
    case failed
}

struct JavaRepositoryIndexState: Equatable, Identifiable, Sendable {
    let repositoryID: RegisteredRepository.ID
    let displayName: String
    var phase: JavaRepositoryIndexPhase
    var progress: Double?
    var detail: String?
    var branchName: String?
    var cacheBytes: Int64

    var id: RegisteredRepository.ID { repositoryID }
}

struct JavaIndexSnapshot: Equatable, Sendable {
    var repositories: [JavaRepositoryIndexState]
    var activeRepositoryID: RegisteredRepository.ID?
    var runningJVMCount: Int
    var cacheBytes: Int64
    var isBackgroundIndexingPaused: Bool

    static let idle = JavaIndexSnapshot(
        repositories: [],
        activeRepositoryID: nil,
        runningJVMCount: 0,
        cacheBytes: 0,
        isBackgroundIndexingPaused: false
    )

    var javaRepositoryCount: Int {
        repositories.filter { $0.phase != .notRequired }.count
    }

    var readyRepositoryCount: Int {
        repositories.filter { $0.phase == .ready }.count
    }

    var failedRepositoryCount: Int {
        repositories.filter { $0.phase == .failed }.count
    }

    var indexingRepository: JavaRepositoryIndexState? {
        repositories.first { $0.phase == .starting || $0.phase == .indexing }
    }
}

struct JavaSourcePosition: Codable, Equatable, Sendable {
    let line: Int
    let character: Int

    init(line: Int, character: Int) {
        self.line = max(0, line)
        self.character = max(0, character)
    }
}

struct JavaSourceRange: Codable, Equatable, Sendable {
    let start: JavaSourcePosition
    let end: JavaSourcePosition
}

enum JavaSymbolKind: Int, Codable, Equatable, Sendable {
    case file = 1
    case module = 2
    case namespace = 3
    case package = 4
    case `class` = 5
    case method = 6
    case property = 7
    case field = 8
    case constructor = 9
    case `enum` = 10
    case interface = 11
    case function = 12
    case variable = 13
    case constant = 14
    case string = 15
    case number = 16
    case boolean = 17
    case array = 18
    case object = 19
    case key = 20
    case null = 21
    case enumMember = 22
    case `struct` = 23
    case event = 24
    case `operator` = 25
    case typeParameter = 26
}

struct JavaNavigationTarget: Equatable, Identifiable, Sendable {
    let fileURL: URL
    let range: JavaSourceRange
    let selectionRange: JavaSourceRange?
    let name: String
    let detail: String?
    let containerName: String?
    let kind: JavaSymbolKind?

    var id: String {
        "\(fileURL.path):\(range.start.line):\(range.start.character):\(name)"
    }
}

enum JavaNavigationAction: Equatable, Sendable {
    case contextual
    case declaration
    case implementation
    case incomingCalls
    case references
    case superDeclaration
}

struct JavaNavigationRequest: Equatable, Sendable {
    let action: JavaNavigationAction
    let fileURL: URL
    let position: JavaSourcePosition
    let documentText: String
}

enum JavaSymbolSearchScope: Equatable, Sendable {
    case types
    case methods
    case all
}

struct JavaSymbolSearchRequest: Equatable, Sendable {
    let repositoryID: RegisteredRepository.ID
    let query: String
    let scope: JavaSymbolSearchScope
}

enum JavaSemanticTokenStyle: String, Codable, Equatable, Sendable {
    case namespace
    case type
    case `class`
    case `enum`
    case interface
    case `struct`
    case typeParameter
    case parameter
    case variable
    case property
    case enumMember
    case event
    case function
    case method
    case macro
    case keyword
    case modifier
    case comment
    case string
    case number
    case regexp
    case `operator`
    case annotation
}

struct JavaSemanticToken: Equatable, Sendable {
    let range: JavaSourceRange
    let style: JavaSemanticTokenStyle
}

struct JavaNavigationHistoryEntry: Equatable, Sendable {
    let fileURL: URL
    let range: JavaSourceRange
}

struct JavaNavigationPopupAnchor: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct JavaNavigationResultPresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let targets: [JavaNavigationTarget]
    let origin: JavaNavigationHistoryEntry?
    let anchor: JavaNavigationPopupAnchor?
}
