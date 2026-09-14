import AppKit
import XCTest

@MainActor
final class JavaNavigationUITests: XCTestCase {
    func testCommandClickReturnTypeOpensItsClass() throws {
        let app = try launch(file: "ProcessingNotifyApi.java")
        defer { app.terminate() }
        let editor = try sourceEditor(in: app)
        try clickSourceToken("ProcessingNotifyDetailPageResult search", in: editor, command: false)
        XCTAssertTrue(waitUntilSelected(app.buttons["RepoDesk.FileTab.ProcessingNotifyApi.java"]))
        XCTAssertFalse(app.buttons["RepoDesk.FileTab.ProcessingNotifyDetailPageResult.java"].exists)

        try clickSourceToken("ProcessingNotifyDetailPageResult search", in: editor)
        guard app.buttons["RepoDesk.FileTab.ProcessingNotifyDetailPageResult.java"].waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "return-type-click-misdirected")
            XCTFail("Command+click on return type must open its class, not a usage")
            return
        }
        XCTAssertTrue(String(describing: editor.value ?? "").contains("class ProcessingNotifyDetailPageResult"))
        XCTAssertFalse(app.buttons["RepoDesk.FileTab.ProcessingSearchHandler.java"].exists)
    }

    func testCommandClickInvocationOpensDefinitionAndDeclarationOffersCallers() throws {
        let app = try launch(file: "ProcessingSearchHandler.java")
        defer { app.terminate() }
        let editor = try sourceEditor(in: app)
        try clickSourceToken("api.searchProcessingNotifyDetailPage()", offset: 4, in: editor)
        guard app.buttons["RepoDesk.FileTab.ProcessingNotifyApi.java"].waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "method-call-definition-missing")
            XCTFail("Command+click on method invocation must open the method definition")
            return
        }
        XCTAssertTrue(String(describing: editor.value ?? "").contains("interface ProcessingNotifyApi"))

        try clickSourceToken("searchProcessingNotifyDetailPage()", in: editor, command: false)
        editor.typeKey("b", modifierFlags: .command)
        XCTAssertTrue(waitUntilSelected(app.buttons["RepoDesk.FileTab.ProcessingNotifyApi.java"]))
        XCTAssertFalse(app.descendants(matching: .any)["RepoDesk.JavaNavigationResults"].exists)

        try clickSourceToken("searchProcessingNotifyDetailPage()", in: editor)
        let results = app.descendants(matching: .any)["RepoDesk.JavaNavigationResults"]
        guard results.waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "method-declaration-callers-missing")
            XCTFail("Command+click on a method declaration must offer its callers")
            return
        }
        let callers = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "RepoDesk.JavaTarget.ProcessingSearchHandler.java.")
        )
        XCTAssertEqual(callers.count, 2)
        callers.element(boundBy: 1).click()
        XCTAssertTrue(waitUntilSelected(app.buttons["RepoDesk.FileTab.ProcessingSearchHandler.java"]))
        XCTAssertTrue(String(describing: editor.value ?? "").contains("class ProcessingSearchHandler"))
    }

    func testCallersPopupMovesLeftAndShowsLongFileNames() throws {
        let app = try launch(file: "RightAlignedProcessingNotifyApi.java")
        defer { app.terminate() }
        let editor = try sourceEditor(in: app)

        let clickPoint = try clickSourceToken("searchProcessingNotifyPage()", in: editor)
        let results = app.descendants(matching: .any)["RepoDesk.JavaNavigationResults"]
        guard results.waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "right-aligned-callers-popup-missing")
            XCTFail("Command+click did not show the callers popup")
            return
        }

        let apiTest = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "RepoDesk.JavaTarget.ProcessingNotifyApiTest.java."
            )
        ).firstMatch
        let implementationTest = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "RepoDesk.JavaTarget.ProcessingNotifyApiImplUnitTest.java."
            )
        ).firstMatch
        XCTAssertTrue(apiTest.waitForExistence(timeout: 5))
        XCTAssertTrue(implementationTest.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            results.frame.maxX,
            clickPoint.x - 12,
            "The popup should be fully to the left of a right-edge click"
        )
        captureScreenshot(from: app, named: "java-navigation-popup-long-file-names")
    }

    func testCommandClickUnusedMethodDeclarationStaysPut() throws {
        let app = try launch(file: "ProcessingNotifyApi.java")
        defer { app.terminate() }
        let editor = try sourceEditor(in: app)
        try clickSourceToken("unused()", in: editor)
        XCTAssertFalse(app.descendants(matching: .any)["RepoDesk.JavaNavigationResults"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilSelected(app.buttons["RepoDesk.FileTab.ProcessingNotifyApi.java"]))
        XCTAssertFalse(app.buttons["RepoDesk.FileTab.ProcessingSearchHandler.java"].exists)
    }

    func testCommandBOpensJavaDeclarationFromSourceEditor() throws {
        let app = try launch(file: "Caller.java")
        defer { app.terminate() }

        let editor = try sourceEditor(in: app)
        try select("Greeter", in: editor, app: app)
        editor.typeKey("b", modifierFlags: .command)

        let declarationTab = app.buttons["RepoDesk.FileTab.Greeter.java"]
        guard declarationTab.waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "declaration-navigation-failed")
            XCTFail("Command+B did not open Greeter.java")
            return
        }
        XCTAssertTrue(
            String(describing: editor.value ?? "").contains("interface Greeter"),
            "The visible editor did not switch to Greeter.java"
        )
    }

    func testOptionCommandBOffersMultipleImplementations() throws {
        let app = try launch(file: "Greeter.java")
        defer { app.terminate() }

        let editor = try sourceEditor(in: app)
        try select("Greeter", in: editor, app: app)
        editor.typeKey("b", modifierFlags: [.command, .option])

        let results = app.descendants(matching: .any)["RepoDesk.JavaNavigationResults"]
        guard results.waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "implementation-results-missing")
            XCTFail("Option+Command+B did not show multiple implementations")
            return
        }
        let friendly = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "RepoDesk.JavaTarget.FriendlyGreeter.java.")
        ).firstMatch
        let formal = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "RepoDesk.JavaTarget.FormalGreeter.java.")
        ).firstMatch
        XCTAssertTrue(friendly.waitForExistence(timeout: 5))
        guard formal.waitForExistence(timeout: 5) else {
            captureDiagnostics(from: app, named: "implementation-options-incomplete")
            XCTFail("Implementation chooser did not contain both implementations")
            return
        }
        formal.click()

        XCTAssertTrue(app.buttons["RepoDesk.FileTab.FormalGreeter.java"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            String(describing: editor.value ?? "").contains("class FormalGreeter"),
            "Selecting an implementation did not open its source file"
        )
    }

    func testCommandUAndJavaNavigationHistory() throws {
        let app = try launch(file: "FriendlyGreeter.java")
        defer { app.terminate() }

        let editor = try sourceEditor(in: app)
        try select("greet(", in: editor, app: app)
        editor.typeKey("u", modifierFlags: .command)

        let greeterTab = app.buttons["RepoDesk.FileTab.Greeter.java"]
        XCTAssertTrue(greeterTab.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: editor.value ?? "").contains("interface Greeter"))

        editor.typeKey(.leftArrow, modifierFlags: [.command, .option])
        let friendlyTab = app.buttons["RepoDesk.FileTab.FriendlyGreeter.java"]
        XCTAssertTrue(waitUntilSelected(friendlyTab))
        XCTAssertTrue(String(describing: editor.value ?? "").contains("class FriendlyGreeter"))

        editor.typeKey(.rightArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(waitUntilSelected(greeterTab))
        XCTAssertTrue(String(describing: editor.value ?? "").contains("interface Greeter"))
    }

    func testJavaTypeAndMethodSearchOpenTheirTargets() throws {
        let app = try launch(file: "Caller.java")
        defer { app.terminate() }

        let editor = try sourceEditor(in: app)
        editor.typeKey("o", modifierFlags: .command)
        try searchJavaSymbol("FormalGreeter", app: app)
        XCTAssertTrue(app.buttons["RepoDesk.FileTab.FormalGreeter.java"].waitForExistence(timeout: 20))

        editor.typeKey("o", modifierFlags: [.command, .option])
        try searchJavaSymbol("callTwice", app: app)
        let callerTab = app.buttons["RepoDesk.FileTab.Caller.java"]
        XCTAssertTrue(callerTab.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilSelected(callerTab))
        XCTAssertTrue(String(describing: editor.value ?? "").contains("callTwice"))
    }

    private func launch(file: String) throws -> XCUIApplication {
        continueAfterFailure = false
        let fixture = try JavaNavigationFixture.prepare()
        let app = XCUIApplication()
        app.launchArguments = [
            "--repodesk-ui-test-workspace", fixture.workspaceURL.path,
            "--repodesk-ui-test-repository", "java-repo",
            "--repodesk-ui-test-file", "src/main/java/sample/\(file)"
        ]
        app.launchEnvironment["REPODESK_JAVA_LANGUAGE_RUNTIME"] = fixture.runtimeURL.path
        app.launchEnvironment["REPODESK_JAVA_LANGUAGE_CACHE_ROOT"] = fixture.cacheURL.path
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: fixture.workspaceURL)
            try? FileManager.default.removeItem(at: fixture.cacheURL)
        }
        app.launch()

        guard app.buttons["RepoDesk.FileTab.\(file)"].waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "initial-file-missing")
            XCTFail("RepoDesk did not launch directly into \(file)")
            throw JavaNavigationUITestError.preconditionFailed
        }
        let indexStatus = app.buttons["RepoDesk.JavaIndexStatus"]
        guard indexStatus.waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "index-status-missing")
            XCTFail("Java indexing status did not appear")
            throw JavaNavigationUITestError.preconditionFailed
        }
        let ready = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return "\(element.label) \(element.value ?? "")".contains("Java 索引已就绪")
        }
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: indexStatus)
        guard XCTWaiter.wait(for: [expectation], timeout: 120) == .completed else {
            captureDiagnostics(from: app, named: "index-not-ready")
            XCTFail("Java indexing did not become ready")
            throw JavaNavigationUITestError.preconditionFailed
        }
        return app
    }

    private func sourceEditor(in app: XCUIApplication) throws -> XCUIElement {
        let editor = app.textViews["RepoDesk.SourceEditor"]
        guard editor.waitForExistence(timeout: 10) else {
            captureDiagnostics(from: app, named: "source-editor-missing")
            XCTFail("Source editor is not accessible")
            throw JavaNavigationUITestError.preconditionFailed
        }
        return editor
    }

    @discardableResult
    private func clickSourceToken(
        _ symbol: String,
        offset: Int = 1,
        in editor: XCUIElement,
        command: Bool = true
    ) throws -> CGPoint {
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        let source = String(describing: editor.value ?? "")
        let range = (source as NSString).range(of: symbol)
        guard range.location != NSNotFound, offset >= 0, offset < range.length else {
            XCTFail("Source fixture does not contain click target: \(symbol)")
            throw JavaNavigationUITestError.preconditionFailed
        }
        let storage = NSTextStorage(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 10_000, height: 10_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: range.location + offset)
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let coordinate = editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 14 + bounds.midX, dy: 12 + bounds.midY))
        if command {
            XCUIElement.perform(withKeyModifiers: .command) { coordinate.click() }
        } else {
            coordinate.click()
        }
        return CGPoint(
            x: editor.frame.minX + 14 + bounds.midX,
            y: editor.frame.minY + 12 + bounds.midY
        )
    }

    private func select(_ query: String, in editor: XCUIElement, app: XCUIApplication) throws {
        editor.click()
        editor.typeKey("f", modifierFlags: .command)
        let findField = app.textFields["Find"]
        guard findField.waitForExistence(timeout: 5) else {
            captureDiagnostics(from: app, named: "content-find-missing")
            XCTFail("Command+F did not expose the editor find field")
            throw JavaNavigationUITestError.preconditionFailed
        }
        try paste(query, into: findField)
        findField.typeKey(.escape, modifierFlags: [])
    }

    private func searchJavaSymbol(_ query: String, app: XCUIApplication) throws {
        let queryField = app.textFields["RepoDesk.JavaSymbolSearch.Query"]
        guard queryField.waitForExistence(timeout: 5) else {
            captureDiagnostics(from: app, named: "java-symbol-search-missing")
            XCTFail("Java symbol search did not open")
            throw JavaNavigationUITestError.preconditionFailed
        }
        try paste(query, into: queryField)
        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "RepoDesk.JavaTarget.")
        ).firstMatch
        guard result.waitForExistence(timeout: 20) else {
            captureDiagnostics(from: app, named: "java-symbol-result-missing")
            XCTFail("Java symbol search returned no target")
            throw JavaNavigationUITestError.preconditionFailed
        }
        result.click()
    }

    private func paste(_ text: String, into field: XCUIElement) throws {
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.writeObjects(previousItems)
            XCTFail("Could not prepare literal search text")
            throw JavaNavigationUITestError.preconditionFailed
        }
        let changeCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
                pasteboard.writeObjects(previousItems)
            }
        }
        field.typeKey("v", modifierFlags: .command)
        let predicate = NSPredicate(format: "value == %@", text)
        guard XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: field)],
            timeout: 5
        ) == .completed else {
            XCTFail("Search field did not receive literal text: \(text)")
            throw JavaNavigationUITestError.preconditionFailed
        }
    }

    private func waitUntilSelected(_ tab: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate { object, _ in
            String(describing: (object as? XCUIElement)?.value ?? "") == "selected"
        }
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: tab)],
            timeout: timeout
        ) == .completed
    }

    private func captureDiagnostics(from app: XCUIApplication, named name: String) {
        captureScreenshot(from: app, named: name)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func captureScreenshot(from app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

private enum JavaNavigationUITestError: Error {
    case preconditionFailed
}

private struct JavaNavigationFixture {
    let workspaceURL: URL
    let runtimeURL: URL
    let cacheURL: URL

    static func prepare() throws -> JavaNavigationFixture {
        let fileManager = FileManager.default
        let fixtureID = UUID().uuidString
        let workspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent("RepoDeskUITests/JavaNavigationWorkspace/\(fixtureID)", isDirectory: true)
        let cacheURL = fileManager.temporaryDirectory
            .appendingPathComponent("RepoDeskUITests/JavaLanguageCache/\(fixtureID)", isDirectory: true)
        let repositoryURL = workspaceURL.appendingPathComponent("java-repo", isDirectory: true)
        let sourceURL = repositoryURL
            .appendingPathComponent("src/main/java/sample", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: workspaceURL.appendingPathComponent("non-java-repo", isDirectory: true),
            withIntermediateDirectories: true
        )

        try write(
            """
            <project xmlns="http://maven.apache.org/POM/4.0.0">
              <modelVersion>4.0.0</modelVersion>
              <groupId>sample</groupId>
              <artifactId>java-navigation-fixture</artifactId>
              <version>1.0.0</version>
              <properties><maven.compiler.release>17</maven.compiler.release></properties>
            </project>
            """,
            to: repositoryURL.appendingPathComponent("pom.xml")
        )
        try write(
            """
            package sample;

            public interface Greeter {
                String greet(String name);
            }
            """,
            to: sourceURL.appendingPathComponent("Greeter.java")
        )
        try write(
            """
            package sample;

            public final class FriendlyGreeter implements Greeter {
                @Override
                public String greet(String name) {
                    return "Hello " + name;
                }
            }
            """,
            to: sourceURL.appendingPathComponent("FriendlyGreeter.java")
        )
        try write(
            """
            package sample;

            public final class FormalGreeter implements Greeter {
                @Override
                public String greet(String name) {
                    return "Good day " + name;
                }
            }
            """,
            to: sourceURL.appendingPathComponent("FormalGreeter.java")
        )
        try write(
            """
            package sample;

            public final class Caller {
                private final Greeter greeter = new FriendlyGreeter();

                public String callOnce(String name) {
                    return greeter.greet(name);
                }

                public String callTwice(String name) {
                    return greeter.greet(name) + greeter.greet(name);
                }
            }
            """,
            to: sourceURL.appendingPathComponent("Caller.java")
        )
        try ensureGitRepository(at: repositoryURL)

        try write(
            """
            package sample;

            public final class ProcessingNotifyDetailPageResult {}
            """,
            to: sourceURL.appendingPathComponent("ProcessingNotifyDetailPageResult.java")
        )
        try write(
            """
            package sample;

            public interface ProcessingNotifyApi {
                ProcessingNotifyDetailPageResult searchProcessingNotifyDetailPage();
                ProcessingNotifyDetailPageResult unused();
            }
            """,
            to: sourceURL.appendingPathComponent("ProcessingNotifyApi.java")
        )
        try write(
            """
            package sample;

            public final class ProcessingSearchHandler {
                public ProcessingNotifyDetailPageResult callOnce(ProcessingNotifyApi api) {
                    return api.searchProcessingNotifyDetailPage();
                }

                public ProcessingNotifyDetailPageResult callTwice(ProcessingNotifyApi api) {
                    return api.searchProcessingNotifyDetailPage();
                }
            }
            """,
            to: sourceURL.appendingPathComponent("ProcessingSearchHandler.java")
        )
        try write(
            """
            package sample;

            public interface RightAlignedProcessingNotifyApi {
                                                                        ProcessingNotifyDetailPageResult searchProcessingNotifyPage();
            }
            """,
            to: sourceURL.appendingPathComponent("RightAlignedProcessingNotifyApi.java")
        )
        try write(
            """
            package sample;

            public final class ProcessingNotifyApiTest {
                public ProcessingNotifyDetailPageResult call(RightAlignedProcessingNotifyApi api) {
                    return api.searchProcessingNotifyPage();
                }
            }
            """,
            to: sourceURL.appendingPathComponent("ProcessingNotifyApiTest.java")
        )
        try write(
            """
            package sample;

            public final class ProcessingNotifyApiImplUnitTest {
                public ProcessingNotifyDetailPageResult call(RightAlignedProcessingNotifyApi api) {
                    return api.searchProcessingNotifyPage();
                }
            }
            """,
            to: sourceURL.appendingPathComponent("ProcessingNotifyApiImplUnitTest.java")
        )

        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeURL = projectURL
            .appendingPathComponent("build/JavaLanguageRuntime", isDirectory: true)
        return JavaNavigationFixture(
            workspaceURL: workspaceURL,
            runtimeURL: runtimeURL,
            cacheURL: cacheURL
        )
    }

    private static func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func ensureGitRepository(at repositoryURL: URL) throws {
        let fileManager = FileManager.default
        let gitURL = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        for relativePath in ["objects", "refs/heads", "refs/tags"] {
            try fileManager.createDirectory(
                at: gitURL.appendingPathComponent(relativePath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try write("ref: refs/heads/main\n", to: gitURL.appendingPathComponent("HEAD"))
        try write(
            """
            [core]
                repositoryformatversion = 0
                filemode = true
                bare = false
                ignorecase = true
                precomposeunicode = true
            """,
            to: gitURL.appendingPathComponent("config")
        )
    }

}
