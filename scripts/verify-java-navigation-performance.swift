import Foundation
@testable import RepoDesk

private struct NavigationPerformanceError: Error, CustomStringConvertible {
    let description: String
}

@main
enum VerifyJavaNavigationPerformance {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-Navigation-Performance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("src/main/java/example")
        let resources = root.appendingPathComponent("src/main/resources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let handler = sources.appendingPathComponent("Handler.java")
        let caller = sources.appendingPathComponent("Caller.java")
        let handlerText = "package example; public class Handler { public void query() {} }"
        let callerText = "package example; class Caller { Handler handler; void run() { handler.query(); } }"
        try handlerText.write(to: handler, atomically: true, encoding: .utf8)
        try callerText.write(to: caller, atomically: true, encoding: .utf8)
        for index in 0..<1500 {
            let methods = (0..<80).map { "void method\($0)() { service.call\($0)(); }" }.joined(separator: "\n")
            try "package example; class Noise\(index) { \(methods) }".write(
                to: sources.appendingPathComponent("Noise\(index).java"), atomically: false, encoding: .utf8
            )
        }
        for index in 0..<300 {
            try "<mapper namespace=\"example.Noise\(index)\"><select id=\"query\">select 1</select></mapper>".write(
                to: resources.appendingPathComponent("Noise\(index).xml"), atomically: false, encoding: .utf8
            )
        }
        let mapper = sources.appendingPathComponent("GoodsMapper.java")
        let mapperText = "package example; public interface GoodsMapper { String query(); }"
        let xml = resources.appendingPathComponent("arbitrary.xml")
        let xmlText = "<mapper namespace=\"example.GoodsMapper\"><select id=\"query\">select 1</select></mapper>"
        try mapperText.write(to: mapper, atomically: true, encoding: .utf8)
        try xmlText.write(to: xml, atomically: true, encoding: .utf8)
        let repositories = [RegisteredRepository(displayName: "fixture", relativePath: ".", isPinned: false)]
        func request(_ action: JavaNavigationAction, file: URL, text: String) -> JavaNavigationRequest {
            let offset = (text as NSString).range(of: "query()").location + 2
            return JavaNavigationRequest(action: action, fileURL: file,
                                         position: JavaSourcePosition(line: 0, character: offset), documentText: text)
        }
        let callersRequest = request(.contextual, file: handler, text: handlerText)
        let coldStart = ContinuousClock.now
        let cold = await JavaWorkspaceNavigationFallback.targets(
            for: callersRequest, workspaceURL: root, repositories: repositories
        )
        try require(cold.count == 1 && cold[0].fileURL == caller, "Cold navigation lost its caller")
        let coldTime = coldStart.duration(to: .now)
        print("Caller cold index: \(coldTime)")
        try require(coldTime < .seconds(2), "Cold caller index exceeded its two-second budget: \(coldTime)")

        // An ordinary Java save must update the existing index rather than read
        // all the unrelated files again. New and deleted callers must be visible.
        let newCaller = sources.appendingPathComponent("NewCaller.java")
        try callerText.replacingOccurrences(of: "class Caller", with: "class NewCaller")
            .write(to: newCaller, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: caller)
        let updateStart = ContinuousClock.now
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: root, changedFileURLs: [caller, newCaller])
        let updated = await JavaWorkspaceNavigationFallback.targets(
            for: callersRequest, workspaceURL: root, repositories: repositories
        )
        let updateTime = updateStart.duration(to: .now)
        try require(updated.count == 1 && updated[0].fileURL == newCaller, "Incremental navigation retained a deleted caller or missed a new one")
        print("Caller after Java save: \(updateTime)")
        try require(updateTime < .milliseconds(350), "Java save rebuilt unrelated caller files: \(updateTime)")

        let mapperRequest = request(.implementation, file: mapper, text: mapperText)
        let firstXML = MyBatisMapperNavigationResolver.targets(
            for: mapperRequest, workspaceURL: root, repositories: repositories
        )
        try require(firstXML.count == 1 && firstXML[0].fileURL == xml, "Mapper implementation was not found")
        let warmStart = ContinuousClock.now
        for _ in 0..<5 {
            let targets = MyBatisMapperNavigationResolver.targets(
                for: mapperRequest, workspaceURL: root, repositories: repositories
            )
            try require(targets.count == 1, "Warm XML navigation lost its implementation")
        }
        let warmTime = warmStart.duration(to: .now)
        print("Five warm Mapper lookups: \(warmTime)")
        try require(warmTime < .milliseconds(100), "Warm Mapper navigation rescanned repository XML: \(warmTime)")
        print("Java navigation performance verification passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NavigationPerformanceError(description: message) }
    }
}
