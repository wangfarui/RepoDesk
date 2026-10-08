import Foundation
@testable import RepoDesk

@main
enum VerifyJavaCrossRepositoryFieldNavigation {
    static func main() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDesk-JavaFieldNavigation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let consumer = workspace.appendingPathComponent("consumer/src/main/java/example/Consumer.java")
        let provider = workspace.appendingPathComponent("provider/src/main/java/example/InventoryExtFieldKeys.java")
        try FileManager.default.createDirectory(at: consumer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: provider.deletingLastPathComponent(), withIntermediateDirectories: true)
        let usage = """
        package example;
        import example.InventoryExtFieldKeys;
        class Consumer {
            String value = InventoryExtFieldKeys.INVENTORY_EXT_FIELD_1_CONFIG;
        }
        """
        let declaration = """
        package example;
        public final class InventoryExtFieldKeys {
            public static final String INVENTORY_EXT_FIELD_1_CONFIG = "inventoryExtField1Config";
        }
        """
        try Data(usage.utf8).write(to: consumer)
        try Data(declaration.utf8).write(to: provider)

        let offset = (usage as NSString).range(of: "INVENTORY_EXT_FIELD_1_CONFIG").location
        let lines = SourceLineIndex(text: usage)
        let line = lines.lineNumber(containingUTF16Offset: offset) - 1
        let position = JavaSourcePosition(line: line, character: offset - lines.lineStartOffsets[line] + 5)
        let repositories = [
            RegisteredRepository(displayName: "consumer", relativePath: "consumer", isPinned: false),
            RegisteredRepository(displayName: "provider", relativePath: "provider", isPinned: false)
        ]

        for action in [JavaNavigationAction.contextual, .declaration] {
            let targets = await JavaWorkspaceNavigationFallback.targets(
                for: JavaNavigationRequest(
                    action: action,
                    fileURL: consumer,
                    position: position,
                    documentText: usage
                ),
                workspaceURL: workspace,
                repositories: repositories
            )
            guard targets.count == 1,
                  targets[0].fileURL == provider.standardizedFileURL,
                  targets[0].name == "INVENTORY_EXT_FIELD_1_CONFIG",
                  targets[0].range.start.line == 2,
                  targets[0].kind == .field else {
                throw NavigationFailure(targets: targets)
            }
        }
        print("Cross-repository Java field navigation passed")
    }
}

private struct NavigationFailure: Error, CustomStringConvertible {
    let targets: [JavaNavigationTarget]
    var description: String {
        "Cross-repository field definition was not found: \(targets)"
    }
}
