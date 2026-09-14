import Foundation

enum JavaLanguageServerEvent: Equatable, Sendable {
    case status(type: String, message: String?)
    case progress(fraction: Double?, detail: String?)
    case ready
    case log(String)
    case terminated(String?)
}

struct JavaLanguageServerConfiguration: Equatable, Sendable {
    let repository: JavaRepositoryDescriptor
    let dataDirectoryURL: URL
    let settings: JavaIndexSettings
    let projectJavaHome: String?
    let mavenUserSettingsFile: String?
}

protocol JavaLanguageServerSession: Sendable {
    var events: AsyncStream<JavaLanguageServerEvent> { get }

    func start(configuration: JavaLanguageServerConfiguration) async throws
    func waitUntilReady(timeout: Duration) async throws
    func shutdown() async
    func openOrUpdateDocument(fileURL: URL, text: String) async throws
    func closeDocument(fileURL: URL) async
    func navigationTargets(for request: JavaNavigationRequest) async throws -> [JavaNavigationTarget]
    func searchSymbols(query: String, scope: JavaSymbolSearchScope) async throws -> [JavaNavigationTarget]
    func semanticTokens(fileURL: URL, text: String) async throws -> [JavaSemanticToken]
    func notifyFilesChanged(_ fileURLs: [URL]) async
}

typealias JavaLanguageServerFactory = @Sendable () -> any JavaLanguageServerSession
