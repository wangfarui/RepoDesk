import Foundation

enum MavenHomeValidationResult: Equatable, Sendable {
    case unconfigured
    case valid(version: String)
    case invalid(message: String)
}

protocol MavenHomeValidating: Sendable {
    func validate(mavenHome: String) async -> MavenHomeValidationResult
}

struct MavenHomeValidator: MavenHomeValidating {
    private let commandRunner: any CommandRunning

    init(commandRunner: any CommandRunning = SystemCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func validate(mavenHome: String) async -> MavenHomeValidationResult {
        let trimmedHome = mavenHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else { return .unconfigured }

        let expandedHome = NSString(string: trimmedHome).expandingTildeInPath
        let homeURL = URL(fileURLWithPath: expandedHome, isDirectory: true).standardizedFileURL
        let executableURL = homeURL.appendingPathComponent("bin/mvn", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .invalid(message: "路径有误：未找到可执行文件 bin/mvn")
        }

        do {
            let result = try await commandRunner.run(
                CommandRequest(
                    executableURL: executableURL,
                    arguments: ["-version"],
                    workingDirectoryURL: homeURL,
                    environment: ProcessInfo.processInfo.environment
                )
            )
            let output = [result.standardOutput, result.standardError]
                .compactMap { String(data: $0, encoding: .utf8) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard result.terminationStatus == 0 else {
                let detail = output.isEmpty ? "mvn -version 退出码为 \(result.terminationStatus)" : output
                return .invalid(message: "路径有误：\(detail)")
            }
            guard let version = output.split(whereSeparator: { $0.isNewline }).first.map(String.init),
                  !version.isEmpty else {
                return .invalid(message: "路径有误：mvn -version 未返回版本信息")
            }
            return .valid(version: version)
        } catch {
            return .invalid(message: "路径有误：无法执行 bin/mvn（\(error.localizedDescription)）")
        }
    }
}
