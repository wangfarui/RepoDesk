import Foundation

/// Resolves the same repository for Maven execution, Java indexing and source navigation.
enum MavenLocalRepositoryResolver {
    static func resolve(
        settings: MavenSettings,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = expanded(settings.localRepository, home: homeDirectory, environment: environment) {
            return explicit
        }
        let userSettings = expanded(settings.userSettingsFile, home: homeDirectory, environment: environment)
            ?? homeDirectory.appendingPathComponent(".m2/settings.xml")
        var settingsFiles = [userSettings]
        if let mavenHome = expanded(settings.mavenHome, home: homeDirectory, environment: environment) {
            settingsFiles.append(mavenHome.appendingPathComponent("conf/settings.xml"))
        }
        for file in settingsFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            let delegate = LocalRepositoryXMLDelegate()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            if parser.parse(), let path = expanded(delegate.value, home: homeDirectory, environment: environment) {
                return path
            }
        }
        return homeDirectory.appendingPathComponent(".m2/repository", isDirectory: true)
    }

    private static func expanded(_ value: String, home: URL, environment: [String: String]) -> URL? {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        path = path.replacingOccurrences(of: "${user.home}", with: home.path)
        for (key, value) in environment {
            path = path.replacingOccurrences(of: "${env.\(key)}", with: value)
        }
        if path == "~" { path = home.path }
        else if path.hasPrefix("~/") { path = home.path + String(path.dropFirst()) }
        guard path.hasPrefix("/"), !path.contains("${") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

private final class LocalRepositoryXMLDelegate: NSObject, XMLParserDelegate {
    private var elements: [String] = []
    var value = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        elements.append(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elements == ["settings", "localRepository"] { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if !elements.isEmpty { elements.removeLast() }
    }
}
