import Foundation

enum GitDiffPresentation: String, CaseIterable, Codable, Identifiable, Sendable {
    case unified = "Unified"
    case sideBySide = "Side-by-side"

    var id: Self { self }
}

struct GitRepositorySnapshot: Equatable, Sendable {
    let branch: String
    let isDetachedHEAD: Bool
    let aheadCount: Int
    let behindCount: Int
    let changes: [GitFileChange]
    let lastCommit: GitCommitSummary?

    var stagedCount: Int { changes.filter { $0.isStaged && !$0.isConflicted }.count }
    var unstagedCount: Int {
        changes.filter { $0.isUnstaged && !$0.isUntracked && !$0.isConflicted }.count
    }
    var untrackedCount: Int { changes.filter(\.isUntracked).count }
    var conflictedCount: Int { changes.filter(\.isConflicted).count }
    var trackedChangeCount: Int { changes.filter { !$0.isUntracked }.count }
    var unversionedFileCount: Int { changes.filter(\.isUntracked).count }
}

struct GitCommitSummary: Equatable, Identifiable, Sendable {
    let hash: String
    let subject: String
    let author: String
    let authoredAt: Date?
    let refs: [String]

    init(
        hash: String,
        subject: String,
        author: String,
        authoredAt: Date?,
        refs: [String] = []
    ) {
        self.hash = hash
        self.subject = subject
        self.author = author
        self.authoredAt = authoredAt
        self.refs = refs
    }

    var id: String { hash }
}

struct GitBranch: Equatable, Identifiable, Sendable {
    let name: String
    let hash: String
    let upstream: String?
    let isRemote: Bool
    let isCurrent: Bool

    var id: String { name }
}

struct GitBranchComparison: Equatable, Sendable {
    let baseBranch: String
    let comparedBranch: String
    let commits: [GitCommitSummary]
    let diffText: String
}

struct GitConflictFile: Equatable, Identifiable, Sendable {
    let path: String
    let ours: String
    let theirs: String
    var result: String
    var isResolved: Bool

    var id: String { path }
}

struct GitConflictBlock: Equatable, Identifiable, Sendable {
    let index: Int
    let ours: String
    let theirs: String

    var id: Int { index }
}

enum GitConflictSide: Sendable {
    case ours
    case theirs
}

struct GitCommitFile: Equatable, Identifiable, Sendable {
    let path: String
    let originalPath: String?
    let status: GitStatusCode

    var id: String { path }
}

struct GitCommitDetail: Equatable, Sendable {
    let summary: GitCommitSummary
    let files: [GitCommitFile]
}

enum GitDiffTarget: Equatable, Sendable {
    case change(GitChangeSelection)
    case commit(hash: String, file: GitCommitFile)
}

enum GitPatchLineKind: Equatable, Sendable {
    case context
    case deletion
    case addition
}

struct GitPatchLine: Equatable, Sendable {
    let kind: GitPatchLineKind
    let text: String
}

struct GitDiffHunk: Equatable, Sendable, Identifiable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [GitPatchLine]

    var id: String { "\(oldStart):\(newStart):\(oldCount):\(newCount)" }
}

struct GitFileDiff: Equatable, Sendable {
    let path: String
    let originalPath: String?
    let oldLabel: String
    let newLabel: String
    let oldLines: [String]
    let newLines: [String]
    let hunks: [GitDiffHunk]
    let isBinary: Bool
}

enum GitBlameSide: Hashable, Sendable {
    case old
    case new
}

struct GitBlameLine: Equatable, Sendable {
    let lineNumber: Int
    let commitHash: String
    let author: String
    let authoredAt: Date?

    var isUncommitted: Bool {
        commitHash.allSatisfy { $0 == "0" }
    }
}

extension Sequence where Element == GitBlameLine {
    var indexedByLineNumber: [Int: GitBlameLine] {
        reduce(into: [:]) { result, line in
            result[line.lineNumber] = line
        }
    }
}

enum GitHistoryBranchFilter: Codable, Equatable, Hashable, Identifiable, Sendable {
    case current
    case all
    case branch(String)

    var id: String {
        switch self {
        case .current: "current"
        case .all: "all"
        case .branch(let name): "branch:\(name)"
        }
    }
}

struct GitChangesGrouping: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let directory = GitChangesGrouping(rawValue: 1 << 0)
    static let module = GitChangesGrouping(rawValue: 1 << 1)
    static let all: GitChangesGrouping = [.directory, .module]

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let legacyValue = try? container.decode(String.self) {
            switch legacyValue {
            case "directory": self = .directory
            case "module": self = .module
            default: self = []
            }
            return
        }
        let values = try container.decode([String].self)
        self = values.reduce(into: []) { grouping, value in
            switch value {
            case "directory": grouping.insert(.directory)
            case "module": grouping.insert(.module)
            default: break
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var values: [String] = []
        if contains(.directory) { values.append("directory") }
        if contains(.module) { values.append("module") }
        try container.encode(values)
    }
}

struct GitFileChange: Equatable, Identifiable, Sendable {
    let path: String
    var originalPath: String?
    var indexStatus: GitStatusCode
    let workTreeStatus: GitStatusCode
    let isUntracked: Bool
    let isConflicted: Bool

    var id: String { path }
    var isStaged: Bool { !isUntracked && indexStatus != .unchanged }
    var isUnstaged: Bool { isUntracked || workTreeStatus != .unchanged || isConflicted }
    var presentationKind: GitChangeKind { isUntracked ? .unversioned : .changes }
}

enum GitChangeKind: String, Codable, Hashable, Sendable {
    case changes = "Changes"
    case unversioned = "Unversioned Files"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case Self.changes.rawValue, "Staged", "Unstaged", "Conflicted":
            self = .changes
        case Self.unversioned.rawValue, "Untracked":
            self = .unversioned
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Git change kind: \(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct GitChangeSelection: Codable, Equatable, Hashable, Identifiable, Sendable {
    let path: String
    let kind: GitChangeKind
    let originalPath: String?

    init(path: String, kind: GitChangeKind, originalPath: String? = nil) {
        self.path = path
        self.kind = kind
        self.originalPath = originalPath
    }

    var id: String { "\(kind.rawValue):\(path)" }
}

enum GitStatusCode: Character, Codable, Sendable {
    case unchanged = "."
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case updatedButUnmerged = "U"
    case typeChanged = "T"
    case untracked = "?"
    case ignored = "!"
    case unknown = "X"

    init(character: Character?) {
        self = character.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}
