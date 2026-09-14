import Foundation

enum LSPMessageFramingError: LocalizedError, Equatable, Sendable {
    case missingContentLength
    case invalidContentLength
    case messageTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .missingContentLength:
            "Java language server message is missing Content-Length."
        case .invalidContentLength:
            "Java language server returned an invalid Content-Length."
        case .messageTooLarge(let length):
            "Java language server message is too large: \(length) bytes."
        }
    }
}

struct LSPMessageFramer: Sendable {
    private static let headerDelimiter = Data("\r\n\r\n".utf8)
    private static let maximumMessageLength = 64 * 1_024 * 1_024
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var messages: [Data] = []

        while let headerRange = buffer.range(of: Self.headerDelimiter) {
            let headerData = buffer[..<headerRange.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8) else {
                throw LSPMessageFramingError.invalidContentLength
            }
            guard let lengthLine = header.split(separator: "\r\n").first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }) else {
                throw LSPMessageFramingError.missingContentLength
            }
            let rawLength = lengthLine.split(separator: ":", maxSplits: 1)
                .dropFirst()
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawLength, let length = Int(rawLength), length >= 0 else {
                throw LSPMessageFramingError.invalidContentLength
            }
            guard length <= Self.maximumMessageLength else {
                throw LSPMessageFramingError.messageTooLarge(length)
            }
            let bodyStart = headerRange.upperBound
            guard buffer.count - bodyStart >= length else { break }
            let bodyEnd = bodyStart + length
            messages.append(buffer.subdata(in: bodyStart..<bodyEnd))
            buffer.removeSubrange(0..<bodyEnd)
        }
        return messages
    }

    static func frame(_ body: Data) -> Data {
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        return framed
    }
}
