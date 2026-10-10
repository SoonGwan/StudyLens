import AppKit
import Combine
import SwiftUI

@main
struct StudyLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

enum StatusItemInteraction {
    static let iconTitle = "●"

    static func shouldToggleMenu(for modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection(.deviceIndependentFlagsMask).contains(.option)
    }
}

enum StatusDot {
    static func image(for status: AppModel.Status) -> NSImage {
        let active = status != .idle
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let color: NSColor
            switch status {
            case .idle: color = .black
            case .selecting, .analyzing: color = .systemOrange
            case .ready: color = .systemGreen
            case .failed: color = .systemRed
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = !active
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusObservation: AnyCancellable?
    private var resultWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()

        statusObservation = model.$status.combineLatest(model.$quickCopyMessage)
            .sink { [weak self] status, message in
                self?.updateStatusItem(for: status, message: message)
            }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openResultFromNotification),
            name: .studyLensOpenResult,
            object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(hideResultFromNotification), name: .studyLensHideResult, object: nil)

        // Explicit local result restore also allows UI verification without another AI request.
        if let argument = CommandLine.arguments.firstIndex(of: "--result-file"),
           CommandLine.arguments.indices.contains(argument + 1),
           let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[argument + 1])),
           data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) {
            model.restoreExplanation(text)
            showResultWindow()
        }
        if CommandLine.arguments.contains("--settings") { showSettingsWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageOnly
        button.font = .systemFont(ofSize: 9, weight: .medium)
        button.setAccessibilityLabel("StudyLens")
        button.setAccessibilityHelp("Option 키를 누른 채 클릭하면 메뉴가 열립니다.")
        statusItem = item
        updateStatusItem(for: model.status)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                model: model,
                openResult: { [weak self] in self?.showResultWindow() },
                openSettings: { [weak self] in self?.showSettingsWindow() }
            )
        )
    }

    private func updateStatusItem(for status: AppModel.Status, message: String? = nil) {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = StatusDot.image(for: status)
        button.contentTintColor = nil
        let description = message ?? status.menuTitle
        button.toolTip = "StudyLens · \(description) · ⌥-클릭으로 메뉴 열기"
        button.setAccessibilityValue(description)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        guard StatusItemInteraction.shouldToggleMenu(for: modifiers) else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    @objc private func openResultFromNotification() {
        showResultWindow()
    }

    @objc private func hideResultFromNotification() {
        popover.performClose(nil)
        resultWindowController?.window?.orderOut(nil)
    }

    private func showResultWindow() {
        popover.performClose(nil)
        if resultWindowController == nil {
            resultWindowController = makeWindowController(
                title: "StudyLens 학습 설명",
                contentSize: NSSize(width: 720, height: 680),
                rootView: ResultView(model: model)
            )
        }
        present(resultWindowController)
    }

    private func showSettingsWindow() {
        popover.performClose(nil)
        if settingsWindowController == nil {
            settingsWindowController = makeWindowController(
                title: "StudyLens 설정",
                contentSize: NSSize(width: 600, height: 700),
                rootView: SettingsView(model: model)
            )
        }
        present(settingsWindowController)
    }

    private func makeWindowController<Content: View>(
        title: String,
        contentSize: NSSize,
        rootView: Content
    ) -> NSWindowController {
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(contentSize)
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }

    private func present(_ controller: NSWindowController?) {
        guard let controller else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
