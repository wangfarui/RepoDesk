import Foundation
import Testing
@testable import RepoDesk

struct MavenModuleTests {
    @Test func refreshPlannerRefreshesForFullRescan() {
        let repositoryURL = URL(fileURLWithPath: "/tmp/workspace/repository", isDirectory: true)
        let batch = WorkspaceChangeBatch(
            changedURLs: [],
            requiresFullRescan: true,
            monitoringError: nil
        )

        #expect(MavenProjectRefreshPlanner.shouldRefresh(
            for: batch,
            repositoryURL: repositoryURL
        ))
    }

    @Test func refreshPlannerRefreshesForMavenProjectFilesInsideRepository() {
        let repositoryURL = URL(fileURLWithPath: "/tmp/workspace/repository", isDirectory: true)
        for relativePath in ["pom.xml", "service/pom.xml", "mvnw", "tools/mvnw.cmd"] {
            let batch = WorkspaceChangeBatch(
                changedURLs: [repositoryURL.appendingPathComponent(relativePath)],
                requiresFullRescan: false,
                monitoringError: nil
            )

            #expect(MavenProjectRefreshPlanner.shouldRefresh(
                for: batch,
                repositoryURL: repositoryURL
            ))
        }
    }

    @Test func refreshPlannerIgnoresSourceFilesAndMavenFilesOutsideRepository() {
        let repositoryURL = URL(fileURLWithPath: "/tmp/workspace/repository", isDirectory: true)
        let batch = WorkspaceChangeBatch(
            changedURLs: [
                repositoryURL.appendingPathComponent("src/main/java/App.java"),
                URL(fileURLWithPath: "/tmp/workspace/other/pom.xml"),
                URL(fileURLWithPath: "/tmp/workspace/repository-sibling/mvnw")
            ],
            requiresFullRescan: false,
            monitoringError: nil
        )

        #expect(!MavenProjectRefreshPlanner.shouldRefresh(
            for: batch,
            repositoryURL: repositoryURL
        ))
    }

    @Test func refreshPlannerStandardizesRepositoryAndChangedPaths() {
        let repositoryURL = URL(
            fileURLWithPath: "/tmp/workspace/ignored/../repository/.",
            isDirectory: true
        )
        let changedURL = URL(
            fileURLWithPath: "/tmp/workspace/repository/module/../pom.xml"
        )
        let batch = WorkspaceChangeBatch(
            changedURLs: [changedURL],
            requiresFullRescan: false,
            monitoringError: nil
        )

        #expect(MavenProjectRefreshPlanner.shouldRefresh(
            for: batch,
            repositoryURL: repositoryURL
        ))
    }

    @Test func refreshPlannerIgnoresMonitoringFailures() {
        let repositoryURL = URL(fileURLWithPath: "/tmp/workspace/repository", isDirectory: true)
        let batch = WorkspaceChangeBatch(
            changedURLs: [repositoryURL.appendingPathComponent("pom.xml")],
            requiresFullRescan: false,
            monitoringError: "stream failed"
        )

        #expect(!MavenProjectRefreshPlanner.shouldRefresh(
            for: batch,
            repositoryURL: repositoryURL
        ))
    }

    @Test func scannerBuildsRecursiveModuleTreeAndInheritsParentCoordinates() throws {
        let repositoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        try writePOM(
            at: repositoryURL,
            contents: """
            <project xmlns="http://maven.apache.org/POM/4.0.0">
              <groupId>com.example</groupId>
              <artifactId>sample-parent</artifactId>
              <version>1.0.0</version>
              <packaging>pom</packaging>
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
                <artifactId>sample-parent</artifactId>
                <version>1.0.0</version>
              </parent>
              <artifactId>sample-service</artifactId>
              <name>Sample Service</name>
            </project>
            """
        )

        let project = try MavenProjectScanner().scan(repositoryURL: repositoryURL)

        #expect(project.rootModule.artifactID == "sample-parent")
        #expect(project.rootModule.packaging == "pom")
        #expect(project.rootModule.children.count == 1)
        let service = try #require(project.rootModule.children.first)
        #expect(service.modulePath == "service")
        #expect(service.displayName == "Sample Service")
        #expect(service.groupID == "com.example")
        #expect(service.version == "1.0.0")
        #expect(service.packaging == "jar")
    }

    @Test func scannerKeepsDeclaredModuleVisibleWhenItsPOMIsMissing() throws {
        let repositoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        try writePOM(
            at: repositoryURL,
            contents: """
            <project>
              <artifactId>sample-parent</artifactId>
              <modules><module>missing-module</module></modules>
            </project>
            """
        )

        let project = try MavenProjectScanner().scan(repositoryURL: repositoryURL)
        let missingModule = try #require(project.rootModule.children.first)

        #expect(missingModule.modulePath == "missing-module")
        #expect(!missingModule.hasPOM)
    }

    @Test func commandBuilderUsesArrayArgumentsAndWorkspaceSettings() {
        let repositoryURL = URL(fileURLWithPath: "/work/sample", isDirectory: true)
        let module = MavenModule(
            modulePath: "service one",
            pomURL: repositoryURL.appendingPathComponent("service one/pom.xml"),
            displayName: "Service",
            groupID: "com.example",
            artifactID: "service",
            version: "1.0.0",
            packaging: "jar",
            hasPOM: true,
            children: []
        )
        let command = MavenCommandBuilder.makeCommand(
            repositoryURL: repositoryURL,
            module: module,
            goal: .package,
            settings: MavenSettings(
                mavenHome: "/opt/apache-maven",
                userSettingsFile: "/work/settings file.xml",
                localRepository: "/work/local repository"
            )
        )

        #expect(command.executableURL.path == "/opt/apache-maven/bin/mvn")
        #expect(command.arguments == [
            "-s", "/work/settings file.xml",
            "-Dmaven.repo.local=/work/local repository",
            "-f", "/work/sample/pom.xml",
            "-pl", "service one",
            "package"
        ])
        #expect(command.workingDirectoryURL == repositoryURL)
    }

    @Test func commandBuilderBuildsModuleProfilesAlsoMakeAdditionalArgumentsAndJavaEnvironment() {
        let repositoryURL = URL(fileURLWithPath: "/work/sample", isDirectory: true)
        let module = MavenModule(
            modulePath: "services/order service",
            pomURL: repositoryURL.appendingPathComponent("services/order service/pom.xml"),
            displayName: "Order Service",
            groupID: "com.example",
            artifactID: "order-service",
            version: "1.0.0",
            packaging: "jar",
            hasPOM: true,
            children: []
        )
        let command = MavenCommandBuilder.makeCommand(
            repositoryURL: repositoryURL,
            module: module,
            goal: .install,
            settings: MavenSettings(
                mavenHome: "/opt/apache-maven",
                javaHome: "/opt/jdk-21",
                userSettingsFile: "/work/settings.xml",
                localRepository: "/work/m2 repository",
                activeProfiles: [" dev ", "company", "dev", ""],
                alsoMake: true,
                additionalArguments: ["-DskipTests", "--offline"]
            ),
            processEnvironment: ["LANG": "zh_CN.UTF-8"]
        )

        #expect(command.arguments == [
            "-s", "/work/settings.xml",
            "-Dmaven.repo.local=/work/m2 repository",
            "-Pdev,company",
            "-f", "/work/sample/pom.xml",
            "-pl", "services/order service",
            "-am",
            "-DskipTests", "--offline",
            "install"
        ])
        #expect(command.environment == [
            "LANG": "zh_CN.UTF-8",
            "JAVA_HOME": "/opt/jdk-21"
        ])
        #expect(command.displayComponents == [command.executableURL.path] + command.arguments)
    }

    @Test func rootModuleCommandDoesNotAddProjectSelectionOrAlsoMake() {
        let repositoryURL = URL(fileURLWithPath: "/work/sample", isDirectory: true)
        let module = MavenModule(
            modulePath: ".",
            pomURL: repositoryURL.appendingPathComponent("pom.xml"),
            displayName: "Sample",
            groupID: "com.example",
            artifactID: "sample",
            version: "1.0.0",
            packaging: "pom",
            hasPOM: true,
            children: []
        )

        let command = MavenCommandBuilder.makeCommand(
            repositoryURL: repositoryURL,
            module: module,
            goal: .clean,
            settings: MavenSettings(alsoMake: true),
            processEnvironment: [:]
        )

        let localRepository = MavenLocalRepositoryResolver.resolve(settings: .empty, environment: [:])
        #expect(command.arguments == ["mvn", "-Dmaven.repo.local=\(localRepository.path)",
                                     "-f", "/work/sample/pom.xml", "clean"])
    }

    @Test func deployAlwaysRequiresConfirmation() {
        #expect(MavenLifecycleGoal.deploy.requiresConfirmation)
        #expect(!MavenLifecycleGoal.install.requiresConfirmation)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskMavenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePOM(at directoryURL: URL, contents: String) throws {
        try Data(contents.utf8).write(to: directoryURL.appendingPathComponent("pom.xml"))
    }
}

