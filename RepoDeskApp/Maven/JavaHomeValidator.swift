import Foundation

enum JavaHomeValidationResult: Equatable, Sendable {
    case unconfigured
    case valid(version: String)
    case invalid(message: String)
}

protocol JavaHomeValidating: Sendable {
    func validate(javaHome: String) async -> JavaHomeValidationResult
}

struct JavaHomeValidator: JavaHomeValidating {
    private let commandRunner: any CommandRunning

    init(commandRunner: any CommandRunning = SystemCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func validate(javaHome: String) async -> JavaHomeValidationResult {
        let trimmedHome = javaHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty else { return .unconfigured }

        let expandedHome = NSString(string: trimmedHome).expandingTildeInPath
        let homeURL = URL(fileURLWithPath: expandedHome, isDirectory: true).standardizedFileURL
        let executableURL = homeURL.appendingPathComponent("bin/java", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .invalid(message: "路径有误：未找到可执行文件 bin/java")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["JAVA_HOME"] = homeURL.path
        do {
            let result = try await commandRunner.run(
                CommandRequest(
                    executableURL: executableURL,
                    arguments: ["-version"],
                    workingDirectoryURL: homeURL,
                    environment: environment
                )
            )
            let output = [result.standardOutput, result.standardError]
                .compactMap { String(data: $0, encoding: .utf8) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard result.terminationStatus == 0 else {
                let detail = output.isEmpty ? "java -version 退出码为 \(result.terminationStatus)" : output
                return .invalid(message: "路径有误：\(detail)")
            }
            guard let version = output.split(whereSeparator: { $0.isNewline }).first.map(String.init),
                  !version.isEmpty else {
                return .invalid(message: "路径有误：java -version 未返回版本信息")
            }
            return .valid(version: version)
        } catch {
            return .invalid(message: "路径有误：无法执行 bin/java（\(error.localizedDescription)）")
        }
    }
}
