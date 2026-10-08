import Foundation

enum JavaNavigationTargetSourceResolver {
    static func origin(
        for target: JavaNavigationTarget,
        workspaceURL: URL?,
        repositories: [RegisteredRepository],
        mavenLocalRepositoryURL: URL? = nil,
        workspaceMavenProjectIndex: [JavaWorkspaceMavenProject]? = nil,
        mavenCoordinateLookup: JavaMavenCoordinateLookup? = nil
    ) -> JavaNavigationTargetOrigin {
        let uri = target.fileURL.absoluteString
        if let workspaceURL,
           let repository = containingRepository(
               fileURL: target.fileURL,
               workspaceURL: workspaceURL,
               repositories: repositories
           ) {
            return .workspaceRepository(
                repositoryID: repository.id,
                repositoryName: repository.name,
                fileURL: target.fileURL.standardizedFileURL
            )
        }

        if var dependency = JavaDependencyReference(uri: uri) {
            let resolvedMavenCoordinate: String?
            if let mavenCoordinateLookup,
               mavenCoordinateLookup.contains(dependency.jarName) {
                resolvedMavenCoordinate = mavenCoordinateLookup.coordinate(for: dependency.jarName)
            } else {
                resolvedMavenCoordinate = mavenCoordinate(
                    for: dependency.jarName,
                    localRepositoryURL: mavenLocalRepositoryURL
                )
            }
            dependency = JavaDependencyReference(
                uri: dependency.uri,
                jarName: dependency.jarName,
                packageName: dependency.packageName,
                typeName: dependency.typeName,
                mavenCoordinate: resolvedMavenCoordinate
            )
            if let workspaceURL,
               let workspaceProject = workspaceMavenProjects(
                   dependency: dependency,
                   workspaceURL: workspaceURL,
                   repositories: repositories,
                   projects: workspaceMavenProjectIndex
               ),
               let sourceFileURL = sourceFileURL(
                   for: dependency,
                   in: workspaceProject
               ) {
                return .workspaceRepository(
                    repositoryID: workspaceProject.repositoryID,
                    repositoryName: workspaceProject.repositoryName,
                    fileURL: sourceFileURL
                )
            }
            return .dependency(dependency)
        }
        return .external(uri: uri)
    }

    static func workspaceMavenProjects(
        workspaceURL: URL,
        repositories: [RegisteredRepository]
    ) -> [JavaWorkspaceMavenProject] {
        let scanner = MavenProjectScanner()
        var result: [JavaWorkspaceMavenProject] = []
        for repository in repositories {
            let repositoryURL = repository.relativePath == "."
                ? workspaceURL.standardizedFileURL
                : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
                    .standardizedFileURL
            guard let project = try? scanner.scan(repositoryURL: repositoryURL) else { continue }
            result.append(contentsOf: modules(
                project.rootModule,
                repositoryID: repository.id,
                repositoryName: repository.name,
                repositoryURL: repositoryURL
            ))
        }
        return result
    }

    static func mavenCoordinates(
        for jarNames: Set<String>,
        localRepositoryURL: URL?
    ) -> [String: String] {
        guard !jarNames.isEmpty,
              let localRepositoryURL,
              FileManager.default.fileExists(atPath: localRepositoryURL.path),
              let enumerator = FileManager.default.enumerator(
                  at: localRepositoryURL,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles],
                  errorHandler: { _, _ in true }
              ) else { return [:] }

        let repositoryPath = localRepositoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        var result: [String: String] = [:]
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > 20_000 || result.count == jarNames.count { break }
            let jarName = fileURL.lastPathComponent
            guard jarNames.contains(jarName), result[jarName] == nil else { continue }
            let filePath = fileURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard filePath.hasPrefix(repositoryPath + "/") else { continue }
            let relativePath = String(filePath.dropFirst(repositoryPath.count + 1))
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count >= 4 else { continue }

