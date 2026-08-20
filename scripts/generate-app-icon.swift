import Foundation
import ImageIO
import UniformTypeIdentifiers

private let iconSizes = [16, 32, 64, 128, 256, 512, 1_024]

private func writeResizedTIFF(source: CGImageSource, size: Int, to outputURL: URL) throws {
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: size,
        kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary
    guard let resizedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
        throw CocoaError(.fileWriteUnknown)
    }

    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.tiff.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, resizedImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func run(_ executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon <master.png> <output.icns>\n".utf8))
    exit(2)
}

let masterURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
      CGImageSourceGetCount(source) > 0 else {
    throw CocoaError(.fileReadCorruptFile)
}

let fileManager = FileManager.default
let temporaryDirectory = fileManager.temporaryDirectory
    .appendingPathComponent("RepoDeskIcon-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporaryDirectory) }

let tiffURLs = try iconSizes.map { size in
    let tiffURL = temporaryDirectory.appendingPathComponent("icon-\(size).tiff")
    try writeResizedTIFF(
        source: source,
        size: size,
        to: tiffURL
    )
    return tiffURL
}

let combinedTIFFURL = temporaryDirectory.appendingPathComponent("RepoDesk.tiff")
try run(
    "/usr/bin/tiffutil",
    arguments: ["-catnosizecheck"] + tiffURLs.map(\.path) + ["-out", combinedTIFFURL.path]
)
try run(
    "/usr/bin/tiff2icns",
    arguments: [combinedTIFFURL.path, outputURL.path]
)
