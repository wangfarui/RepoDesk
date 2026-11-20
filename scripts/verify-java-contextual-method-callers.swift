import Foundation
@testable import RepoDesk

@main
enum VerifyJavaContextualMethodCallers {
    static func main() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-JavaContextualCallers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceRoot = workspace.appendingPathComponent("src/main/java/example", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let handlerURL = sourceRoot.appendingPathComponent("EsGoodsItemHandler.java")
        let daoURL = sourceRoot.appendingPathComponent("EsGoodsItemDao.java")
        let callerURL = sourceRoot.appendingPathComponent("Caller.java")
        let handler = """
        package example;
        public class EsGoodsItemHandler {
            public void searchPriceVersions() {}
        }
        """
        let dao = """
        package example;
        import example.EsGoodsItemHandler;
        public class EsGoodsItemDao {
            private EsGoodsItemHandler handler;
            public void searchPriceVersions() {
                handler.searchPriceVersions();
            }
        }
        """
        let caller = """
        package example;
        public class Caller {
            private EsGoodsItemDao dao;
            public void run() {
                dao.searchPriceVersions();
            }
        }
        """
        try Data(handler.utf8).write(to: handlerURL)
        try Data(dao.utf8).write(to: daoURL)
        try Data(caller.utf8).write(to: callerURL)

        let repositories = [
            RegisteredRepository(displayName: "repo", relativePath: ".", isPinned: false)
        ]
        func request(
            action: JavaNavigationAction,
            fileURL: URL,
            text: String,
            symbol: String
        ) -> JavaNavigationRequest {
            let offset = (text as NSString).range(of: symbol).location
            let index = SourceLineIndex(text: text)
            let line = index.lineNumber(containingUTF16Offset: offset) - 1
            return JavaNavigationRequest(
                action: action,
                fileURL: fileURL,
                position: JavaSourcePosition(
                    line: line,
                    character: offset - index.lineStartOffsets[line] + 2
                ),
                documentText: text
            )
        }

        let handlerTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(
                action: .contextual,
                fileURL: handlerURL,
                text: handler,
                symbol: "searchPriceVersions()"
            ),
            workspaceURL: workspace,
            repositories: repositories
        )
        try require(
            handlerTargets.count == 1,
            "Handler declaration did not find its DAO caller: \(handlerTargets)"
        )
        try require(
            handlerTargets[0].fileURL == daoURL.standardizedFileURL
                && handlerTargets[0].range.start.line == 5,
            "Handler declaration resolved to the wrong caller: \(handlerTargets)"
        )

