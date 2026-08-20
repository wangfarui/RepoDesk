import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: prepare-app-icon <input.png> <output.png>\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: inputURL),
      let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: 1_024,
          pixelsHigh: 1_024,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
      ) else {
    throw CocoaError(.fileReadCorruptFile)
}

NSGraphicsContext.saveGraphicsState()
defer { NSGraphicsContext.restoreGraphicsState() }
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1_024, height: 1_024).fill()
NSBezierPath(
    roundedRect: NSRect(x: 16, y: 16, width: 992, height: 992),
    xRadius: 190,
    yRadius: 190
).addClip()
image.draw(
    in: NSRect(x: 0, y: 0, width: 1_024, height: 1_024),
    from: NSRect(origin: .zero, size: image.size),
    operation: .copy,
    fraction: 1
)

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
}
try png.write(to: outputURL, options: .atomic)
