import Foundation
@testable import RepoDesk

private struct RepositoryVerificationError: Error { let message: String }

@main
enum VerifyMavenRepository {
    @MainActor
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("RepoDesk-MavenRepository-\(UUID())")
        try manager.createDirectory(at: root.appendingPathComponent(".m2"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw RepositoryVerificationError(message: message) }
        }
        func resolve(_ settings: MavenSettings = .empty) -> URL {
            MavenLocalRepositoryResolver.resolve(settings: settings, homeDirectory: root,
                                                 environment: ["CACHE_ROOT": root.path])
        }
        try require(resolve().path == root.appendingPathComponent(".m2/repository").path,
                    "A fresh installation must use its own home directory")
        let globalHome = root.appendingPathComponent("maven")
        try manager.createDirectory(at: globalHome.appendingPathComponent("conf"), withIntermediateDirectories: true)
        try Data("<settings><localRepository>${env.CACHE_ROOT}/global</localRepository></settings>".utf8)
            .write(to: globalHome.appendingPathComponent("conf/settings.xml"))
        try require(resolve(MavenSettings(mavenHome: globalHome.path)).lastPathComponent == "global",
                    "Maven Home settings must be respected")
        try Data("<settings><localRepository>${user.home}/cache &amp; artifacts</localRepository></settings>".utf8)
            .write(to: root.appendingPathComponent(".m2/settings.xml"))
        try require(resolve(MavenSettings(mavenHome: globalHome.path)).lastPathComponent == "cache & artifacts",
                    "User settings must override global settings and decode XML entities")
        let customSettings = root.appendingPathComponent("custom.xml")
        try Data("<settings><localRepository>~/custom</localRepository></settings>".utf8).write(to: customSettings)
        let configured = MavenSettings(userSettingsFile: customSettings.path, localRepository: root.appendingPathComponent("existing repository").path)
        try require(resolve(configured).lastPathComponent == "existing repository",
                    "Saved explicit paths must win over all inferred defaults")
        try require(resolve(MavenSettings(userSettingsFile: customSettings.path)).lastPathComponent == "custom",
                    "Explicit settings files must replace the default user settings")
        try Data("<settings><localRepository>unresolved/${unknown}</localRepository></settings>".utf8)
            .write(to: customSettings)
        try require(resolve(MavenSettings(userSettingsFile: customSettings.path)).path == root.appendingPathComponent(".m2/repository").path,
                    "Unsupported settings placeholders must not become relative filesystem paths")
        let suite = "RepoDesk.RepositoryCompatibility.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Missing isolated preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsMavenSettingsStore(defaults: defaults)
        try store.save(configured, for: root)
        let before = defaults.data(forKey: "maven.settingsByWorkspace.v1")
        let restored = store.settings(for: root)
        try require(restored == configured && resolve(restored) == resolve(configured),
                    "Existing per-workspace settings must round-trip unchanged")
        try require(defaults.data(forKey: "maven.settingsByWorkspace.v1") == before,
                    "Reading settings must never rewrite the saved configuration")
        let module = MavenModule(modulePath: ".", pomURL: root.appendingPathComponent("pom.xml"),
                                 displayName: "sample", groupID: nil, artifactID: "sample", version: nil,
                                 packaging: "pom", hasPOM: true, children: [])
        let command = MavenCommandBuilder.makeCommand(repositoryURL: root, module: module, goal: .compile, settings: configured)
        try require(command.arguments.contains("-Dmaven.repo.local=\(resolve(configured).path)"),
                    "The Maven command and Java navigation must share the explicit repository")
        print("Maven repository precedence and saved-configuration compatibility passed")
    }
}
