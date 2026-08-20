import Foundation

enum MavenProjectScannerError: LocalizedError, Equatable {
    case pomNotFound(String)
    case invalidPOM(String)

    var errorDescription: String? {
        switch self {
        case .pomNotFound(let path):
            "未找到 pom.xml：\(path)"
        case .invalidPOM(let path):
            "无法解析 pom.xml：\(path)"
        }
    }
}

struct MavenProjectScanner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func scan(repositoryURL: URL) throws -> MavenProject {
        let repositoryURL = repositoryURL.standardizedFileURL
        var visitedPOMs: Set<String> = []
        let rootModule = try scanModule(
            directoryURL: repositoryURL,
            repositoryURL: repositoryURL,
            visitedPOMs: &visitedPOMs,
            isDeclaredModule: false
        )
        return MavenProject(repositoryURL: repositoryURL, rootModule: rootModule)
    }

    private func scanModule(
        directoryURL: URL,
        repositoryURL: URL,
        visitedPOMs: inout Set<String>,
        isDeclaredModule: Bool
    ) throws -> MavenModule {
        let directoryURL = directoryURL.standardizedFileURL
        let pomURL = directoryURL.appendingPathComponent("pom.xml", isDirectory: false)
        let modulePath = relativePath(of: directoryURL, from: repositoryURL)
        guard fileManager.fileExists(atPath: pomURL.path) else {
            if isDeclaredModule {
                return MavenModule(
                    modulePath: modulePath,
                    pomURL: pomURL,
                    displayName: directoryURL.lastPathComponent,
                    groupID: nil,
                    artifactID: directoryURL.lastPathComponent,
                    version: nil,
                    packaging: "jar",
                    hasPOM: false,
                    children: []
                )
            }
            throw MavenProjectScannerError.pomNotFound(pomURL.path)
        }

        guard visitedPOMs.insert(pomURL.path).inserted else {
            throw MavenProjectScannerError.invalidPOM(pomURL.path)
        }
        let metadata = try parsePOM(at: pomURL)
        let rawGroupID = metadata.groupID ?? metadata.parentGroupID
        let rawArtifactID = metadata.artifactID ?? directoryURL.lastPathComponent
        let rawVersion = metadata.version ?? metadata.parentVersion
        var interpolationValues = metadata.properties
        interpolationValues["project.groupId"] = rawGroupID
        interpolationValues["pom.groupId"] = rawGroupID
        interpolationValues["project.artifactId"] = rawArtifactID
        interpolationValues["pom.artifactId"] = rawArtifactID
        interpolationValues["project.version"] = rawVersion
        interpolationValues["pom.version"] = rawVersion
        interpolationValues["project.parent.groupId"] = metadata.parentGroupID
        interpolationValues["project.parent.version"] = metadata.parentVersion

        let groupID = resolvedValue(rawGroupID, using: interpolationValues)
        let artifactID = resolvedValue(rawArtifactID, using: interpolationValues)
            ?? directoryURL.lastPathComponent
        let version = resolvedValue(rawVersion, using: interpolationValues)
        interpolationValues["project.groupId"] = groupID
        interpolationValues["pom.groupId"] = groupID
        interpolationValues["project.artifactId"] = artifactID
        interpolationValues["pom.artifactId"] = artifactID
        interpolationValues["project.version"] = version
        interpolationValues["pom.version"] = version

        var children: [MavenModule] = []
        for declaredPath in metadata.modules.map({
            resolvedValue($0, using: interpolationValues) ?? $0
        }) {
            let childDirectory = directoryURL
                .appendingPathComponent(declaredPath, isDirectory: true)
                .standardizedFileURL
            guard isDescendant(childDirectory, of: repositoryURL) else { continue }
            let child = try scanModule(
                directoryURL: childDirectory,
                repositoryURL: repositoryURL,
                visitedPOMs: &visitedPOMs,
                isDeclaredModule: true
            )
            children.append(child)
        }

        let resolvedName = resolvedValue(metadata.name, using: interpolationValues)
        let displayName = resolvedName?.contains("${") == false ? resolvedName : artifactID
        return MavenModule(
            modulePath: modulePath,
            pomURL: pomURL,
            displayName: displayName ?? artifactID,
            groupID: groupID,
            artifactID: artifactID,
            version: version,
            packaging: resolvedValue(metadata.packaging, using: interpolationValues)
                ?? (children.isEmpty ? "jar" : "pom"),
            hasPOM: true,
            children: children
        )
    }

    private func parsePOM(at pomURL: URL) throws -> POMMetadata {
        guard let parser = XMLParser(contentsOf: pomURL) else {
            throw MavenProjectScannerError.invalidPOM(pomURL.path)
        }
        let delegate = POMParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw MavenProjectScannerError.invalidPOM(pomURL.path)
        }
        return delegate.metadata
    }

    private func resolvedValue(
        _ value: String?,
        using interpolationValues: [String: String]
    ) -> String? {
        guard var result = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }

        for _ in 0..<10 {
            guard let openingRange = result.range(of: "${"),
                  let closingIndex = result[openingRange.upperBound...].firstIndex(of: "}") else {
                break
            }
            let key = String(result[openingRange.upperBound..<closingIndex])
            guard let replacement = interpolationValues[key] else { break }
            result.replaceSubrange(openingRange.lowerBound...closingIndex, with: replacement)
        }
        return result
    }

    private func relativePath(of directoryURL: URL, from repositoryURL: URL) -> String {
        guard directoryURL != repositoryURL else { return "." }
        let rootPath = repositoryURL.path.hasSuffix("/") ? repositoryURL.path : repositoryURL.path + "/"
        guard directoryURL.path.hasPrefix(rootPath) else { return directoryURL.lastPathComponent }
        return String(directoryURL.path.dropFirst(rootPath.count))
    }

    private func isDescendant(_ candidate: URL, of repositoryURL: URL) -> Bool {
        if candidate == repositoryURL { return true }
        let rootPath = repositoryURL.path.hasSuffix("/") ? repositoryURL.path : repositoryURL.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }
}

private struct POMMetadata {
    var groupID: String?
    var artifactID: String?
    var version: String?
    var packaging: String?
    var name: String?
    var parentGroupID: String?
    var parentVersion: String?
    var modules: [String] = []
    var properties: [String: String] = [:]
}

private final class POMParserDelegate: NSObject, XMLParserDelegate {
    private(set) var metadata = POMMetadata()
    private var elementStack: [String] = []
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementStack.joined(separator: "/") {
        case "project/groupId": metadata.groupID = nonempty(value)
        case "project/artifactId": metadata.artifactID = nonempty(value)
        case "project/version": metadata.version = nonempty(value)
        case "project/packaging": metadata.packaging = nonempty(value)
        case "project/name": metadata.name = nonempty(value)
        case "project/parent/groupId": metadata.parentGroupID = nonempty(value)
        case "project/parent/version": metadata.parentVersion = nonempty(value)
        case "project/modules/module":
            if let module = nonempty(value) { metadata.modules.append(module) }
        default:
            if elementStack.count == 3,
               elementStack[0] == "project",
               elementStack[1] == "properties",
               let propertyValue = nonempty(value) {
                metadata.properties[elementName] = propertyValue
            }
        }
        elementStack.removeLast()
        text = ""
    }

    private func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
