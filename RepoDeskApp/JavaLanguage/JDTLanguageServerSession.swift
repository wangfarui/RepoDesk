import Darwin
import Foundation

enum JDTLanguageServerError: LocalizedError, Sendable {
    case notRunning
    case requestTimedOut(String)
    case remote(String)
    case terminated(String?)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Java language server is not running."
        case .requestTimedOut(let method):
            "Java language server request timed out: \(method)"
        case .remote(let message):
            message
        case .terminated(let detail):
            detail.map { "Java language server exited: \($0)" }
                ?? "Java language server exited unexpectedly."
        case .invalidResponse(let method):
            "Java language server returned an invalid response for \(method)."
        }
    }
}

actor JDTLanguageServerSession: JavaLanguageServerSession {
    nonisolated let events: AsyncStream<JavaLanguageServerEvent>
    private let eventContinuation: AsyncStream<JavaLanguageServerEvent>.Continuation
    private let inputStream: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private var framer = LSPMessageFramer()
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 1
    private var documentVersions: [URL: Int] = [:]
    private var semanticTokenTypes: [String] = []
    private var isServiceReady = false
    private var terminationDetail: String?
    private var configuration: JavaLanguageServerConfiguration?

    init() {
        let eventPair = AsyncStream<JavaLanguageServerEvent>.makeStream()
        events = eventPair.stream
        eventContinuation = eventPair.continuation
        let inputPair = AsyncStream<Data>.makeStream()
        inputStream = inputPair.stream
        inputContinuation = inputPair.continuation
    }

    deinit {
        readerTask?.cancel()
        process?.terminate()
        inputContinuation.finish()
        eventContinuation.finish()
    }

    func start(configuration: JavaLanguageServerConfiguration) async throws {
        guard process == nil else { return }
        self.configuration = configuration
        isServiceReady = false
        terminationDetail = nil
        try FileManager.default.createDirectory(
            at: configuration.dataDirectoryURL,
            withIntermediateDirectories: true
        )
        try Self.ensureMavenGlobalSettings(in: configuration.dataDirectoryURL)
        let runtime = try JavaLanguageRuntime.resolve()
        let writableConfigurationURL = try Self.prepareWritableConfiguration(
            sourceURL: runtime.configurationURL,
            dataDirectoryURL: configuration.dataDirectoryURL
        )
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = runtime.javaExecutableURL
        process.currentDirectoryURL = configuration.dataDirectoryURL
        process.arguments = [
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dlog.level=WARNING",
            "-Djava.import.generatesMetadataFilesAtProjectRoot=false",
            "-Dmaven.repo.local=/usr/local/maven/repository",
            "-Xms128m",
            "-Xmx\(configuration.settings.maximumHeapMegabytes)m",
            "-XX:ActiveProcessorCount=\(configuration.settings.processorCountPerJVM)",
            "--add-modules=ALL-SYSTEM",
            "--add-opens", "java.base/java.util=ALL-UNNAMED",
            "--add-opens", "java.base/java.lang=ALL-UNNAMED",
            "-jar", runtime.launcherURL.path,
            "-configuration", writableConfigurationURL.path,
            "-data", configuration.dataDirectoryURL.path
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLIENT_PORT")
        environment.removeValue(forKey: "CLIENT_HOST")
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [inputContinuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                inputContinuation.finish()
            } else {
                inputContinuation.yield(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [eventContinuation] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { eventContinuation.yield(.log(message)) }
        }
        let session = self
        process.terminationHandler = { process in
            Task { await session.processDidTerminate(status: process.terminationStatus) }
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        readerTask = Task { [weak self, inputStream] in
            for await data in inputStream {
                await self?.consume(data)
            }
        }

        do {
            try process.run()
            _ = Darwin.setpriority(PRIO_PROCESS, UInt32(process.processIdentifier), 10)
        } catch {
            clearProcessResources()
            throw error
        }

        let initializeResult = try await sendRequest(
            method: "initialize",
            params: initializeParameters(configuration: configuration),
            timeout: .seconds(60)
        )
        semanticTokenTypes = initializeResult["capabilities"]?["semanticTokensProvider"]?["legend"]?["tokenTypes"]?
            .arrayValue?
            .compactMap(\.stringValue) ?? []
        try sendNotification(method: "initialized", params: .object([:]))
        try sendNotification(
            method: "workspace/didChangeConfiguration",
            params: .object(["settings": javaSettings(configuration: configuration)])
        )
    }

    func waitUntilReady(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isServiceReady {
            if process == nil {
                throw JDTLanguageServerError.terminated(terminationDetail)
            }
            guard clock.now < deadline else {
                throw JDTLanguageServerError.requestTimedOut("language/status ServiceReady")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    func shutdown() async {
        guard process != nil else { return }
        _ = try? await sendRequest(method: "shutdown", params: .null, timeout: .seconds(3))
        try? sendNotification(method: "exit", params: .null)
        try? await Task.sleep(for: .milliseconds(250))
        if process?.isRunning == true {
            process?.terminate()
            try? await Task.sleep(for: .seconds(1))
        }
        if process?.isRunning == true, let identifier = process?.processIdentifier {
            _ = Darwin.kill(identifier, SIGKILL)
        }
        clearProcessResources()
    }

    func openOrUpdateDocument(fileURL: URL, text: String) async throws {
        guard process != nil else { throw JDTLanguageServerError.notRunning }
        let fileURL = fileURL.standardizedFileURL
        if let version = documentVersions[fileURL] {
            let nextVersion = version + 1
            documentVersions[fileURL] = nextVersion
            try sendNotification(
                method: "textDocument/didChange",
                params: .object([
                    "textDocument": .object([
                        "uri": .uri(fileURL),
                        "version": .integer(nextVersion)
                    ]),
                    "contentChanges": .array([.object(["text": .string(text)])])
                ])
            )
        } else {
            documentVersions[fileURL] = 1
            try sendNotification(
                method: "textDocument/didOpen",
                params: .object([
                    "textDocument": .object([
                        "uri": .uri(fileURL),
                        "languageId": .string("java"),
                        "version": .integer(1),
                        "text": .string(text)
                    ])
                ])
            )
        }
    }

    func closeDocument(fileURL: URL) async {
        let fileURL = fileURL.standardizedFileURL
        guard documentVersions.removeValue(forKey: fileURL) != nil else { return }
        try? sendNotification(
            method: "textDocument/didClose",
            params: .object(["textDocument": .object(["uri": .uri(fileURL)])])
        )
    }

    func navigationTargets(for request: JavaNavigationRequest) async throws -> [JavaNavigationTarget] {
        try await openOrUpdateDocument(fileURL: request.fileURL, text: request.documentText)
        let params = textDocumentPositionParams(fileURL: request.fileURL, position: request.position)
        switch request.action {
        case .contextual:
            let symbols = try await sendRequest(
                method: "textDocument/documentSymbol",
                params: .object(["textDocument": .object(["uri": .uri(request.fileURL)])])
            )
            if Self.isMethodDeclaration(in: symbols, at: request.position) {
                return try await incomingCallTargets(params: params)
            }
            if Self.isEnumDeclaration(in: symbols, at: request.position) {
                return try await enumUsageTargets(params: params)
            }
            let result = try await sendRequest(method: "textDocument/definition", params: params)
            let definitionTargets = parseLocations(result)
            if try await pointsToEnumDeclaration(
                definitionTargets,
                request: request
            ) {
                return try await enumUsageTargets(params: params)
            }
            return definitionTargets
        case .declaration:
            let result = try await sendRequest(method: "textDocument/definition", params: params)
            return parseLocations(result)
        case .implementation:
            let result = try await sendRequest(method: "textDocument/implementation", params: params)
            return parseLocations(result)
        case .references:
            let result = try await sendRequest(
                method: "textDocument/references",
                params: params.mergingObject([
                    "context": .object(["includeDeclaration": .bool(false)])
                ])
            )
            return parseLocations(result)
        case .incomingCalls:
            return try await incomingCallTargets(params: params)
        case .superDeclaration:
            let declaration = try await sendRequest(
                method: "textDocument/declaration",
                params: params
            )
            let declarationTargets = parseLocations(declaration).filter {
                !Self.contains($0.range, position: request.position) || $0.fileURL != request.fileURL
            }
            if !declarationTargets.isEmpty { return declarationTargets }
            let prepared = try await sendRequest(
                method: "textDocument/prepareTypeHierarchy",
                params: params
            )
            guard let item = prepared.arrayValue?.first else { return [] }
            let supertypes = try await sendRequest(
                method: "typeHierarchy/supertypes",
                params: .object(["item": item])
            )
            return parseSymbols(supertypes)
        }
    }

    static func isMethodDeclaration(in symbols: JSONValue, at position: JavaSourcePosition) -> Bool {
        for symbol in symbols.arrayValue ?? [] {
            if symbol["kind"]?.intValue == JavaSymbolKind.method.rawValue,
               let range = parseRange(symbol["selectionRange"]),
               contains(range, position: position),
               position != range.end {
                return true
            }
            if let children = symbol["children"], isMethodDeclaration(in: children, at: position) {
                return true
            }
        }
        return false
    }

    static func isEnumDeclaration(in symbols: JSONValue, at position: JavaSourcePosition) -> Bool {
        for symbol in symbols.arrayValue ?? [] {
            if symbol["kind"]?.intValue == JavaSymbolKind.enum.rawValue,
               let range = parseRange(symbol["selectionRange"]),
               contains(range, position: position),
               position != range.end {
                return true
            }
            if let children = symbol["children"], isEnumDeclaration(in: children, at: position) {
                return true
            }
        }
        return false
    }

    private func enumUsageTargets(params: JSONValue) async throws -> [JavaNavigationTarget] {
        let result = try await sendRequest(
            method: "textDocument/references",
            params: params.mergingObject([
                "context": .object(["includeDeclaration": .bool(false)])
            ])
        )
        return Self.markEnumUsageTargets(parseLocations(result))
    }

    private func pointsToEnumDeclaration(
        _ targets: [JavaNavigationTarget],
        request: JavaNavigationRequest
    ) async throws -> Bool {
        for target in targets {
            let targetFileURL = target.fileURL.standardizedFileURL
            let text: String
            if targetFileURL == request.fileURL.standardizedFileURL {
                text = request.documentText
            } else if let targetText = try? String(contentsOf: targetFileURL, encoding: .utf8) {
                text = targetText
            } else {
                continue
            }
            try await openOrUpdateDocument(fileURL: targetFileURL, text: text)
            let symbols = try await sendRequest(
                method: "textDocument/documentSymbol",
                params: .object(["textDocument": .object(["uri": .uri(targetFileURL)])])
            )
            let position = target.selectionRange?.start ?? target.range.start
            if Self.isEnumDeclaration(in: symbols, at: position) {
                return true
            }
        }
        return false
    }

    private static func markEnumUsageTargets(
        _ targets: [JavaNavigationTarget]
    ) -> [JavaNavigationTarget] {
        targets.map {
            JavaNavigationTarget(
                fileURL: $0.fileURL,
                range: $0.range,
                selectionRange: $0.selectionRange,
                name: $0.name,
                detail: $0.detail,
                containerName: $0.containerName,
                kind: .enum
            )
        }
    }

    private func incomingCallTargets(params: JSONValue) async throws -> [JavaNavigationTarget] {
        let prepared = try await sendRequest(method: "textDocument/prepareCallHierarchy", params: params)
        guard let item = prepared.arrayValue?.first else {
            let references = try await sendRequest(
                method: "textDocument/references",
                params: params.mergingObject([
                    "context": .object(["includeDeclaration": .bool(false)])
                ])
            )
            return parseLocations(references)
        }
        let incoming = try await sendRequest(
            method: "callHierarchy/incomingCalls",
            params: .object(["item": item])
        )
        return parseIncomingCalls(incoming)
    }

    func searchSymbols(query: String, scope: JavaSymbolSearchScope) async throws -> [JavaNavigationTarget] {
        let result = try await sendRequest(
            method: "workspace/symbol",
            params: .object(["query": .string(query)]),
            timeout: .seconds(30)
        )
        return parseSymbols(result).filter { target in
            switch scope {
            case .types:
                [.class, .interface, .enum, .struct, .typeParameter].contains(target.kind)
            case .methods:
                [.method, .constructor, .function].contains(target.kind)
            case .all:
                true
            }
        }
    }

    func semanticTokens(fileURL: URL, text: String) async throws -> [JavaSemanticToken] {
        try await openOrUpdateDocument(fileURL: fileURL, text: text)
        let result = try await sendRequest(
            method: "textDocument/semanticTokens/full",
            params: .object(["textDocument": .object(["uri": .uri(fileURL)])]),
            timeout: .seconds(20)
        )
        guard let values = result["data"]?.arrayValue?.compactMap(\.intValue) else { return [] }
        var tokens: [JavaSemanticToken] = []
        var line = 0
        var character = 0
        for index in stride(from: 0, to: values.count - 4, by: 5) {
            let lineDelta = values[index]
            let characterDelta = values[index + 1]
            let length = values[index + 2]
            let typeIndex = values[index + 3]
            line += lineDelta
            character = lineDelta == 0 ? character + characterDelta : characterDelta
            guard semanticTokenTypes.indices.contains(typeIndex),
                  let style = JavaSemanticTokenStyle(rawValue: semanticTokenTypes[typeIndex]) else {
                continue
            }
            tokens.append(
                JavaSemanticToken(
                    range: JavaSourceRange(
                        start: JavaSourcePosition(line: line, character: character),
                        end: JavaSourcePosition(line: line, character: character + length)
                    ),
                    style: style
                )
            )
        }
        return tokens
    }

    func notifyFilesChanged(_ fileURLs: [URL]) async {
        guard !fileURLs.isEmpty else { return }
        let changes = fileURLs.map {
            JSONValue.object(["uri": .uri($0.standardizedFileURL), "type": .integer(2)])
        }
        try? sendNotification(
            method: "workspace/didChangeWatchedFiles",
            params: .object(["changes": .array(changes)])
        )
    }

    private func initializeParameters(
        configuration: JavaLanguageServerConfiguration
    ) -> JSONValue {
        let repositoryURL = configuration.repository.repositoryURL
        return .object([
            "processId": .integer(Int(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .uri(repositoryURL),
            "workspaceFolders": .array([
                .object([
                    "uri": .uri(repositoryURL),
                    "name": .string(configuration.repository.displayName)
                ])
            ]),
            "capabilities": .object([
                "workspace": .object([
                    "configuration": .bool(true),
                    "workspaceFolders": .bool(true),
                    "symbol": .object(["dynamicRegistration": .bool(false)])
                ]),
                "textDocument": .object([
                    "declaration": .object(["linkSupport": .bool(true)]),
                    "definition": .object(["linkSupport": .bool(true)]),
                    "implementation": .object(["linkSupport": .bool(true)]),
                    "references": .object([:]),
                    "callHierarchy": .object(["dynamicRegistration": .bool(false)]),
                    "typeHierarchy": .object(["dynamicRegistration": .bool(false)]),
                    "documentSymbol": .object(["hierarchicalDocumentSymbolSupport": .bool(true)]),
                    "semanticTokens": .object([
                        "requests": .object(["full": .bool(true)]),
                        "tokenTypes": .array(JavaSemanticTokenStyle.allLSPValues.map(JSONValue.string)),
                        "tokenModifiers": .array([]),
                        "formats": .array([.string("relative")]),
                        "multilineTokenSupport": .bool(false),
                        "overlappingTokenSupport": .bool(false)
                    ])
                ]),
                "window": .object(["workDoneProgress": .bool(true)])
            ]),
            "initializationOptions": .object([
                "settings": javaSettings(configuration: configuration),
                "extendedClientCapabilities": .object([
                    "progressReportProvider": .bool(true),
                    "actionableNotificationSupported": .bool(true),
                    "classFileContentsSupport": .bool(false),
                    "shouldLanguageServerExitOnShutdown": .bool(true)
                ])
            ])
        ])
    }

    private func javaSettings(configuration: JavaLanguageServerConfiguration) -> JSONValue {
        var javaConfiguration: [String: JSONValue] = [
            "updateBuildConfiguration": .string("automatic"),
            "maven": .object([
                "globalSettings": .string(
                    Self.mavenGlobalSettingsURL(in: configuration.dataDirectoryURL).path
                )
            ])
        ]
        if let projectJavaHome = configuration.projectJavaHome, !projectJavaHome.isEmpty {
            let runtimeName = Self.javaRuntimeName(at: projectJavaHome)
            javaConfiguration["runtimes"] = .array([
                .object([
                    "name": .string(runtimeName),
                    "path": .string(projectJavaHome),
                    "default": .bool(true)
                ])
            ])
        }
        var mavenConfiguration = javaConfiguration["maven"]?.objectValue ?? [:]
        if let settingsFile = configuration.mavenUserSettingsFile, !settingsFile.isEmpty {
            mavenConfiguration["userSettings"] = .string(settingsFile)
        }
        javaConfiguration["maven"] = .object(mavenConfiguration)
        return .object([
            "java": .object([
                "autobuild": .object(["enabled": .bool(false)]),
                "configuration": .object(javaConfiguration),
                "import": .object([
                    "maven": .object(["enabled": .bool(true)]),
                    "exclusions": .array(Self.javaImportExclusions(configuration: configuration))
                ]),
                "symbols": .object([
                    "includeSourceMethodDeclarations": .bool(true)
                ]),
                "maxConcurrentBuilds": .integer(1)
            ])
        ])
    }

    static func javaImportExclusions(
        configuration: JavaLanguageServerConfiguration
    ) -> [JSONValue] {
        let standardPatterns = [
            "**/node_modules/**",
            "**/.git/**",
            "**/target/**",
            "**/build/**"
        ]
        let repositoryPath = configuration.repository.repositoryURL.standardizedFileURL.path
        let nestedRepositoryPatterns: [String] = configuration.repository.nestedRepositoryURLs.compactMap { nestedURL in
            let nestedPath = nestedURL.standardizedFileURL.path
            guard nestedPath.hasPrefix(repositoryPath + "/") else { return nil }
            let relativePath = String(nestedPath.dropFirst(repositoryPath.count + 1))
            return "**/\(globEscapedPath(relativePath))"
        }
        return (standardPatterns + nestedRepositoryPatterns).map(JSONValue.string)
    }

    private static func globEscapedPath(_ path: String) -> String {
        path.reduce(into: "") { result, character in
            if "\\*?[]{}".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }

    private func textDocumentPositionParams(
        fileURL: URL,
        position: JavaSourcePosition
    ) -> JSONValue {
        .object([
            "textDocument": .object(["uri": .uri(fileURL.standardizedFileURL)]),
            "position": .object([
                "line": .integer(position.line),
                "character": .integer(position.character)
            ])
        ])
    }

    private func sendRequest(
        method: String,
        params: JSONValue,
        timeout: Duration = .seconds(15)
    ) async throws -> JSONValue {
        guard process != nil else { throw JDTLanguageServerError.notRunning }
        let id = nextRequestID
        nextRequestID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[id] = continuation
                do {
                    try write(
                        .object([
                            "jsonrpc": .string("2.0"),
                            "id": .integer(id),
                            "method": .string(method),
                            "params": params
                        ])
                    )
                    timeoutTasks[id] = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        await self?.failRequest(
                            id: id,
                            error: JDTLanguageServerError.requestTimedOut(method)
                        )
                    }
                } catch {
                    pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.failRequest(id: id, error: CancellationError()) }
        }
    }

    private func sendNotification(method: String, params: JSONValue) throws {
        try write(
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string(method),
                "params": params
            ])
        )
    }

    private func write(_ message: JSONValue) throws {
        guard let inputPipe else { throw JDTLanguageServerError.notRunning }
        try inputPipe.fileHandleForWriting.write(contentsOf: LSPMessageFramer.frame(message.encodedData()))
    }

    private func consume(_ data: Data) {
        do {
            for body in try framer.append(data) {
                try handle(JSONValue(data: body))
            }
        } catch {
            eventContinuation.yield(.log(error.localizedDescription))
        }
    }

    private func handle(_ message: JSONValue) throws {
        if let rawID = message["id"], message["method"] == nil {
            let id = rawID.intValue ?? rawID.stringValue.flatMap(Int.init)
            guard let id else {
                eventContinuation.yield(.log("Ignored JSON-RPC response with unsupported id: \(rawID)"))
                return
            }
            timeoutTasks.removeValue(forKey: id)?.cancel()
            guard let continuation = pendingRequests.removeValue(forKey: id) else {
                eventContinuation.yield(.log("Ignored JSON-RPC response for unknown id: \(id)"))
                return
            }
            if let error = message["error"]?["message"]?.stringValue {
                continuation.resume(throwing: JDTLanguageServerError.remote(error))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        if let method = message["method"]?.stringValue {
            if message["id"] != nil {
                try respondToServerRequest(message, method: method)
            } else {
                handleNotification(method: method, params: message["params"])
            }
        }
    }

    private func respondToServerRequest(_ message: JSONValue, method: String) throws {
        guard let id = message["id"] else { return }
        let result: JSONValue
        switch method {
        case "workspace/configuration":
            let settings = configuration.map(javaSettings(configuration:)) ?? .object([:])
            let items = message["params"]?["items"]?.arrayValue ?? []
            result = .array(items.map { item in
                guard let section = item["section"]?.stringValue, !section.isEmpty else {
                    return settings
                }
                return Self.configurationValue(section: section, in: settings) ?? .null
            })
        case "workspace/applyEdit":
            result = .object(["applied": .bool(false)])
        default:
            result = .null
        }
        try write(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func handleNotification(method: String, params: JSONValue?) {
        switch method {
        case "language/status":
            let type = params?["type"]?.stringValue ?? "Message"
            let message = params?["message"]?.stringValue
            eventContinuation.yield(.status(type: type, message: message))
            if type == "ServiceReady"
                || (type == "Started" && message?.localizedCaseInsensitiveContains("ready") == true) {
                isServiceReady = true
                eventContinuation.yield(.ready)
            }
        case "language/progressReport":
            let total = params?["totalWork"]?.doubleValue ?? 0
            let done = params?["workDone"]?.doubleValue ?? 0
            let complete = params?["complete"]?.boolValue == true
            let fraction = total > 0 ? min(max(done / total, 0), 1) : (complete ? 1 : nil)
            let detail = params?["subTask"]?.stringValue
                ?? params?["task"]?.stringValue
                ?? params?["status"]?.stringValue
            eventContinuation.yield(.progress(fraction: fraction, detail: detail))
        case "window/logMessage", "window/showMessage":
            if let message = params?["message"]?.stringValue {
                eventContinuation.yield(.log(message))
            }
        default:
            break
        }
    }

    private func processDidTerminate(status: Int32) {
        terminationDetail = status == 0 ? nil : "exit status \(status)"
        let error = JDTLanguageServerError.terminated(terminationDetail)
        for continuation in pendingRequests.values {
            continuation.resume(throwing: error)
        }
        pendingRequests = [:]
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks = [:]
        eventContinuation.yield(.terminated(terminationDetail))
        clearProcessResources()
    }

    private func failRequest(id: Int, error: any Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func clearProcessResources() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        readerTask?.cancel()
        readerTask = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        documentVersions = [:]
    }

    private func parseLocations(_ value: JSONValue) -> [JavaNavigationTarget] {
        let items: [JSONValue]
        if let array = value.arrayValue {
            items = array
        } else if value.objectValue != nil {
            items = [value]
        } else {
            return []
        }
        return items.compactMap(Self.parseLocation).uniqued()
    }

    private func parseIncomingCalls(_ value: JSONValue) -> [JavaNavigationTarget] {
        value.arrayValue?.flatMap { entry -> [JavaNavigationTarget] in
            guard let from = entry["from"], let caller = Self.parseSymbolItem(from) else { return [] }
            return (entry["fromRanges"]?.arrayValue ?? []).compactMap { value in
                guard let range = Self.parseRange(value) else { return nil }
                return JavaNavigationTarget(
                    fileURL: caller.fileURL,
                    range: range,
                    selectionRange: range,
                    name: caller.name,
                    detail: caller.detail,
                    containerName: caller.containerName,
                    kind: caller.kind
                )
            }
        }.uniqued() ?? []
    }

    private func parseSymbols(_ value: JSONValue) -> [JavaNavigationTarget] {
        value.arrayValue?.compactMap(Self.parseSymbolItem).uniqued() ?? []
    }

    private static func parseSymbolItem(_ item: JSONValue) -> JavaNavigationTarget? {
        let location = item["location"] ?? item
        let parsedLocation = parseLocation(location)
        guard let fileURL = parsedLocation?.fileURL
                ?? item["uri"]?.stringValue.flatMap(URL.init(string:)),
              let range = parsedLocation?.range
                ?? parseRange(item["range"])
                ?? parseRange(item["selectionRange"]) else { return nil }
        return JavaNavigationTarget(
            fileURL: fileURL,
            range: range,
            selectionRange: parseRange(item["selectionRange"]),
            name: item["name"]?.stringValue ?? parsedLocation?.name ?? fileURL.lastPathComponent,
            detail: item["detail"]?.stringValue,
            containerName: item["containerName"]?.stringValue,
            kind: item["kind"]?.intValue.flatMap(JavaSymbolKind.init(rawValue:))
        )
    }

    private static func parseLocation(_ item: JSONValue) -> JavaNavigationTarget? {
        let uri = item["uri"]?.stringValue ?? item["targetUri"]?.stringValue
        let rangeValue = item["range"] ?? item["targetRange"]
        guard let uri, let fileURL = URL(string: uri), let range = parseRange(rangeValue) else {
            return nil
        }
        return JavaNavigationTarget(
            fileURL: fileURL,
            range: range,
            selectionRange: parseRange(item["targetSelectionRange"]),
            name: fileURL.lastPathComponent,
            detail: nil,
            containerName: nil,
            kind: nil
        )
    }

    private static func parseRange(_ value: JSONValue?) -> JavaSourceRange? {
        guard let start = value?["start"], let end = value?["end"],
              let startLine = start["line"]?.intValue,
              let startCharacter = start["character"]?.intValue,
              let endLine = end["line"]?.intValue,
              let endCharacter = end["character"]?.intValue else { return nil }
        return JavaSourceRange(
            start: JavaSourcePosition(line: startLine, character: startCharacter),
            end: JavaSourcePosition(line: endLine, character: endCharacter)
        )
    }

    private static func contains(_ range: JavaSourceRange, position: JavaSourcePosition) -> Bool {
        if position.line < range.start.line || position.line > range.end.line { return false }
        if position.line == range.start.line, position.character < range.start.character { return false }
        if position.line == range.end.line, position.character > range.end.character { return false }
        return true
    }

    private static func javaRuntimeName(at javaHome: String) -> String {
        let releaseURL = URL(fileURLWithPath: javaHome, isDirectory: true)
            .appendingPathComponent("release")
        guard let release = try? String(contentsOf: releaseURL, encoding: .utf8),
              let versionLine = release.split(separator: "\n").first(where: {
                  $0.hasPrefix("JAVA_VERSION=")
              }) else { return "JavaSE-17" }
        let version = versionLine
            .dropFirst("JAVA_VERSION=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let major: String
        if version.hasPrefix("1.8") {
            major = "1.8"
        } else {
            major = String(version.split(separator: ".").first ?? "17")
        }
        return major == "1.8" ? "JavaSE-1.8" : "JavaSE-\(major)"
    }

    private static func configurationValue(section: String, in settings: JSONValue) -> JSONValue? {
        section.split(separator: ".").reduce(Optional(settings)) { value, component in
            value?[String(component)]
        }
    }

    private static func mavenGlobalSettingsURL(in dataDirectoryURL: URL) -> URL {
        dataDirectoryURL.appendingPathComponent(".repodesk-maven-global-settings.xml")
    }

    private static func prepareWritableConfiguration(
        sourceURL: URL,
        dataDirectoryURL: URL
    ) throws -> URL {
        let destinationURL = dataDirectoryURL.appendingPathComponent(
            "osgi-configuration",
            isDirectory: true
        )
        let markerURL = destinationURL.appendingPathComponent(".repodesk-ready")
        if FileManager.default.fileExists(atPath: markerURL.path) {
            return destinationURL
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try Data(Date().ISO8601Format().utf8).write(to: markerURL, options: .atomic)
        return destinationURL
    }

    private static func ensureMavenGlobalSettings(in dataDirectoryURL: URL) throws {
        let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"
                  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                  xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.2.0 https://maven.apache.org/xsd/settings-1.2.0.xsd">
          <localRepository>/usr/local/maven/repository</localRepository>
        </settings>
        """
        let url = mavenGlobalSettingsURL(in: dataDirectoryURL)
        let data = Data(settings.utf8)
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
    }
}

private extension JSONValue {
    func mergingObject(_ additions: [String: JSONValue]) -> JSONValue {
        guard case .object(var object) = self else { return self }
        object.merge(additions) { _, new in new }
        return .object(object)
    }
}

private extension Array where Element == JavaNavigationTarget {
    func uniqued() -> [JavaNavigationTarget] {
        var seen: Set<String> = []
        return filter { seen.insert($0.id).inserted }
    }
}

private extension JavaSemanticTokenStyle {
    static let allLSPValues = [
        namespace, type, `class`, `enum`, interface, `struct`, typeParameter, parameter,
        variable, property, enumMember, event, function, method, macro, keyword, modifier,
        comment, string, number, regexp, `operator`, annotation
    ].map(\.rawValue)
}
