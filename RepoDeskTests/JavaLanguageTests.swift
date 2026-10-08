import Foundation
import Testing
@testable import RepoDesk

struct JavaLanguageTests {
    @Test func javaSemanticTokensOnlyScheduleOnReadyTransition() {
        #expect(
            AppState.shouldScheduleJavaSemanticTokens(
                previousPhase: .indexing,
                currentPhase: .ready
            )
        )
        #expect(
            !AppState.shouldScheduleJavaSemanticTokens(
                previousPhase: .ready,
                currentPhase: .ready
            )
        )
        #expect(
            !AppState.shouldScheduleJavaSemanticTokens(
                previousPhase: .failed,
                currentPhase: .indexing
            )
        )
    }

    @Test func javaIndexSnapshotIsFullyReadyOnlyWhenEveryJavaRepositoryIsReady() {
        let ready = JavaRepositoryIndexState(
            repositoryID: "ready",
            displayName: "Ready",
            phase: .ready,
            progress: 1,
            detail: nil,
            branchName: nil,
            cacheBytes: 1
        )
        let indexing = JavaRepositoryIndexState(
            repositoryID: "indexing",
            displayName: "Indexing",
            phase: .indexing,
            progress: 0.5,
            detail: nil,
            branchName: nil,
            cacheBytes: 1
        )

        #expect(JavaIndexSnapshot(
            repositories: [ready],
            activeRepositoryID: nil,
            runningJVMCount: 0,
            cacheBytes: 1,
            isBackgroundIndexingPaused: false
        ).isFullyReady)
        #expect(!JavaIndexSnapshot(
            repositories: [ready, indexing],
            activeRepositoryID: nil,
            runningJVMCount: 1,
            cacheBytes: 2,
            isBackgroundIndexingPaused: false
        ).isFullyReady)
    }

    @Test func javaNavigationFailureMessageExplainsFailedIndex() {
        let message = AppState.javaNavigationFailureMessage(
            repositoryName: "online.base.item.service",
            phase: .failed,
            detail: "Java language runtime is not installed in RepoDesk.app.",
            action: .contextual
        )

        #expect(message.contains("online.base.item.service"))
        #expect(message.contains("Java 索引失败"))
        #expect(message.contains("Java language runtime is not installed in RepoDesk.app."))
        #expect(message.contains("重建索引"))
    }

    @Test func javaNavigationFailureMessageExplainsMissingDefinitionAfterReadyIndex() {
        let message = AppState.javaNavigationFailureMessage(
            repositoryName: "manager",
            phase: .ready,
            detail: "Java 索引已就绪",
            action: .declaration
        )

        #expect(message.contains("未找到目标定义"))
        #expect(message.contains("依赖源码"))
    }

    @Test func javaWorkspaceNavigationFallbackFindsImportedMethodInAnotherRepository() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-JavaNavigationFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let consumer = workspaceURL.appendingPathComponent("consumer", isDirectory: true)
        let provider = workspaceURL.appendingPathComponent("provider", isDirectory: true)
        let consumerFile = consumer.appendingPathComponent("src/main/java/example/Consumer.java")
        let providerFile = provider.appendingPathComponent(
            "src/main/java/example/api/InventoryManagerClientService.java"
        )
        try FileManager.default.createDirectory(at: consumerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        import example.api.InventoryManagerClientService;
        class Consumer {
            private InventoryManagerClientService service;
            void call() { service.queryInventoryByInventoryId(); }
        }
        """.utf8).write(to: consumerFile)
        try Data("""
        package example.api;
        public interface InventoryManagerClientService {
            void queryInventoryByInventoryId();
        }
        """.utf8).write(to: providerFile)

        let repositories = [
            RegisteredRepository(displayName: "consumer", relativePath: "consumer", isPinned: false),
            RegisteredRepository(displayName: "provider", relativePath: "provider", isPinned: false)
        ]
        let text = try String(contentsOf: consumerFile, encoding: .utf8)
        let offset = (text as NSString).range(of: "queryInventoryByInventoryId").location
        let lineIndex = SourceLineIndex(text: text)
        let line = lineIndex.lineNumber(containingUTF16Offset: offset) - 1
        let position = JavaSourcePosition(
            line: line,
            character: offset - lineIndex.lineStartOffsets[line]
        )
        let targets = await JavaWorkspaceNavigationFallback.targets(
            for: JavaNavigationRequest(
                action: .declaration,
                fileURL: consumerFile,
                position: position,
                documentText: text
            ),
            workspaceURL: workspaceURL,
            repositories: repositories
        )

        #expect(targets.count == 1)
        #expect(targets.first?.fileURL == providerFile.standardizedFileURL)
        #expect(targets.first?.name == "queryInventoryByInventoryId")
    }

    @Test func javaIndexSettingsUseRequestedDefaultsAndClampUnsafeValues() {
        #expect(JavaIndexSettings.default.maximumJVMCount == 1)
        #expect(JavaIndexSettings.default.processorCountPerJVM == min(2, ProcessInfo.processInfo.activeProcessorCount))
        #expect(JavaIndexSettings.default.maximumHeapMegabytes == 2_048)
        #expect(JavaIndexSettings.default.cacheLimitGigabytes == 10)

        let clamped = JavaIndexSettings(
            maximumJVMCount: 20,
            processorCountPerJVM: 0,
            maximumHeapMegabytes: 200,
            cacheLimitGigabytes: 500
        )
        #expect(clamped.maximumJVMCount == 4)
        #expect(clamped.processorCountPerJVM == 1)
        #expect(clamped.maximumHeapMegabytes == 1_024)
        #expect(clamped.cacheLimitGigabytes == 100)
    }

    @Test func lspFramerHandlesFragmentedAndCombinedMessages() throws {
        let first = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":2}"#.utf8)
        let combined = LSPMessageFramer.frame(first) + LSPMessageFramer.frame(second)
        var framer = LSPMessageFramer()

        let split = combined.count / 2
        #expect(try framer.append(combined.prefix(split)).isEmpty)
        let messages = try framer.append(combined.suffix(from: split))

        #expect(messages == [first, second])
    }

    @Test func javaDetectorRecognizesMavenAndNestedJavaProjects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-JavaDetector-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let detector = FileSystemJavaProjectDetector()

        #expect(!detector.isJavaProject(at: root))
        try Data("<project/>".utf8).write(to: root.appendingPathComponent("pom.xml"))
        #expect(detector.isJavaProject(at: root))

        try FileManager.default.removeItem(at: root.appendingPathComponent("pom.xml"))
        let source = root.appendingPathComponent("module/src/main/java/example/App.java")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("class App {}".utf8).write(to: source)
        #expect(detector.isJavaProject(at: root))

        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        let nestedRepository = root.appendingPathComponent("nested-repository", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedRepository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("<project/>".utf8).write(to: nestedRepository.appendingPathComponent("pom.xml"))
        #expect(!detector.isJavaProject(at: root))
    }

    @Test func methodReferenceSyntaxRecognizesConstructorKeywordOnlyAfterDoubleColon() {
        let source = "Function<Foo, Bar> reference = Foo::new;\n"
        let offset = (source as NSString).range(of: "new").location
        #expect(
            JavaMethodReferenceSyntax.reference(in: source, atUTF16Offset: offset + 1)
                == JavaMethodReferenceSyntax.Reference(
                    receiver: "Foo",
                    member: "new",
                    memberRange: NSRange(location: offset, length: 3)
                )
        )
        #expect(
            JavaMethodReferenceSyntax.constructorKeywordRange(in: source, atUTF16Offset: offset + 1)
                == NSRange(location: offset, length: 3)
        )

        let ordinaryNew = "Foo value = new Foo();"
        let ordinaryOffset = (ordinaryNew as NSString).range(of: "new").location
        #expect(
            JavaMethodReferenceSyntax.constructorKeywordRange(
                in: ordinaryNew,
                atUTF16Offset: ordinaryOffset
            ) == nil
        )

        let instance = "target::getCargoOwnerName"
        let memberOffset = (instance as NSString).range(of: "getCargoOwnerName").location
        #expect(
            JavaMethodReferenceSyntax.reference(in: instance, atUTF16Offset: memberOffset)
                == JavaMethodReferenceSyntax.Reference(
                    receiver: "target",
                    member: "getCargoOwnerName",
                    memberRange: NSRange(location: memberOffset, length: 17)
                )
        )

        let qualified = "InventoryDO::getItemTitle"
        let qualifiedMemberOffset = (qualified as NSString).range(of: "getItemTitle").location
        #expect(
            JavaMethodReferenceSyntax.reference(
                in: qualified,
                atUTF16Offset: qualifiedMemberOffset + 4
            )?.receiver == "InventoryDO"
        )
        #expect(
            JavaMethodReferenceSyntax.reference(
                in: qualified,
                atUTF16Offset: qualifiedMemberOffset + 4
            )?.member == "getItemTitle"
        )
    }

    @Test func javaNavigationTargetSourceResolverIdentifiesRepositoryAndDependencyTargets() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/navigation-sources", isDirectory: true)
        let repository = RegisteredRepository(
            displayName: "common",
            relativePath: "common",
            isPinned: false
        )
        let sourceURL = workspaceURL
            .appendingPathComponent("common/src/main/java/sample/Greeter.java")
        let repositoryTarget = JavaNavigationTarget(
            fileURL: sourceURL,
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 3, character: 0),
                end: JavaSourcePosition(line: 3, character: 7)
            ),
            selectionRange: nil,
            name: "Greeter",
            detail: nil,
            containerName: nil,
            kind: .interface
        )

        let repositoryOrigin = JavaNavigationTargetSourceResolver.origin(
            for: repositoryTarget,
            workspaceURL: workspaceURL,
            repositories: [repository]
        )
        #expect(
            repositoryOrigin == .workspaceRepository(
                repositoryID: repository.id,
                repositoryName: "common",
                fileURL: sourceURL.standardizedFileURL
            )
        )

        let dependencyURI = "jdt://contents/guava-32.0.0.jar/com/google/common/collect/ImmutableList.class"
        guard let dependencyURL = URL(string: dependencyURI) else {
            Issue.record("Invalid dependency URI fixture")
            return
        }
        let dependencyTarget = JavaNavigationTarget(
            fileURL: dependencyURL,
            range: JavaSourceRange(
                start: JavaSourcePosition(line: 120, character: 8),
                end: JavaSourcePosition(line: 120, character: 20)
            ),
            selectionRange: nil,
            name: "ImmutableList",
            detail: nil,
            containerName: nil,
            kind: .interface
        )
        let dependencyOrigin = JavaNavigationTargetSourceResolver.origin(
            for: dependencyTarget,
            workspaceURL: workspaceURL,
            repositories: [repository],
            mavenLocalRepositoryURL: nil
        )
        #expect(
            dependencyOrigin == .dependency(
                JavaDependencyReference(
                    uri: dependencyURI,
                    jarName: "guava-32.0.0.jar",
                    packageName: "com.google.common.collect",
                    typeName: "ImmutableList",
                    mavenCoordinate: nil
                )
            )
        )

        let crossRepositoryWorkspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Java-CrossRepository-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: crossRepositoryWorkspaceURL) }
        let managerRepository = RegisteredRepository(
            displayName: "manager",
            relativePath: "manager",
            isPinned: false
        )
        let moduleDirectory = crossRepositoryWorkspaceURL
            .appendingPathComponent("manager/inventorymanager-client", isDirectory: true)
        let moduleSourceURL = moduleDirectory
            .appendingPathComponent(
                "src/main/java/com/internet/inventorymanager/client/service/InventoryManagerClientService.java"
            )
        try? FileManager.default.createDirectory(
            at: moduleSourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("interface InventoryManagerClientService {}".utf8).write(to: moduleSourceURL)
        try? Data("""
        <project>
          <groupId>com.internet.saasbusinessmanager</groupId>
          <artifactId>saasbusinessmanager</artifactId>
          <version>${revision}</version>
          <packaging>pom</packaging>
          <modules><module>inventorymanager-client</module></modules>
          <properties><revision>2.6.1-SNAPSHOT</revision></properties>
        </project>
        """.utf8).write(to: crossRepositoryWorkspaceURL
            .appendingPathComponent("manager/pom.xml"))
        try? Data("""
        <project>
          <parent>
            <groupId>com.internet.saasbusinessmanager</groupId>
            <artifactId>saasbusinessmanager</artifactId>
            <version>${revision}</version>
          </parent>
          <artifactId>inventorymanager-client</artifactId>
        </project>
        """.utf8).write(to: moduleDirectory.appendingPathComponent("pom.xml"))

        let workspaceDependencyURI = "jdt://contents/inventorymanager-client-2.6.1-SNAPSHOT.jar/com/internet/inventorymanager/client/service/InventoryManagerClientService.class"
        let workspaceDependencyTarget = JavaNavigationTarget(
            fileURL: URL(string: workspaceDependencyURI)!,
            range: dependencyTarget.range,
            selectionRange: nil,
            name: "InventoryManagerClientService",
            detail: nil,
            containerName: nil,
            kind: .interface
        )
        let workspaceDependencyOrigin = JavaNavigationTargetSourceResolver.origin(
            for: workspaceDependencyTarget,
            workspaceURL: crossRepositoryWorkspaceURL,
            repositories: [managerRepository]
        )
        #expect(
            workspaceDependencyOrigin == .workspaceRepository(
                repositoryID: managerRepository.id,
                repositoryName: managerRepository.name,
                fileURL: moduleSourceURL.standardizedFileURL
            )
        )
    }
}
