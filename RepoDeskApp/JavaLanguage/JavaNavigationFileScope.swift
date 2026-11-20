import Foundation

/// Shared boundaries for full scans and incremental file notifications.
enum JavaNavigationFileScope {
    private static let excludedDirectories: Set<String> = ["target", "build", "out", "node_modules"]

    static func files(under root: URL, extension fileExtension: String) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true || excludedDirectories.contains(url.lastPathComponent)
                || (values?.isDirectory == true && FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)) {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory != true && url.pathExtension.lowercased() == fileExtension {
                files.append(url.standardizedFileURL)
            }
        }
        return files
    }

    static func contains(_ fileURL: URL, under root: URL) -> Bool {
        let fileURL = fileURL.standardizedFileURL
        let root = root.standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/") else { return false }
        var current = fileURL
        while current != root {
            let name = current.lastPathComponent
            if name.hasPrefix(".") || excludedDirectories.contains(name)
                || (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return false
            }
            if current != fileURL && FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return false
            }
            current.deleteLastPathComponent()
        }
        return true
    }
}
