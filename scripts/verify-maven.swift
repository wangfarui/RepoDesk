import Foundation

@main
struct MavenVerification {
    @MainActor
    static func main() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskMavenVerification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        try writePOM(
            at: repositoryURL,
            contents: """
            <project xmlns="http://maven.apache.org/POM/4.0.0">
              <groupId>com.example</groupId>
              <artifactId>verification-parent</artifactId>
              <version>1.0.0</version>
              <packaging>pom</packaging>
              <name>${project.artifactId}</name>
              <modules><module>service</module></modules>
            </project>
            """
        )
        let serviceURL = repositoryURL.appendingPathComponent("service", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceURL, withIntermediateDirectories: true)
        try writePOM(
            at: serviceURL,
            contents: """
            <project>
              <parent>
                <groupId>com.example</groupId>
                <artifactId>verification-parent</artifactId>
                <version>1.0.0</version>
              </parent>
              <artifactId>verification-service</artifactId>
              <name>${project.artifactId}</name>
            </project>
            """
        )

        let project = try MavenProjectScanner().scan(repositoryURL: repositoryURL)
        guard project.rootModule.children.count == 1,
              project.rootModule.displayName == "verification-parent",
              let service = project.rootModule.children.first,
              service.displayName == "verification-service",
              service.groupID == "com.example",
              service.modulePath == "service" else {
            throw VerificationError.unexpectedModuleTree
        }

        let command = MavenCommandBuilder.makeCommand(
            repositoryURL: repositoryURL,
            module: service,
            goal: .install,
            settings: MavenSettings(
                mavenHome: "/opt/apache-maven",
                javaHome: "/opt/jdk-21",
                userSettingsFile: "/tmp/settings file.xml",
                localRepository: "/tmp/local repository",
                activeProfiles: ["verification", " company ", "verification"],
                alsoMake: true,
                additionalArguments: ["-DskipTests", "--offline"]
            ),
            processEnvironment: ["LANG": "C"]
        )
        guard command.executableURL.path == "/opt/apache-maven/bin/mvn",
              command.arguments == [
                "-s", "/tmp/settings file.xml",
                "-Dmaven.repo.local=/tmp/local repository",
                "-Pverification,company",
                "-f", repositoryURL.appendingPathComponent("pom.xml").path,
                "-pl", "service",
                "-am",
                "-DskipTests", "--offline",
                "install"
              ],
              command.environment == ["LANG": "C", "JAVA_HOME": "/opt/jdk-21"] else {
            throw VerificationError.unexpectedCommand
        }

        let legacySettings = try JSONDecoder().decode(
            MavenSettings.self,
            from: Data(
                """
                {
                  "mavenHome": "/opt/maven",
                  "userSettingsFile": "/tmp/settings.xml",
                  "localRepository": "/tmp/repository"
                }
                """.utf8
            )
        )
        guard legacySettings.javaHome.isEmpty,
              legacySettings.activeProfiles.isEmpty,
              !legacySettings.alsoMake,
              legacySettings.additionalArguments.isEmpty,
              legacySettings.runHistoryPolicy == .default else {
            throw VerificationError.legacySettingsCompatibilityFailed
        }

        let historySuiteName = "RepoDeskMavenHistoryVerification.\(UUID().uuidString)"
        guard let historyDefaults = UserDefaults(suiteName: historySuiteName) else {
            throw VerificationError.runHistoryFailed
        }
        historyDefaults.removePersistentDomain(forName: historySuiteName)
        defer { historyDefaults.removePersistentDomain(forName: historySuiteName) }
        let historyStore = UserDefaultsMavenRunHistoryStore(defaults: historyDefaults)
        let historyPolicy = MavenRunHistoryPolicy(
            maximumRecordCount: 2,
            persistsLogs: true,
            maximumLogBytes: 64
        )
        let baseDate = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<3 {
            let finishedAt = baseDate.addingTimeInterval(TimeInterval(offset))
            historyStore.record(
                MavenRunRecord(
                    repositoryURL: repositoryURL,
                    module: service,
                    goal: .install,
                    command: command,
                    terminationStatus: Int32(offset),
                    startedAt: finishedAt.addingTimeInterval(-1),
                    finishedAt: finishedAt,
                    log: String(repeating: "编译输出-\(offset)-", count: 20)
                ),
                for: repositoryURL,
                policy: historyPolicy
            )
        }
        let recentRuns = historyStore.recentRuns(for: repositoryURL)
        guard recentRuns.count == 2,
              recentRuns[0].finishedAt > recentRuns[1].finishedAt,
              recentRuns[0].executablePath == command.executableURL.path,
              recentRuns[0].arguments == command.arguments,
              recentRuns[0].workingDirectoryPath == command.workingDirectoryURL.path,
              recentRuns[0].environment == ["JAVA_HOME": "/opt/jdk-21"],
              recentRuns.allSatisfy({ ($0.log?.utf8.count ?? 0) <= 64 }),
              recentRuns[0].makeRunRequest(module: service)?.command.arguments == command.arguments,
              recentRuns[0].makeRunRequest(module: service)?.command.environment["JAVA_HOME"]
                == "/opt/jdk-21" else {
            throw VerificationError.runHistoryFailed
        }
        historyStore.applyPolicy(
            MavenRunHistoryPolicy(
                maximumRecordCount: 1,
                persistsLogs: false,
                maximumLogBytes: 64
            ),
            for: repositoryURL
        )
        guard historyStore.recentRuns(for: repositoryURL).count == 1,
              historyStore.recentRuns(for: repositoryURL).first?.log == nil else {
            throw VerificationError.runHistoryFailed
        }
        historyStore.clearHistory(for: repositoryURL)
        guard historyStore.recentRuns(for: repositoryURL).isEmpty else {
            throw VerificationError.runHistoryFailed
        }

