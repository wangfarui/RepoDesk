import Foundation
@testable import RepoDesk

private struct JDTVerificationError: Error, CustomStringConvertible {
    let description: String
}

@main
enum VerifyJDTLanguageServer {
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RepoDesk-JDT-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = fileManager.temporaryDirectory
            .appendingPathComponent("RepoDesk-JDT-Data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: dataRoot)
        }
        let ownModule = root.appendingPathComponent("own-module", isDirectory: true)
        let sourceRoot = ownModule.appendingPathComponent("src/main/java/sample", isDirectory: true)
        let nestedRepository = root.appendingPathComponent("nested-repository", isDirectory: true)
        let nestedSourceRoot = nestedRepository.appendingPathComponent(
            "src/main/java/nested",
            isDirectory: true
        )
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: nestedRepository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: nestedSourceRoot, withIntermediateDirectories: true)

        let pom = """
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion>
          <groupId>sample</groupId>
          <artifactId>navigation-fixture</artifactId>
          <version>1.0.0</version>
          <properties>
            <maven.compiler.release>17</maven.compiler.release>
            <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
          </properties>
        </project>
        """
        let greeter = """
        package sample;

        public interface Greeter {
            String greet(String name);

            default String unused(String name) {
                return name;
            }
        }
        """
        let baseGreeter = """
        package sample;

        public abstract class BaseGreeter implements Greeter {
            protected String normalize(String value) {
                return value.trim();
            }
        }
        """
        let friendlyGreeter = """
        package sample;

        public final class FriendlyGreeter extends BaseGreeter {
            @Override
            public String greet(String name) {
                return "Hello " + normalize(name);
            }

            public String greet(int count) {
                return "Count " + count;
            }

            @Override
            public String unused(String name) {
                return name;
            }

            @Deprecated
            public FriendlyGreeter
            asFriendly(
                Greeter candidate
            ) {
                return this;
            }
        }
        """
        let formalGreeter = """
        package sample;

        public final class FormalGreeter implements Greeter {
            @Override
            public String greet(String name) {
                return "Good day " + name;
            }
        }
        """
        let processingOrderNotifyState = """
        package sample;

        public enum ProcessingOrderNotifyState {
            INIT,
            WAITING,
            FINISHED,
            DELETE
        }
        """
        let enumUsage = """
        package sample;

        public final class EnumUsage {
            private ProcessingOrderNotifyState state = ProcessingOrderNotifyState.INIT;

            public void waitForOrder() {
                state = ProcessingOrderNotifyState.WAITING;
            }

            public boolean isFinished() {
                return state == ProcessingOrderNotifyState.FINISHED;
            }
        }
        """
        let caller = """
        package sample;

        public final class Caller {
            private final Greeter greeter = new FriendlyGreeter();
            private final FriendlyGreeter friendly = new FriendlyGreeter();

            public String callOnce(String name) {
                return greeter.greet(name);
            }

            public String callTwice(String name) {
                return greeter.greet(name) + greeter.greet(name);
            }

            public String callFriendly(String name) {
                return friendly.greet(name);
            }

            public String callNumber() {
                return friendly.greet(7);
            }
        }
        """
        let methodReferenceTarget = """
        package sample;

        public final class MethodReferenceTarget {
            public static String staticName(String value) {
                return value;
            }

            public String instanceName(String value) {
                return value;
            }

            public static final class Constructed {
                public Constructed(String value) {}
            }
        }
        """
        let methodReferenceCaller = """
        package sample;

        import java.util.function.Function;

        public final class MethodReferenceCaller {
            private final MethodReferenceTarget target = new MethodReferenceTarget();

            public void use() {
                Function<String, String> staticReference = MethodReferenceTarget::staticName;
                Function<String, String> instanceReference = target::instanceName;
                Function<String, MethodReferenceTarget.Constructed> constructorReference = MethodReferenceTarget.Constructed::new;
            }
        }
        """
        let methodReferenceField = """
        package sample;

        import java.util.function.Function;

        public final class MethodReferenceField {
            private static final Function<String, String> REFERENCE = MethodReferenceTarget::staticName;
        }
        """
        let inventoryDO = """
        package sample;

        public final class InventoryDO {
            public String getItemTitle() {
                return "title";
            }
        }
        """
        let inventoryKey = """
        package sample;

        import java.util.function.Function;

        public enum InventoryKey {
            ITEM_TITLE(InventoryDO::getItemTitle);

            private final Function<InventoryDO, String> extractor;

            InventoryKey(Function<InventoryDO, String> extractor) {
                this.extractor = extractor;
            }
        }
        """
        let generatedInventoryDO = """
        package sample;

        public final class GeneratedInventoryDO {
            // Simulates a getter generated by Lombok @Data.
            private String itemTitle;
        }
        """
        let customValue = """
        package sample;

        public final class CustomValue {}
        """
        let generatedInventoryKey = """
        package sample;

        import java.util.function.Function;

        public enum GeneratedInventoryKey {
            ITEM_TITLE(GeneratedInventoryDO::getItemTitle, CustomValue.class);

            GeneratedInventoryKey(
                Function<GeneratedInventoryDO, String> extractor,
                Class<?> valueType
            ) {}
        }
        """
        let priceHandler = """
        package sample;
        import java.util.Map;
        public class PriceHandler {
            public Map<String, Long> searchPriceVersions(Object request) { return null; }
        }
        """
        let priceDao = """
        package sample;
        import java.util.Map;
        public class PriceDao {
            private PriceHandler handler;
            public Map<String, Long> searchPriceVersions(Object request) {
                return handler.searchPriceVersions(request);
            }
        }
        """
        let priceManager = """
        package sample;
        import java.util.Map;
        public class PriceManager {
            private PriceDao dao;
            public Map<String, Long> searchByPriceId(Object request) {
                return dao.searchPriceVersions(request);
            }
        }
        """
        let files: [(String, String)] = [
            ("PriceHandler.java", priceHandler),
            ("PriceDao.java", priceDao),
            ("PriceManager.java", priceManager),
            ("Greeter.java", greeter),
            ("BaseGreeter.java", baseGreeter),
            ("FriendlyGreeter.java", friendlyGreeter),
            ("FormalGreeter.java", formalGreeter),
            ("ProcessingOrderNotifyState.java", processingOrderNotifyState),
            ("EnumUsage.java", enumUsage),
            ("Caller.java", caller),
            ("MethodReferenceTarget.java", methodReferenceTarget),
            ("MethodReferenceCaller.java", methodReferenceCaller),
            ("MethodReferenceField.java", methodReferenceField),
            ("InventoryDO.java", inventoryDO),
            ("InventoryKey.java", inventoryKey),
            ("GeneratedInventoryDO.java", generatedInventoryDO),
            ("CustomValue.java", customValue),
            ("GeneratedInventoryKey.java", generatedInventoryKey)
        ]
        try Data(pom.utf8).write(to: ownModule.appendingPathComponent("pom.xml"))
        try Data(pom.replacingOccurrences(
            of: "navigation-fixture",
            with: "nested-navigation-fixture"
        ).utf8).write(to: nestedRepository.appendingPathComponent("pom.xml"))
        try Data("package nested; public final class NestedOnly {}".utf8).write(
            to: nestedSourceRoot.appendingPathComponent("NestedOnly.java")
        )
        for (name, contents) in files {
            try Data(contents.utf8).write(to: sourceRoot.appendingPathComponent(name))
        }

        let session = JDTLanguageServerSession()
        let eventTask = Task<Void, Never> {
            for await _ in session.events {}
        }
        defer { eventTask.cancel() }
        let repository = RegisteredRepository(
            displayName: "navigation-fixture",
            relativePath: ".",
            isPinned: false
        )
        let descriptor = JavaRepositoryDescriptor(
            repositoryID: repository.id,
            displayName: repository.name,
            repositoryURL: root,
            isJavaProject: true,
            nestedRepositoryURLs: [nestedRepository]
        )
        do {
            try await session.start(
                configuration: JavaLanguageServerConfiguration(
                    repository: descriptor,
                    dataDirectoryURL: dataRoot,
                    settings: .default,
                    projectJavaHome: nil,
                    mavenUserSettingsFile: nil,
                    mavenLocalRepositoryURL: dataRoot.appendingPathComponent("maven & artifacts")
                )
            )
            try await session.waitUntilReady(timeout: .seconds(120))
            let generatedSettings = try String(
                contentsOf: dataRoot.appendingPathComponent(".repodesk-maven-global-settings.xml"),
                encoding: .utf8
            )
            guard generatedSettings.contains("maven &amp; artifacts") else {
                throw JDTVerificationError(description: "The configured Maven repository was not XML-escaped")
            }
            try verifyNoProjectMetadata(in: root)

            // Query declarations before opening or navigating from any caller.
            for (file, text, expectedFile, expectedText, expectedSymbol) in [
                ("PriceHandler.java", priceHandler, "PriceDao.java", priceDao,
                 "handler.searchPriceVersions(request)"),
                ("PriceDao.java", priceDao, "PriceManager.java", priceManager,
                 "dao.searchPriceVersions(request)")
            ] {
                let result = try await targets(
                    session: session, action: .contextual,
                    fileURL: sourceRoot.appendingPathComponent(file), text: text,
                    symbol: "searchPriceVersions(Object"
                )
                let callPosition = try position(text: expectedText, symbol: expectedSymbol,
                                                symbolOffset: expectedSymbol.range(of: ".")!.upperBound
                                                    .utf16Offset(in: expectedSymbol))
                try require(result.count == 1 && result.contains {
                    target($0, in: sourceRoot.appendingPathComponent(expectedFile), contains: callPosition)
                }, "Cold declaration click on \(file) did not find its actual caller: \(result)")
            }
            try await Task.sleep(for: .milliseconds(500))

            let nestedSymbols = try await session.searchSymbols(query: "NestedOnly", scope: .types)
            try require(
                nestedSymbols.isEmpty,
                "Parent repository indexed a Java type from a nested Git repository: \(nestedSymbols)"
            )

            let greeterURL = sourceRoot.appendingPathComponent("Greeter.java")
            let friendlyURL = sourceRoot.appendingPathComponent("FriendlyGreeter.java")
            let callerURL = sourceRoot.appendingPathComponent("Caller.java")
            let methodReferenceTargetURL = sourceRoot.appendingPathComponent("MethodReferenceTarget.java")
            let methodReferenceCallerURL = sourceRoot.appendingPathComponent("MethodReferenceCaller.java")
            let methodReferenceFieldURL = sourceRoot.appendingPathComponent("MethodReferenceField.java")
            let inventoryDOURL = sourceRoot.appendingPathComponent("InventoryDO.java")
            let inventoryKeyURL = sourceRoot.appendingPathComponent("InventoryKey.java")
            let generatedInventoryDOURL = sourceRoot.appendingPathComponent("GeneratedInventoryDO.java")
            let customValueURL = sourceRoot.appendingPathComponent("CustomValue.java")
            let generatedInventoryKeyURL = sourceRoot.appendingPathComponent("GeneratedInventoryKey.java")
            let enumURL = sourceRoot.appendingPathComponent("ProcessingOrderNotifyState.java")

            let enumUsages = try await targets(
                session: session,
                action: .contextual,
                fileURL: enumURL,
                text: processingOrderNotifyState,
                symbol: "ProcessingOrderNotifyState"
            )
            try require(
                enumUsages.contains { $0.fileURL.lastPathComponent == "EnumUsage.java" },
                "Command-click enum did not return usages: \(enumUsages)"
            )
            try require(
                !enumUsages.isEmpty && enumUsages.allSatisfy { $0.kind == .enum },
                "Enum usages were not marked as enum navigation targets"
            )

            let declaration = try await targets(
                session: session,
                action: .declaration,
                fileURL: callerURL,
                text: caller,
                symbol: "Greeter greeter"
            )
            try require(declaration.contains { $0.fileURL.lastPathComponent == "Greeter.java" }, "Command+B declaration failed")

            let typeImplementations = try await targets(
                session: session,
                action: .implementation,
                fileURL: greeterURL,
                text: greeter,
                symbol: "Greeter"
            )
            try require(
                Set(typeImplementations.map { $0.fileURL.lastPathComponent }).isSuperset(of: ["FriendlyGreeter.java", "FormalGreeter.java"]),
                "Interface implementation navigation failed"
            )

            let methodImplementations = try await targets(
                session: session,
                action: .implementation,
                fileURL: greeterURL,
                text: greeter,
                symbol: "greet"
            )
            try require(methodImplementations.count >= 2, "Method implementation navigation failed")

            let incoming = try await targets(
                session: session,
                action: .incomingCalls,
                fileURL: greeterURL,
                text: greeter,
                symbol: "greet"
            )
            try require(
                incoming.contains { $0.name.hasPrefix("callOnce") },
                "Single incoming caller was not found: \(incoming.map(\.name))"
            )
            try require(
                incoming.contains { $0.name.hasPrefix("callTwice") },
                "Multiple incoming caller was not found: \(incoming.map(\.name))"
            )

            let classReferences = try await targets(
                session: session,
                action: .references,
                fileURL: friendlyURL,
                text: friendlyGreeter,
                symbol: "FriendlyGreeter"
            )
            try require(classReferences.contains { $0.fileURL.lastPathComponent == "Caller.java" }, "Class usage navigation failed")

            let superMethod = try await targets(
                session: session,
                action: .superDeclaration,
                fileURL: friendlyURL,
                text: friendlyGreeter,
                symbol: "greet"
            )
            try require(superMethod.contains { $0.fileURL.lastPathComponent == "Greeter.java" }, "Super method navigation failed")

            let superType = try await targets(
                session: session,
                action: .superDeclaration,
                fileURL: friendlyURL,
                text: friendlyGreeter,
                symbol: "FriendlyGreeter"
            )
            try require(superType.contains { $0.fileURL.lastPathComponent == "BaseGreeter.java" }, "Super type navigation failed")

            let typeSymbols = try await session.searchSymbols(query: "FrGr", scope: .types)
            try require(typeSymbols.contains { $0.name == "FriendlyGreeter" }, "Camel-hump type search failed")
            let methodSymbols = try await session.searchSymbols(query: "call", scope: .methods)
            try require(methodSymbols.contains { $0.name == "callOnce" }, "Method search failed")

            let semanticTokens = try await session.semanticTokens(fileURL: friendlyURL, text: friendlyGreeter)
            try require(!semanticTokens.isEmpty, "Java semantic tokens were empty")
            let methodDeclarationPosition = try position(
                text: friendlyGreeter,
                symbol: "greet(String name)"
            )
            try require(
                semanticTokens.contains {
                    $0.style == .method && token($0, contains: methodDeclarationPosition)
                },
                "Java method declaration was not highlighted as a method: \(semanticTokens)"
            )
            let methodInvocationPosition = try position(
                text: friendlyGreeter,
                symbol: "normalize(name)"
            )
            try require(
                semanticTokens.contains {
                    $0.style == .method && token($0, contains: methodInvocationPosition)
                },
                "Java method invocation was not highlighted as a method: \(semanticTokens)"
            )

            let definitionCases: [(String, URL, String, String, Int, URL, String, String)] = [
                ("Interface type reference", callerURL, caller, "Greeter greeter", 0,
                 greeterURL, greeter, "Greeter"),
                ("Concrete type reference", callerURL, caller, "FriendlyGreeter friendly", 0,
                 friendlyURL, friendlyGreeter, "FriendlyGreeter extends"),
                ("Annotated multiline return type", friendlyURL, friendlyGreeter, "FriendlyGreeter\n", 0,
                 friendlyURL, friendlyGreeter, "FriendlyGreeter extends"),
                ("Multiline parameter type", friendlyURL, friendlyGreeter, "Greeter candidate", 0,
                 greeterURL, greeter, "Greeter"),
                ("Interface method invocation", callerURL, caller, "greeter.greet(name);", 8,
                 greeterURL, greeter, "greet(String name)"),
                ("Implementation method invocation", callerURL, caller, "friendly.greet(name)", 9,
                 friendlyURL, friendlyGreeter, "greet(String name)"),
                ("Overloaded method invocation", callerURL, caller, "friendly.greet(7)", 9,
                 friendlyURL, friendlyGreeter, "greet(int count)"),
                ("Invocation inside method body", friendlyURL, friendlyGreeter, "normalize(name)", 2,
                 sourceRoot.appendingPathComponent("BaseGreeter.java"), baseGreeter, "normalize(String value)")
            ]
            for (label, fileURL, text, symbol, offset, expectedURL, expectedText, expectedSymbol) in definitionCases {
                let result = try await targets(
                    session: session,
                    action: .contextual,
                    fileURL: fileURL,
                    text: text,
                    symbol: symbol,
                    symbolOffset: offset
                )
                let expectedPosition = try position(text: expectedText, symbol: expectedSymbol)
                try require(
                    result.count == 1 && result.contains {
                        target($0, in: expectedURL, contains: expectedPosition)
                    },
                    "Contextual \(label) did not resolve to the exact definition: \(result)"
                )
            }

            let methodReferenceCases: [(String, String, Int, String)] = [
                ("MethodReferenceTarget::staticName", "MethodReferenceTarget::staticName", "MethodReferenceTarget::".utf16.count, "staticName(String value)"),
                ("target::instanceName", "target::instanceName", "target::".utf16.count, "instanceName(String value)"),
                ("MethodReferenceTarget.Constructed::new", "MethodReferenceTarget.Constructed::new", "MethodReferenceTarget.Constructed::".utf16.count, "Constructed(String value)")
            ]
            for (label, symbol, offset, expectedSymbol) in methodReferenceCases {
                let result = try await targets(
                    session: session,
                    action: .contextual,
                    fileURL: methodReferenceCallerURL,
                    text: methodReferenceCaller,
                    symbol: symbol,
                    symbolOffset: offset
                )
                let expectedPosition = try position(text: methodReferenceTarget, symbol: expectedSymbol)
                try require(
                    result.count == 1 && result.contains {
                        target($0, in: methodReferenceTargetURL, contains: expectedPosition)
                    },
                    "Contextual \(label) did not resolve to the exact definition: \(result)"
                )
            }

            let fieldReferenceResult = try await targets(
                session: session,
                action: .contextual,
                fileURL: methodReferenceFieldURL,
                text: methodReferenceField,
                symbol: "MethodReferenceTarget::staticName",
                symbolOffset: "MethodReferenceTarget::".utf16.count
            )
            let staticMethodPosition = try position(text: methodReferenceTarget, symbol: "staticName(String value)")
            try require(
                fieldReferenceResult.count == 1 && fieldReferenceResult.contains {
                    target($0, in: methodReferenceTargetURL, contains: staticMethodPosition)
                },
                "Method reference in a field initializer resolved to callers instead of the method: \(fieldReferenceResult)"
            )

            let inventoryTypeResult = try await targets(
                session: session,
                action: .contextual,
                fileURL: inventoryKeyURL,
                text: inventoryKey,
                symbol: "InventoryDO::getItemTitle",
                symbolOffset: 1
            )
            let inventoryMethodResult = try await targets(
                session: session,
                action: .contextual,
                fileURL: inventoryKeyURL,
                text: inventoryKey,
                symbol: "InventoryDO::getItemTitle",
                symbolOffset: "InventoryDO::".utf16.count
            )
            let inventoryTypePosition = try position(text: inventoryDO, symbol: "InventoryDO")
            let inventoryMethodPosition = try position(text: inventoryDO, symbol: "getItemTitle()")
            try require(
                inventoryTypeResult.count == 1 && inventoryTypeResult.contains {
                    target($0, in: inventoryDOURL, contains: inventoryTypePosition)
                },
                "InventoryDO in a method reference did not resolve to the class: \(inventoryTypeResult)"
            )
            try require(
                inventoryMethodResult.count == 1 && inventoryMethodResult.contains {
                    target($0, in: inventoryDOURL, contains: inventoryMethodPosition)
                },
                "InventoryDO::getItemTitle resolved to callers instead of the method: \(inventoryMethodResult)"
            )

            let generatedGetterResult = try await targets(
                session: session,
                action: .contextual,
                fileURL: generatedInventoryKeyURL,
                text: generatedInventoryKey,
                symbol: "GeneratedInventoryDO::getItemTitle",
                symbolOffset: "GeneratedInventoryDO::".utf16.count
            )
            let generatedFieldPosition = try position(text: generatedInventoryDO, symbol: "itemTitle;")
            try require(
                generatedGetterResult.count == 1 && generatedGetterResult.contains {
                    target($0, in: generatedInventoryDOURL, contains: generatedFieldPosition)
                },
                "Generated getter method reference did not resolve to its source field: \(generatedGetterResult)"
            )

            let customClassResult = try await targets(
                session: session,
                action: .contextual,
                fileURL: generatedInventoryKeyURL,
                text: generatedInventoryKey,
                symbol: "CustomValue.class",
                symbolOffset: 1
            )
            let customClassPosition = try position(text: customValue, symbol: "CustomValue")
            try require(
                customClassResult.count == 1 && customClassResult.contains {
                    target($0, in: customValueURL, contains: customClassPosition)
                },
                "Project-local class literal did not resolve to its class declaration: \(customClassResult)"
            )

            let callerCases: [(String, URL, String, String, [(String, String, Int)])] = [
                ("Interface declaration", greeterURL, greeter, "greet(String name)", [
                    ("callOnce", "greeter.greet(name);", 8),
                    ("callTwice", "greeter.greet(name) + greeter.greet(name)", 8),
                    ("callTwice", "greeter.greet(name) + greeter.greet(name)", "greeter.greet(name) + greeter.".utf16.count)
                ]),
                ("Implementation declaration", friendlyURL, friendlyGreeter, "greet(String name)", [
                    ("callFriendly", "friendly.greet(name)", 9)
                ]),
                ("Overloaded declaration", friendlyURL, friendlyGreeter, "greet(int count)", [
                    ("callNumber", "friendly.greet(7)", 9)
                ])
            ]
            for (label, fileURL, text, symbol, expectedCallers) in callerCases {
                let result = try await targets(
                    session: session,
                    action: .contextual,
                    fileURL: fileURL,
                    text: text,
                    symbol: symbol,
                    symbolOffset: 2
                )
                var matchedCallIDs = Set<String>()
                for (expectedCaller, callSymbol, callOffset) in expectedCallers {
                    let expectedPosition = try position(text: caller, symbol: callSymbol, symbolOffset: callOffset)
                    let callerDeclarationPosition = try position(text: caller, symbol: expectedCaller)
                    let matchingCalls = result.filter {
                        $0.name.hasPrefix(expectedCaller)
                            && target($0, in: callerURL, contains: expectedPosition)
                            && !target($0, in: callerURL, contains: callerDeclarationPosition)
                    }
                    try require(
                        matchingCalls.count == 1,
                        "Contextual \(label) missed the actual call in \(expectedCaller) at \(expectedPosition): \(result)"
                    )
                    matchedCallIDs.formUnion(matchingCalls.map(\.id))
                }
                try require(
                    matchedCallIDs.count == expectedCallers.count,
                    "Contextual \(label) collapsed distinct call expressions into one caller range"
                )
                let declarationPosition = try position(text: text, symbol: symbol)
                try require(
                    !result.contains { target($0, in: fileURL, contains: declarationPosition) },
                    "Contextual \(label) returned its own declaration instead of callers"
                )
                if symbol == "greet(int count)" {
                    try require(result.count == 1, "Overloaded declaration included callers of the String overload")
                } else {
                    let numberCallPosition = try position(text: caller, symbol: "friendly.greet(7)", symbolOffset: 9)
                    try require(
                        !result.contains { target($0, in: callerURL, contains: numberCallPosition) },
                        "String declaration included a call to the int overload"
                    )
                }
            }

            let unusedCases: [(URL, String, String)] = [
                (greeterURL, greeter, "unused(String name)"),
                (friendlyURL, friendlyGreeter, "unused(String name)"),
                (friendlyURL, friendlyGreeter, "asFriendly(")
            ]
            for (fileURL, text, symbol) in unusedCases {
                let result = try await targets(
                    session: session,
                    action: .contextual,
                    fileURL: fileURL,
                    text: text,
                    symbol: symbol,
                    symbolOffset: 2
                )
                try require(result.isEmpty, "Contextual unused declaration must not fall back to definition: \(symbol): \(result)")
            }

            let methodDeclaration = try await targets(
                session: session,
                action: .declaration,
                fileURL: friendlyURL,
                text: friendlyGreeter,
                symbol: "greet(String name)"
            )
            let methodPosition = try position(text: friendlyGreeter, symbol: "greet(String name)")
            try require(
                methodDeclaration.count == 1 && methodDeclaration.contains {
                    target($0, in: friendlyURL, contains: methodPosition)
                },
                "Command+B on a method declaration must still navigate to definition, not callers"
            )

            let shiftedFriendly = """
            // public String greet(String name) { return null; }
            // public String greet(int count) { return null; }

            """ + friendlyGreeter.replacingOccurrences(
                of: "public String greet(String name)",
                with: "public String\n    greet(\n        String name\n    )"
            )
            try await session.openOrUpdateDocument(fileURL: friendlyURL, text: shiftedFriendly)
            try await Task.sleep(for: .milliseconds(400))
            let shiftedIncoming = try await targets(
                session: session,
                action: .contextual,
                fileURL: friendlyURL,
                text: shiftedFriendly,
                symbol: "greet(\n",
                symbolOffset: 2
            )
            let friendlyCallerPosition = try position(text: caller, symbol: "friendly.greet(name)", symbolOffset: 9)
            let friendlyCallerDeclarationPosition = try position(text: caller, symbol: "callFriendly")
            try require(
                shiftedIncoming.contains {
                    $0.name.hasPrefix("callFriendly")
                        && target($0, in: callerURL, contains: friendlyCallerPosition)
                        && !target($0, in: callerURL, contains: friendlyCallerDeclarationPosition)
                },
                "Unsaved multiline declaration with misleading comment signatures did not resolve to the actual call expression"
            )
            let shiftedDefinition = try await targets(
                session: session,
                action: .contextual,
                fileURL: callerURL,
                text: caller,
                symbol: "friendly.greet(name)",
                symbolOffset: 9
            )
            let shiftedMethodPosition = try position(text: shiftedFriendly, symbol: "greet(\n")
            try require(
                shiftedDefinition.count == 1 && shiftedDefinition.contains {
                    target($0, in: friendlyURL, contains: shiftedMethodPosition)
                },
                "Contextual invocation did not resolve to the unsaved, shifted method definition"
            )
            let savedFriendly = try String(contentsOf: friendlyURL, encoding: .utf8)
            try require(
                savedFriendly == friendlyGreeter,
                "Unsaved contextual fixture unexpectedly changed the on-disk source"
            )

            let changedCaller = caller.replacingOccurrences(
                of: "\n}",
                with: """

                    public String callThree(String name) {
                        return greeter.greet(name);
                    }
                }
                """
            )
            try await session.openOrUpdateDocument(fileURL: callerURL, text: changedCaller)
            try await Task.sleep(for: .milliseconds(400))
            let changedIncoming = try await targets(
                session: session,
                action: .incomingCalls,
                fileURL: greeterURL,
                text: greeter,
                symbol: "greet"
            )
            try require(
                changedIncoming.contains { $0.name.hasPrefix("callThree") },
                "Unsaved didChange was not indexed: \(changedIncoming.map(\.name))"
            )
            let changedContextualIncoming = try await targets(
                session: session,
                action: .contextual,
                fileURL: greeterURL,
                text: greeter,
                symbol: "greet"
            )
            let changedCallPrefix = "callThree(String name) {\n        return greeter."
            let changedCallerPosition = try position(
                text: changedCaller,
                symbol: changedCallPrefix + "greet(name)",
                symbolOffset: changedCallPrefix.utf16.count
            )
            let changedCallerDeclarationPosition = try position(text: changedCaller, symbol: "callThree")
            try require(
                changedContextualIncoming.contains {
                    $0.name.hasPrefix("callThree")
                        && target($0, in: callerURL, contains: changedCallerPosition)
                        && !target($0, in: callerURL, contains: changedCallerDeclarationPosition)
                },
                "Contextual declaration did not include the actual unsaved call expression"
            )
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
        try verifyNoProjectMetadata(in: root)
        let metadataRoot = dataRoot.appendingPathComponent(
            ".metadata/.plugins/org.eclipse.core.resources/.projects",
            isDirectory: true
        )
        let cachedMetadata = metadataPaths(in: metadataRoot)
        try require(
            cachedMetadata.contains { $0.lastPathComponent == ".project" }
                && cachedMetadata.contains { $0.lastPathComponent == ".classpath" },
            "Eclipse project metadata was not stored in the external Java cache"
        )
        print("JDT language server integration verification passed")
    }

    private static func verifyNoProjectMetadata(in root: URL) throws {
        let unexpected = metadataPaths(in: root).map(\.path).sorted()
        try require(unexpected.isEmpty, "JDT wrote Eclipse metadata into the source repository: \(unexpected)")
    }

    private static func metadataPaths(in root: URL) -> [URL] {
        let names: Set<String> = [".project", ".classpath", ".factorypath", ".settings"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, names.contains(url.lastPathComponent) else { return nil }
            return url
        }
    }

    private static func targets(
        session: JDTLanguageServerSession,
        action: JavaNavigationAction,
        fileURL: URL,
        text: String,
        symbol: String,
        symbolOffset: Int = 0
    ) async throws -> [JavaNavigationTarget] {
        let position = try position(text: text, symbol: symbol, symbolOffset: symbolOffset)
        return try await session.navigationTargets(
            for: JavaNavigationRequest(
                action: action,
                fileURL: fileURL,
                position: position,
                documentText: text
            )
        )
    }

    private static func position(text: String, symbol: String, symbolOffset: Int = 0) throws -> JavaSourcePosition {
        let source = text as NSString
        let range = source.range(of: symbol)
        guard range.location != NSNotFound, symbolOffset >= 0, symbolOffset < range.length else {
            throw JDTVerificationError(description: "Fixture symbol not found: \(symbol)")
        }
        let offset = range.location + symbolOffset
        let index = SourceLineIndex(text: text)
        let line = index.lineNumber(containingUTF16Offset: offset) - 1
        return JavaSourcePosition(
            line: line,
            character: offset - index.lineStartOffsets[line]
        )
    }

    private static func target(_ target: JavaNavigationTarget, in fileURL: URL, contains position: JavaSourcePosition) -> Bool {
        guard target.fileURL.standardizedFileURL == fileURL.standardizedFileURL else { return false }
        let range = target.selectionRange ?? target.range
        let afterStart = position.line > range.start.line
            || (position.line == range.start.line && position.character >= range.start.character)
        let beforeEnd = position.line < range.end.line
            || (position.line == range.end.line && position.character < range.end.character)
        return afterStart && beforeEnd
    }

    private static func token(_ token: JavaSemanticToken, contains position: JavaSourcePosition) -> Bool {
        let range = token.range
        let afterStart = position.line > range.start.line
            || (position.line == range.start.line && position.character >= range.start.character)
        let beforeEnd = position.line < range.end.line
            || (position.line == range.end.line && position.character < range.end.character)
        return afterStart && beforeEnd
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw JDTVerificationError(description: message) }
    }
}
