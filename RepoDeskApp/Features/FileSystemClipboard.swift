import AppKit
import Foundation

@MainActor
enum FileSystemClipboard {
    @discardableResult
    static func copyItem(
        at url: URL,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        copyItems(at: [url], to: pasteboard)
    }

    @discardableResult
    static func copyItems(
        at urls: [URL],
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let urls = supportedFileURLs(urls)
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0.standardizedFileURL as NSURL })
    }

    static func fileURLs(
        from pasteboard: NSPasteboard = .general
    ) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        return supportedFileURLs(objects.map { $0 as URL })
    }

    static func supportedFileURLs(_ urls: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        return urls.compactMap { object in
            let url = object.standardizedFileURL
            guard seenPaths.insert(url.path).inserted,
                  isSupportedFileSystemItem(url) else { return nil }
            return url
        }
    }

    private static func isSupportedFileSystemItem(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true
            || values.isRegularFile == true
            || values.isSymbolicLink == true
    }
}
