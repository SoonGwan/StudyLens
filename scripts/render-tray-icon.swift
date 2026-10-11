import AppKit

guard CommandLine.arguments.count == 2,
      let symbol = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "StudyLens"),
      let image = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("Unable to render moon.fill") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
image.draw(in: NSRect(x: 2, y: 2, width: 32, height: 32), from: .zero,
           operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode moon.fill")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
