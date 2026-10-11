import AppKit
import ApplicationServices
import Foundation

public struct AXSelectionElement: Hashable {
    public let raw: AXUIElement
    public init(raw: AXUIElement) { self.raw = raw }
    public static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }
}

public struct NativeSelectionAccessibilityClient: SelectionAccessibilityClient {
    public init() {}
    public func focusedElement(in application: AXSelectionElement) -> AXSelectionElement? {
        element(application, kAXFocusedUIElementAttribute)
    }
    public func focusedWindow(in application: AXSelectionElement) -> AXSelectionElement? {
        element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute)
    }
    public func parent(of element: AXSelectionElement) -> AXSelectionElement? { self.element(element, kAXParentAttribute) }
    public func children(of element: AXSelectionElement) -> [AXSelectionElement] {
        guard let values = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return values.map { AXSelectionElement(raw: $0) }
    }
    public func isSecure(_ element: AXSelectionElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }
    public func isHidden(_ element: AXSelectionElement) -> Bool { (attribute(element, "AXHidden") as? Bool) == true }

    public func selectedText(of element: AXSelectionElement) throws -> String? {
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

    public static func substring(_ text: String, range: CFRange) -> String? {
        let value = text as NSString
        guard range.location >= 0, range.length > 0, range.location <= value.length,
              range.length <= value.length - range.location else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }

    /// Request a lazy accessibility tree only from supported apps, restoring prior flags afterwards.
    public func requestAccessibility(in application: AXSelectionElement, bundleID: String?) -> () -> Void {
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