struct MavenHomeValidatorTests {
    @Test @MainActor func unchangedMavenHomeUsesCachedValidation() async throws {
        let mavenHomeURL = try makeExecutableMavenHome()
        defer { try? FileManager.default.removeItem(at: mavenHomeURL) }
        let javaHomeURL = try makeExecutableJavaHome()
        defer { try? FileManager.default.removeItem(at: javaHomeURL) }
        let runner = MavenValidationCommandRunnerDouble(
            result: CommandResult(
                standardOutput: Data("Apache Maven 3.9.9\n".utf8),
                standardError: Data(),
                terminationStatus: 0
            )
        )
        let javaRunner = MavenValidationCommandRunnerDouble(
            result: CommandResult(
                standardOutput: Data(),
                standardError: Data("openjdk version \"21.0.6\"\n".utf8),
                terminationStatus: 0
            )
        )
        let store = MavenEnvironmentValidationStore(
            mavenHomeValidator: MavenHomeValidator(commandRunner: runner),
            javaHomeValidator: JavaHomeValidator(commandRunner: javaRunner)
        )
        let workspaceURL = URL(fileURLWithPath: "/workspace", isDirectory: true)

        await store.validateMavenHome(workspaceURL: workspaceURL, home: mavenHomeURL.path)
        await store.validateMavenHome(workspaceURL: workspaceURL, home: mavenHomeURL.path)
        await store.validateJavaHome(workspaceURL: workspaceURL, home: javaHomeURL.path)
        await store.validateJavaHome(workspaceURL: workspaceURL, home: javaHomeURL.path)

        #expect(await runner.runCount() == 1)
        #expect(await javaRunner.runCount() == 1)
        #expect(store.mavenResult(workspaceURL: workspaceURL, home: mavenHomeURL.path) == .valid(version: "Apache Maven 3.9.9"))
        #expect(store.javaResult(workspaceURL: workspaceURL, home: javaHomeURL.path) == .valid(version: "openjdk version \"21.0.6\""))
    }

