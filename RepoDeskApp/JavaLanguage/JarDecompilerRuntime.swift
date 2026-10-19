import Foundation

enum JarDecompilerRuntimeError: LocalizedError, Sendable {
    case decompilerMissing

    var errorDescription: String? {
        "CFR Java decompiler is not installed in RepoDesk.app. Rebuild the application to install it."
    }
}

struct JarDecompilerRuntime: Sendable {
    let javaURL: URL
    let decompilerURL: URL

    static func resolve() throws -> JarDecompilerRuntime {
        let javaURL = try JavaLanguageRuntime.resolve().javaExecutableURL
        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let roots = [
            Bundle.main.resourceURL?.appendingPathComponent("JarDecompiler", isDirectory: true),
            currentDirectoryURL.appendingPathComponent("build/JarDecompilerRuntime", isDirectory: true)
        ].compactMap { $0 }
        guard let decompilerURL = roots
            .map({ $0.appendingPathComponent("cfr-0.152.jar") })
            .first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw JarDecompilerRuntimeError.decompilerMissing
        }
        return JarDecompilerRuntime(javaURL: javaURL, decompilerURL: decompilerURL)
    }
}
