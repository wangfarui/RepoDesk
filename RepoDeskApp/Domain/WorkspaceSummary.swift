import Foundation

struct WorkspaceSummary: Equatable {
    let name: String
    let path: String
    let isAvailable: Bool

    init(name: String, path: String, isAvailable: Bool = true) {
        self.name = name
        self.path = path
        self.isAvailable = isAvailable
    }

    init(url: URL) {
        let normalizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: normalizedURL.path,
            isDirectory: &isDirectory
        )
        self.init(
            name: normalizedURL.lastPathComponent,
            path: normalizedURL.path,
            isAvailable: exists && isDirectory.boolValue
        )
    }
}