    @Test func emptyMavenHomeRemainsUnconfiguredWithoutLaunchingProcess() async {
        let runner = MavenValidationCommandRunnerDouble(
            result: CommandResult(
                standardOutput: Data(),
                standardError: Data(),
                terminationStatus: 0
            )
        )
        let validator = MavenHomeValidator(commandRunner: runner)

        let result = await validator.validate(mavenHome: "   ")

        #expect(result == .unconfigured)
        #expect(!(await runner.hasCapturedRequest()))
    }

    @Test func validMavenHomeReportsVersionAndRunsItsExecutable() async throws {
        let mavenHomeURL = try makeExecutableMavenHome()
        defer { try? FileManager.default.removeItem(at: mavenHomeURL) }
        let runner = MavenValidationCommandRunnerDouble(
            result: CommandResult(
                standardOutput: Data("Apache Maven 3.9.9\nMaven home: /opt/maven\n".utf8),
                standardError: Data(),
                terminationStatus: 0
            )
        )
        let validator = MavenHomeValidator(commandRunner: runner)

        let result = await validator.validate(mavenHome: mavenHomeURL.path)

        #expect(result == .valid(version: "Apache Maven 3.9.9"))
        let request = try #require(await runner.capturedRequest())
        #expect(request.executableURL == mavenHomeURL.appendingPathComponent("bin/mvn"))
        #expect(request.arguments == ["-version"])
        #expect(request.workingDirectoryURL == mavenHomeURL)
    }

