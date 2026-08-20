import Foundation

struct WorkspaceFileEntry: Equatable, Identifiable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool

    var id: URL { url }
}

enum LoadedDocument: Equatable, Sendable {
    case text(LoadedTextDocument)
    case binary(size: Int)
    case unavailable(String)
}

struct LoadedTextDocument: Equatable, Sendable {
    let text: String
    let isLarge: Bool
    let encoding: DocumentTextEncoding
    let revision: DocumentRevision
}

enum DocumentTextEncoding: String, Equatable, Sendable {
    case utf8 = "UTF-8"
    case utf8WithByteOrderMark = "UTF-8 with BOM"
    case utf16LittleEndian = "UTF-16 LE"
    case utf16BigEndian = "UTF-16 BE"
    case isoLatin1 = "ISO Latin-1"
}

struct DocumentRevision: Equatable, Sendable {
    let byteCount: Int
    let contentDigest: UInt64
}

struct DocumentSaveRequest: Equatable, Sendable {
    let fileURL: URL
    let text: String
    let encoding: DocumentTextEncoding
    let expectedRevision: DocumentRevision
    let allowsOverwrite: Bool
}

enum DocumentSaveError: LocalizedError, Equatable, Sendable {
    case changedOnDisk
    case encodingFailed(DocumentTextEncoding)
    case fileUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .changedOnDisk:
            "The file changed on disk after it was opened."
        case .encodingFailed(let encoding):
            "The edited text cannot be represented as \(encoding.rawValue)."
        case .fileUnavailable(let message):
            message
        }
    }
}
