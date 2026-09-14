import Foundation

enum JavaLanguageRuntimeError: LocalizedError, Sendable {
    case runtimeMissing
    case javaExecutableMissing(String)
    case launcherMissing(String)
    case configurationMissing(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            "Java language runtime is not installed in RepoDesk.app."
        case .javaExecutableMissing(let path):
            "Java 21 executable is missing: \(path)"
        case .launcherMissing(let path):
            "Eclipse JDT LS launcher is missing: \(path)"
        case .configurationMissing(let path):
            "Eclipse JDT LS macOS configuration is missing: \(path)"
        }
    }
}

struct JavaLanguageRuntime: Equatable, Sendable {
    let javaExecutableURL: URL
    let jdtRootURL: URL
    let launcherURL: URL
    let configurationURL: URL

    static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) throws -> JavaLanguageRuntime {
        let explicitRoot = environment["REPODESK_JAVA_LANGUAGE_RUNTIME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let roots = [
            explicitRoot,
            bundle.resourceURL?.appendingPathComponent("JavaLanguage", isDirectory: true),
            currentDirectoryURL.appendingPathComponent("build/JavaLanguageRuntime", isDirectory: true)
        ].compactMap { $0 }

        guard let rootURL = roots.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw JavaLanguageRuntimeError.runtimeMissing
        }

        let directJava = rootURL.appendingPathComponent("jre/bin/java")
        let macJava = rootURL.appendingPathComponent("jre/Contents/Home/bin/java")
        let javaURL = FileManager.default.isExecutableFile(atPath: directJava.path)
            ? directJava
            : macJava
        guard FileManager.default.isExecutableFile(atPath: javaURL.path) else {
            throw JavaLanguageRuntimeError.javaExecutableMissing(javaURL.path)
        }

        let jdtRootURL = rootURL.appendingPathComponent("jdtls", isDirectory: true)
        let pluginsURL = jdtRootURL.appendingPathComponent("plugins", isDirectory: true)
        let launcherURL = try FileManager.default.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: nil
        ).first {
            $0.lastPathComponent.hasPrefix("org.eclipse.equinox.launcher_")
                && $0.pathExtension == "jar"
        }
        guard let launcherURL else {
            throw JavaLanguageRuntimeError.launcherMissing(pluginsURL.path)
        }
        let configurationURL = jdtRootURL.appendingPathComponent("config_mac", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configurationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw JavaLanguageRuntimeError.configurationMissing(configurationURL.path)
        }
        return JavaLanguageRuntime(
            javaExecutableURL: javaURL,
            jdtRootURL: jdtRootURL,
            launcherURL: launcherURL,
            configurationURL: configurationURL
        )
    }
}