        let daoTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(
                action: .contextual,
                fileURL: daoURL,
                text: dao,
                symbol: "searchPriceVersions()"
            ),
            workspaceURL: workspace,
            repositories: repositories
        )
        try require(
            daoTargets.count == 1,
            "DAO declaration did not find its caller: \(daoTargets)"
        )
        try require(
            daoTargets[0].fileURL == callerURL.standardizedFileURL
                && daoTargets[0].range.start.line == 4,
            "DAO declaration incorrectly jumped to the handler implementation: \(daoTargets)"
        )

        // Same method name on a different type/package, and comments or strings,
        // must not contribute callers. A return statement is not a variable type.
        let unrelated = """
        package other;
        import other.EsGoodsItemHandler;
        class OtherCaller {
            private EsGoodsItemHandler handler;
            void unrelated() { handler.searchPriceVersions(); }
        }
        """
        try Data(unrelated.utf8).write(to: sourceRoot.appendingPathComponent("OtherCaller.java"))
        let recursiveHandler = handler.replacingOccurrences(
            of: "public void searchPriceVersions() {}",
            with: """
            public void searchPriceVersions() { this.searchPriceVersions(); }
                void localCaller() { searchPriceVersions(); }
                // handler.searchPriceVersions();
                String label = "handler.searchPriceVersions()";
            """
        )
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: workspace)
        let recursiveTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(action: .contextual, fileURL: handlerURL, text: recursiveHandler,
                         symbol: "searchPriceVersions()"),
            workspaceURL: workspace, repositories: repositories
        )
        try require(recursiveTargets.count == 3,
                    "Recursive/local/DAO calls were confused with other types or comments: \(recursiveTargets)")
        try require(Set(recursiveTargets.map(\.name)) == ["searchPriceVersions", "localCaller"],
                    "Callers must retain their enclosing method names: \(recursiveTargets)")

        try Data(dao.replacingOccurrences(of: "handler.searchPriceVersions();",
                                         with: "return handler.searchPriceVersions();").utf8).write(to: daoURL)
        let returnTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(action: .contextual, fileURL: handlerURL, text: handler,
                         symbol: "searchPriceVersions()"),
            workspaceURL: workspace, repositories: repositories
        )
        try require(returnTargets.count == 1 && returnTargets[0].fileURL == daoURL.standardizedFileURL,
                    "Return statement hid the receiver type: \(returnTargets)")

        let overloadedHandler = handler.replacingOccurrences(
            of: "public void searchPriceVersions() {}",
            with: "public void searchPriceVersions() {}\n    public void searchPriceVersions(int value) {}"
        )
        let overloadTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(action: .contextual, fileURL: handlerURL, text: overloadedHandler,
                         symbol: "searchPriceVersions()"),
            workspaceURL: workspace, repositories: repositories
        )
        try require(overloadTargets.isEmpty, "Unresolved overloads must not produce guessed callers")

        try FileManager.default.removeItem(at: callerURL)
        let unusedDaoTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(action: .contextual, fileURL: daoURL, text: dao,
                         symbol: "searchPriceVersions()"),
            workspaceURL: workspace, repositories: repositories
        )
        try require(unusedDaoTargets.isEmpty,
                    "Unused DAO declaration must not fall through to the Handler definition")

        // The prewarmed candidate index must refresh for newly introduced method
        // names after file changes; nested repositories must stay out of scope.
        let changedDao = dao.replacingOccurrences(of: "searchPriceVersions", with: "queryVersions")
        try Data(changedDao.utf8).write(to: daoURL)
        try Data(caller.replacingOccurrences(of: "searchPriceVersions", with: "queryVersions").utf8).write(to: callerURL)
        let nested = workspace.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data(caller.replacingOccurrences(of: "searchPriceVersions", with: "queryVersions").utf8)
            .write(to: nested.appendingPathComponent("Caller.java"))
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: workspace)
        await JavaWorkspaceNavigationFallback.prepareMethodCallers(
            fileURL: daoURL, workspaceURL: workspace, repositories: repositories
        )
        let changedTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(action: .contextual, fileURL: daoURL, text: changedDao, symbol: "queryVersions()"),
            workspaceURL: workspace, repositories: repositories
        )
        try require(changedTargets.count == 1 && changedTargets[0].fileURL == callerURL.standardizedFileURL,
                    "Invalidated caller index missed a new method name or leaked a nested repository: \(changedTargets)")

        // Patch new/deleted files without rebuilding the repository. Exact
        // notifications must observe the same boundaries as the original scan.
        let movedCaller = sourceRoot.appendingPathComponent("MovedCaller.java")
        try FileManager.default.moveItem(at: callerURL, to: movedCaller)
        let ignoredCaller = workspace.appendingPathComponent("target/Generated.java")
        try FileManager.default.createDirectory(at: ignoredCaller.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(caller.replacingOccurrences(of: "searchPriceVersions", with: "queryVersions").utf8).write(to: ignoredCaller)
        await JavaWorkspaceNavigationFallback.invalidate(
            workspaceURL: workspace, changedFileURLs: [callerURL, movedCaller, ignoredCaller, nested.appendingPathComponent("Caller.java")]
        )
        let movedTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(action: .contextual, fileURL: daoURL, text: changedDao, symbol: "queryVersions()"),
            workspaceURL: workspace, repositories: repositories
        )
        try require(movedTargets.count == 1 && movedTargets[0].fileURL == movedCaller,
                    "Incremental caller update missed a rename or indexed excluded files: \(movedTargets)")

        // Two saves arriving while the first update is pending must both land.
        let extraCaller = sourceRoot.appendingPathComponent("ExtraCaller.java")
        let extraText = caller.replacingOccurrences(of: "searchPriceVersions", with: "queryVersions")
            .replacingOccurrences(of: "queryVersions();", with: "queryVersions \t\r\n ();")
        try Data(extraText.utf8).write(to: extraCaller)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: workspace, changedFileURLs: [extraCaller])
        try FileManager.default.removeItem(at: movedCaller)
        await JavaWorkspaceNavigationFallback.invalidate(workspaceURL: workspace, changedFileURLs: [movedCaller])
        let latestTargets = await JavaWorkspaceNavigationFallback.targets(
            for: request(action: .contextual, fileURL: daoURL, text: changedDao, symbol: "queryVersions()"),
            workspaceURL: workspace, repositories: repositories
        )
        try require(latestTargets.count == 1 && latestTargets[0].fileURL == extraCaller,
                    "Successive file changes lost an incremental update: \(latestTargets)")

        print("Contextual Java method caller navigation passed")
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationError(message: message) }
}

private struct VerificationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