    @Test func missingMavenExecutableReportsIncorrectPathWithoutLaunchingProcess() async {
        let runner = MavenValidationCommandRunnerDouble(
            result: CommandResult(
                standardOutput: Data(),
                standardError: Data(),
                terminationStatus: 0
            )
        )
        let validator = MavenHomeValidator(commandRunner: runner)

        let result = await validator.validate(mavenHome: "/not/a/maven/home")

        guard case .invalid(let message) = result else {
            Issue.record("Expected an invalid Maven Home result")
            return
        }
        #expect(message.contains("路径有误"))
        #expect(message.contains("bin/mvn"))
        #expect(!(await runner.hasCapturedRequest()))
    }

    @Test func failingVersionCommandReportsIncorrectPath() async throws {
        let mavenHomeURL = try makeExecutableMavenHome()
        defer { try? FileManager.default.removeItem(at: mavenHomeURL) }
        let runner = MavenValidationCommandRunnerDouble(
            result: CommandResult(
                standardOutput: Data(),
                standardError: Data("invalid installation".utf8),
                terminationStatus: 1
            )
        )
        let validator = MavenHomeValidator(commandRunner: runner)

        let result = await validator.validate(mavenHome: mavenHomeURL.path)

        guard case .invalid(let message) = result else {
            Issue.record("Expected an invalid Maven Home result")
            return
        }
        #expect(message.contains("路径有误"))
        #expect(message.contains("invalid installation"))
    }

    private func makeExecutableMavenHome() throws -> URL {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskMavenHomeTests-\(UUID().uuidString)", isDirectory: true)
        let binURL = homeURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let executableURL = binURL.appendingPathComponent("mvn")
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )
        return homeURL
    }

    private func makeExecutableJavaHome() throws -> URL {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskJavaHomeCacheTests-\(UUID().uuidString)", isDirectory: true)
        let binURL = homeURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let executableURL = binURL.appendingPathComponent("java")
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )
        return homeURL
    }
}

struct JavaHomeValidatorTests {
    @Test func validJavaHomeReportsVersionAndExportsJavaHome() async throws {
        let javaHomeURL = try makeExecutableJavaHome()
        defer { try? FileManager.default.removeItem(at: javaHomeURL) }
        let runner = MavenValidationCommandRunnerDouble(
            result: CommandResult(
                standardOutput: Data(),
                standardError: Data("openjdk version \"21.0.6\" 2025-01-21\n".utf8),
                terminationStatus: 0
            )
        )
        let validator = JavaHomeValidator(commandRunner: runner)

        let result = await validator.validate(javaHome: javaHomeURL.path)

        #expect(result == .valid(version: "openjdk version \"21.0.6\" 2025-01-21"))
        let request = try #require(await runner.capturedRequest())
        #expect(request.executableURL == javaHomeURL.appendingPathComponent("bin/java"))
        #expect(request.arguments == ["-version"])
        #expect(request.workingDirectoryURL == javaHomeURL)
        #expect(request.environment?["JAVA_HOME"] == javaHomeURL.path)
    }

    @Test func missingJavaExecutableReportsIncorrectPathWithoutLaunchingProcess() async {
        let runner = MavenValidationCommandRunnerDouble(
            result: CommandResult(
                standardOutput: Data(),
                standardError: Data(),
                terminationStatus: 0
            )
        )
        let validator = JavaHomeValidator(commandRunner: runner)

        let result = await validator.validate(javaHome: "/not/a/java/home")

        guard case .invalid(let message) = result else {
            Issue.record("Expected an invalid Java Home result")
            return
        }
        #expect(message.contains("路径有误"))
        #expect(message.contains("bin/java"))
        #expect(!(await runner.hasCapturedRequest()))
    }

    private func makeExecutableJavaHome() throws -> URL {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskJavaHomeTests-\(UUID().uuidString)", isDirectory: true)
        let binURL = homeURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let executableURL = binURL.appendingPathComponent("java")
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )
        return homeURL
    }
}

struct MavenPathValidatorTests {
    @Test func validatesSettingsFileAndLocalRepositoryByExpectedPathKind() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDeskMavenPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let settingsURL = rootURL.appendingPathComponent("settings.xml")
        try Data("<settings/>".utf8).write(to: settingsURL)
        let repositoryURL = rootURL.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let validator = MavenPathValidator()

