import Foundation
@testable import RepoDesk

private struct MapperVerificationError: Error, CustomStringConvertible {
    let description: String
}

private actor MapperLanguageProvider: JavaLanguageProviding {
    nonisolated let events = AsyncStream<JavaLanguageProviderEvent> { $0.finish() }
    private(set) var implementationRequests = 0
    let target: JavaNavigationTarget

    init(target: JavaNavigationTarget) { self.target = target }
    func configure(_ settings: JavaIndexSettings) async {}
    func updateWorkspace(
        workspaceURL: URL?, repositories: [RegisteredRepository],
        projectJavaHome: String?, mavenUserSettingsFile: String?, mavenLocalRepositoryURL: URL?
    ) async {}
    func prioritize(repositoryID: RegisteredRepository.ID) async {}
    func navigationTargets(
        repositoryID: RegisteredRepository.ID, request: JavaNavigationRequest
    ) async -> [JavaNavigationTarget] {
        implementationRequests += 1
        return [target]
    }
    func searchSymbols(_ request: JavaSymbolSearchRequest) async -> [JavaNavigationTarget] { [] }
    func semanticTokens(
        repositoryID: RegisteredRepository.ID, fileURL: URL, text: String
    ) async -> [JavaSemanticToken] { [] }
    func notifyFilesChanged(_ fileURLs: [URL]) async {}
    func setBackgroundIndexingPaused(_ paused: Bool) async {}
    func rebuildIndex(repositoryID: RegisteredRepository.ID) async {}
    func clearUnusedCaches() async {}
    func shutdown() async {}
}

@MainActor
private final class MapperWindowStore: WindowStateStoring {
    func state(for workspaceURL: URL) -> WorkspaceWindowState { .initial }
    func save(_ state: WorkspaceWindowState, for workspaceURL: URL) {}
}

