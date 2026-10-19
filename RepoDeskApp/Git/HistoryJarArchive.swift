import Foundation
import zlib

enum HistoryJarError: LocalizedError, Sendable {
    case invalidArchive(String)
    case limit(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let reason): "无法读取 JAR：\(reason)"
        case .limit(let reason): "JAR 预览超出限制：\(reason)"
        case .command(let reason): reason
        }
    }
}

/// Reads ZIP entries in memory; archive paths are never extracted to the filesystem.
struct HistoryJarArchive: Sendable {
    struct Entry: Sendable {
        let path: String
        let size: Int
        let compressedSize: Int
        let crc: UInt32
        let method: Int
        let flags: Int
        let offset: Int
    }

    static let maximumArchiveSize = 256 * 1_048_576
    static let maximumEntrySize = 16 * 1_048_576
    let data: Data
    let entries: [String: Entry]

    init(data: Data) throws {
        guard data.count <= Self.maximumArchiveSize else {
            throw HistoryJarError.limit("单个 JAR 最大支持 256 MB。")
        }
        guard data.count >= 22 else { throw HistoryJarError.invalidArchive("缺少 ZIP 目录。") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if data.u32(offset) == 0x06054b50,
               offset + 22 + Int(data.u16(offset + 20)) == data.count {
                end = offset
                break
            }
        }
        guard let end else { throw HistoryJarError.invalidArchive("缺少 ZIP 目录。") }
        guard data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10) else {
            throw HistoryJarError.invalidArchive("暂不支持分卷 ZIP。")
        }
        let count = Int(data.u16(end + 10))
        let directorySize = Int(data.u32(end + 12))
        var cursor = Int(data.u32(end + 16))
        guard count != 0xffff, directorySize != Int(UInt32.max), cursor != Int(UInt32.max) else {
            throw HistoryJarError.invalidArchive("暂不支持 ZIP64。")
        }
        let directoryEnd = cursor + directorySize
        guard directoryEnd <= end else { throw HistoryJarError.invalidArchive("ZIP 目录越界。") }
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor + 46 <= directoryEnd, data.u32(cursor) == 0x02014b50 else {
                throw HistoryJarError.invalidArchive("ZIP 目录损坏。")
            }
            let nameLength = Int(data.u16(cursor + 28))
            let next = cursor + 46 + nameLength + Int(data.u16(cursor + 30)) + Int(data.u16(cursor + 32))
            guard next <= directoryEnd else { throw HistoryJarError.invalidArchive("文件名越界。") }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            // Java JAR names are UTF-8, including archives without the ZIP UTF-8 flag.
            guard let name = String(data: nameData, encoding: .utf8), !name.contains("\0") else {
                throw HistoryJarError.invalidArchive("包内文件名不是有效的 UTF-8。")
            }
            if !name.hasSuffix("/") {
                guard entries[name] == nil else {
                    throw HistoryJarError.invalidArchive("存在重复文件路径：\(name)")
                }
                let size = Int(data.u32(cursor + 24))
                let compressedSize = Int(data.u32(cursor + 20))
                let offset = Int(data.u32(cursor + 42))
                guard size != Int(UInt32.max), compressedSize != Int(UInt32.max), offset != Int(UInt32.max) else {
                    throw HistoryJarError.invalidArchive("暂不支持 ZIP64 文件。")
                }
                entries[name] = Entry(
                    path: name, size: size, compressedSize: compressedSize,
                    crc: data.u32(cursor + 16), method: Int(data.u16(cursor + 10)),
                    flags: Int(data.u16(cursor + 8)), offset: offset
                )
            }
            cursor = next
        }
        guard cursor == directoryEnd else { throw HistoryJarError.invalidArchive("ZIP 目录长度不匹配。") }
        self.data = data
        self.entries = entries
    }

    func compressedBytes(for entry: Entry) throws -> Data {
        let offset = entry.offset
        guard offset + 30 <= data.count, data.u32(offset) == 0x04034b50 else {
            throw HistoryJarError.invalidArchive("文件头损坏：\(entry.path)")
        }
        let start = offset + 30 + Int(data.u16(offset + 26)) + Int(data.u16(offset + 28))
        guard start + entry.compressedSize <= data.count else {
            throw HistoryJarError.invalidArchive("文件内容越界：\(entry.path)")
        }
        return data.subdata(in: start..<start + entry.compressedSize)
    }

    func contents(of entry: Entry) throws -> Data {
        guard entry.flags & 1 == 0 else { throw HistoryJarError.invalidArchive("暂不支持加密文件。") }
        guard entry.size <= Self.maximumEntrySize else {
            throw HistoryJarError.limit("单个包内文件最大预览 16 MB。")
        }
        let compressed = try compressedBytes(for: entry)
        let result: Data
        switch entry.method {
        case 0: result = compressed
        case 8:
            var output = Data(count: max(1, entry.size))
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw HistoryJarError.invalidArchive("无法初始化解压。")
            }
            defer { inflateEnd(&stream) }
            let status = compressed.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size,
                  stream.total_in == compressed.count else {
                throw HistoryJarError.invalidArchive("解压失败：\(entry.path)")
            }
            result = output.prefix(entry.size)
        default: throw HistoryJarError.invalidArchive("不支持压缩算法 \(entry.method)。")
        }
        let checksum = result.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        guard result.count == entry.size, UInt32(checksum) == entry.crc else {
            throw HistoryJarError.invalidArchive("文件校验失败：\(entry.path)")
        }
        return result
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
}
