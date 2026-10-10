import AppKit
import Carbon
import Foundation

struct HotKeyConfiguration: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let captureDefault = HotKeyConfiguration(
        keyCode: 25, // 9
        modifiers: UInt32(cmdKey | shiftKey)
    )
    static let textDefault = HotKeyConfiguration(
        keyCode: 29, // 0
        modifiers: UInt32(cmdKey | shiftKey)
    )
    static let codeDefault = HotKeyConfiguration(keyCode: 28, modifiers: UInt32(cmdKey | shiftKey)) // 8

    static func load(prefix: String, fallback: HotKeyConfiguration) -> HotKeyConfiguration {
        let defaults = UserDefaults.standard
        let keyCodeKey = "\(prefix)HotKeyCode"
        let modifiersKey = "\(prefix)HotKeyModifiers"
        guard defaults.object(forKey: keyCodeKey) != nil else { return fallback }
        return HotKeyConfiguration(
            keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
    }

    func save(prefix: String) {
        UserDefaults.standard.set(Int(keyCode), forKey: "\(prefix)HotKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "\(prefix)HotKeyModifiers")
    }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += KeyCodeNames.name(for: keyCode)
        return result
    }

    static func from(event: NSEvent) -> HotKeyConfiguration? {
        var carbonModifiers: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // 전역 단축키는 Command, Option, Control 중 하나를 반드시 포함한다.
        guard carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        return HotKeyConfiguration(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
    }
}

final class HotKeyService {
    var onCaptureTrigger: (() -> Void)?
    var onTextTrigger: (() -> Void)?
    var onCodeTrigger: (() -> Void)?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    if identifier.id == 1 { service.onCaptureTrigger?() }
                    if identifier.id == 2 { service.onTextTrigger?() }
                    if identifier.id == 3 { service.onCodeTrigger?() }
                }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &handlerRef
        )
    }

    deinit {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func register(capture: HotKeyConfiguration, text: HotKeyConfiguration, code: HotKeyConfiguration) -> [String] {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        var errors: [String] = []
        for (configuration, id, title) in [(capture, UInt32(1), "영역 캡처"), (text, UInt32(2), "선택 텍스트"), (code, UInt32(3), "코드 바로 복사")] {
            if !registerOne(configuration, id: id) {
                errors.append("\(title) 단축키 \(configuration.displayName)를 등록하지 못했습니다. 다른 조합을 설정해 주세요.")
            }
        }
        return errors
    }

    private func registerOne(_ configuration: HotKeyConfiguration, id: UInt32) -> Bool {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: fourCharCode("STDY"), id: id)
        let status = RegisterEventHotKey(
            configuration.keyCode, configuration.modifiers, identifier,
            GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else { return false }
        hotKeyRefs.append(reference)
        return true
    }
}

private func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}

enum KeyCodeNames {
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
        17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=",
        25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U",
        33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "Space",
        36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