        let mavenHomeURL = repositoryURL.appendingPathComponent("apache-maven", isDirectory: true)
        let binURL = mavenHomeURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let executableURL = binURL.appendingPathComponent("mvn")
        try Data("#!/bin/sh\necho 'Apache Maven 3.9.9'\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )
        let validator = MavenHomeValidator()
        guard await validator.validate(mavenHome: mavenHomeURL.path)
            == .valid(version: "Apache Maven 3.9.9") else {
            throw VerificationError.mavenHomeValidationFailed
        }
        guard case .invalid(let invalidPathMessage) = await validator.validate(
            mavenHome: repositoryURL.appendingPathComponent("missing-maven").path
        ), invalidPathMessage.contains("路径有误") else {
            throw VerificationError.mavenHomeValidationFailed
        }
        guard await validator.validate(mavenHome: "") == .unconfigured else {
            throw VerificationError.mavenHomeValidationFailed
        }

        let javaHomeURL = repositoryURL.appendingPathComponent("jdk", isDirectory: true)
        let javaBinURL = javaHomeURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: javaBinURL, withIntermediateDirectories: true)
        let javaExecutableURL = javaBinURL.appendingPathComponent("java")
        try Data("#!/bin/sh\necho 'openjdk version \"21.0.6\"' >&2\n".utf8).write(to: javaExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: javaExecutableURL.path
        )
        guard await JavaHomeValidator().validate(javaHome: javaHomeURL.path)
            == .valid(version: "openjdk version \"21.0.6\"") else {
            throw VerificationError.javaHomeValidationFailed
        }

        let settingsURL = repositoryURL.appendingPathComponent("settings.xml")
        try Data("<settings/>".utf8).write(to: settingsURL)
        let localRepositoryURL = repositoryURL.appendingPathComponent("local-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: localRepositoryURL, withIntermediateDirectories: true)
        let pathValidator = MavenPathValidator()
        guard pathValidator.validate(path: settingsURL.path, kind: .userSettingsFile) == .valid,
              pathValidator.validate(path: localRepositoryURL.path, kind: .localRepository) == .valid,
              pathValidator.validate(path: "", kind: .localRepository) == .unconfigured else {
            throw VerificationError.mavenPathValidationFailed
        }

        let refreshBatch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL.appendingPathComponent("service/../pom.xml")],
            requiresFullRescan: false,
            monitoringError: nil
        )
        let wrapperBatch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL.appendingPathComponent("tools/mvnw.cmd")],
            requiresFullRescan: false,
            monitoringError: nil
        )
        let fullRescanBatch = WorkspaceChangeBatch(
            changedURLs: [],
            requiresFullRescan: true,
            monitoringError: nil
        )
        let sourceOnlyBatch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL.appendingPathComponent("service/src/App.java")],
            requiresFullRescan: false,
            monitoringError: nil
        )
        let externalBatch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL.deletingLastPathComponent().appendingPathComponent("pom.xml")],
            requiresFullRescan: false,
            monitoringError: nil
        )
        let failureBatch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL.appendingPathComponent("pom.xml")],
            requiresFullRescan: false,
            monitoringError: "stream failed"
        )
        guard MavenProjectRefreshPlanner.shouldRefresh(
            for: refreshBatch,
            repositoryURL: repositoryURL.appendingPathComponent("ignored/..", isDirectory: true)
        ), MavenProjectRefreshPlanner.shouldRefresh(
            for: wrapperBatch,
            repositoryURL: repositoryURL
        ), MavenProjectRefreshPlanner.shouldRefresh(
            for: fullRescanBatch,
            repositoryURL: repositoryURL
        ), !MavenProjectRefreshPlanner.shouldRefresh(
            for: sourceOnlyBatch,
            repositoryURL: repositoryURL
        ), !MavenProjectRefreshPlanner.shouldRefresh(
            for: externalBatch,
            repositoryURL: repositoryURL
        ), !MavenProjectRefreshPlanner.shouldRefresh(
            for: failureBatch,
            repositoryURL: repositoryURL
        ) else {
            throw VerificationError.mavenRefreshPlanningFailed
        }

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.count > 1 {
            let externalRepositoryURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let externalProject = try MavenProjectScanner().scan(repositoryURL: externalRepositoryURL)
            let externalModuleNames = moduleNames(in: externalProject.rootModule)
            guard externalModuleNames.allSatisfy({ !$0.contains("${") }) else {
                throw VerificationError.unresolvedExternalModuleName
            }
            print("External Maven modules: \(externalModuleNames.joined(separator: ", "))")
        }

        print("Maven module verification passed")
    }

    private static func moduleNames(in module: MavenModule) -> [String] {
        [module.displayName] + module.children.flatMap(moduleNames(in:))
    }

    private static func writePOM(at directoryURL: URL, contents: String) throws {
        try Data(contents.utf8).write(to: directoryURL.appendingPathComponent("pom.xml"))
    }
}

private enum VerificationError: Error {
    case unexpectedModuleTree
    case unexpectedCommand
    case legacySettingsCompatibilityFailed
    case mavenHomeValidationFailed
    case javaHomeValidationFailed
    case mavenPathValidationFailed
    case mavenRefreshPlanningFailed
    case runHistoryFailed
    case unresolvedExternalModuleName
}