@main
@MainActor
enum VerifyMyBatisNavigation {
    private static let java = """
    // interface WrongMapper { String wrong(); }
    package example.inventory;
    import java.util.List;
    public interface GoodsMapper {
        // List<GoodsDO> commented();
        List<GoodsDO> query(@Param("id") Long id);
        int insert(GoodsDO goods);
        int update(GoodsDO goods);
        int delete(Long id);
        java.util.List<GoodsDO>
            multiline(Long id);
        String missing();
        default void caller() { query(1L); }
    }
    """

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-MyBatis-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let javaURL = root.appendingPathComponent("src/main/java/example/inventory/GoodsMapper.java")
        let xmlURL = root.appendingPathComponent("module/src/main/resources/sql/ArbitraryName.xml")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN" "http://mybatis.org/dtd/mybatis-3-mapper.dtd">
        <!-- 中文😀 <mapper namespace="example.inventory.GoodsMapper"><select id="query"/></mapper> -->
        <mapper
            namespace = 'example.inventory.GoodsMapper'>
            <!-- <select id="query"/> -->
            <sql id="query">select 0</sql>
            <resultMap id="query" type="GoodsDO"/>
            <selectKey id="query">select 0</selectKey>
            <select data-id="query" note="id='query'">select 0</select>
            <select note="a > b" resultType="GoodsDO"
                id = "query">select * from goods</select>
            <insert id='insert'>insert into goods values(1)</insert>
            <update id="update">update goods set id=1</update>
            <delete id='delete'>delete from goods</delete>
            <select id="multiline"><![CDATA[ <select id="query"/> ]]></select>
        </mapper>
        """
        try write(java, to: javaURL)
        try write(xml, to: xmlURL)
        let repositories = [RegisteredRepository(displayName: "inventory", relativePath: ".", isPinned: false)]
        func request(_ name: String, action: JavaNavigationAction = .implementation) -> JavaNavigationRequest {
            JavaNavigationRequest(
                action: action, fileURL: javaURL,
                position: position(of: name + "(", in: java), documentText: java
            )
        }
        func targets(_ name: String) -> [JavaNavigationTarget] {
            MyBatisMapperNavigationResolver.targets(
                for: request(name), workspaceURL: root, repositories: repositories
            )
        }
        for (name, tag) in [("query", "select"), ("insert", "insert"), ("update", "update"), ("delete", "delete"), ("multiline", "select")] {
            let matches = targets(name)
            try require(matches.count == 1, "\(name): expected one SQL statement, found \(matches.count)")
            try require(matches[0].fileURL == xmlURL, "XML filename must not affect namespace matching")
            try require(matches[0].detail == "MyBatis <\(tag)>", "Incorrect statement type")
        }
        let queryTarget = targets("query")[0]
        let idAttributePosition = position(of: "id = \"query\">", in: xml)
        let expectedPosition = JavaSourcePosition(
            line: idAttributePosition.line, character: idAttributePosition.character + 6
        )
        try require(queryTarget.selectionRange?.start == expectedPosition, "XML id selection did not preserve UTF-16 location")
        try require(targets("missing").isEmpty, "A missing statement must return no XML targets")
        try require(MyBatisMapperNavigationResolver.targets(
            for: request("query", action: .declaration), workspaceURL: root, repositories: repositories
        ).isEmpty, "Declaration navigation must keep its Java behavior")

        // Wrong namespaces, build outputs, sibling repositories and nested Git repositories must not produce duplicates.
        try write(xml.replacingOccurrences(of: "example.inventory.GoodsMapper", with: "other.GoodsMapper"),
                  to: root.appendingPathComponent("src/main/resources/Wrong.xml"))
        try write(xml, to: root.appendingPathComponent("target/classes/Duplicate.xml"))
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try write(xml, to: nested.appendingPathComponent("Duplicate.xml"))
        MyBatisMapperNavigationResolver.invalidate(workspaceURL: root)
        try require(targets("query").count == 1, "Build outputs or nested repositories leaked into Mapper navigation")

        // File events must refresh cached positive and negative results, even
        // when names are arbitrary and the new file is in another module.
        let addedXML = root.appendingPathComponent("other-module/resources/Added.xml")
        try write("<mapper namespace='example.inventory.GoodsMapper'><select id='missing'/></mapper>", to: addedXML)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: root, changedFileURLs: [addedXML])
        try require(targets("missing").count == 1, "Cached missing SQL ignored a newly added XML file")
        try write("<mapper namespace='other.GoodsMapper'><select id='missing'/></mapper>", to: addedXML)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: root, changedFileURLs: [addedXML])
        try require(targets("missing").isEmpty, "Namespace edit retained a stale SQL target")
        try FileManager.default.removeItem(at: addedXML)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: root, changedFileURLs: [addedXML])
        try require(targets("missing").isEmpty, "Deleted XML retained a cached target")

        let renamedXML = xmlURL.deletingLastPathComponent().appendingPathComponent("Renamed.xml")
        try FileManager.default.moveItem(at: xmlURL, to: renamedXML)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: root, changedFileURLs: [xmlURL, renamedXML])
        try require(targets("query").first?.fileURL == renamedXML, "XML rename did not update its target path")
        try FileManager.default.moveItem(at: renamedXML, to: xmlURL)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: root, changedFileURLs: [renamedXML, xmlURL])

        let classText = java.replacingOccurrences(of: "interface GoodsMapper", with: "class GoodsMapper")
        let classRequest = JavaNavigationRequest(
            action: .implementation, fileURL: javaURL,
            position: position(of: "query(", in: classText), documentText: classText
        )
        try require(MyBatisMapperNavigationResolver.targets(
            for: classRequest, workspaceURL: root, repositories: repositories
        ).isEmpty, "A Java class must not be treated as a Mapper interface")
        let callRequest = JavaNavigationRequest(
            action: .implementation, fileURL: javaURL,
            position: position(of: "query(1L)", in: java), documentText: java
        )
        try require(MyBatisMapperNavigationResolver.targets(
            for: callRequest, workspaceURL: root, repositories: repositories
        ).isEmpty, "A call in a default method must not be treated as a declaration")

        let javaImplementationURL = root.appendingPathComponent("src/main/java/example/inventory/GoodsImpl.java")
        try write("class GoodsImpl {}", to: javaImplementationURL)
        let zero = JavaSourcePosition(line: 0, character: 0)
        let provider = MapperLanguageProvider(target: JavaNavigationTarget(
            fileURL: javaImplementationURL, range: JavaSourceRange(start: zero, end: zero),
            selectionRange: nil, name: "query", detail: nil, containerName: nil, kind: .method
        ))
        let state = AppState(
            workspace: WorkspaceSummary(url: root), repositories: repositories,
            selectedRepositoryID: ".", selectedSection: .files,
            windowStateStore: MapperWindowStore(), javaLanguageProvider: provider,
            restoresWorkspaceOnLaunch: false
        )
        state.selectFile(javaURL)
        try await waitUntil { !state.isLoadingDocument }
        let queryRequest = request("query")
        state.performJavaNavigation(
            action: .implementation, fileURL: javaURL,
            position: queryRequest.position, documentText: java
        )
        try await waitUntil { state.selectedFileURL == xmlURL }
        let callsAfterXML = await provider.implementationRequests
        try require(callsAfterXML == 0, "XML must take priority over an available Java implementation")
        try require(state.selectedSourceNavigationRequest?.range == queryTarget.selectionRange, "AppState lost XML selection")
        try require(state.navigateFileBack() && state.selectedFileURL == javaURL, "Back did not return to Mapper")
        try require(state.selectedSourceNavigationRequest?.range?.start == queryRequest.position, "Back lost the original caret")
        try require(state.navigateFileForward() && state.selectedFileURL == xmlURL, "Forward did not return to XML")

        let duplicateURL = root.appendingPathComponent("src/main/resources/Second.xml")
        try write(xml, to: duplicateURL)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: root, changedFileURLs: [duplicateURL])
        state.selectFile(javaURL)
        state.performJavaNavigation(
            action: .implementation, fileURL: javaURL,
            position: queryRequest.position, documentText: java
        )
        try await waitUntil { state.javaNavigationResultPresentation != nil }
        try require(state.javaNavigationResultPresentation?.targets.count == 2, "Multiple SQL matches must offer a choice")
        state.javaNavigationResultPresentation = nil
        try FileManager.default.removeItem(at: duplicateURL)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: root, changedFileURLs: [duplicateURL])

        let missing = request("missing")
        state.performJavaNavigation(
            action: .implementation, fileURL: javaURL,
            position: missing.position, documentText: java
        )
        try await waitUntil { state.selectedFileURL == javaImplementationURL }
        let callsAfterFallback = await provider.implementationRequests
        try require(callsAfterFallback == 1, "Missing XML did not fall back to Java LSP")
        print("MyBatis navigation verification passed (CRUD, namespace/id, UTF-16 position, comments/CDATA, Java priority/fallback, multiple results, back/forward)")
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func position(of value: String, in text: String) -> JavaSourcePosition {
        let offset = (text as NSString).range(of: value).location
        let index = SourceLineIndex(text: text)
        let line = max(0, index.lineNumber(containingUTF16Offset: offset) - 1)
        return JavaSourcePosition(line: line, character: offset - index.lineStartOffsets[line])
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            try require(ContinuousClock.now < deadline, "Timed out waiting for navigation")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw MapperVerificationError(description: message) }
    }
}