        #expect(validator.validate(path: settingsURL.path, kind: .userSettingsFile) == .valid)
        #expect(validator.validate(path: repositoryURL.path, kind: .localRepository) == .valid)
        #expect(validator.validate(path: "  ", kind: .localRepository) == .unconfigured)

        guard case .invalid(let fileMessage) = validator.validate(
            path: repositoryURL.path,
            kind: .userSettingsFile
        ) else {
            Issue.record("Expected a directory to be rejected as settings.xml")
            return
        }
        #expect(fileMessage.contains("文件"))

        guard case .invalid(let directoryMessage) = validator.validate(
            path: settingsURL.path,
            kind: .localRepository
        ) else {
            Issue.record("Expected a file to be rejected as Local repository")
            return
        }
        #expect(directoryMessage.contains("目录"))
    }
}

@MainActor
struct MavenSettingsStoreTests {
    @Test func legacySettingsDecodeWithDefaultsForNewExecutionOptions() throws {
        let data = Data(
            """
            {
              "mavenHome": "/opt/maven",
              "userSettingsFile": "/work/settings.xml",
              "localRepository": "/work/repository"
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(MavenSettings.self, from: data)

        #expect(settings.mavenHome == "/opt/maven")
        #expect(settings.javaHome.isEmpty)
        #expect(settings.userSettingsFile == "/work/settings.xml")
        #expect(settings.localRepository == "/work/repository")
        #expect(settings.activeProfiles.isEmpty)
        #expect(!settings.alsoMake)
        #expect(settings.additionalArguments.isEmpty)
        #expect(settings.runHistoryPolicy == .default)
    }

    @Test func settingsArePersistedPerWorkspace() throws {
        let suiteName = "RepoDeskMavenSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsMavenSettingsStore(defaults: defaults)
        let firstWorkspace = URL(fileURLWithPath: "/work/first", isDirectory: true)
        let secondWorkspace = URL(fileURLWithPath: "/work/second", isDirectory: true)
        let settings = MavenSettings(
            mavenHome: "/opt/maven",
            userSettingsFile: "/work/settings.xml",
            localRepository: "/work/repository"
        )

        try store.save(settings, for: firstWorkspace)

        #expect(store.settings(for: firstWorkspace) == settings)
        #expect(store.settings(for: secondWorkspace) == .empty)
    }

    @Test func appStateLoadsSavesAndRunsMavenWithArrayArguments() async throws {
        let workspaceURL = URL(fileURLWithPath: "/work/sample", isDirectory: true)
        let repository = RegisteredRepository(displayName: "sample", relativePath: ".", isPinned: false)
        let storedSettings = MavenSettings(
            mavenHome: "/opt/maven",
            userSettingsFile: "/work/settings.xml",
            localRepository: "/work/repository"
        )
        let settingsStore = MavenSettingsStoreDouble(
            settingsByWorkspace: [workspaceURL.standardizedFileURL.path: storedSettings]
        )
        let historyStore = MavenRunHistoryStoreDouble()
        let taskRunner = MavenTaskRunnerDouble()
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            repositories: [repository],
            selectedRepositoryID: repository.id,
            mavenRunnerFactory: { taskRunner },
            mavenSettingsStore: settingsStore,
            mavenRunHistoryStore: historyStore,
            restoresWorkspaceOnLaunch: false
        )
        state.selectRepositoryContext(repository.id)
        #expect(state.mavenSettings == storedSettings)

        let updatedSettings = MavenSettings(
            mavenHome: "/opt/maven-2",
            userSettingsFile: "/work/settings-2.xml",
            localRepository: "/work/repository-2"
        )
        state.updateMavenSettings(updatedSettings)
        #expect(settingsStore.savedSettings == updatedSettings)
        #expect(settingsStore.savedWorkspaceURL == workspaceURL)

        let module = MavenModule(
            modulePath: "service one",
            pomURL: workspaceURL.appendingPathComponent("service one/pom.xml"),
            displayName: "Service",
            groupID: "com.example",
            artifactID: "service",
            version: "1.0.0",
            packaging: "jar",
            hasPOM: true,
            children: []
        )
        let command = MavenCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["mvn", "-f", module.pomURL.path, "package"],
            workingDirectoryURL: workspaceURL
        )
        state.runMaven(MavenRunRequest(module: module, goal: .package, command: command))
        for _ in 0..<100 where state.mavenExecution.terminationStatus == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let captured = await taskRunner.capturedTask()
        let capturedTask = try #require(captured)
        #expect(capturedTask.executableURL == command.executableURL)
        #expect(capturedTask.arguments == command.arguments)
        #expect(capturedTask.workingDirectoryURL == command.workingDirectoryURL)
        #expect(state.mavenExecution.terminationStatus == 0)
        #expect(state.mavenExecution.log.contains("Maven output"))
        let recordedRun = try #require(historyStore.runs.first)
        #expect(recordedRun.repositoryPath == workspaceURL.standardizedFileURL.path)
        #expect(recordedRun.modulePath == module.modulePath)
        #expect(recordedRun.goal == .package)
        #expect(recordedRun.arguments == command.arguments)
        #expect(recordedRun.log == nil)
        var sessionRun = try #require(state.recentMavenRuns.first)
        #expect(sessionRun.log?.contains("Maven output") == true)
        sessionRun.log = nil
        #expect(sessionRun == recordedRun)
    }

    @Test func appStateSurfacesMavenSettingsPersistenceFailure() {
        let workspaceURL = URL(fileURLWithPath: "/work/settings-failure", isDirectory: true)
        let settingsStore = MavenSettingsStoreDouble(
            settingsByWorkspace: [:],
            saveError: MavenSettingsPersistenceError.verificationFailed
        )
        let state = AppState(
            workspace: WorkspaceSummary(url: workspaceURL),
            mavenSettingsStore: settingsStore,
            restoresWorkspaceOnLaunch: false
        )

        state.updateMavenSettings(MavenSettings(mavenHome: "/opt/maven"))

        #expect(state.mavenSettingsErrorMessage?.contains("保存失败") == true)
    }
}

struct MavenRunRecordTests {
    @Test func recordRestoresExactCommandAndBuildsRerunRequestForMatchingModule() throws {
        let repositoryURL = URL(fileURLWithPath: "/work/sample", isDirectory: true)
        let module = makeMavenRunHistoryModule(repositoryURL: repositoryURL)
        let command = MavenCommand(
            executableURL: URL(fileURLWithPath: "/opt/maven/bin/mvn"),
            arguments: ["-f", "/work/sample/pom.xml", "-pl", "service", "package"],
            workingDirectoryURL: repositoryURL,
            environment: ["JAVA_HOME": "/opt/jdk-21", "SECRET_TOKEN": "must-not-persist"]
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        let record = MavenRunRecord(
            repositoryURL: repositoryURL,
            module: module,
            goal: .package,
            command: command,
            terminationStatus: 2,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(3.5),
            log: "build failed"
        )

        #expect(record.repositoryPath == repositoryURL.path)
        #expect(record.modulePath == "service")
        #expect(record.moduleName == "Sample Service")
        #expect(record.environment == ["JAVA_HOME": "/opt/jdk-21"])
        #expect(record.command.executableURL == command.executableURL)
        #expect(record.command.arguments == command.arguments)
        #expect(record.command.workingDirectoryURL == command.workingDirectoryURL)
        #expect(record.command.environment["JAVA_HOME"] == "/opt/jdk-21")
        #expect(record.command.environment["SECRET_TOKEN"] != "must-not-persist")
        #expect(record.duration == 3.5)
        let rerunRequest = try #require(record.makeRunRequest(module: module))
        #expect(rerunRequest.goal == .package)
        #expect(rerunRequest.command.executableURL == command.executableURL)
        #expect(rerunRequest.command.arguments == command.arguments)
        #expect(rerunRequest.command.environment["JAVA_HOME"] == "/opt/jdk-21")

        let otherModule = MavenModule(
            modulePath: "other",
            pomURL: repositoryURL.appendingPathComponent("other/pom.xml"),
            displayName: "Other",
            groupID: nil,
            artifactID: "other",
            version: nil,
            packaging: "jar",
            hasPOM: true,
            children: []
        )
        #expect(record.makeRunRequest(module: otherModule) == nil)
    }

    @Test func persistedLogKeepsUtf8WithinConfiguredByteLimit() {
        let repositoryURL = URL(fileURLWithPath: "/work/sample", isDirectory: true)
        let record = makeMavenRunRecord(
            repositoryURL: repositoryURL,
            finishedAt: Date(),
            log: String(repeating: "编译失败-", count: 50)
        )

        let persisted = record.preparedForPersistence(
            policy: MavenRunHistoryPolicy(
                maximumRecordCount: 10,
                persistsLogs: true,
                maximumLogBytes: 64
            )
        )

        #expect(persisted.log != nil)
        #expect((persisted.log?.utf8.count ?? 0) <= 64)
        #expect(persisted.log?.hasSuffix("编译失败-") == true)
    }
}

@MainActor
struct MavenRunHistoryStoreTests {
    @Test func storeIsolatesWorkspacesSortsRunsAndAppliesCapacityAndLogPolicy() throws {
        let suiteName = "RepoDeskMavenRunHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsMavenRunHistoryStore(defaults: defaults)
        let firstWorkspace = URL(fileURLWithPath: "/work/first", isDirectory: true)
        let secondWorkspace = URL(fileURLWithPath: "/work/second", isDirectory: true)
        let policy = MavenRunHistoryPolicy(
            maximumRecordCount: 2,
            persistsLogs: true,
            maximumLogBytes: 48
        )
        let baseDate = Date(timeIntervalSince1970: 1_000)

        for offset in 0..<3 {
            store.record(
                makeMavenRunRecord(
                    repositoryURL: firstWorkspace,
                    finishedAt: baseDate.addingTimeInterval(TimeInterval(offset)),
                    log: String(repeating: "output-\(offset)-", count: 20)
                ),
                for: firstWorkspace,
                policy: policy
            )
        }
        store.record(
            makeMavenRunRecord(
                repositoryURL: secondWorkspace,
                finishedAt: baseDate,
                log: "second"
            ),
            for: secondWorkspace,
            policy: policy
        )

        let firstRuns = store.recentRuns(for: firstWorkspace)
        #expect(firstRuns.count == 2)
        #expect(firstRuns[0].finishedAt > firstRuns[1].finishedAt)
        #expect(firstRuns.allSatisfy { ($0.log?.utf8.count ?? 0) <= 48 })
        #expect(store.recentRuns(for: secondWorkspace).count == 1)

        store.applyPolicy(
            MavenRunHistoryPolicy(
                maximumRecordCount: 1,
                persistsLogs: false,
                maximumLogBytes: 48
            ),
            for: firstWorkspace
        )
        #expect(store.recentRuns(for: firstWorkspace).count == 1)
        #expect(store.recentRuns(for: firstWorkspace).first?.log == nil)
    }

    @Test func storeCanRemoveRunsClearLogsAndClearWorkspaceHistory() throws {
        let suiteName = "RepoDeskMavenRunHistoryClearTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsMavenRunHistoryStore(defaults: defaults)
        let workspaceURL = URL(fileURLWithPath: "/work/sample", isDirectory: true)
        let policy = MavenRunHistoryPolicy(persistsLogs: true)
        let first = makeMavenRunRecord(
            repositoryURL: workspaceURL,
            finishedAt: Date(timeIntervalSince1970: 1),
            log: "first"
        )
        let second = makeMavenRunRecord(
            repositoryURL: workspaceURL,
            finishedAt: Date(timeIntervalSince1970: 2),
            log: "second"
        )
        store.record(first, for: workspaceURL, policy: policy)
        store.record(second, for: workspaceURL, policy: policy)

        store.remove(runID: first.id, for: workspaceURL)
        #expect(store.recentRuns(for: workspaceURL).map(\.id) == [second.id])
        store.clearPersistedLogs(for: workspaceURL)
        #expect(store.recentRuns(for: workspaceURL).first?.log == nil)
        store.clearHistory(for: workspaceURL)
        #expect(store.recentRuns(for: workspaceURL).isEmpty)
    }
}

private func makeMavenRunHistoryModule(repositoryURL: URL) -> MavenModule {
    MavenModule(
        modulePath: "service",
        pomURL: repositoryURL.appendingPathComponent("service/pom.xml"),
        displayName: "Sample Service",
        groupID: "com.example",
        artifactID: "service",
        version: "1.0.0",
        packaging: "jar",
        hasPOM: true,
        children: []
    )
}

private func makeMavenRunRecord(
    repositoryURL: URL,
    finishedAt: Date,
    log: String?
) -> MavenRunRecord {
    let module = makeMavenRunHistoryModule(repositoryURL: repositoryURL)
    return MavenRunRecord(
        repositoryURL: repositoryURL,
        module: module,
        goal: .package,
        command: MavenCommand(
            executableURL: URL(fileURLWithPath: "/opt/maven/bin/mvn"),
            arguments: ["-pl", module.modulePath, "package"],
            workingDirectoryURL: repositoryURL,
            environment: ["JAVA_HOME": "/opt/jdk-21"]
        ),
        terminationStatus: 0,
        startedAt: finishedAt.addingTimeInterval(-2),
        finishedAt: finishedAt,
        log: log
    )
}

@MainActor
private final class MavenSettingsStoreDouble: MavenSettingsStoring {
    private let settingsByWorkspace: [String: MavenSettings]
    private let saveError: Error?
    private(set) var savedSettings: MavenSettings?
    private(set) var savedWorkspaceURL: URL?

    init(settingsByWorkspace: [String: MavenSettings], saveError: Error? = nil) {
        self.settingsByWorkspace = settingsByWorkspace
        self.saveError = saveError
    }

    func settings(for workspaceURL: URL) -> MavenSettings {
        settingsByWorkspace[workspaceURL.standardizedFileURL.path] ?? .empty
    }

    func save(_ settings: MavenSettings, for workspaceURL: URL) throws {
        if let saveError { throw saveError }
        savedSettings = settings
        savedWorkspaceURL = workspaceURL.standardizedFileURL
    }
}

@MainActor
private final class MavenRunHistoryStoreDouble: MavenRunHistoryStoring {
    private(set) var runs: [MavenRunRecord] = []

    func recentRuns(for workspaceURL: URL) -> [MavenRunRecord] {
        runs
    }

    func record(
        _ run: MavenRunRecord,
        for workspaceURL: URL,
        policy: MavenRunHistoryPolicy
    ) {
        runs.insert(run.preparedForPersistence(policy: policy), at: 0)
        runs = Array(runs.prefix(policy.normalized.maximumRecordCount))
    }

    func applyPolicy(_ policy: MavenRunHistoryPolicy, for workspaceURL: URL) {
        runs = Array(
            runs
                .map { $0.preparedForPersistence(policy: policy) }
                .prefix(policy.normalized.maximumRecordCount)
        )
    }

    func remove(runID: MavenRunRecord.ID, for workspaceURL: URL) {
        runs.removeAll { $0.id == runID }
    }

    func clearPersistedLogs(for workspaceURL: URL) {
        for index in runs.indices { runs[index].log = nil }
    }

    func clearHistory(for workspaceURL: URL) {
        runs = []
    }
}

private actor MavenTaskRunnerDouble: RepoTaskRunning {
    private var task: ResolvedRepoTask?
    private var stopCount = 0

    func run(
        _ task: ResolvedRepoTask,
        output: @escaping @Sendable (TaskOutputChunk) -> Void
    ) async throws -> TaskRunResult {
        self.task = task
        output(TaskOutputChunk(channel: .standardOutput, text: "Maven output\n"))
        let now = Date()
        return TaskRunResult(terminationStatus: 0, startedAt: now, finishedAt: now)
    }

    func stop() async {
        stopCount += 1
    }

    func capturedTask() -> ResolvedRepoTask? {
        task
    }
}

private actor MavenValidationCommandRunnerDouble: CommandRunning {
    private let result: CommandResult
    private var request: CommandRequest?
    private var invocationCount = 0

    init(result: CommandResult) {
        self.result = result
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        invocationCount += 1
        self.request = request
        return result
    }

    func capturedRequest() -> CommandRequest? {
        request
    }

    func hasCapturedRequest() -> Bool {
        request != nil
    }

    func runCount() -> Int {
        invocationCount
    }
}