            let artifactIndex = components.count - 3
            let groupComponents = components.prefix(artifactIndex)
            let artifact = components[artifactIndex]
            let version = components[artifactIndex + 1]
            guard !groupComponents.isEmpty,
                  !artifact.isEmpty,
                  !version.isEmpty,
                  jarName.hasPrefix("\(artifact)-\(version)") else { continue }
            result[jarName] = "\(groupComponents.joined(separator: ".")):\(artifact):\(version)"
        }
        return result
    }

    static func jarName(for uri: String) -> String? {
        JavaDependencyReference(uri: uri)?.jarName
    }

    private static func mavenCoordinate(
        for jarName: String,
        localRepositoryURL: URL?
    ) -> String? {
        guard let localRepositoryURL,
              FileManager.default.fileExists(atPath: localRepositoryURL.path) else {
            return nil
        }
        guard let enumerator = FileManager.default.enumerator(
            at: localRepositoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > 20_000 { break }
            guard fileURL.lastPathComponent == jarName else { continue }
            let repositoryPath = localRepositoryURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            let filePath = fileURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard filePath.hasPrefix(repositoryPath + "/") else { continue }
            let relativePath = String(filePath.dropFirst(repositoryPath.count + 1))
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count >= 4 else { continue }

            let artifactIndex = components.count - 3
            let groupComponents = components.prefix(artifactIndex)
            let artifact = components[artifactIndex]
            let version = components[artifactIndex + 1]
            guard !groupComponents.isEmpty,
                  !artifact.isEmpty,
                  !version.isEmpty,
                  jarName.hasPrefix("\(artifact)-\(version)") else { continue }
            return "\(groupComponents.joined(separator: ".")):\(artifact):\(version)"
        }
        return nil
    }

    private static func workspaceMavenProjects(
        dependency: JavaDependencyReference,
        workspaceURL: URL,
        repositories: [RegisteredRepository],
        projects indexedProjects: [JavaWorkspaceMavenProject]?
    ) -> JavaWorkspaceMavenProject? {
        let projects = indexedProjects ?? workspaceMavenProjects(
            workspaceURL: workspaceURL,
            repositories: repositories
        )
        return projects.first { project in
            if let coordinate = dependency.mavenCoordinate,
               coordinate == project.coordinate {
                return true
            }
            let baseName = (dependency.jarName as NSString).deletingPathExtension
            let artifactPrefix = project.artifactID + "-"
            guard baseName == project.artifactID || baseName.hasPrefix(artifactPrefix) else {
                return false
            }
            guard let version = project.version,
                  !version.isEmpty,
                  !version.contains("${") else {
                return true
            }
            return baseName == "\(project.artifactID)-\(version)"
                || baseName.hasPrefix("\(project.artifactID)-\(version)-")
        }
    }

    private static func sourceFileURL(
        for dependency: JavaDependencyReference,
        in project: JavaWorkspaceMavenProject
    ) -> URL? {
        guard let typeName = dependency.typeName, !typeName.isEmpty else { return nil }
        let topLevelTypeName = typeName.split(separator: "$", maxSplits: 1).first.map(String.init)
            ?? typeName
        var relativeSourcePath = dependency.packageName?.split(separator: ".").map(String.init) ?? []
        relativeSourcePath.append("\(topLevelTypeName).java")
        let candidates = [
            "src/main/java",
            "src/main/kotlin",
            "src/generated/java",
            "target/generated-sources/annotations"
        ].map { root in
            relativeSourcePath.reduce(
                project.moduleURL.appendingPathComponent(root, isDirectory: true)
            ) { partial, component in
                partial.appendingPathComponent(component)
            }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.standardizedFileURL
    }

    private static func modules(
        _ module: MavenModule,
        repositoryID: RegisteredRepository.ID,
        repositoryName: String,
        repositoryURL: URL
    ) -> [JavaWorkspaceMavenProject] {
        let moduleURL = module.modulePath == "."
            ? repositoryURL
            : repositoryURL.appendingPathComponent(module.modulePath, isDirectory: true)
        var current: [JavaWorkspaceMavenProject] = []
        if let groupID = module.groupID {
            current.append(
                JavaWorkspaceMavenProject(
                    repositoryID: repositoryID,
                    repositoryName: repositoryName,
                    moduleURL: moduleURL.standardizedFileURL,
                    groupID: groupID,
                    artifactID: module.artifactID,
                    version: module.version
                )
            )
        }
        return current + module.children.flatMap {
            modules(
                $0,
                repositoryID: repositoryID,
                repositoryName: repositoryName,
                repositoryURL: repositoryURL
            )
        }
    }

    static func containingRepository(
        fileURL: URL,
        workspaceURL: URL,
        repositories: [RegisteredRepository]
    ) -> RegisteredRepository? {
        guard fileURL.isFileURL else { return nil }
        let candidate = fileURL.standardizedFileURL
        let workspaceURL = workspaceURL.standardizedFileURL
        return repositories.compactMap { repository -> (RegisteredRepository, Int)? in
            let repositoryURL = repository.relativePath == "."
                ? workspaceURL
                : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
                    .standardizedFileURL
            guard isSameOrDescendant(candidate, of: repositoryURL), candidate != repositoryURL else {
                return nil
            }
            return (repository, repositoryURL.path.count)
        }
        .max { lhs, rhs in lhs.1 < rhs.1 }?.0
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        if candidate == root { return true }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(prefix)
    }
}

struct JavaWorkspaceMavenProject: Equatable, Sendable {
    let repositoryID: RegisteredRepository.ID
    let repositoryName: String
    let moduleURL: URL
    let groupID: String
    let artifactID: String
    let version: String?

    var coordinate: String? {
        version.map { "\(groupID):\(artifactID):\($0)" }
    }
}

struct JavaMavenCoordinateLookup: Sendable {
    let coordinates: [String: String]
    let misses: Set<String>

    func coordinate(for jarName: String) -> String? {
        if let coordinate = coordinates[jarName] { return coordinate }
        if misses.contains(jarName) { return nil }
        return nil
    }

    func contains(_ jarName: String) -> Bool {
        coordinates[jarName] != nil || misses.contains(jarName)
    }
}

private extension JavaDependencyReference {
    init?(uri: String) {
        guard let url = URL(string: uri),
              ["jdt", "jar"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }

        var components: [String] = []
        if let host = url.host, !host.isEmpty {
            components.append(host)
        }
        components.append(contentsOf: url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) })
        guard let contentsIndex = components.firstIndex(where: { $0 == "contents" }),
              components.indices.contains(contentsIndex + 1) else {
            return nil
        }

        let jarName = components[contentsIndex + 1]
        let classPath = Array(components.dropFirst(contentsIndex + 2))
        let className = classPath.last.map { component in
            component.hasSuffix(".class")
                ? String(component.dropLast(".class".count))
                : component
        }
        let packageComponents = classPath.dropLast().filter { !$0.isEmpty }

        self.init(
            uri: uri,
            jarName: jarName,
            packageName: packageComponents.isEmpty
                ? nil
                : packageComponents.joined(separator: "."),
            typeName: className
        )
    }
}
