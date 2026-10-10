// Render the repository's unmodified ResultView using a saved example, no AI request.
// This captures our own NSHostingView, without requesting screen-recording permission.
import AppKit
import SwiftUI

@main
struct RenderResult {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected input text and output PNG paths") }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        app.finishLaunching()
        let model = AppModel()
        model.restoreExplanation(try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))
        let view = ResultView(model: model).environment(\.colorScheme, .light).frame(width: 720, height: 780).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 780)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render result view") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Rendered actual ResultView: \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }
}
