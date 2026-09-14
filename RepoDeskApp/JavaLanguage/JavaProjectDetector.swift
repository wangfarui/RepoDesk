import Foundation

struct JavaRepositoryInspection: Equatable, Sendable {
    let isJavaProject: Bool
    let nestedRepositoryURLs: [URL]
}

protocol JavaProjectDetecting: Sendable {
    func inspectRepository(
        at repositoryURL: URL,
        excluding nestedRepositoryURLs: [URL]
    ) -> JavaRepositoryInspection
}

extension JavaProjectDetecting {
    func isJavaProject(at repositoryURL: URL) -> Bool {
        inspectRepository(at: repositoryURL, excluding: []).isJavaProject
    }
}

struct FileSystemJavaProjectDetector: JavaProjectDetecting, @unchecked Sendable {
    private let fileManager: FileManager
    private let maximumVisitedItems: Int

    init(fileManager: FileManager = .default, maximumVisitedItems: Int = 5_000) {
        self.fileManager = fileManager
        self.maximumVisitedItems = maximumVisitedItems
    }

    func inspectRepository(
        at repositoryURL: URL,
        excluding nestedRepositoryURLs: [URL]
    ) -> JavaRepositoryInspection {
        let repositoryURL = repositoryURL.standardizedFileURL
        let knownNestedRepositoryURLs = Set(nestedRepositoryURLs.map(\.standardizedFileURL))
        let directMarkers = [
            "pom.xml", "mvnw", ".classpath",
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"
        ]
        var isJavaProject = directMarkers.contains(where: {
            fileManager.fileExists(atPath: repositoryURL.appendingPathComponent($0).path)
        })
        var discoveredNestedRepositoryURLs = knownNestedRepositoryURLs

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .nameKey]
        guard let enumerator = fileManager.enumerator(
            at: repositoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return JavaRepositoryInspection(
                isJavaProject: isJavaProject,
                nestedRepositoryURLs: discoveredNestedRepositoryURLs.sorted(by: Self.pathAscending)
            )
        }

        var visited = 0
        for case let itemURL as URL in enumerator {
            visited += 1
            if visited > maximumVisitedItems { break }
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let standardizedItemURL = itemURL.standardizedFileURL
                if discoveredNestedRepositoryURLs.contains(standardizedItemURL)
                    || Self.isGitRepository(at: standardizedItemURL, fileManager: fileManager) {
                    discoveredNestedRepositoryURLs.insert(standardizedItemURL)
                    enumerator.skipDescendants()
                    continue
                }
                if Self.excludedDirectoryNames.contains(itemURL.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
            }
            guard values?.isRegularFile == true else { continue }
            if Self.javaProjectFileNames.contains(itemURL.lastPathComponent)
                || itemURL.pathExtension.lowercased() == "java" {
                isJavaProject = true
            }
        }
        return JavaRepositoryInspection(
            isJavaProject: isJavaProject,
            nestedRepositoryURLs: discoveredNestedRepositoryURLs.sorted(by: Self.pathAscending)
        )
    }

    private static func isGitRepository(at directoryURL: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: directoryURL.appendingPathComponent(".git").path)
    }

    private static func pathAscending(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private static let excludedDirectoryNames: Set<String> = [
        "target", "build", "node_modules", "vendor", "dist", "out"
    ]

    private static let javaProjectFileNames: Set<String> = [
        "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"
    ]
}
