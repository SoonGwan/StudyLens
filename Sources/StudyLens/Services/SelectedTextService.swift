import AppKit
import ApplicationServices
import Foundation

enum SelectedTextError: LocalizedError, Equatable {
    case permissionDenied, noFocusedApplication, noSelection, secureInput, selectionTooLong

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "접근성 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 StudyLens를 허용해 주세요. 업데이트 후에는 항목을 다시 등록하고 앱을 재실행해야 할 수 있습니다."
        case .noFocusedApplication:
            return "텍스트가 있는 앱을 클릭한 뒤 내용을 드래그하고 선택 텍스트 단축키를 눌러 주세요."
        case .noSelection:
            return "선택 텍스트를 읽지 못했습니다. 텍스트를 다시 드래그한 뒤 단축키를 눌러 주세요. 지원하지 않는 앱이나 이미지 속 글자는 영역 캡처를 사용하세요."
        case .secureInput:
            return "비밀번호 등 보안 입력 영역은 읽지 않습니다. 일반 학습 텍스트를 선택해 주세요."
        case .selectionTooLong:
            return "선택한 내용이 너무 깁니다. 30,000자 이하로 나누어 선택해 주세요."
        }
    }
}

/// Never sends Copy keystrokes, reads the clipboard, or substitutes the whole page.
@MainActor
final class SelectedTextService {
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init() {
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

    private func remember(_ application: NSRunningApplication?) {
        guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular, !application.isTerminated else { return }
        lastExternalApplication = application
    }

    func readSelectedText(promptForPermission: Bool = true) async throws -> String {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForPermission] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw SelectedTextError.permissionDenied }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        let source = front?.processIdentifier == ownPID ? lastExternalApplication : front
        guard let source, !source.isTerminated, source.processIdentifier != ownPID else {
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
               active.processIdentifier != ownPID, active.processIdentifier != source.processIdentifier {
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

protocol SelectionAccessibilityClient {
    associatedtype Element: Hashable
    func focusedElement(in application: Element) -> Element?
    func focusedWindow(in application: Element) -> Element?
    func parent(of element: Element) -> Element?
    func children(of element: Element) -> [Element]
    func selectedText(of element: Element) throws -> String?
    func isSecure(_ element: Element) -> Bool
    func isHidden(_ element: Element) -> Bool
}

struct SelectionResolver<Client: SelectionAccessibilityClient> {
    let client: Client
    var maxNodes = 400
    var timeBudget: TimeInterval = 0.8

    func resolve(in application: Client.Element) throws -> String {
        let deadline = Date.timeIntervalSinceReferenceDate + timeBudget
        var ancestors: [Client.Element] = []
        var seen = Set<Client.Element>()
        var current = client.focusedElement(in: application)
        for _ in 0..<12 {
            guard let element = current, seen.insert(element).inserted else { break }
            if client.isSecure(element) { throw SelectedTextError.secureInput }
            ancestors.append(element)
            if element == application { break }
            current = client.parent(of: element)
        }
        // Check secure ancestors before reading any child value.
        for element in ancestors where !client.isHidden(element) {
            if let text = try normalized(client.selectedText(of: element)) { return text }
        }
        guard let window = client.focusedWindow(in: application) else { throw SelectedTextError.noSelection }
        var queue = [window]
        var traversed = Set<Client.Element>() // Independent from the ancestor walk.
        var index = 0
        while index < queue.count, index < maxNodes, Date.timeIntervalSinceReferenceDate < deadline {
            let element = queue[index]
            index += 1
            guard traversed.insert(element).inserted,
                  !client.isHidden(element), !client.isSecure(element) else { continue }
            if let text = try normalized(client.selectedText(of: element)) { return text }
            let remaining = max(0, maxNodes - queue.count)
            queue.append(contentsOf: client.children(of: element).prefix(remaining))
        }
        throw SelectedTextError.noSelection
    }

    private func normalized(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard value.utf16.count <= 120_000 else { throw SelectedTextError.selectionTooLong }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= 30_000 else { throw SelectedTextError.selectionTooLong }
        return trimmed
    }
}

struct AXSelectionElement: Hashable {
    let raw: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }
}

struct NativeSelectionAccessibilityClient: SelectionAccessibilityClient {
    func focusedElement(in application: AXSelectionElement) -> AXSelectionElement? {
        element(application, kAXFocusedUIElementAttribute)
    }
    func focusedWindow(in application: AXSelectionElement) -> AXSelectionElement? {
        element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute)
    }
    func parent(of element: AXSelectionElement) -> AXSelectionElement? { self.element(element, kAXParentAttribute) }
    func children(of element: AXSelectionElement) -> [AXSelectionElement] {
        guard let values = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return values.map { AXSelectionElement(raw: $0) }
    }
    func isSecure(_ element: AXSelectionElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }
    func isHidden(_ element: AXSelectionElement) -> Bool { (attribute(element, "AXHidden") as? Bool) == true }

    func selectedText(of element: AXSelectionElement) throws -> String? {
        if let text = string(attribute(element, kAXSelectedTextAttribute)), !text.isEmpty { return text }
        // Chromium exposes document selections through text markers rather than focused inputs.
        if let markerRange = attribute(element, "AXSelectedTextMarkerRange"),
           let text = string(parameter(element, "AXStringForTextMarkerRange", markerRange)), !text.isEmpty {
            return text
        }
        guard let rawRange = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        let value = rawRange as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length > 0 else { return nil }
        guard range.length <= 120_000 else { throw SelectedTextError.selectionTooLong }
        if let text = string(parameter(element, kAXStringForRangeParameterizedAttribute, value)) { return text }
        // AXValue is read only when an explicit selection range has been provided.
        guard let text = attribute(element, kAXValueAttribute) as? String else { return nil }
        return Self.substring(text, range: range)
    }

    static func substring(_ text: String, range: CFRange) -> String? {
        let value = text as NSString
        guard range.location >= 0, range.length > 0, range.location <= value.length,
              range.length <= value.length - range.location else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }

    /// Request a lazy accessibility tree only from supported apps, restoring prior flags afterwards.
    func requestAccessibility(in application: AXSelectionElement, bundleID: String?) -> () -> Void {
        // Chromium's application role getter bootstraps its native accessibility tree.
        _ = attribute(application, kAXRoleAttribute)
        var changes: [(AXSelectionElement, String)] = []
        func enable(_ target: AXSelectionElement, _ name: String) {
            var writable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(target.raw, name as CFString, &writable) == .success,
                  writable.boolValue, let previous = attribute(target, name) as? Bool, !previous else { return }
            if AXUIElementSetAttributeValue(target.raw, name as CFString, kCFBooleanTrue) == .success {
                changes.append((target, name))
            }
        }
        enable(application, "AXManualAccessibility")
        let chromiumIDs: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
                                        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi"]
        if let bundleID, chromiumIDs.contains(bundleID) {
            enable(application, "AXEnhancedUserInterface")
            if let window = focusedWindow(in: application) { enable(window, "AXEnhancedUserInterface") }
        }
        return {
            for (target, name) in changes.reversed() {
                AXUIElementSetAttributeValue(target.raw, name as CFString, kCFBooleanFalse)
            }
        }
    }

    private func attribute(_ element: AXSelectionElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element.raw, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func parameter(_ element: AXSelectionElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element.raw, name as CFString, argument, &value) == .success else { return nil }
        return value
    }
    private func element(_ element: AXSelectionElement, _ name: String) -> AXSelectionElement? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXSelectionElement(raw: raw as! AXUIElement)
    }
    private func string(_ value: CFTypeRef?) -> String? {
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }
}
