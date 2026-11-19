import Foundation

struct JavaLanguageCacheStore: @unchecked Sendable {
    private static let cacheSchemaVersion = "jdtls-1.61.0-release-v1"
    private static let defaultScopeIdentifier = "repository-boundaries-v1"
    private static let scopeMarkerName = ".repodesk-repository-scope"
    private let fileManager: FileManager
    let rootURL: URL

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL
            ?? environment["REPODESK_JAVA_LANGUAGE_CACHE_ROOT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RepoDesk/JavaLanguage", isDirectory: true)
    }

    func dataDirectory(
        for repositoryURL: URL,
        scopeIdentifier: String = Self.defaultScopeIdentifier
    ) throws -> URL {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let directoryURL = cacheDirectory(for: repositoryURL)
        let scopeMarkerURL = directoryURL.appendingPathComponent(Self.scopeMarkerName)
        let expectedScope = Data(scopeIdentifier.utf8)
        if fileManager.fileExists(atPath: directoryURL.path),
           (try? Data(contentsOf: scopeMarkerURL)) != expectedScope {
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if (try? Data(contentsOf: scopeMarkerURL)) != expectedScope {
            try expectedScope.write(to: scopeMarkerURL, options: .atomic)
        }
        return directoryURL
    }

    func hasReadyCache(
        for repositoryURL: URL,
        scopeIdentifier: String = Self.defaultScopeIdentifier
    ) -> Bool {
        let directoryURL = cacheDirectory(for: repositoryURL)
        let markerURL = directoryURL.appendingPathComponent(".repodesk-ready")
        let scopeMarkerURL = directoryURL.appendingPathComponent(Self.scopeMarkerName)
        return fileManager.fileExists(atPath: markerURL.path)
            && (try? String(contentsOf: scopeMarkerURL, encoding: .utf8)) == scopeIdentifier
    }

    func markReady(
        repositoryURL: URL,
        scopeIdentifier: String = Self.defaultScopeIdentifier
    ) throws {
        let directoryURL = try dataDirectory(
            for: repositoryURL,
            scopeIdentifier: scopeIdentifier
        )
        let markerURL = directoryURL.appendingPathComponent(".repodesk-ready")
        try Data(Date().ISO8601Format().utf8).write(to: markerURL, options: .atomic)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: directoryURL.path)
    }

    func touch(repositoryURL: URL) {
        let directoryURL = cacheDirectory(for: repositoryURL)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: directoryURL.path)
    }

    func removeCache(for repositoryURL: URL) throws {
        let directoryURL = cacheDirectory(for: repositoryURL)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    func totalBytes() -> Int64 {
        directoryBytes(rootURL)
    }

    func bytes(for repositoryURL: URL) -> Int64 {
        directoryBytes(cacheDirectory(for: repositoryURL))
    }

    func trim(to maximumBytes: Int64, excluding repositoryURLs: Set<URL>) -> Int64 {
        var total = totalBytes()
        guard total > maximumBytes else { return total }
        let excludedPaths = Set(repositoryURLs.map {
            cacheDirectory(for: $0).resolvingSymlinksInPath().standardizedFileURL.path
        })
        let directories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = directories.filter {
            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return !excludedPaths.contains(path)
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs < rhs
        }
        for directoryURL in candidates where total > maximumBytes {
            let bytes = directoryBytes(directoryURL)
            try? fileManager.removeItem(at: directoryURL)
            total = max(0, total - bytes)
        }
        return total
    }

    private func cacheDirectory(for repositoryURL: URL) -> URL {
        rootURL.appendingPathComponent(
            Self.stableKey(
                "\(Self.cacheSchemaVersion)|\(repositoryURL.standardizedFileURL.path)"
            ),
            isDirectory: true
        )
    }

    private func directoryBytes(_ directoryURL: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func stableKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
