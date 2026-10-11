import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Expected tray PNG path") }

func workBadge() -> NSImage {
    // Focus's portrait ID badge is not exposed as a public SF Symbol.
    NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
        let path = NSBezierPath(roundedRect: NSRect(x: 4, y: 1, width: 16, height: 22), xRadius: 3, yRadius: 3)
        path.append(NSBezierPath(roundedRect: NSRect(x: 8, y: 19, width: 8, height: 2), xRadius: 1, yRadius: 1))
        path.appendOval(in: NSRect(x: 9, y: 10, width: 6, height: 6))
        path.move(to: NSPoint(x: 7, y: 5))
        path.curve(to: NSPoint(x: 12, y: 10), controlPoint1: NSPoint(x: 7, y: 8), controlPoint2: NSPoint(x: 9, y: 10))
        path.curve(to: NSPoint(x: 17, y: 5), controlPoint1: NSPoint(x: 15, y: 10), controlPoint2: NSPoint(x: 17, y: 8))
        path.close()
        path.windingRule = .evenOdd
        NSColor.black.setFill()
        path.fill()
        return true
    }
}

func render(_ name: String, to destination: URL, pixels: Int = 36) throws {
let symbol = name == "focus-work" ? workBadge() : NSImage(systemSymbolName: name, accessibilityDescription: nil)
guard let image = name == "focus-work" ? symbol : symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("Unable to render \(name)") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let canvas = CGFloat(pixels)
let scale = min(canvas * 8 / 9 / image.size.width, canvas * 8 / 9 / image.size.height)
let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
image.draw(in: NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2,
                     width: size.width, height: size.height), from: .zero,
           operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode \(name)")
}
try png.write(to: destination)
}

let trayURL = URL(fileURLWithPath: CommandLine.arguments[1])
try render("moon.fill", to: trayURL)
for (key, name) in [("moon", "moon.fill"), ("person", "person.fill"),
                    ("work", "focus-work"), ("bed", "bed.double.fill"),
                    ("reduce", "atom")] {
    try render(name, to: trayURL.deletingLastPathComponent().appendingPathComponent("focus-\(key).png"), pixels: 72)
}
