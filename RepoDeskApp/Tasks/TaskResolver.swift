import Foundation

enum TaskResolutionError: LocalizedError, Equatable {
    case missingRepository
    case missingSelectedFile
    case missingEnvironmentVariable(String)
    case invalidWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .missingRepository: "This task requires an active repository."
        case .missingSelectedFile: "This task requires a selected file."
        case .missingEnvironmentVariable(let name): "Environment variable \(name) is not defined."
        case .invalidWorkingDirectory(let path): "Task working directory is unavailable: \(path)"
        }
    }
}

enum RepoTaskResolver {
    static func resolve(
        _ definition: RepoTaskDefinition,
        context: TaskResolutionContext,
        fileManager: FileManager = .default
    ) throws -> ResolvedRepoTask {
        let executable = try expand(definition.executable, context: context)
        let expandedArguments = try definition.arguments.map { try expand($0, context: context) }
        let workingDirectory = try expand(definition.workingDirectory, context: context)
        let workingDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workingDirectoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TaskResolutionError.invalidWorkingDirectory(workingDirectory)
        }

        var environment = context.processEnvironment
        for (name, value) in definition.environment {
            environment[name] = try expand(value, context: context)
        }

        let executableURL: URL
        let arguments: [String]
        if executable.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: executable)
            arguments = expandedArguments
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            arguments = [executable] + expandedArguments
        }

        return ResolvedRepoTask(
            definitionID: definition.id,
            name: definition.name,
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: workingDirectoryURL,
            environment: environment,
            confirmation: definition.confirmation
        )
    }

    private static func expand(
        _ value: String,
        context: TaskResolutionContext
    ) throws -> String {
        var result = value
        result = result.replacingOccurrences(of: "${workspaceRoot}", with: context.workspaceURL.path)
        if result.contains("${repositoryRoot}") {
            guard let repositoryURL = context.repositoryURL else {
                throw TaskResolutionError.missingRepository
            }
            result = result.replacingOccurrences(of: "${repositoryRoot}", with: repositoryURL.path)
        }
        if result.contains("${selectedFile}") {
            guard let selectedFileURL = context.selectedFileURL else {
                throw TaskResolutionError.missingSelectedFile
            }
            result = result.replacingOccurrences(of: "${selectedFile}", with: selectedFileURL.path)
        }
        result = result.replacingOccurrences(of: "${userHome}", with: context.userHomeURL.path)

        let pattern = #"\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}"#
        let regex = try! NSRegularExpression(pattern: pattern)
        while let match = regex.firstMatch(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ), let wholeRange = Range(match.range(at: 0), in: result),
              let nameRange = Range(match.range(at: 1), in: result) {
            let name = String(result[nameRange])
            guard let replacement = context.processEnvironment[name] else {
                throw TaskResolutionError.missingEnvironmentVariable(name)
            }
            result.replaceSubrange(wholeRange, with: replacement)
        }
        return result
    }
}
