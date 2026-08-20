import Foundation

protocol DocumentLoading: Sendable {
    func load(_ fileURL: URL) async -> LoadedDocument
}

protocol DocumentSaving: Sendable {
    func save(_ request: DocumentSaveRequest) async throws -> DocumentRevision
}

struct FileSystemDocumentStore: DocumentLoading, DocumentSaving {
    let largeFileThreshold = 1_000_000
    let maximumTextFileSize = 10_000_000

    func load(_ fileURL: URL) async -> LoadedDocument {
        await Task.detached(priority: .userInitiated) {
            do {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                let size = values.fileSize ?? 0
                guard size <= maximumTextFileSize else {
                    return .unavailable("This file is larger than the 10 MB viewing limit.")
                }
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                if data.prefix(8_192).contains(0) {
                    let hasUTF16ByteOrderMark = data.starts(with: [0xFF, 0xFE])
                        || data.starts(with: [0xFE, 0xFF])
                    if hasUTF16ByteOrderMark, let decoded = Self.decodeText(data) {
                        return .text(
                            LoadedTextDocument(
                                text: decoded.text,
                                isLarge: size > largeFileThreshold,
                                encoding: decoded.encoding,
                                revision: Self.revision(for: data)
                            )
                        )
                    }
                    return .binary(size: size)
                }
                if isLikelyText(data), let decoded = Self.decodeText(data) {
                    return .text(
                        LoadedTextDocument(
                            text: decoded.text,
                            isLarge: size > largeFileThreshold,
                            encoding: decoded.encoding,
                            revision: Self.revision(for: data)
                        )
                    )
                }
                return .binary(size: size)
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }.value
    }

    func save(_ request: DocumentSaveRequest) async throws -> DocumentRevision {
        try await Task.detached(priority: .userInitiated) {
            do {
                let targetURL = request.fileURL.resolvingSymlinksInPath()
                let currentData = try Data(contentsOf: targetURL, options: .mappedIfSafe)
                if !request.allowsOverwrite,
                   Self.revision(for: currentData) != request.expectedRevision {
                    throw DocumentSaveError.changedOnDisk
                }
                guard let data = Self.encode(request.text, as: request.encoding) else {
                    throw DocumentSaveError.encodingFailed(request.encoding)
                }
                let originalAttributes = try? FileManager.default.attributesOfItem(atPath: targetURL.path)
                try data.write(to: targetURL, options: .atomic)
                if let permissions = originalAttributes?[.posixPermissions] {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: targetURL.path
                    )
                }
                return Self.revision(for: data)
            } catch let error as DocumentSaveError {
                throw error
            } catch {
                throw DocumentSaveError.fileUnavailable(error.localizedDescription)
            }
        }.value
    }

    private func isLikelyText(_ data: Data) -> Bool {
        let sample = data.prefix(8_192)
        guard !sample.isEmpty else { return true }
        let controlByteCount = sample.reduce(into: 0) { count, byte in
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) {
                count += 1
            }
        }
        return Double(controlByteCount) / Double(sample.count) < 0.01
    }

    private static func decodeText(_ data: Data) -> (text: String, encoding: DocumentTextEncoding)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, .utf8WithByteOrderMark)
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return (text, .isoLatin1)
        }
        return nil
    }

    private static func encode(_ text: String, as encoding: DocumentTextEncoding) -> Data? {
        switch encoding {
        case .utf8:
            text.data(using: .utf8)
        case .utf8WithByteOrderMark:
            text.data(using: .utf8).map { Data([0xEF, 0xBB, 0xBF]) + $0 }
        case .utf16LittleEndian:
            text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case .utf16BigEndian:
            text.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        case .isoLatin1:
            text.data(using: .isoLatin1, allowLossyConversion: false)
        }
    }

    static func revision(for data: Data) -> DocumentRevision {
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return DocumentRevision(byteCount: data.count, contentDigest: digest)
    }
}

typealias FileSystemDocumentLoader = FileSystemDocumentStore
