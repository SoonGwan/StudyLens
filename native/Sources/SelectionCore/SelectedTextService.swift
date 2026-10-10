import AppKit
import ApplicationServices
import Foundation

/// Never sends Copy keystrokes, reads the clipboard, or substitutes the whole page.
///
/// `excludedPIDs` replaces the original "own process" check: in the Electron build the helper is a
/// separate process, so both the Electron main process (owner) and the helper itself count as "own app".
@MainActor
public final class SelectedTextService {
    private let excludedPIDs: Set<pid_t>
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    public init(ownerPID: pid_t) {
        excludedPIDs = [ownerPID, ProcessInfo.processInfo.processIdentifier]
        remember(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in self?.remember(application) }
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private func isOwn(_ pid: pid_t) -> Bool { excludedPIDs.contains(pid) }

    private func remember(_ application: NSRunningApplication?) {
        guard let application, !isOwn(application.processIdentifier),
              application.activationPolicy == .regular, !application.isTerminated else { return }
        lastExternalApplication = application
    }

    public func readSelectedText(promptForPermission: Bool = false) async throws -> String {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForPermission] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw SelectedTextError.permissionDenied }
        let front = NSWorkspace.shared.frontmostApplication
        let frontIsOwn = front.map { isOwn($0.processIdentifier) } ?? false
        let source = frontIsOwn ? lastExternalApplication : front
        guard let source, !source.isTerminated, !isOwn(source.processIdentifier) else {
            throw SelectedTextError.noFocusedApplication
        }
        let application = AXSelectionElement(raw: AXUIElementCreateApplication(source.processIdentifier))
        AXUIElementSetMessagingTimeout(application.raw, 0.08)
        let client = NativeSelectionAccessibilityClient()
        let restore = client.requestAccessibility(in: application, bundleID: source.bundleIdentifier)
        defer { restore() }

        // Chrome may debounce accessibility activation for two seconds.
        for attempt in 0..<8 {
            try Task.checkCancellation()
            guard !source.isTerminated else { throw SelectedTextError.noFocusedApplication }
            // Do not collect from a different app if the user switches during the retry.
            if let active = NSWorkspace.shared.frontmostApplication,
               !isOwn(active.processIdentifier), active.processIdentifier != source.processIdentifier {
                throw SelectedTextError.noFocusedApplication
            }
            do {
                return try SelectionResolver(client: client).resolve(in: application)
            } catch SelectedTextError.noSelection {
                if attempt < 7 { try await Task.sleep(nanoseconds: 350_000_000) }
            }
        }
        guard AXIsProcessTrusted() else { throw SelectedTextError.permissionDenied }
        throw SelectedTextError.noSelection
    }
}
