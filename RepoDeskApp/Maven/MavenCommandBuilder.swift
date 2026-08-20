import Foundation

enum MavenCommandBuilder {
    static func makeCommand(
        repositoryURL: URL,
        module: MavenModule,
        goal: MavenLifecycleGoal,
        settings: MavenSettings,
        fileManager: FileManager = .default,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MavenCommand {
        let repositoryURL = repositoryURL.standardizedFileURL
        let wrapperURL = repositoryURL.appendingPathComponent("mvnw", isDirectory: false)
        let mavenHome = expandedPath(settings.mavenHome)

        let executableURL: URL
        var arguments: [String]
        if fileManager.isExecutableFile(atPath: wrapperURL.path) {
            executableURL = wrapperURL
            arguments = []
        } else if !mavenHome.isEmpty {
            executableURL = URL(fileURLWithPath: mavenHome, isDirectory: true)
                .appendingPathComponent("bin/mvn", isDirectory: false)
            arguments = []
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
            arguments = ["mvn"]
        }

        let userSettingsFile = expandedPath(settings.userSettingsFile)
        if !userSettingsFile.isEmpty {
            arguments.append(contentsOf: ["-s", userSettingsFile])
        }

        let localRepository = expandedPath(settings.localRepository)
        if !localRepository.isEmpty {
            arguments.append("-Dmaven.repo.local=\(localRepository)")
        }

        let profiles = normalizedProfiles(settings.activeProfiles)
        if !profiles.isEmpty {
            arguments.append("-P\(profiles.joined(separator: ","))")
        }

        let rootPOMURL = repositoryURL.appendingPathComponent("pom.xml", isDirectory: false)
        arguments.append(contentsOf: ["-f", rootPOMURL.path])
        if module.modulePath != "." {
            arguments.append(contentsOf: ["-pl", module.modulePath])
            if settings.alsoMake {
                arguments.append("-am")
            }
        }
        arguments.append(contentsOf: settings.additionalArguments.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        arguments.append(goal.rawValue)

        var environment = processEnvironment
        let javaHome = expandedPath(settings.javaHome)
        if !javaHome.isEmpty {
            environment["JAVA_HOME"] = javaHome
        }

        return MavenCommand(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: repositoryURL,
            environment: environment
        )
    }

    private static func expandedPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "" }
        return NSString(string: trimmedPath).expandingTildeInPath
    }

    private static func normalizedProfiles(_ profiles: [String]) -> [String] {
        var seen: Set<String> = []
        return profiles.compactMap { profile in
            let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedProfile.isEmpty, seen.insert(trimmedProfile).inserted else { return nil }
            return trimmedProfile
        }
    }
}
