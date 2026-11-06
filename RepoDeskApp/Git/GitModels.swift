import Foundation

enum GitLineChangeKind: Equatable, Sendable {
    case modified
    case added
}

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
    let parentHashes: [String]

    init(
        hash: String,
        subject: String,
        author: String,
        authoredAt: Date?,
        refs: [String] = [],
        parentHashes: [String] = []
    ) {
        self.hash = hash
        self.subject = subject
        self.author = author
        self.authoredAt = authoredAt
        self.refs = refs
        self.parentHashes = parentHashes
    }

    var id: String { hash }
    var isMerge: Bool { parentHashes.count > 1 }
}

struct GitBranch: Equatable, Identifiable, Sendable {
    let name: String
    let hash: String
    let upstream: String?
    let isRemote: Bool
    let isCurrent: Bool

    var id: String { name }
}

struct GitStash: Equatable, Identifiable, Sendable {
    let reference: String
    let message: String
    let hash: String

    init(reference: String, message: String, hash: String? = nil) {
        self.reference = reference
        self.message = message
        self.hash = hash ?? reference
    }

    var id: String { hash }
}

struct GitBranchComparison: Equatable, Sendable {
    let baseBranch: String
    let comparedBranch: String
    let commits: [GitCommitSummary]
    let diffText: String
}

struct GitConflictFile: Equatable, Identifiable, Codable, Sendable {
    let path: String
    let ours: String
    let theirs: String
    var result: String
    var isResolved: Bool
    /// The common ancestor (Git index stage 1). `nil` means the base is absent
    /// or cannot be represented as text; inspect `hasBase`/`baseData` to tell
    /// those cases apart.
    let base: String?
    let baseData: Data?
    let oursData: Data?
    let theirsData: Data?
    var resultData: Data?
    let hasBase: Bool
    let hasOurs: Bool
    let hasTheirs: Bool
    let isBinary: Bool
    var mergeDocument: GitThreeWayMergeDocument? = nil
    var expectedWorktreeData: Data? = nil
    var expectedIndex: Data? = nil
    var deletesResult = false
    var unsupportedReason: String? = nil

    init(
        path: String,
        ours: String,
        theirs: String,
        result: String,
        isResolved: Bool,
        base: String? = nil,
        baseData: Data? = nil,
        oursData: Data? = nil,
        theirsData: Data? = nil,
        resultData: Data? = nil,
        hasBase: Bool? = nil,
        hasOurs: Bool = true,
        hasTheirs: Bool = true,
        isBinary: Bool = false
    ) {
        self.path = path
        self.ours = ours
        self.theirs = theirs
        self.result = result
        self.isResolved = isResolved
        self.base = base
        self.baseData = baseData
        self.oursData = oursData
        self.theirsData = theirsData
        self.resultData = resultData
        self.hasBase = hasBase ?? (base != nil || baseData != nil)
        self.hasOurs = hasOurs
        self.hasTheirs = hasTheirs
        self.isBinary = isBinary
    }

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
    let parentHashes: [String]
    let containingBranches: [String]
    let authorEmail: String?

    init(
        summary: GitCommitSummary,
        files: [GitCommitFile],
        parentHashes: [String] = [],
        containingBranches: [String] = [],
        authorEmail: String? = nil
    ) {
        self.summary = summary
        self.files = files
        self.parentHashes = parentHashes
        self.containingBranches = containingBranches
        self.authorEmail = authorEmail
    }

    var isTwoParentMerge: Bool { parentHashes.count == 2 }
}

enum GitDiffTarget: Equatable, Sendable {
    case change(GitChangeSelection)
    case commit(hash: String, file: GitCommitFile)
    case revisionRange(base: String?, head: String, file: GitCommitFile)
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
    let oldLineCount: Int
    let newLineCount: Int
    let hunks: [GitDiffHunk]
    let isBinary: Bool

    init(
        path: String,
        originalPath: String?,
        oldLabel: String,
        newLabel: String,
        oldLines: [String],
        newLines: [String],
        oldLineCount: Int? = nil,
        newLineCount: Int? = nil,
        hunks: [GitDiffHunk],
        isBinary: Bool
    ) {
        self.path = path
        self.originalPath = originalPath
        self.oldLabel = oldLabel
        self.newLabel = newLabel
        self.oldLines = oldLines
        self.newLines = newLines
        self.oldLineCount = max(oldLines.count, oldLineCount ?? oldLines.count)
        self.newLineCount = max(newLines.count, newLineCount ?? newLines.count)
        self.hunks = hunks
        self.isBinary = isBinary
    }
}

struct GitMergeFileDiff: Equatable, Sendable {
    let target: GitFileDiff
    let source: GitFileDiff

    var path: String { target.path }
    var resultLines: [String] { target.newLines }
    var isBinary: Bool { target.isBinary || source.isBinary }
}

enum GitHistoryBlameSide: String, CaseIterable, Hashable, Sendable {
    case target
    case result
    case source
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
    let authorEmail: String?
    let message: String?

    init(lineNumber: Int, commitHash: String, author: String, authoredAt: Date?,
         authorEmail: String? = nil, message: String? = nil) {
        self.lineNumber = lineNumber
        self.commitHash = commitHash
        self.author = author
        self.authoredAt = authoredAt
        self.authorEmail = authorEmail
        self.message = message
    }

    var isUncommitted: Bool {
        commitHash.allSatisfy { $0 == "0" }
    }
}

struct GitMergeConflictBlame: Equatable, Sendable {
    let yours: [Int: GitBlameLine]
    let result: [Int: GitBlameLine]
    let theirs: [Int: GitBlameLine]

    init(
        yours: [Int: GitBlameLine] = [:],
        result: [Int: GitBlameLine] = [:],
        theirs: [Int: GitBlameLine] = [:]
    ) {
        self.yours = yours
        self.result = result
        self.theirs = theirs
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

struct GitMergeSessionSnapshot: Codable, Equatable, Sendable {
    let identity: String
    var files: [GitConflictFile]
}
