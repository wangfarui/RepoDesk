import Foundation
import Observation

@MainActor
@Observable
final class MavenEnvironmentValidationStore {
    private struct ValidationKey: Hashable {
        let workspacePath: String
        let homePath: String
    }

    private var mavenResults: [ValidationKey: MavenHomeValidationResult] = [:]
    private var javaResults: [ValidationKey: JavaHomeValidationResult] = [:]
    private var validatingMavenKeys: Set<ValidationKey> = []
    private var validatingJavaKeys: Set<ValidationKey> = []

    private let mavenHomeValidator: any MavenHomeValidating
    private let javaHomeValidator: any JavaHomeValidating

    init(
        mavenHomeValidator: any MavenHomeValidating = MavenHomeValidator(),
        javaHomeValidator: any JavaHomeValidating = JavaHomeValidator()
    ) {
        self.mavenHomeValidator = mavenHomeValidator
        self.javaHomeValidator = javaHomeValidator
    }

    func mavenResult(workspaceURL: URL, home: String) -> MavenHomeValidationResult {
        mavenResults[key(workspaceURL: workspaceURL, home: home)] ?? .unconfigured
    }

    func javaResult(workspaceURL: URL, home: String) -> JavaHomeValidationResult {
        javaResults[key(workspaceURL: workspaceURL, home: home)] ?? .unconfigured
    }

    func isValidatingMavenHome(workspaceURL: URL, home: String) -> Bool {
        validatingMavenKeys.contains(key(workspaceURL: workspaceURL, home: home))
    }

    func isValidatingJavaHome(workspaceURL: URL, home: String) -> Bool {
        validatingJavaKeys.contains(key(workspaceURL: workspaceURL, home: home))
    }

    func validateMavenHome(workspaceURL: URL, home: String) async {
        let key = key(workspaceURL: workspaceURL, home: home)
        guard !key.homePath.isEmpty else {
            mavenResults[key] = .unconfigured
            validatingMavenKeys.remove(key)
            return
        }
        guard mavenResults[key] == nil else { return }

        if validatingMavenKeys.contains(key) {
            guard await waitForMavenValidation(key: key) else { return }
            guard mavenResults[key] == nil else { return }
        }

        validatingMavenKeys.insert(key)
        defer { validatingMavenKeys.remove(key) }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        let result = await mavenHomeValidator.validate(mavenHome: home)
        guard !Task.isCancelled else { return }
        mavenResults[key] = result
    }

    func validateJavaHome(workspaceURL: URL, home: String) async {
        let key = key(workspaceURL: workspaceURL, home: home)
        guard !key.homePath.isEmpty else {
            javaResults[key] = .unconfigured
            validatingJavaKeys.remove(key)
            return
        }
        guard javaResults[key] == nil else { return }

        if validatingJavaKeys.contains(key) {
            guard await waitForJavaValidation(key: key) else { return }
            guard javaResults[key] == nil else { return }
        }

        validatingJavaKeys.insert(key)
        defer { validatingJavaKeys.remove(key) }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        let result = await javaHomeValidator.validate(javaHome: home)
        guard !Task.isCancelled else { return }
        javaResults[key] = result
    }

    func invalidate(workspaceURL: URL) {
        let workspacePath = workspaceURL.standardizedFileURL.path
        mavenResults = mavenResults.filter { $0.key.workspacePath != workspacePath }
        javaResults = javaResults.filter { $0.key.workspacePath != workspacePath }
    }

    private func key(workspaceURL: URL, home: String) -> ValidationKey {
        ValidationKey(
            workspacePath: workspaceURL.standardizedFileURL.path,
            homePath: Self.normalizedHome(home)
        )
    }

    private func waitForMavenValidation(key: ValidationKey) async -> Bool {
        while validatingMavenKeys.contains(key) {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    private func waitForJavaValidation(key: ValidationKey) async -> Bool {
        while validatingJavaKeys.contains(key) {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    private static func normalizedHome(_ home: String) -> String {
        let trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }
}
